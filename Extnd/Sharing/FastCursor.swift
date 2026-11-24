import CoreGraphics
import Foundation
import Network

@MainActor
final class FastCursor {
    var viewerReady = false
    var hidesVideoCursor = false

    private let connection: NWConnection
    private var sampling: Task<Void, Never>?
    private var lastPosition: Position?
    private var lastSent: UInt64 = 0
    private var sequence: UInt32 = 0

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        connection.start(queue: .main)
    }

    func start(displayID: CGDirectDisplayID) {
        sampling = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample(displayID: displayID)
                do { try await Task.sleep(for: .microseconds(8_333)) } catch { return }
            }
        }
    }

    func stop() {
        sampling?.cancel()
        sampling = nil
        connection.cancel()
    }

    private func sample(displayID: CGDirectDisplayID) {
        let bounds = CGDisplayBounds(displayID)
        let point = CGEvent(source: nil)?.location
        let position = Position(point: point, bounds: bounds, active: hidesVideoCursor)
        let now = DispatchTime.now().uptimeNanoseconds
        guard position != lastPosition || now - lastSent >= 200_000_000 else { return }
        lastPosition = position
        lastSent = now
        sequence &+= 1
        send(position.packet(sequence: sequence))
    }

    func send(_ packet: Data) {
        connection.send(content: packet, completion: .idempotent)
    }

    struct Position: Equatable {
        let x: UInt16
        let y: UInt16
        let visible: Bool
        let active: Bool

        init(point: CGPoint?, bounds: CGRect, active: Bool) {
            self.active = active
            if let point, !bounds.isEmpty, bounds.contains(point) {
                x = UInt16((point.x - bounds.minX) / bounds.width * CGFloat(UInt16.max))
                y = UInt16((point.y - bounds.minY) / bounds.height * CGFloat(UInt16.max))
                visible = true
            } else {
                x = 0
                y = 0
                visible = false
            }
        }

        func packet(sequence: UInt32) -> Data {
            let flags: UInt8 = (active ? 1 : 0) | (visible ? 2 : 0)
            var packet = Data([flags])
            withUnsafeBytes(of: sequence.bigEndian) { packet.append(contentsOf: $0) }
            withUnsafeBytes(of: x.bigEndian) { packet.append(contentsOf: $0) }
            withUnsafeBytes(of: y.bigEndian) { packet.append(contentsOf: $0) }
            return packet
        }
    }
}
