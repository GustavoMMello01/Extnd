import Darwin
import Foundation
import Network

@MainActor
final class LocalScreenServer {
    private let listener: NWListener
    private let address: String
    private let token = UUID().uuidString.lowercased()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var streams: [ObjectIdentifier: StreamClient] = [:]
    private var latestFrame: Data?
    private var latestPart: Data?
    private var frameNumber = 0

    private struct StreamClient {
        var sentFrame = 0
        var isSending = false
    }
    var onReady: ((URL) -> Void)?
    var onFailure: ((String) -> Void)?

    init(address: String) throws {
        self.address = address
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
        var part = Data("Content-Type: image/jpeg\r\nContent-Length: \(frame.count)\r\n\r\n".utf8)
        part.append(frame)
        part.append(Data("\r\n--extnd-frame\r\n".utf8))
        latestPart = part
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
                onFailure?("O servidor não informou um endereço.")
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
        let path = parts.count == 3 && parts[0] == "GET" ? parts[1].split(separator: "?").first : nil
        switch path {
        case "/\(token)/":
            send(connection, status: "200 OK", type: "text/html; charset=utf-8", body: Data(Self.page.utf8))
        case "/\(token)/screen.mjpeg":
            startStream(connection)
        case "/\(token)/frame.jpg":
            if let latestFrame {
                send(connection, status: "200 OK", type: "image/jpeg", body: latestFrame)
            } else {
                send(connection, status: "503 Service Unavailable")
            }
        default:
            send(connection, status: "404 Not Found")
        }
    }

    private func startStream(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        streams[id] = StreamClient(isSending: true)
        let headers = Data((
            "HTTP/1.0 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=extnd-frame\r\n" +
            "Cache-Control: no-store\r\nConnection: close\r\n\r\n--extnd-frame\r\n"
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
        client.sentFrame = frameNumber
        client.isSending = true
        streams[id] = client
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

    private static let page = """
    <!doctype html>
    <html lang="pt-BR">
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Extnd</title>
    <style>
    body { margin:0; background:#111; color:#eee; font:16px -apple-system,sans-serif; text-align:center }
    img { position:absolute; top:0; left:0; width:100%; height:100%; object-fit:contain }
    p { position:relative; margin:32px 12px; pointer-events:none }
    a { position:absolute; bottom:10px; right:10px; color:white; background:#222; padding:8px }
    </style>
    <img id="screen" alt="Tela estendida do Mac" hidden>
    <p id="status" role="status">Aguardando a tela do Mac…</p>
    <a id="mode" href="?compat=1">Modo compatível</a>
    <script>
    (function () {
      var screen = document.getElementById('screen');
      var status = document.getElementById('status');
      var mode = document.getElementById('mode');
      if (location.search !== '?compat=1') {
        screen.hidden = false;
        screen.onload = function () { status.hidden = true; };
        screen.onerror = function () {
          status.textContent = 'A transmissão foi interrompida. Recarregue a página ou tente o modo compatível.';
          status.hidden = false;
        };
        screen.src = 'screen.mjpeg';
        return;
      }
      mode.href = './';
      mode.textContent = 'Modo rápido';
      function next() {
        var frame = new Image();
        frame.onload = function () {
          frame.id = 'screen';
          frame.alt = screen.alt;
          screen.parentNode.replaceChild(frame, screen);
          screen = frame;
          status.hidden = true;
          setTimeout(next, 85);
        };
        frame.onerror = function () {
          status.textContent = 'Aguardando a tela do Mac…';
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
