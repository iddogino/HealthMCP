import Foundation
import CryptoKit

struct APIError: LocalizedError {
    let status: Int, message: String
    let retryAfter: TimeInterval?
    var errorDescription: String? { message }
    var isRetryable: Bool { status == 409 || status == 429 || status >= 500 && status != 507 }
}
struct APIClient: Sendable {
    static let production = URL(string: "https://mcp.healthmcp.cc")!
    let identity: DeviceIdentity
    let baseURL: URL
    var userID: String
    let session: URLSession
    var cacheGeneration: Int?
    var privacyRevision: Int?
    init(identity: DeviceIdentity, userID: String = "", baseURL: URL = production, session: URLSession = .shared) { self.identity = identity; self.userID = userID; self.baseURL = baseURL; self.session = session }
    func request(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        let path = path + (cacheGeneration.map { (path.contains("?") ? "&" : "?") + "cache_generation=\($0)&privacy_revision=\(privacyRevision ?? 0)" } ?? "")
        guard let url = URL(string: path, relativeTo: baseURL), url.host == baseURL.host else { throw HealthMCPError.message("Invalid server address.") }
        let timestamp = String(Int(Date().timeIntervalSince1970)), nonce = UUID().uuidString
        let digest = SHA256.hash(data: body ?? Data()).map { String(format: "%02x", $0) }.joined()
        let canonical = [method, path, timestamp, nonce, digest].joined(separator: "\n")
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userID, forHTTPHeaderField: "X-User-ID")
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-Nonce")
        request.setValue(try identity.signature(for: Data(canonical.utf8)).base64EncodedString(), forHTTPHeaderField: "X-Signature")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HealthMCPError.message("The sync service did not respond.") }
        guard (200..<300).contains(http.statusCode) else {
            let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw APIError(status: http.statusCode, message: error?["error"] as? String ?? "Sync service returned \(http.statusCode). Please try again.", retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        }
        return data
    }
    func forSync() async throws -> APIClient {
        let status = try await json("GET", "/v1/status")
        guard let generation = status["cache_generation"] as? Int, let revision = status["privacy_revision"] as? Int else { throw HealthMCPError.message("The sync service is being updated. Please retry shortly.") }
        var client = self; client.cacheGeneration = generation; client.privacyRevision = revision
        return client
    }
    func json(_ method: String, _ path: String, _ value: [String: Any]? = nil) async throws -> [String: Any] {
        let body = try value.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        let data = try await request(method, path, body: body)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    func upload(series: String, period: String, plaintext: Data, key: String) async throws -> Int {
        try await upload(series: series, period: period, plaintext: plaintext, key: key, coverage: nil)
    }
    func upload(series: String, period: String, plaintext: Data, key: String, coverage: ChunkCoverage?) async throws -> Int {
        let path = objectPath(series: series, period: period)
        let envelope = try await Task.detached(priority: .utility) { try HealthCrypto.encrypt(plaintext, key: key, path: path) }.value
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= 16 * 1024 * 1024 else { throw HealthMCPError.message("The \(series) chunk is larger than 16 MB. Disable route detail and try again.") }
        _ = try await request("PUT", uploadPath(series: series, period: period) + (coverage.map { "&first_day=\($0.first)&last_day=\($0.last)" } ?? ""), body: data)
        return data.count
    }
    func delete(series: String, period: String) async throws { _ = try await request("DELETE", uploadPath(series: series, period: period)) }
    func objectPath(series: String, period: String) -> String { ["profile", "check"].contains(series) ? "\(userID)/\(series)" : "\(userID)/\(series)/\(period)" }
    func uploadPath(series: String, period: String) -> String {
        var parts = URLComponents(); parts.queryItems = [URLQueryItem(name: "series", value: series), URLQueryItem(name: "period", value: period)]
        return "/v1/upload?" + (parts.percentEncodedQuery ?? "")
    }
}
