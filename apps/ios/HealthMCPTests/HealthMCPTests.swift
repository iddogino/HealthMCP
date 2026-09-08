import XCTest
import CryptoKit
import HealthKit
@testable import HealthMCP

final class HealthMCPTests: XCTestCase {
    @MainActor func testLockedHealthDataPausesWithoutLosingPendingWork() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SyncStore(url: directory.appendingPathComponent("test.sqlite"))
        let sample = IndexedSample(uuid: UUID().uuidString, hkType: "steps", series: "steps", period: "2026-09-01", start: Date(), end: Date())
        try store.applyPage(type: "steps", samples: [sample], deleted: [], anchor: HKQueryAnchor(fromValue: 42))
        let pending = Set(try store.dirtyChunks().map(\.id))
        var run = SyncRun(trigger: "Initial backfill")
        run.uploadedChunks = 8; run.totalChunks = 12; run.progress = 0.6
        let locked = NSError(domain: HKErrorDomain, code: HKError.Code.errorDatabaseInaccessible.rawValue)
        XCTAssertTrue(SyncInterruption.isHealthDataLocked(locked))
        XCTAssertFalse(SyncInterruption.isHealthDataLocked(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        run.pauseForProtectedData(); try store.save(run)
        let saved = try XCTUnwrap(store.history().first)
        XCTAssertEqual(saved.status, "paused"); XCTAssertEqual(saved.uploadedChunks, 8)
        XCTAssertEqual(saved.progress, 0.6); XCTAssertTrue(saved.errors.isEmpty)
        XCTAssertNotNil(try store.anchor(for: "steps"))
        XCTAssertEqual(Set(try store.dirtyChunks().map(\.id)), pending)
    }
    func testNodeCryptoVectorAndTamperRejection() throws {
        let file = Bundle(for: Self.self).url(forResource:"crypto-v1",withExtension:"json")!
        let vector = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        let key=vector["key"] as! String, path=vector["path"] as! String
        let envelope=try JSONDecoder().decode(Envelope.self,from:JSONSerialization.data(withJSONObject:vector["envelope"]!))
        XCTAssertEqual(try HealthCrypto.decrypt(envelope,key:key,path:path),Data("\"ok\"".utf8))
        XCTAssertEqual(try HealthCrypto.derive(key).withUnsafeBytes { Data($0).map { String(format:"%02x",$0) }.joined() },vector["derived_key_hex"] as? String)
        XCTAssertThrowsError(try HealthCrypto.decrypt(envelope,key:key,path:path+".enc"))
        var changed = envelope; changed.alg="none"; XCTAssertThrowsError(try HealthCrypto.decrypt(changed,key:key,path:path))
        XCTAssertEqual(try HealthCrypto.normalize(HealthCrypto.formatted(key).lowercased()),key)
        XCTAssertThrowsError(try HealthCrypto.normalize("I"+key.dropFirst()))
        XCTAssertThrowsError(try HealthCrypto.normalize(String(key.dropLast())+"!"))
    }
    func testGzipAndRandomNonces() throws {
        let key=try HealthCrypto.generateKey(), value=Data(String(repeating:"synthetic health fixture",count:5000).utf8)
        let first=try HealthCrypto.encrypt(value,key:key,path:"test/check"),second=try HealthCrypto.encrypt(value,key:key,path:"test/check")
        XCTAssertNotEqual(first.iv,second.iv)
        XCTAssertEqual(try HealthCrypto.decrypt(first,key:key,path:"test/check"),value)
        XCTAssertEqual(try Gzip.decompress(Gzip.compress(Data())),Data())
        XCTAssertThrowsError(try Gzip.decompress(Data([1,2,3])))
    }
    func testP256SignatureWireFormat() throws {
        let key=P256.Signing.PrivateKey(),request=Data("PUT\n/v1/upload?series=steps&period=2026-09-01\n1\nnonce\nhash".utf8)
        let signature=try key.signature(for:request)
        XCTAssertEqual(signature.rawRepresentation.count,64)
        XCTAssertEqual(key.publicKey.x963Representation.count,65)
        XCTAssertTrue(key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation:signature.rawRepresentation),for:request))
        XCTAssertFalse(key.publicKey.isValidSignature(signature,for:Data("different".utf8)))
    }
    @MainActor func testAnchorAndDirtyJournalSurviveReopenAndDeletionAcrossMonth() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("test.sqlite"), id=UUID(), type="HKCategoryTypeIdentifierSleepAnalysis"
        let start=HealthDates.iso.date(from:"2026-08-31T23:00:00Z")!,end=HealthDates.iso.date(from:"2026-09-01T07:00:00Z")!
        var store:SyncStore?=try SyncStore(url:url)
        try store!.applyPage(type:type,samples:[IndexedSample(uuid:id.uuidString.lowercased(),hkType:type,series:"sleep",period:"2026-09-01",start:start,end:end)],deleted:[],anchor:HKQueryAnchor(fromValue:123))
        XCTAssertEqual(try store!.totalSamples(),1)
        XCTAssertNotNil(try store!.anchor(for:type))
        store=nil
        let reopened=try SyncStore(url:url)
        XCTAssertEqual(Set(try reopened.dirtyChunks().map(\.id)),Set(["sleep/2026-09-01","daily_summary/2026-08","daily_summary/2026-09","activity_rings/2026-08","activity_rings/2026-09"]))
        for chunk in try reopened.dirtyChunks(){try reopened.clearDirty(chunk)}
        try reopened.applyPage(type:type,samples:[],deleted:[id],anchor:HKQueryAnchor(fromValue:124))
        XCTAssertEqual(try reopened.totalSamples(),0)
        XCTAssertEqual(Set(try reopened.dirtyChunks().map(\.id)),Set(["sleep/2026-09-01","daily_summary/2026-08","daily_summary/2026-09","activity_rings/2026-08","activity_rings/2026-09"]))
        try reopened.clearSeries("sleep");XCTAssertNil(try reopened.anchor(for:type))
    }
    @MainActor func testJournalRollbackDoesNotAdvanceAnchor() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let store=try SyncStore(url:directory.appendingPathComponent("test.sqlite"))
        try store.execute("CREATE TRIGGER fail_dirty BEFORE INSERT ON dirty BEGIN SELECT RAISE(ABORT,'test'); END")
        let sample=IndexedSample(uuid:UUID().uuidString,hkType:"test",series:"steps",period:"2026-09-01",start:Date(),end:Date())
        XCTAssertThrowsError(try store.applyPage(type:"test",samples:[sample],deleted:[],anchor:HKQueryAnchor(fromValue:10)))
        XCTAssertNil(try store.anchor(for:"test"));XCTAssertEqual(try store.totalSamples(),0)
    }
    @MainActor func testSleepSourceUnionAndUTCPeriods() throws {
        let zero=Date(timeIntervalSince1970:0)
        XCTAssertEqual(HealthReader.unionDuration([(zero,zero+100),(zero+50,zero+150),(zero+200,zero+260)]),210)
        let bounds=try HealthDates.bounds("2024-02");XCTAssertEqual(bounds.1.timeIntervalSince(bounds.0),29*86400)
        XCTAssertEqual(HealthDates.day(bounds.1),"2024-03-01")
    }
    func testQuantityUnitsAreCompatibleWithHealthKit() throws {
        for definition in SeriesDefinition.quantities {
            guard let type=definition.sampleType as? HKQuantityType else { XCTFail("Missing HealthKit type: \(definition.id)");continue }
            let quantity=HKQuantity(unit:definition.unit,doubleValue:1)
            XCTAssertTrue(quantity.is(compatibleWith:definition.unit),definition.id)
            _ = HKQuantitySample(type:type,quantity:quantity,start:Date().addingTimeInterval(-60),end:Date())
        }
    }
    @MainActor func testMenstrualFlowUsesSDKValue() throws {
        let definition=SeriesDefinition.categories.first{$0.id=="menstrual_flow"}!
        let sample=HKCategorySample(type:definition.sampleType as! HKCategoryType,value:HKCategoryValueVaginalBleeding.heavy.rawValue,start:Date().addingTimeInterval(-60),end:Date(),metadata:[HKMetadataKeyMenstrualCycleStart:true])
        XCTAssertEqual(HealthReader().categoryRecord(sample,definition:definition)["c"] as? String,"heavy")
    }
}
