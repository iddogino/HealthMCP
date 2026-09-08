import Foundation
import HealthKit

enum HealthDates {
    static let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }()
    static let iso = ISO8601DateFormatter()
    static func timestamp(_ date: Date) -> String { date.formatted(.iso8601) }
    static func day(_ date: Date) -> String { let c = calendar.dateComponents([.year, .month, .day], from: date); return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!) }
    static func month(_ date: Date) -> String { let c = calendar.dateComponents([.year, .month], from: date); return String(format: "%04d-%02d", c.year!, c.month!) }
    static func bounds(_ period: String) throws -> (Date, Date) {
        let part = String(period.prefix(10))
        let isMonth = part.count == 7
        guard let start = iso.date(from: (isMonth ? part + "-01" : part) + "T00:00:00Z"), let end = calendar.date(byAdding: isMonth ? .month : .day, value: 1, to: start) else { throw HealthMCPError.message("Invalid health data period.") }
        return (start, end)
    }
}
struct SeriesDefinition: Identifiable, Sendable {
    enum Kind: Sendable { case quantity, cumulative, category, correlation, workout, ecg, route }
    let id: String, hkName: String, unitName: String, chunk: String, group: String
    let kind: Kind
    var title: String { id.split(separator: "_").map { $0.capitalized }.joined(separator: " ") }
    var sampleType: HKSampleType? {
        switch kind {
        case .quantity, .cumulative: return HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: "HKQuantityTypeIdentifier" + hkName))
        case .category: return HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: "HKCategoryTypeIdentifier" + hkName))
        case .correlation: return HKObjectType.correlationType(forIdentifier: .bloodPressure)
        case .workout: return HKObjectType.workoutType()
        case .ecg: return HKObjectType.electrocardiogramType()
        case .route: return HKSeriesType.workoutRoute()
        }
    }
    var unit: HKUnit {
        switch unitName {
        case "%": return .percent()
        case "°C": return .degreeCelsius()
        case "rpm": return HKUnit.count().unitDivided(by: .minute())
        case "mL/kg/min": return HKUnit.literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo)).unitDivided(by: .minute())
        case "kcal/hr/kg": return HKUnit.kilocalorie().unitDivided(by: .hour()).unitDivided(by: .gramUnit(with: .kilo))
        default: return HKUnit(from: unitName)
        }
    }
    func period(for sample: HKSample) -> String {
        let date = id == "sleep" ? sample.endDate : sample.startDate
        if chunk == "record" { return HealthDates.day(date) + "/" + sample.uuid.uuidString.lowercased() }
        return chunk == "month" ? HealthDates.month(date) : HealthDates.day(date)
    }
    static let reproductiveNames = ["OvulationTestResult", "CervicalMucusQuality", "IntermenstrualBleeding", "PregnancyTestResult", "ProgesteroneTestResult", "Contraceptive", "Lactation", "Pregnancy", "InfrequentMenstrualCycles", "IrregularMenstrualCycles", "ProlongedMenstrualPeriods", "PersistentIntermenstrualBleeding"]
    static let categories: [SeriesDefinition] = {
        var result = [
            SeriesDefinition(id: "sleep", hkName: "SleepAnalysis", unitName: "category", chunk: "day", group: "default", kind: .category),
            SeriesDefinition(id: "stand_hour", hkName: "AppleStandHour", unitName: "category", chunk: "day", group: "default", kind: .category),
            SeriesDefinition(id: "mindful_session", hkName: "MindfulSession", unitName: "category", chunk: "month", group: "default", kind: .category),
            SeriesDefinition(id: "low_cardio_fitness_event", hkName: "LowCardioFitnessEvent", unitName: "category", chunk: "month", group: "default", kind: .category),
            SeriesDefinition(id: "menstrual_flow", hkName: "MenstrualFlow", unitName: "category", chunk: "month", group: "reproductive", kind: .category)
        ]
        for name in ["HighHeartRateEvent", "LowHeartRateEvent", "IrregularHeartRhythmEvent"] { result.append(SeriesDefinition(id: "heart_rate_events", hkName: name, unitName: "category", chunk: "month", group: "default", kind: .category)) }
        for name in reproductiveNames { result.append(SeriesDefinition(id: "reproductive_events", hkName: name, unitName: "category", chunk: "month", group: "reproductive", kind: .category)) }
        for name in symptomNames { result.append(SeriesDefinition(id: "symptoms", hkName: name, unitName: "category", chunk: "month", group: "symptoms", kind: .category)) }
        return result
    }()
    static var all: [SeriesDefinition] { quantities + categories + [
        SeriesDefinition(id: "blood_pressure_systolic", hkName: "BloodPressure", unitName: "mmHg", chunk: "month", group: "default", kind: .correlation),
        SeriesDefinition(id: "blood_pressure_diastolic", hkName: "BloodPressure", unitName: "mmHg", chunk: "month", group: "default", kind: .correlation),
        SeriesDefinition(id: "workouts", hkName: "Workout", unitName: "workout", chunk: "record", group: "default", kind: .workout),
        SeriesDefinition(id: "ecg", hkName: "Electrocardiogram", unitName: "µV", chunk: "record", group: "ecg", kind: .ecg)
    ] }
    static let workoutRoutes = SeriesDefinition(id: "_workout_routes", hkName: "WorkoutRoute", unitName: "route", chunk: "record", group: "routes", kind: .route)
    static func enabled(groups: Set<String>) -> [SeriesDefinition] { all.filter { $0.group == "default" || groups.contains($0.group) } }
}
