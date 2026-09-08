import XCTest
import CryptoKit
import HealthKit
@testable import HealthMCP

final class HealthMCPTests: XCTestCase {
    @MainActor func testLockedHealthDataPausesWithoutLosingPendingWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SyncStore.open(url: directory.appendingPathComponent("test.sqlite"))
        let sample = IndexedSample(uuid: UUID().uuidString, hkType: "steps", series: "steps", period: "2026-09-01", start: Date(), end: Date())
        try await store.applyPage(type: "steps", samples: [sample], deleted: [], anchor: HKQueryAnchor(fromValue: 42))
        let pending = Set(try await store.dirtyChunks().map(\.id))
        var run = SyncRun(trigger: "Initial backfill")
        run.uploadedChunks = 8; run.totalChunks = 12; run.progress = 0.6
        let locked = NSError(domain: HKErrorDomain, code: HKError.Code.errorDatabaseInaccessible.rawValue)
        XCTAssertTrue(SyncInterruption.isHealthDataLocked(locked))
        XCTAssertFalse(SyncInterruption.isHealthDataLocked(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        run.pauseForProtectedData(); try await store.save(run)
        let savedHistory = try await store.history(); let saved = try XCTUnwrap(savedHistory.first)
        XCTAssertEqual(saved.status, "paused"); XCTAssertEqual(saved.uploadedChunks, 8)
        XCTAssertEqual(saved.progress, 0.6); XCTAssertTrue(saved.errors.isEmpty)
        let savedAnchor = try await store.anchor(for: "steps"); XCTAssertNotNil(savedAnchor)
        let stillPending = Set(try await store.dirtyChunks().map(\.id)); XCTAssertEqual(stillPending, pending)
    }
    func testNodeCryptoVectorAndTamperRejection() async throws {
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
    func testGzipAndRandomNonces() async throws {
        let key=try HealthCrypto.generateKey(), value=Data(String(repeating:"synthetic health fixture",count:5000).utf8)
        let first=try HealthCrypto.encrypt(value,key:key,path:"test/check"),second=try HealthCrypto.encrypt(value,key:key,path:"test/check")
        XCTAssertNotEqual(first.iv,second.iv)
        XCTAssertEqual(try HealthCrypto.decrypt(first,key:key,path:"test/check"),value)
        XCTAssertEqual(try Gzip.decompress(Gzip.compress(Data())),Data())
        XCTAssertThrowsError(try Gzip.decompress(Data([1,2,3])))
    }
    func testP256SignatureWireFormat() async throws {
        let key=P256.Signing.PrivateKey(),request=Data("PUT\n/v1/upload?series=steps&period=2026-09-01\n1\nnonce\nhash".utf8)
        let signature=try key.signature(for:request)
        XCTAssertEqual(signature.rawRepresentation.count,64)
        XCTAssertEqual(key.publicKey.x963Representation.count,65)
        XCTAssertTrue(key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation:signature.rawRepresentation),for:request))
        XCTAssertFalse(key.publicKey.isValidSignature(signature,for:Data("different".utf8)))
    }
    @MainActor func testAnchorAndDirtyJournalSurviveReopenAndDeletionAcrossMonth() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("test.sqlite"), id=UUID(), type="HKCategoryTypeIdentifierSleepAnalysis"
        let start=HealthDates.iso.date(from:"2026-08-31T23:00:00Z")!,end=HealthDates.iso.date(from:"2026-09-01T07:00:00Z")!
        var store:SyncStore?=try await SyncStore.open(url:url)
        try await store!.applyPage(type:type,samples:[IndexedSample(uuid:id.uuidString.lowercased(),hkType:type,series:"sleep",period:"2026-09-01",start:start,end:end)],deleted:[],anchor:HKQueryAnchor(fromValue:123))
        let initialCount = try await store!.totalSamples(); XCTAssertEqual(initialCount,1)
        let initialAnchor = try await store!.anchor(for:type); XCTAssertNotNil(initialAnchor)
        store=nil
        let reopened=try await SyncStore.open(url:url)
        let firstDirty = Set(try await reopened.dirtyChunks().map(\.id)); XCTAssertEqual(firstDirty,Set(["sleep/2026-09-01","daily_summary/2026-08","daily_summary/2026-09","activity_rings/2026-08","activity_rings/2026-09"]))
        for chunk in try await reopened.dirtyChunks(){try await reopened.clearDirty(chunk)}
        try await reopened.applyPage(type:type,samples:[],deleted:[id],anchor:HKQueryAnchor(fromValue:124))
        let deletedCount = try await reopened.totalSamples(); XCTAssertEqual(deletedCount,0)
        let afterDeletion = Set(try await reopened.dirtyChunks().map(\.id)); XCTAssertEqual(afterDeletion, firstDirty)
        try await reopened.clearSeries("sleep");let clearedAnchor = try await reopened.anchor(for:type); XCTAssertNil(clearedAnchor)
    }
    @MainActor func testJournalRollbackDoesNotAdvanceAnchor() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let store=try await SyncStore.open(url:directory.appendingPathComponent("test.sqlite"))
        try await store.execute("CREATE TRIGGER fail_dirty BEFORE INSERT ON dirty BEGIN SELECT RAISE(ABORT,'test'); END")
        let sample=IndexedSample(uuid:UUID().uuidString,hkType:"test",series:"steps",period:"2026-09-01",start:Date(),end:Date())
        do { try await store.applyPage(type:"test",samples:[sample],deleted:[],anchor:HKQueryAnchor(fromValue:10)); XCTFail("Transaction should roll back") } catch {}
        let rolledBackAnchor = try await store.anchor(for:"test"), rolledBackCount = try await store.totalSamples(); XCTAssertNil(rolledBackAnchor);XCTAssertEqual(rolledBackCount,0)
    }
    @MainActor func testSleepSourceUnionAndUTCPeriods() async throws {
        let zero=Date(timeIntervalSince1970:0)
        XCTAssertEqual(HealthReader.unionDuration([(zero,zero+100),(zero+50,zero+150),(zero+200,zero+260)]),210)
        let bounds=try HealthDates.bounds("2024-02");XCTAssertEqual(bounds.1.timeIntervalSince(bounds.0),29*86400)
        XCTAssertEqual(HealthDates.day(bounds.1),"2024-03-01")
    }
    func testQuantityUnitsAreCompatibleWithHealthKit() async throws {
        for definition in SeriesDefinition.quantities {
            guard let type=definition.sampleType as? HKQuantityType else { XCTFail("Missing HealthKit type: \(definition.id)");continue }
            let quantity=HKQuantity(unit:definition.unit,doubleValue:1)
            XCTAssertTrue(quantity.is(compatibleWith:definition.unit),definition.id)
            _ = HKQuantitySample(type:type,quantity:quantity,start:Date().addingTimeInterval(-60),end:Date())
        }
    }
    @MainActor func testMenstrualFlowUsesSDKValue() async throws {
        let definition=SeriesDefinition.categories.first{$0.id=="menstrual_flow"}!
        let sample=HKCategorySample(type:definition.sampleType as! HKCategoryType,value:HKCategoryValueVaginalBleeding.heavy.rawValue,start:Date().addingTimeInterval(-60),end:Date(),metadata:[HKMetadataKeyMenstrualCycleStart:true])
        let category = await HealthReader().categoryRecord(sample,definition:definition); XCTAssertEqual(category["c"] as? String,"heavy")
    }
}
