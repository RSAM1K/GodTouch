import Foundation
import Network

/// Tiny HTTP server for a PAC file — same idea as zapret-macos-easy:
/// only listed domains go through the DPI SOCKS proxy, everything else is DIRECT.
final class PACServer {
    let port: UInt16 = 9877
    private var listener: NWListener?
    private var pac = Data()

    var url: String { "http://127.0.0.1:\(port)/zapret.pac" }

    func start(pacScript: String) throws {
        stop()
        pac = Data(pacScript.utf8)
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] conn in
            self?.serve(conn)
        }
        l.start(queue: .global(qos: .utility))
        listener = l
        Thread.sleep(forTimeInterval: 0.15)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [pac] _, _, _, _ in
            var header = "HTTP/1.1 200 OK\r\n"
            header += "Content-Type: application/x-ns-proxy-autoconfig\r\n"
            header += "Content-Length: \(pac.count)\r\n"
            header += "Connection: close\r\n\r\n"
            var payload = Data(header.utf8)
            payload.append(pac)
            conn.send(content: payload, completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }
}
