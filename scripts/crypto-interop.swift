import Foundation
@main struct Interop {
    static func main() throws {
        let payload="0123456789ABCDEF",key=payload+String(try HealthCrypto.checksum(payload)),path="u_00000000-0000-4000-8000-000000000001/steps/2026-09-01"
        let value=Data("[{\"t0\":\"2026-09-01T00:00:00Z\",\"t1\":\"2026-09-01T01:00:00Z\",\"v\":123,\"src\":\"Synthetic Swift fixture\"}]".utf8)
        let envelope=try HealthCrypto.encrypt(value,key:key,path:path)
        let output:[String:Any]=["key":key,"path":path,"envelope":try JSONSerialization.jsonObject(with:JSONEncoder().encode(envelope)),"expected":try JSONSerialization.jsonObject(with:value)]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:output))
    }
}
