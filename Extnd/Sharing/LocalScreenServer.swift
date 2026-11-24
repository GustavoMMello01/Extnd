import Darwin
import Foundation
import Network

@MainActor
final class LocalScreenServer {
    private let listener: NWListener
    private let address: String
    private let webRTC: Bool
    private let token = UUID().uuidString.lowercased()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var streams: [ObjectIdentifier: StreamClient] = [:]
    private var latestFrame: Data?
    private var latestPart: Data?
    private var frameNumber = 0
    private var latestIsKeyFrame = false
    private var encodedBytes = 0
    private let startedAt = ProcessInfo.processInfo.systemUptime
    var showsStatistics = false
    var showsBlackBorder = true
    var showsTiming = false
    var peakLimitStatus: H264Encoder.PeakLimitStatus = .off
    private var captureTiming = TimingWindow()
    private var encodingTiming = TimingWindow()
    private var handoffTiming = TimingWindow()
    private var latestEncodedAt: UInt64?
    private var lastTimedHandoffFrame = 0

    private struct Timings: Encodable {
        let capture: TimingWindow.Summary?
        let encode: TimingWindow.Summary?
        let handoff: TimingWindow.Summary?
        let peakLimit: H264Encoder.PeakLimitStatus
    }

    private struct Statistics: Encodable {
        let enabled: Bool
        let blackBorder: Bool
        let codec: String?
        let frames: Int?
        let encodedBytes: Int?
        let seconds: TimeInterval?
        let timings: Timings?
    }

    private struct StreamClient {
        var sentFrame = 0
        var isSending = false
    }
    var onReady: ((URL) -> Void)?
    var onViewerReady: ((URL) -> Void)?
    var onCursorPort: ((UInt16) -> Void)?
    var onCursorReady: ((Bool) -> Void)?
    var onKeyFrameRequest: (() -> Void)?
    var onFailure: ((String) -> Void)?

    init(address: String, webRTC: Bool = false) throws {
        self.address = address
        self.webRTC = webRTC
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        streams.removeAll()
        latestFrame = nil
        latestPart = nil
    }

    func update(frame: Data) {
        latestFrame = frame
        frameNumber += 1
        encodedBytes += frame.count
        var part = Data("Content-Type: image/jpeg\r\nContent-Length: \(frame.count)\r\n\r\n".utf8)
        part.append(frame)
        part.append(Data("\r\n--extnd-frame\r\n".utf8))
        publish(part: part, isKeyFrame: true)
    }

    func update(h264 frame: H264Frame) {
        frameNumber += 1
        encodedBytes += frame.bytes.count
        let now = DispatchTime.now().uptimeNanoseconds
        if let age = frame.captureAgeMs { captureTiming.record(age, at: now) }
        encodingTiming.record(frame.encodingMs, at: now)
        latestEncodedAt = frame.readyAt
        publish(part: frame.wireData, isKeyFrame: frame.isKeyFrame)
    }

    private func publish(part: Data, isKeyFrame: Bool) {
        latestPart = part
        latestIsKeyFrame = isKeyFrame
        for id in Array(streams.keys) {
            sendLatestFrame(to: id)
        }
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port,
               let url = URL(string: "http://\(address):\(port.rawValue)/\(token)/") {
                onReady?(url)
            } else {
                onFailure?("The server did not provide an address.")
            }
        case .waiting(let error), .failed(let error):
            onFailure?(error.localizedDescription)
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.start(queue: .main)
        receive(connection, data: Data())
        Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(5))
            if let connection, self?.streams[id] == nil { self?.close(connection) }
        }
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] chunk, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[ObjectIdentifier(connection)] != nil else { return }
                var request = data
                if let chunk { request.append(chunk) }
                if request.count > 8192 || error != nil {
                    self.close(connection)
                } else if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.respond(to: connection, request: request)
                } else if complete {
                    self.close(connection)
                } else {
                    self.receive(connection, data: request)
                }
            }
        }
    }

    private func respond(to connection: NWConnection, request: Data) {
        let line = String(decoding: request.prefix(while: { $0 != 13 }), as: UTF8.self)
        let parts = line.split(separator: " ")
        guard parts.count == 3, let path = parts[1].split(separator: "?").first else {
            send(connection, status: "400 Bad Request")
            return
        }
        if parts[0] == "POST", webRTC, isLocalPeer(connection), handleRelayControl(path, connection: connection) {
            return
        }
        guard parts[0] == "GET" else {
            send(connection, status: "404 Not Found")
            return
        }
        switch path {
        case "/\(token)/" where !webRTC:
            send(connection, status: "200 OK", type: "text/html; charset=utf-8", body: Data(Self.page.utf8))
        case "/\(token)/screen.mjpeg" where !webRTC:
            startStream(connection)
        case "/\(token)/h264" where webRTC && isLocalPeer(connection):
            startStream(connection)
        case "/\(token)/stats" where !webRTC || isLocalPeer(connection):
            sendStatistics(to: connection)
        case "/\(token)/stats.js" where !webRTC || isLocalPeer(connection):
            send(connection, status: "200 OK", type: "application/javascript; charset=utf-8",
                 body: Data(Self.statisticsScript.utf8))
        case "/\(token)/favicon.png", "/\(token)/apple-touch-icon.png":
            if (!webRTC || isLocalPeer(connection)),
               let name = path.split(separator: "/").last,
               let icon = Self.viewerIcons[String(name)] {
                send(connection, status: "200 OK", type: "image/png", body: icon)
            } else {
                send(connection, status: "404 Not Found")
            }
        case "/\(token)/frame.jpg" where !webRTC:
            if let latestFrame {
                send(connection, status: "200 OK", type: "image/jpeg", body: latestFrame)
            } else {
                send(connection, status: "503 Service Unavailable")
            }
        default:
            send(connection, status: "404 Not Found")
        }
    }

    private func handleRelayControl(_ path: Substring, connection: NWConnection) -> Bool {
        if path == "/\(token)/keyframe" {
            onKeyFrameRequest?()
            send(connection, status: "204 No Content")
            return true
        }
        if path == "/\(token)/cursor-on" || path == "/\(token)/cursor-off" {
            onCursorReady?(path.hasSuffix("/cursor-on"))
            send(connection, status: "204 No Content")
            return true
        }
        let segments = path.split(separator: "/")
        guard (4...5).contains(segments.count), segments[0] == token, segments[1] == "viewer",
              let port = UInt16(segments[2]), port > 0,
              segments[3].utf8.count == 32, segments[3].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let url = URL(string: "http://\(address):\(port)/\(segments[3])/") else { return false }
        if segments.count == 5 {
            guard let cursorPort = UInt16(segments[4]), cursorPort > 0 else { return false }
            onCursorPort?(cursorPort)
        }
        onViewerReady?(url)
        send(connection, status: "204 No Content")
        return true
    }

    private func sendStatistics(to connection: NWConnection) {
        let now = DispatchTime.now().uptimeNanoseconds
        let timings = showsStatistics && showsTiming && webRTC ? Timings(
            capture: captureTiming.summarize(at: now),
            encode: encodingTiming.summarize(at: now),
            handoff: handoffTiming.summarize(at: now),
            peakLimit: peakLimitStatus
        ) : nil
        let statistics = Statistics(
            enabled: showsStatistics,
            blackBorder: showsBlackBorder,
            codec: showsStatistics ? (webRTC ? "H.264" : "MJPEG") : nil,
            frames: showsStatistics ? frameNumber : nil,
            encodedBytes: showsStatistics ? encodedBytes : nil,
            seconds: showsStatistics ? ProcessInfo.processInfo.systemUptime - startedAt : nil,
            timings: timings
        )
        guard let body = try? JSONEncoder().encode(statistics) else {
            send(connection, status: "500 Internal Server Error")
            return
        }
        send(connection, status: "200 OK", type: "application/json", body: body)
    }

    private func isLocalPeer(_ connection: NWConnection) -> Bool {
        guard case .hostPort(let host, _) = connection.endpoint else { return false }
        return host == NWEndpoint.Host(address)
    }

    private func startStream(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        streams[id] = StreamClient(isSending: true)
        let contentType = webRTC ? "application/octet-stream" : "multipart/x-mixed-replace; boundary=extnd-frame"
        let firstBoundary = webRTC ? "" : "--extnd-frame\r\n"
        let headers = Data((
            "HTTP/1.0 200 OK\r\nContent-Type: \(contentType)\r\n" +
            "Cache-Control: no-store\r\nConnection: close\r\n\r\n" + firstBoundary
        ).utf8)
        sendStreamData(headers, to: connection)

        // Watch for a viewer closing its tab while the desktop is idle.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
            Task { @MainActor in self?.close(connection) }
        }
    }

    private func sendLatestFrame(to id: ObjectIdentifier) {
        guard let connection = connections[id], let part = latestPart, var client = streams[id],
              !client.isSending, client.sentFrame != frameNumber else { return }
        if webRTC, !latestIsKeyFrame, client.sentFrame == 0 || client.sentFrame != frameNumber - 1 {
            return
        }
        client.sentFrame = frameNumber
        client.isSending = true
        streams[id] = client
        if let encodedAt = latestEncodedAt, lastTimedHandoffFrame != frameNumber {
            lastTimedHandoffFrame = frameNumber
            let now = DispatchTime.now().uptimeNanoseconds
            handoffTiming.record(TimingWindow.milliseconds(from: encodedAt, to: now), at: now)
        }
        sendStreamData(part, to: connection)
    }

    private func sendStreamData(_ data: Data, to connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, self.streams[id] != nil else { return }
                if error != nil {
                    self.close(connection)
                } else {
                    self.streams[id]?.isSending = false
                    self.sendLatestFrame(to: id)
                }
            }
        })
    }

    private func send(_ connection: NWConnection, status: String, type: String = "text/plain", body: Data = Data()) {
        var response = Data((
            "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n" +
            "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        ).utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(connection) }
        })
    }

    private func close(_ connection: NWConnection) {
        streams.removeValue(forKey: ObjectIdentifier(connection))
        if connections.removeValue(forKey: ObjectIdentifier(connection)) != nil {
            connection.cancel()
        }
    }

    static func localAddresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        var addresses: [String] = []
        for interface in sequence(first: interfaces, next: { $0.pointee.ifa_next }) {
            let entry = interface.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == AF_INET,
                  entry.ifa_flags & UInt32(IFF_UP) != 0,
                  String(cString: entry.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(decoding: host.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
                if !addresses.contains(value) { addresses.append(value) }
            }
        }
        return addresses
    }

    private static let statisticsScript = """
    (function () {
      function rate(now, previous, seconds) {
        if (typeof now !== 'number' || typeof previous !== 'number' || seconds <= 0 || now < previous) return null;
        return (now - previous) / seconds;
      }

      function intervalMeanMs(sum, previousSum, count, previousCount) {
        if (typeof sum !== 'number' || typeof previousSum !== 'number' ||
            typeof count !== 'number' || typeof previousCount !== 'number' ||
            count <= previousCount || sum < previousSum) return null;
        return 1000 * (sum - previousSum) / (count - previousCount);
      }

      window.startStreamStatistics = function (getPeer, video, getPicture) {
        var panel = document.getElementById('stats');
        var frame = document.getElementById('stream-frame');
        var pictureRatio = 0;
        var previousSource;
        var previousReceiver;
        var previousPeer;
        var sampleNumber = 0;

        function layoutFrame() {
          if (!frame) return;
          var picture = getPicture ? getPicture() : video;
          if (!picture) return;
          var width = picture.videoWidth || picture.naturalWidth;
          var height = picture.videoHeight || picture.naturalHeight;
          if (width && height) pictureRatio = width / height;
          if (frame.hidden) return;

          var rect = picture.getBoundingClientRect();
          if (!rect.width || !rect.height) return;
          var fittedWidth = pictureRatio ? Math.min(rect.width, rect.height * pictureRatio) : rect.width;
          var fittedHeight = pictureRatio ? fittedWidth / pictureRatio : rect.height;
          frame.style.left = (rect.left + (rect.width - fittedWidth) / 2) + 'px';
          frame.style.top = (rect.top + (rect.height - fittedHeight) / 2) + 'px';
          frame.style.width = fittedWidth + 'px';
          frame.style.height = fittedHeight + 'px';
        }

        window.addEventListener('resize', layoutFrame);
        if (video) {
          video.addEventListener('loadedmetadata', layoutFrame);
          video.addEventListener('resize', layoutFrame);
        }

        function render(source, inbound, time) {
          var sourceSeconds = previousSource ? source.seconds - previousSource.seconds : 0;
          var sourceFPS = rate(source.frames, previousSource && previousSource.frames, sourceSeconds);
          var sourceBytes = rate(source.encodedBytes, previousSource && previousSource.encodedBytes, sourceSeconds);
          var frames = inbound && typeof inbound.framesDecoded === 'number'
            ? inbound.framesDecoded
            : video && video.webkitDecodedFrameCount;
          var bytes = inbound && inbound.bytesReceived;
          var receiveSeconds = previousReceiver ? (time - previousReceiver.time) / 1000 : 0;
          var fps = rate(frames, previousReceiver && previousReceiver.frames, receiveSeconds);
          var receiveBytes = rate(bytes, previousReceiver && previousReceiver.bytes, receiveSeconds);
          if (fps === null && inbound && typeof inbound.framesPerSecond === 'number') fps = inbound.framesPerSecond;
          previousSource = source;
          var bufferDelay = intervalMeanMs(inbound && inbound.jitterBufferDelay,
            previousReceiver && previousReceiver.bufferDelay, inbound && inbound.jitterBufferEmittedCount,
            previousReceiver && previousReceiver.bufferFrames);
          var decodeDelay = intervalMeanMs(inbound && inbound.totalDecodeTime,
            previousReceiver && previousReceiver.decodeDelay, inbound && inbound.framesDecoded,
            previousReceiver && previousReceiver.decodedFrames);
          previousReceiver = {
            time: time, frames: frames, bytes: bytes,
            bufferDelay: inbound && inbound.jitterBufferDelay, bufferFrames: inbound && inbound.jitterBufferEmittedCount,
            decodeDelay: inbound && inbound.totalDecodeTime, decodedFrames: inbound && inbound.framesDecoded
          };

          var details = [source.codec];
          if (video && video.videoWidth) details.push(video.videoWidth + ' × ' + video.videoHeight);
          if (fps !== null) details.push(Math.round(fps) + ' fps decoded');
          else if (sourceFPS !== null) details.push(Math.round(sourceFPS) + ' fps encoded');
          if (receiveBytes !== null) details.push((receiveBytes * 8 / 1000000).toFixed(2) + ' Mb/s received');
          else if (sourceBytes !== null) details.push((sourceBytes * 8 / 1000000).toFixed(2) + ' Mb/s encoded');
          if (inbound && typeof inbound.packetsLost === 'number') {
            details.push(Math.max(0, inbound.packetsLost) + ' packets lost');
          }
          var lines = [details.join(' · ')];
          if (source.timings) {
            var stages = [];
            function addTiming(label, timing) {
              if (timing) stages.push(label + ' ' + timing.p50.toFixed(1) + '/' + timing.p95.toFixed(1) + ' ms');
            }
            addTiming('Capture', source.timings.capture);
            addTiming('Encode', source.timings.encode);
            addTiming('Handoff', source.timings.handoff);
            addTiming('Relay', source.relayTiming);
            if (stages.length) lines.push('p50/p95 · ' + stages.join(' · '));
            var receiver = [];
            if (bufferDelay !== null) receiver.push('Buffer avg ' + bufferDelay.toFixed(1) + ' ms');
            if (decodeDelay !== null) receiver.push('Decode avg ' + decodeDelay.toFixed(1) + ' ms');
            if (source.timings.peakLimit === 'configured') receiver.push('Peak limit configured');
            if (source.timings.peakLimit === 'unavailable') receiver.push('Peak limit unavailable');
            if (receiver.length) lines.push(receiver.join(' · '));
          }
          panel.textContent = lines.join('\\n');
          panel.hidden = false;
        }

        function reset() {
          panel.hidden = true;
          previousSource = undefined;
          previousReceiver = undefined;
          previousPeer = undefined;
        }

        function tick() {
          var request = new XMLHttpRequest();
          request.open('GET', 'stats');
          request.timeout = 1500;
          request.onloadend = function () {
            var sample = ++sampleNumber;
            setTimeout(tick, 1000);
            var source;
            try { if (request.status === 200) source = JSON.parse(request.responseText); } catch (error) {}
            if (frame && source && typeof source.blackBorder === 'boolean' && frame.hidden === source.blackBorder) {
              frame.hidden = !source.blackBorder;
              layoutFrame();
            }
            if (!source || !source.enabled) {
              reset();
            } else {
              var peer = getPeer && getPeer();
              if (peer !== previousPeer) previousReceiver = undefined;
              previousPeer = peer;
              var time = performance.now();
              if (peer && typeof peer.getStats === 'function') {
                Promise.resolve().then(function () {
                  return peer.getStats();
                }).then(function (entries) {
                  var inbound;
                  entries.forEach(function (entry) {
                    if (entry.type === 'inbound-rtp' && (entry.kind || entry.mediaType) === 'video') inbound = entry;
                  });
                  if (sampleNumber === sample) render(source, inbound, time);
                }).catch(function () {
                  if (sampleNumber === sample) render(source, undefined, time);
                });
              } else {
                render(source, undefined, time);
              }
            }
          };
          request.send();
        }
        tick();
        return layoutFrame;
      };
    }());
    """

    private static let viewerIcons: [String: Data] = {
        var icons: [String: Data] = [:]
        for name in ["favicon", "apple-touch-icon"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let data = try? Data(contentsOf: url) {
                icons[name + ".png"] = data
            }
        }
        return icons
    }()

    private static let page = """
    <!doctype html>
    <html lang="en">
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Extnd</title>
    <link rel="icon" type="image/png" sizes="48x48" href="favicon.png">
    <link rel="apple-touch-icon" sizes="180x180" href="apple-touch-icon.png">
    <style>
    body { margin:0; background:#131419; color:#f0f1f4; font:16px -apple-system,sans-serif; text-align:center }
    img { position:absolute; top:0; left:0; width:100%; height:100%; object-fit:contain }
    #stream-frame { position:fixed; top:0; left:0; width:100%; height:100%; box-sizing:border-box; border:2px solid #000; pointer-events:none; z-index:1 }
    #status { z-index:2; position:relative; display:inline-block; margin:24px 12px; padding:9px 12px; background:#22242c; border:1px solid #373a46; border-radius:8px; color:#d1d5df; pointer-events:none }
    #status[hidden] { display:none }
    #mode { z-index:2; position:absolute; bottom:10px; right:10px; color:#c4d3ff; background:#22242c; border-radius:8px; padding:10px 12px; font-size:12px; text-decoration:none }
    #stats { z-index:2; position:absolute; top:8px; right:8px; margin:0; max-width:calc(100% - 32px); padding:3px 6px; border-radius:4px; background:rgba(0,0,0,.44); color:#fff; font-size:11px; line-height:1.3 }
    </style>
    <img id="screen" alt="Extended Mac display" hidden>
    <div id="stream-frame" aria-hidden="true" hidden></div>
    <p id="status" role="status">Waiting for the Mac display…</p>
    <a id="mode" href="?compat=1">Compatibility Mode</a>
    <p id="stats" hidden></p>
    <script src="stats.js"></script>
    <script>
    (function () {
      var screen = document.getElementById('screen');
      var status = document.getElementById('status');
      var mode = document.getElementById('mode');
      var layoutFrame = window.startStreamStatistics
        ? window.startStreamStatistics(null, null, function () { return screen; })
        : function () {};
      if (location.search !== '?compat=1') {
        screen.hidden = false;
        screen.onload = function () { status.hidden = true; layoutFrame(); };
        screen.onerror = function () {
          status.textContent = 'The stream stopped. Reload the page or try Compatibility Mode.';
          status.hidden = false;
        };
        screen.src = 'screen.mjpeg';
        return;
      }
      mode.href = './';
      mode.textContent = 'Fast Mode';
      function next() {
        var frame = new Image();
        frame.onload = function () {
          frame.id = 'screen';
          frame.alt = screen.alt;
          screen.parentNode.replaceChild(frame, screen);
          screen = frame;
          layoutFrame();
          status.hidden = true;
          setTimeout(next, 85);
        };
        frame.onerror = function () {
          status.textContent = 'Waiting for the Mac display…';
          status.hidden = false;
          setTimeout(next, 750);
        };
        frame.src = 'frame.jpg?' + Date.now();
      }
      next();
    }());
    </script>
    </html>
    """
}
