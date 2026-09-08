import Foundation
import CryptoKit
import Security
import zlib

enum HealthMCPError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum Keychain {
    static let service = "cc.healthmcp.app"
    static func read(_ name: String) throws -> Data? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw HealthMCPError.message("The device is locked. Unlock it to access your private keys.") }
        return item as? Data
    }
    static func set(_ name: String, _ value: Data) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: value] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData] = value; item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw HealthMCPError.message("Could not save the private key securely.") }; return
        }
        guard status == errSecSuccess else { throw HealthMCPError.message("Could not update secure device storage.") }
    }
    static func remove(_ name: String) { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name] as CFDictionary) }
}

struct DeviceIdentity: Sendable {
    private let signData: @Sendable (Data) throws -> Data
    let publicKey: Data
    init() throws {
        #if targetEnvironment(simulator)
        let key: P256.Signing.PrivateKey
        if let saved = try Keychain.read("simulator-device-key") { key = try P256.Signing.PrivateKey(rawRepresentation: saved) }
        else { key = P256.Signing.PrivateKey(); try Keychain.set("simulator-device-key", key.rawRepresentation) }
        publicKey = key.publicKey.x963Representation
        signData = { try key.signature(for: $0).rawRepresentation }
        #else
        let key: SecureEnclave.P256.Signing.PrivateKey
        if let saved = try Keychain.read("device-key") { key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: saved) }
        else {
            guard SecureEnclave.isAvailable, let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil) else { throw HealthMCPError.message("Secure Enclave is unavailable on this device.") }
            key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            try Keychain.set("device-key", key.dataRepresentation)
        }
        publicKey = key.publicKey.x963Representation
        signData = { try key.signature(for: $0).rawRepresentation }
        #endif
    }
    func signature(for data: Data) throws -> Data { try signData(data) }
}

struct Envelope: Codable, Sendable {
    var v = 1
    var alg = "A256GCM"
    var kdf = "sha256"
    let iv: String
    let ct: String
}

enum HealthCrypto {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let checkAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ*~$=U")
    static func checksum(_ payload: String) throws -> Character {
        guard payload.count == 16 else { throw HealthMCPError.message("Invalid key length.") }
        var remainder = 0
        for character in payload {
            guard let value = alphabet.firstIndex(of: character) else { throw HealthMCPError.message("Invalid key character.") }
            remainder = (remainder * 32 + value) % 37
        }
        return checkAlphabet[remainder]
    }
    static func generateKey() throws -> String {
        var random = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw HealthMCPError.message("Could not generate a secure key.") }
        let payload = String(random.map { alphabet[Int($0 & 31)] })
        return payload + String(try checksum(payload))
    }
    static func normalize(_ input: String) throws -> String {
        let key = input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard key.count == 17, try checksum(String(key.prefix(16))) == key.last else { throw HealthMCPError.message("The private key checksum does not match.") }
        return key
    }
    static func formatted(_ key: String) -> String {
        let chars = Array(key)
        guard chars.count == 17 else { return key }
        return stride(from: 0, to: 16, by: 4).map { String(chars[$0..<$0+4]) }.joined(separator: "-") + "-" + String(chars[16])
    }
    static func derive(_ key: String) throws -> SymmetricKey { SymmetricKey(data: SHA256.hash(data: Data(("healthmcp/v1:" + (try normalize(key))).utf8))) }
    static func encrypt(_ json: Data, key: String, path: String) throws -> Envelope {
        let compressed = try Gzip.compress(json)
        let sealed = try AES.GCM.seal(compressed, using: derive(key), authenticating: Data(path.utf8))
        return Envelope(iv: Data(sealed.nonce).base64EncodedString(), ct: (sealed.ciphertext + sealed.tag).base64EncodedString())
    }
    static func decrypt(_ envelope: Envelope, key: String, path: String) throws -> Data {
        guard envelope.v == 1, envelope.alg == "A256GCM", envelope.kdf == "sha256", let iv = Data(base64Encoded: envelope.iv), iv.count == 12, let ct = Data(base64Encoded: envelope.ct), ct.count >= 18 else { throw HealthMCPError.message("Invalid encrypted envelope.") }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ct.dropLast(16), tag: ct.suffix(16))
        return try Gzip.decompress(AES.GCM.open(box, using: derive(key), authenticating: Data(path.utf8)))
    }
}

enum Gzip {
    static func compress(_ data: Data) throws -> Data { try process(data, compress: true) }
    static func decompress(_ data: Data) throws -> Data { try process(data, compress: false) }
    private static func process(_ data: Data, compress: Bool) throws -> Data {
        var stream = z_stream()
        let initialized = compress ? deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) : inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw HealthMCPError.message("Compression could not start.") }
        defer { if compress { deflateEnd(&stream) } else { inflateEnd(&stream) } }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var result = Data(), output = [UInt8](repeating: 0, count: 32768), status: Int32 = Z_OK
            repeat {
                let written = output.withUnsafeMutableBytes { buffer -> Int in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = 32768
                    status = compress ? deflate(&stream, Z_FINISH) : inflate(&stream, Z_NO_FLUSH)
                    return 32768 - Int(stream.avail_out)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw HealthMCPError.message("The compressed data is invalid.") }
                result.append(contentsOf: output.prefix(written))
                guard result.count <= 64 * 1024 * 1024 else { throw HealthMCPError.message("This chunk is too large to process safely.") }
            } while status != Z_STREAM_END
            return result
        }
    }
}
