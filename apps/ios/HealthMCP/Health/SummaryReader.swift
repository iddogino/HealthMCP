import Foundation
import HealthKit

extension HealthReader {
    func statistics(identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date, cumulative: Bool) async throws -> [String: Double] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [:] }
        return try await withCheckedThrowingContinuation { continuation in
            // Omitting separateBySource lets HealthKit merge overlapping device sources.
            let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end), options: cumulative ? .cumulativeSum : .discreteAverage, anchorDate: start, intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    if (error as NSError).code == HKError.errorNoData.rawValue { continuation.resume(returning: [:]) } else { continuation.resume(throwing: error) }
                    return
                }
                var result: [String: Double] = [:]
                collection?.enumerateStatistics(from: start, to: end.addingTimeInterval(-0.001)) { statistics, _ in
                    if let quantity = cumulative ? statistics.sumQuantity() : statistics.averageQuantity() { result[HealthDates.day(statistics.startDate)] = quantity.doubleValue(for: unit) }
                }
                continuation.resume(returning: result)
            }
            healthStore.execute(query)
        }
    }
    func dailySummary(month: String) async throws -> [[String: Any]] {
        let (start, next) = try HealthDates.bounds(month), end = min(next, Date())
        guard start < end else { return [] }
        async let steps = statistics(identifier: .stepCount, unit: .count(), start: start, end: end, cumulative: true)
        async let energy = statistics(identifier: .activeEnergyBurned, unit: .kilocalorie(), start: start, end: end, cumulative: true)
        async let exercise = statistics(identifier: .appleExerciseTime, unit: .minute(), start: start, end: end, cumulative: true)
        async let resting = statistics(identifier: .restingHeartRate, unit: .count().unitDivided(by: .minute()), start: start, end: end, cumulative: false)
        async let hrv = statistics(identifier: .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), start: start, end: end, cumulative: false)
        async let glucose = statistics(identifier: .bloodGlucose, unit: HKUnit(from: "mg/dL"), start: start, end: end, cumulative: false)
        async let oxygen = statistics(identifier: .oxygenSaturation, unit: .percent(), start: start, end: end, cumulative: false)
        let quantities = try await ["steps": steps, "active_energy": energy, "exercise_min": exercise, "resting_hr": resting, "hrv_avg": hrv, "glucose_avg": glucose, "blood_oxygen_avg": oxygen]
        let sleep = try await samples(type: HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!, predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)).compactMap { $0 as? HKCategorySample }.filter { HealthDates.month($0.endDate) == month }
        let workouts = try await samples(type: HKObjectType.workoutType(), predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)).compactMap { $0 as? HKWorkout }.filter { $0.endDate <= Date() }
        var days = Set(quantities.values.flatMap { Array($0.keys) })
        days.formUnion(sleep.map { HealthDates.day($0.endDate) }); days.formUnion(workouts.map { HealthDates.day($0.startDate) })
        return days.sorted().map { day in
            var row: [String: Any] = ["d": day]
            for (name, values) in quantities { if let value = values[day] { row[name] = value * (name == "blood_oxygen_avg" ? 100 : 1) } }
            let night = sleep.filter { HealthDates.day($0.endDate) == day }
            if !night.isEmpty {
                let asleep = night.filter { Self.sleepStage($0.value).hasPrefix("asleep") }
                row["sleep_total_min"] = Self.unionDuration(asleep.map { ($0.startDate, $0.endDate) }) / 60
                var stages: [String: Double] = [:]
                for stage in Set(asleep.map { Self.sleepStage($0.value) }) { stages[stage] = Self.unionDuration(asleep.filter { Self.sleepStage($0.value) == stage }.map { ($0.startDate, $0.endDate) }) / 60 }
                row["sleep_by_stage"] = stages
            }
            row["workouts"] = workouts.filter { HealthDates.day($0.startDate) == day }.count
            return row
        }
    }
    static func unionDuration(_ intervals: [(Date, Date)]) -> TimeInterval {
        let sorted = intervals.filter { $0.0 < $0.1 }.sorted { $0.0 < $1.0 }
        guard var current = sorted.first else { return 0 }
        var duration: TimeInterval = 0
        for interval in sorted.dropFirst() {
            if interval.0 <= current.1 { current.1 = max(current.1, interval.1) }
            else { duration += current.1.timeIntervalSince(current.0); current = interval }
        }
        return duration + current.1.timeIntervalSince(current.0)
    }
    func activityRings(month: String) async throws -> [[String: Any]] {
        let (start, end) = try HealthDates.bounds(month)
        guard start < Date() else { return [] }
        var first = HealthDates.calendar.dateComponents([.era, .year, .month, .day], from: start)
        var last = HealthDates.calendar.dateComponents([.era, .year, .month, .day], from: min(Date(), end.addingTimeInterval(-1)))
        first.calendar = HealthDates.calendar; last.calendar = HealthDates.calendar
        let summaries: [HKActivitySummary] = try await withCheckedThrowingContinuation { continuation in
            let query = HKActivitySummaryQuery(predicate: HKQuery.predicate(forActivitySummariesBetweenStart: first, end: last)) { _, summaries, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: summaries ?? []) }
            }
            healthStore.execute(query)
        }
        return summaries.compactMap { summary in
            guard let day = HealthDates.calendar.date(from: summary.dateComponents(for: HealthDates.calendar)) else { return nil }
            return ["d": HealthDates.day(day), "move_kcal": summary.activeEnergyBurned.doubleValue(for: .kilocalorie()), "move_goal": summary.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie()), "exercise_min": summary.appleExerciseTime.doubleValue(for: .minute()), "exercise_goal": summary.exerciseTimeGoal?.doubleValue(for: .minute()) ?? 0, "stand_h": summary.appleStandHours.doubleValue(for: .count()), "stand_goal": summary.standHoursGoal?.doubleValue(for: .count()) ?? 0]
        }
    }
}
