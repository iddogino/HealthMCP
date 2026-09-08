#if DEBUG
import Foundation
import CryptoKit

// Development-only E2E probe. The health key and plaintext never leave this process.
// The report contains booleans and counts; the separate short-lived OAuth session
// lets the local test runner request APNs delivery, then is explicitly revoked.
@MainActor enum DeviceValidation {
    static let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Validation", isDirectory: true)
    static func write(_ value: [String: Any], name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true; var url = directory; try url.setResourceValues(values)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func run(model: AppModel) async {
        guard let api = model.api, !api.userID.isEmpty else { return }
        model.diagnosticResult = "Validating the encrypted round trip…"
        var checks: [String] = []
        let session = URLSession(configuration: .ephemeral)
        var connectionID: String?
        func request(_ path: String, method: String = "GET", body: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
            guard let url = URL(string: path, relativeTo: api.baseURL), url.scheme == "https", url.host == api.baseURL.host else { throw HealthMCPError.message("Validation URL rejected.") }
            var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw HealthMCPError.message("Validation request failed: \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
            return (data, http)
        }
        func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        func object(_ data: Data) throws -> [String: Any] { guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HealthMCPError.message("Invalid validation response.") }; return result }
        func match(_ pattern: String, in text: String) throws -> String {
            let regex = try NSRegularExpression(pattern: pattern)
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { throw HealthMCPError.message("Pairing page did not contain a validation code.") }
            return String(text[range])
        }
        func form(_ values: [String: String]) -> Data { var components = URLComponents(); components.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }; return Data((components.percentEncodedQuery ?? "").utf8) }
        do {
            if let saved = UserDefaults.standard.string(forKey: "validationConnection") { _ = try? await api.json("DELETE", "/v1/connections/"+saved) }
            let verifier = UUID().uuidString + UUID().uuidString
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let redirect = "http://localhost:18944/callback"
            let registration = try await request("/register", method: "POST", body: json(["client_name":"Health MCP Device Validation", "redirect_uris":[redirect], "token_endpoint_auth_method":"none", "grant_types":["authorization_code","refresh_token"], "response_types":["code"]]), headers: ["Content-Type":"application/json"])
            guard let clientID = try object(registration.0)["client_id"] as? String else { throw HealthMCPError.message("Client registration failed.") }
            let parameters = ["response_type":"code", "client_id":clientID, "redirect_uri":redirect, "scope":"health:read offline_access", "state":"device-validation", "code_challenge":challenge, "code_challenge_method":"S256", "resource":api.baseURL.absoluteString+"/mcp"]
            let auth = try await request("/authorize?"+String(decoding: form(parameters), as: UTF8.self))
            let html = String(decoding: auth.0, as: UTF8.self)
            let code = try match("id=\"pairing-code\">([0-9]{3} [0-9]{3})", in: html).replacingOccurrences(of: " ", with: "")
            let pairingID = try match("const pairingId=\"([^\"]+)\"", in: html)
            connectionID = pairingID
            let preview = try await api.json("POST", "/v1/pair/preview", ["code":code])
            guard preview["client_name"] as? String == "Health MCP Device Validation", preview["pairing_id"] as? String == pairingID else { throw HealthMCPError.message("Validation consent did not match.") }
            _ = try await api.json("POST", "/v1/pair/approve", ["code":code, "pairing_id":pairingID])
            let poll = try await request("/authorize/poll", method:"POST", body:json(["id":pairingID]), headers:["Content-Type":"application/json"])
            guard let callback = try object(poll.0)["redirect_to"] as? String, let parts = URLComponents(string:callback), parts.queryItems?.first(where:{$0.name=="state"})?.value == "device-validation", let authorizationCode = parts.queryItems?.first(where:{$0.name=="code"})?.value else { throw HealthMCPError.message("OAuth callback did not match.") }
            let exchange = try await request("/token", method:"POST", body:form(["grant_type":"authorization_code", "client_id":clientID, "code":authorizationCode, "redirect_uri":redirect, "code_verifier":verifier, "resource":api.baseURL.absoluteString+"/mcp"]), headers:["Content-Type":"application/x-www-form-urlencoded"])
            guard let token = try object(exchange.0)["access_token"] as? String else { throw HealthMCPError.message("Token exchange failed.") }
            checks.append("Secure Enclave device signatures and OAuth PKCE pairing")
            func rpc(_ method: String, _ parameters: [String: Any]) async throws -> [String: Any] {
                let response = try await request("/mcp", method:"POST", body:json(["jsonrpc":"2.0", "id":UUID().uuidString, "method":method, "params":parameters]), headers:["Content-Type":"application/json", "Accept":"application/json, text/event-stream", "Authorization":"Bearer "+token])
                let decoded = try object(response.0)
                guard let result = decoded["result"] as? [String: Any] else { throw HealthMCPError.message("MCP protocol error: \((decoded["error"] as? [String: Any])?["code"] as? Int ?? 0)") }
                if result["isError"] as? Bool == true {
                    let message = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "Request failed"
                    throw HealthMCPError.message("MCP tool failed: \(message.prefix(200))")
                }
                return result
            }
            func tool(_ name: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
                let result = try await rpc("tools/call", ["name":name,"arguments":arguments])
                guard let structured = result["structuredContent"] as? [String: Any] else { throw HealthMCPError.message("MCP returned no structured manifest.") }; return structured
            }
            _ = try await rpc("initialize", ["protocolVersion":"2025-03-26", "capabilities":[:], "clientInfo":["name":"healthmcp-device-validation","version":"1.0.0"]])
            let tools = try await rpc("tools/list", [:]); guard (tools["tools"] as? [Any])?.count == 6 else { throw HealthMCPError.message("MCP tools are incomplete.") }
            checks.append("MCP initialization and six tools")
            let catalog = try await tool("list_series")
            guard let checkURL = catalog["check_url"] as? String, let checkPath = catalog["check_path"] as? String else { throw HealthMCPError.message("Key-check file missing.") }
            let check = try JSONDecoder().decode(Envelope.self, from: await request(checkURL).0)
            guard try HealthCrypto.decrypt(check, key:model.privateKey, path:checkPath) == Data("\"ok\"".utf8) else { throw HealthMCPError.message("Private key verification failed.") }
            checks.append("Live encrypted key-check decrypted on device")
            let today = HealthDates.day(Date())
            let series = (catalog["series"] as? [[String: Any]] ?? []).filter {
                !["profile","daily_summary","activity_rings"].contains($0["series"] as? String ?? "") && ($0["first_day"] as? String ?? today) < today
            }.sorted { ($0["first_day"] as? String ?? "") < ($1["first_day"] as? String ?? "") }
            guard let first = series.first, let name = first["series"] as? String, let start = first["first_day"] as? String, let end = first["last_day"] as? String else { throw HealthMCPError.message("No real readable health series has completed syncing.") }
            let manifest = try await tool("get_samples", ["series":name,"start":start,"end":min(end, HealthDates.day(Date().addingTimeInterval(-86400)))])
            guard let chunk = (manifest["chunks"] as? [[String: Any]])?.first, let path = chunk["path"] as? String, let url = chunk["url"] as? String else { throw HealthMCPError.message("Real health chunk missing.") }
            let envelope = try JSONDecoder().decode(Envelope.self, from: await request(url).0)
            let plaintext = try HealthCrypto.decrypt(envelope, key:model.privateKey, path:path)
            _ = try JSONSerialization.jsonObject(with:plaintext, options:.fragmentsAllowed)
            let period = String(path.dropFirst((api.userID+"/"+name+"/").count))
            let local = try await model.reader.chunk(DirtyChunk(series:name,period:period), definitions:model.definitions)
            guard plaintext == local.0, local.1 > 0 else { throw HealthMCPError.message("Decrypted data did not match a fresh Apple Health read.") }
            checks.append("Real HealthKit → encryption → Cloudflare → MCP → local decryption matches HealthKit")
            do { _ = try HealthCrypto.decrypt(envelope,key:model.privateKey,path:path+"x"); throw HealthMCPError.message("Incorrect AAD was accepted.") } catch let error as HealthMCPError { throw error } catch { checks.append("Incorrect object path fails authentication") }
            UserDefaults.standard.set(pairingID,forKey:"validationConnection")
            try write(["base_url":api.baseURL.absoluteString,"access_token":token,"connection_id":pairingID,"user_id":api.userID],name:"session.json")
            try write(["passed":true,"checks":checks,"series_count":series.count,"completed_at":HealthDates.timestamp(Date())],name:"report.json")
            model.diagnosticResult = "Passed \(checks.count) device E2E checks."
        } catch {
            if let connectionID { _ = try? await api.json("DELETE","/v1/connections/"+connectionID) }
            try? write(["passed":false,"checks":checks,"error":error.localizedDescription],name:"report.json")
            model.diagnosticResult = "Validation needs attention: \(error.localizedDescription)"
        }
        await model.refreshStatus()
    }
    static func finish(model: AppModel) async {
        if let id = UserDefaults.standard.string(forKey:"validationConnection") { _ = try? await model.api?.json("DELETE","/v1/connections/"+id) }
        UserDefaults.standard.removeObject(forKey:"validationConnection")
        try? FileManager.default.removeItem(at:directory.appendingPathComponent("session.json"))
        await model.refreshStatus()
    }
}
#endif
