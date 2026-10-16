import Foundation

enum HTTPError: LocalizedError {
    case badURL(String)
    case status(Int, String?)
    case decoding(String)
    case unauthorized
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let s): return "Invalid URL: \(s)"
        case .status(let code, let body):
            if let body, !body.isEmpty { return "Server returned \(code): \(body.prefix(200))" }
            return "Server returned HTTP \(code)"
        case .decoding(let s): return "Unexpected response: \(s)"
        case .unauthorized: return "Wrong username or password"
        case .transport(let s): return s
        }
    }
}

/// Thin async HTTP layer shared by every service.
final class HTTPClient: @unchecked Sendable {
    static let shared = HTTPClient()

    let session: URLSession
    let decoder: JSONDecoder

    init(timeout: TimeInterval = 30) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 8
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        decoder = JSONDecoder()
    }

    func data(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("StreamForge/1.0", forHTTPHeaderField: "User-Agent")
        if body != nil, headers["Content-Type"] == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let data: Data
        let response: URLResponse
        do {
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError where error.code == .networkConnectionLost {
                // A pooled keep-alive connection died while the app was suspended (URLSession
                // doesn't retry non-idempotent requests like TorrServer's POST API). Retry once
                // on a fresh connection.
                (data, response) = try await session.data(for: request)
            }
        } catch let error as URLError {
            throw HTTPError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { return data }
        if http.statusCode == 401 || http.statusCode == 403 { throw HTTPError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError.status(http.statusCode, String(data: data, encoding: .utf8))
        }
        return data
    }

    /// Drops pooled keep-alive connections so the next requests open fresh TCP connections
    /// (`URLSession.flush`: "ensures that future requests occur on a new TCP connection").
    /// Called when the app returns from the background, where those sockets may have died.
    func flushConnections() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.flush { continuation.resume() }
        }
    }

    func get<T: Decodable>(_ type: T.Type, _ url: URL, headers: [String: String] = [:], timeout: TimeInterval? = nil) async throws -> T {
        let data = try await data(url, headers: headers, timeout: timeout)
        return try decode(type, data, url: url)
    }

    func send<T: Decodable, B: Encodable>(
        _ type: T.Type, _ url: URL, method: String = "POST", body: B, headers: [String: String] = [:]
    ) async throws -> T {
        let encoded = try JSONEncoder().encode(body)
        let data = try await data(url, method: method, headers: headers, body: encoded)
        return try decode(type, data, url: url)
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data, url: URL? = nil) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let snippet = String(data: data.prefix(160), encoding: .utf8) ?? ""
            throw HTTPError.decoding("\(url?.lastPathComponent ?? "") \(error.localizedDescription) \(snippet)")
        }
    }
}

extension URL {
    /// Builds a URL from a user-entered base ("192.168.1.5:9191", "https://x.y/") plus a path.
    static func normalizedBase(_ raw: String) -> URL? {
        var s = raw.trimmed
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    func appendingQuery(_ items: [String: String?]) -> URL {
        guard var comps = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        var q = comps.queryItems ?? []
        for (k, v) in items.sorted(by: { $0.key < $1.key }) {
            if let v { q.append(URLQueryItem(name: k, value: v)) }
        }
        comps.queryItems = q
        // '+' must be escaped or many servers treat it as a space.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url ?? self
    }

    func appendingRawPath(_ path: String) -> URL {
        var s = absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        let p = path.hasPrefix("/") ? path : "/" + path
        return URL(string: s + p) ?? self
    }
}

/// Small in-memory TTL cache for API responses.
actor ResponseCache<Value> {
    private var storage: [String: (Date, Value)] = [:]
    private let ttl: TimeInterval
    private let limit: Int

    init(ttl: TimeInterval, limit: Int = 500) {
        self.ttl = ttl
        self.limit = limit
    }

    func value(_ key: String) -> Value? {
        guard case let (date, value)? = storage[key] else { return nil }
        if Date().timeIntervalSince(date) > ttl {
            storage[key] = nil
            return nil
        }
        return value
    }

    func set(_ key: String, _ value: Value) {
        if storage.count >= limit, let oldest = storage.min(by: { $0.value.0 < $1.value.0 })?.key {
            storage[oldest] = nil
        }
        storage[key] = (Date(), value)
    }

    func removeAll() { storage.removeAll() }
}
