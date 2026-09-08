import Foundation
import HealthKit
import CoreLocation

@MainActor final class HealthReader {
    let healthStore = HKHealthStore()
    private var observers: [HKObserverQuery] = []
    var routesEnabled = false
    func requestAuthorization(definitions: [SeriesDefinition]) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthMCPError.message("Apple Health is not available on this device.") }
        var types = Set<HKObjectType>(definitions.compactMap(\.sampleType))
        // HealthKit does not authorize correlation types directly; authorize their quantities.
        types = types.filter { !($0 is HKCorrelationType) }
        types.insert(HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic)!)
        types.insert(HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic)!)
        types.insert(HKObjectType.activitySummaryType())
        if routesEnabled { types.insert(HKSeriesType.workoutRoute()) }
        for name in ["DateOfBirth", "BiologicalSex", "BloodType", "FitzpatrickSkinType", "WheelchairUse", "ActivityMoveMode"] {
            if let type = HKObjectType.characteristicType(forIdentifier: HKCharacteristicTypeIdentifier(rawValue: "HKCharacteristicTypeIdentifier" + name)) { types.insert(type) }
        }
        try await healthStore.requestAuthorization(toShare: [], read: types)
    }
    func observe(definitions: [SeriesDefinition], changed: @escaping (@escaping () -> Void) -> Void) {
        observers.forEach { healthStore.stop($0) }; observers.removeAll()
        var seen = Set<String>()
        for definition in definitions {
            guard let type = definition.sampleType, seen.insert(type.identifier).inserted else { continue }
            let observer = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                if error != nil { completion(); return }
                Task { @MainActor in changed(completion) }
            }
            healthStore.execute(observer); observers.append(observer)
            let frequency: HKUpdateFrequency = definition.id == "sleep" ? .daily : definition.kind == .cumulative ? .hourly : .immediate
            healthStore.enableBackgroundDelivery(for: type, frequency: frequency) { _, _ in }
        }
    }
    func stopObservers() { observers.forEach { healthStore.stop($0) }; observers.removeAll(); healthStore.disableAllBackgroundDelivery { _, _ in } }
    func anchored(type: HKSampleType, anchor: HKQueryAnchor?) async throws -> ([HKSample], [HKDeletedObject], HKQueryAnchor?) {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: 1000) { _, samples, deleted, next, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (samples ?? [], deleted ?? [], next)) }
            }
            healthStore.execute(query)
        }
    }
    func samples(type: HKSampleType, predicate: NSPredicate) async throws -> [HKSample] {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: samples ?? []) }
            }
            healthStore.execute(query)
        }
    }
    func index(_ sample: HKSample, definition: SeriesDefinition) -> IndexedSample {
        IndexedSample(uuid: sample.uuid.uuidString.lowercased(), hkType: sample.sampleType.identifier, series: definition.id, period: definition.period(for: sample), start: sample.startDate, end: sample.endDate)
    }
    func chunk(_ chunk: DirtyChunk, definitions: [SeriesDefinition]) async throws -> (Data, Int) {
        if chunk.series == "daily_summary" { let rows = try await dailySummary(month: chunk.period); return (try json(rows), rows.count) }
        if chunk.series == "activity_rings" { let rows = try await activityRings(month: chunk.period); return (try json(rows), rows.count) }
        let defs = definitions.filter { $0.id == chunk.series }
        guard !defs.isEmpty else { return (Data("[]".utf8), 0) }
        let (start, end) = try HealthDates.bounds(chunk.period)
        var records: [[String: Any]] = []
        for definition in defs {
            guard let type = definition.sampleType else { continue }
            let predicate: NSPredicate
            if definition.chunk == "record", let uuid = UUID(uuidString: String(chunk.period.dropFirst(11))) { predicate = HKQuery.predicateForObject(with: uuid) }
            else { predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: definition.id == "sleep" ? .strictEndDate : .strictStartDate) }
            let samples = try await samples(type: type, predicate: predicate)
            for sample in samples where definition.period(for: sample) == chunk.period {
                if let workout = sample as? HKWorkout { guard workout.endDate <= Date() else { continue }; return (try json(await workoutRecord(workout)), 1) }
                if let ecg = sample as? HKElectrocardiogram { return (try json(await ecgRecord(ecg)), 1) }
                if let correlation = sample as? HKCorrelation {
                    let identifier: HKQuantityTypeIdentifier = definition.id == "blood_pressure_systolic" ? .bloodPressureSystolic : .bloodPressureDiastolic
                    let quantities = correlation.objects(for: HKObjectType.quantityType(forIdentifier: identifier)!).compactMap { $0 as? HKQuantitySample }
                    for quantity in quantities { records.append(["t": HealthDates.timestamp(correlation.startDate), "v": quantity.quantity.doubleValue(for: definition.unit), "src": correlation.sourceRevision.source.name]) }
                } else if let quantity = sample as? HKQuantitySample {
                    var row: [String: Any] = ["v": quantity.quantity.doubleValue(for: definition.unit) * (definition.unitName == "%" ? 100 : 1), "src": sample.sourceRevision.source.name]
                    if definition.kind == .cumulative { row["t0"] = HealthDates.timestamp(sample.startDate); row["t1"] = HealthDates.timestamp(sample.endDate) }
                    else { row["t"] = HealthDates.timestamp(sample.startDate) }
                    records.append(row)
                } else if let category = sample as? HKCategorySample { records.append(categoryRecord(category, definition: definition)) }
            }
        }
        records.sort { ($0["t"] as? String ?? $0["t0"] as? String ?? "") < ($1["t"] as? String ?? $1["t0"] as? String ?? "") }
        return (try json(records), records.count)
    }
    func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
    func categoryRecord(_ sample: HKCategorySample, definition: SeriesDefinition) -> [String: Any] {
        var row: [String: Any] = ["t0": HealthDates.timestamp(sample.startDate), "t1": HealthDates.timestamp(sample.endDate), "src": sample.sourceRevision.source.name]
        switch definition.id {
        case "sleep": row["c"] = Self.sleepStage(sample.value)
        case "stand_hour": row["c"] = sample.value == HKCategoryValueAppleStandHour.stood.rawValue ? "stood" : "idle"
        case "menstrual_flow": row["c"] = [1: "unspecified", 2: "light", 3: "medium", 4: "heavy", 5: "none"][sample.value] ?? "unspecified"
        case "heart_rate_events":
            row["c"] = definition.hkName == "HighHeartRateEvent" ? "high" : definition.hkName == "LowHeartRateEvent" ? "low" : "irregular"
            if let threshold = sample.metadata?[HKMetadataKeyHeartRateEventThreshold] as? HKQuantity { row["meta"] = ["threshold": threshold.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))] }
        case "low_cardio_fitness_event":
            row["c"] = "low_cardio_fitness_event"
            if let value = sample.metadata?[HKMetadataKeyVO2MaxValue] as? HKQuantity { row["meta"] = ["vo2max": value.doubleValue(for: HKUnit(from: "ml/kg*min"))] }
        case "symptoms":
            row["c"] = Self.snakeCase(definition.hkName)
            if definition.hkName == "AppetiteChanges" { row["meta"] = ["severity": sample.value == 1 ? "notPresent" : "present", "value": [0: "unspecified", 1: "noChange", 2: "decreased", 3: "increased"][sample.value] ?? "unspecified"] }
            else { row["meta"] = ["severity": [0: "present", 1: "notPresent", 2: "mild", 3: "moderate", 4: "severe"][sample.value] ?? "present"] }
        case "reproductive_events":
            row["c"] = Self.snakeCase(definition.hkName)
            let maps: [String: [Int: String]] = [
                "OvulationTestResult": [1: "negative", 2: "luteinizingHormoneSurge", 3: "indeterminate", 4: "estrogenSurge"],
                "PregnancyTestResult": [1: "negative", 2: "positive", 3: "indeterminate"], "ProgesteroneTestResult": [1: "negative", 2: "positive", 3: "indeterminate"],
                "CervicalMucusQuality": [1: "dry", 2: "sticky", 3: "creamy", 4: "watery", 5: "eggWhite"],
                "Contraceptive": [1: "unspecified", 2: "implant", 3: "injection", 4: "intrauterineDevice", 5: "intravaginalRing", 6: "oral", 7: "patch"]]
            row["meta"] = ["value": maps[definition.hkName]?[sample.value] ?? "notApplicable"]
        default: row["c"] = definition.id
        }
        return row
    }
    static func sleepStage(_ value: Int) -> String { [0: "inBed", 1: "asleepUnspecified", 2: "awake", 3: "asleepCore", 4: "asleepDeep", 5: "asleepREM"][value] ?? "asleepUnspecified" }
    static func snakeCase(_ value: String) -> String { value.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1_$2", options: .regularExpression).lowercased() }
    func profile() throws -> [String: Any] {
        func characteristic<T>(_ read: () throws -> T) throws -> T? {
            do { return try read() }
            catch { if SyncInterruption.isHealthDataLocked(error) { throw error }; return nil }
        }
        var result: [String: Any] = [:]
        if let date = try characteristic({ try healthStore.dateOfBirthComponents() }), let y = date.year, let m = date.month, let d = date.day { result["date_of_birth"] = String(format: "%04d-%02d-%02d", y, m, d) }
        if let value = try characteristic({ try healthStore.biologicalSex() }) { result["biological_sex"] = [0: "notSet", 1: "female", 2: "male", 3: "other"][value.biologicalSex.rawValue] ?? "notSet" }
        if let value = try characteristic({ try healthStore.bloodType() }) { result["blood_type"] = [0: "notSet", 1: "A+", 2: "A-", 3: "B+", 4: "B-", 5: "AB+", 6: "AB-", 7: "O+", 8: "O-"][value.bloodType.rawValue] ?? "notSet" }
        if let value = try characteristic({ try healthStore.fitzpatrickSkinType() }) { result["fitzpatrick_skin_type"] = value.skinType.rawValue }
        if let value = try characteristic({ try healthStore.wheelchairUse() }) { result["wheelchair_use"] = [0: "notSet", 1: "no", 2: "yes"][value.wheelchairUse.rawValue] ?? "notSet" }
        if let value = try characteristic({ try healthStore.activityMoveMode() }) { result["activity_move_mode"] = value.activityMoveMode.rawValue == 1 ? "activeEnergy" : "appleMoveTime" }
        return result
    }
}
