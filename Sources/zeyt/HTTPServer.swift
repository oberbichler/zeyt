import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    /// Parses a complete request, or returns nil if more data is needed.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        guard data.count - end.upperBound >= length else { return nil }
        let body = data[end.upperBound..<end.upperBound + length]

        let components = URLComponents(string: "http://localhost" + start[1])
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }

        return HTTPRequest(method: String(start[0]), path: components?.path ?? "/",
                           query: query, headers: headers, body: Data(body))
    }

    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data

    static func json(_ value: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    static func error(_ message: String, status: Int) -> HTTPResponse {
        .json(["error": message], status: status)
    }

    var data: Data {
        let reason = [200: "OK", 201: "Created", 400: "Bad Request", 401: "Unauthorized",
                      404: "Not Found", 405: "Method Not Allowed"][status] ?? "Status"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// Minimal HTTP/1.1 server bound to 127.0.0.1. Everything runs on the main queue.
@MainActor
final class HTTPServer {
    let port: UInt16
    var handler: (HTTPRequest) -> HTTPResponse = { _ in .error("not ready", status: 404) }
    var onStateChange: (String?) -> Void = { _ in }
    private var listener: NWListener?

    init(port: UInt16) { self.port = port }

    var isRunning: Bool { listener != nil }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: self?.onStateChange(nil)
                    case .failed(let error):
                        self?.stop()
                        let port = self?.port ?? 0
                        if case .posix(.EADDRINUSE) = error {
                            self?.onStateChange("Port \(port) ist schon belegt – läuft zeyt doppelt?")
                        } else {
                            self?.onStateChange("Port \(port): \(error.localizedDescription)")
                        }
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                MainActor.assumeIsolated {
                    conn.start(queue: .main)
                    self?.receive(conn, buffer: Data())
                }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            onStateChange(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { return conn.cancel() }
                var buf = buffer
                if let data { buf.append(data) }
                if let request = HTTPRequest.parse(buf) {
                    let response = self.handler(request)
                    conn.send(content: response.data, completion: .contentProcessed { _ in conn.cancel() })
                } else if done || error != nil || buf.count > 1_000_000 {
                    conn.cancel()
                } else {
                    self.receive(conn, buffer: buf)
                }
            }
        }
    }
}
