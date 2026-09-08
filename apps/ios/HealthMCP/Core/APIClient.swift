import Foundation
import CryptoKit

struct APIClient {
    static let production = URL(string: "https://mcp.healthmcp.cc")!
    let identity: DeviceIdentity
    let baseURL: URL
    var userID: String
    init(identity: DeviceIdentity, userID: String = "", baseURL: URL = production) { self.identity = identity; self.userID = userID; self.baseURL = baseURL }
    func request(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
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
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HealthMCPError.message("The sync service did not respond.") }
        guard (200..<300).contains(http.statusCode) else {
            let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw HealthMCPError.message(error?["error"] as? String ?? "Sync service returned \(http.statusCode). Please try again.")
        }
        return data
    }
    func json(_ method: String, _ path: String, _ value: [String: Any]? = nil) async throws -> [String: Any] {
        let body = try value.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        let data = try await request(method, path, body: body)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    func upload(series: String, period: String, plaintext: Data, key: String) async throws -> Int {
        let path = objectPath(series: series, period: period)
        let envelope = try await Task.detached(priority: .utility) { try HealthCrypto.encrypt(plaintext, key: key, path: path) }.value
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= 16 * 1024 * 1024 else { throw HealthMCPError.message("The \(series) chunk is larger than 16 MB. Disable route detail and try again.") }
        _ = try await request("PUT", uploadPath(series: series, period: period), body: data)
        return data.count
    }
    func delete(series: String, period: String) async throws { _ = try await request("DELETE", uploadPath(series: series, period: period)) }
    func objectPath(series: String, period: String) -> String { ["profile", "check"].contains(series) ? "\(userID)/\(series)" : "\(userID)/\(series)/\(period)" }
    func uploadPath(series: String, period: String) -> String {
        var parts = URLComponents(); parts.queryItems = [URLQueryItem(name: "series", value: series), URLQueryItem(name: "period", value: period)]
        return "/v1/upload?" + (parts.percentEncodedQuery ?? "")
    }
}
