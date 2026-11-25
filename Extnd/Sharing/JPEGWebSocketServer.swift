import Foundation
import Network

@MainActor
final class JPEGWebSocketServer {
    private struct Client {
        let connection: NWConnection
        var lastFrame = 0
        var waitingForFrame = false
        var sending = false
    }

    private let listener: NWListener
    private var clients: [ObjectIdentifier: Client] = [:]
    private var latestFrame: Data?
    private var frameNumber = 0
    var port: NWEndpoint.Port? { listener.port }

    init(address: String, origin: String, token: String) throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: .any)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.setClientRequestHandler(.main) { protocols, headers in
            let matchesOrigin = headers.contains {
                $0.name.caseInsensitiveCompare("Origin") == .orderedSame && $0.value == origin
            }
            guard matchesOrigin, protocols.contains(token) else {
                return .init(status: .reject, subprotocol: nil)
            }
            return .init(status: .accept, subprotocol: token)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        listener = try NWListener(using: parameters)
    }

    func start(
        onReady: @escaping @MainActor @Sendable () -> Void,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) {
        listener.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready: onReady()
                case .waiting(let error), .failed(let error): onFailure(error.localizedDescription)
                default: break
                }
            }
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
        for client in clients.values { client.connection.cancel() }
        clients.removeAll()
        latestFrame = nil
    }

    func update(_ frame: Data) {
        latestFrame = frame
        frameNumber += 1
        for id in Array(clients.keys) { sendLatestFrame(to: id) }
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < 8 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        clients[id] = Client(connection: connection)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.receive(from: id)
                case .failed, .cancelled: self?.close(id)
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive(from id: ObjectIdentifier) {
        guard let connection = clients[id]?.connection else { return }
        connection.receiveMessage { [weak self] data, context, _, error in
            let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata)?.opcode
            Task { @MainActor in
                guard let self, let client = self.clients[id] else { return }
                guard error == nil else { self.close(id); return }
                switch opcode {
                case .text where data == Data("next".utf8) && !client.waitingForFrame:
                    self.clients[id]?.waitingForFrame = true
                    self.sendLatestFrame(to: id)
                case .ping, .pong:
                    break
                default:
                    self.close(id)
                    return
                }
                self.receive(from: id)
            }
        }
    }

    private func sendLatestFrame(to id: ObjectIdentifier) {
        guard let frame = latestFrame, var client = clients[id], client.waitingForFrame,
              !client.sending, client.lastFrame != frameNumber else { return }
        client.lastFrame = frameNumber
        client.waitingForFrame = false
        client.sending = true
        clients[id] = client
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "jpeg", metadata: [metadata])
        client.connection.send(content: frame, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, self.clients[id] != nil else { return }
                if error != nil {
                    self.close(id)
                } else {
                    self.clients[id]?.sending = false
                    self.sendLatestFrame(to: id)
                }
            }
        })
    }

    private func close(_ id: ObjectIdentifier) {
        clients.removeValue(forKey: id)?.connection.cancel()
    }
}
