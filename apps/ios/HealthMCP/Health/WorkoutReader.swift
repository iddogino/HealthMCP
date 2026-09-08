import Foundation
import HealthKit
import CoreLocation

extension HealthReader {
    func workoutRecord(_ workout: HKWorkout) async throws -> [String: Any] {
        var record: [String: Any] = ["id": workout.uuid.uuidString.lowercased(), "type": Self.workoutNames[workout.workoutActivityType.rawValue] ?? "other", "t0": HealthDates.timestamp(workout.startDate), "t1": HealthDates.timestamp(workout.endDate), "duration_s": workout.duration, "src": workout.sourceRevision.source.name]
        var stats: [String: Any] = [:]
        func quantity(_ identifier: HKQuantityTypeIdentifier, _ unit: HKUnit, _ mode: String) -> Double? {
            guard let type = HKObjectType.quantityType(forIdentifier: identifier), let value = workout.statistics(for: type) else { return nil }
            return (mode == "avg" ? value.averageQuantity() : mode == "max" ? value.maximumQuantity() : value.sumQuantity())?.doubleValue(for: unit)
        }
        stats["active_energy_kcal"] = quantity(.activeEnergyBurned, .kilocalorie(), "sum")
        let distance = quantity(.distanceWalkingRunning, .meter(), "sum") ?? quantity(.distanceCycling, .meter(), "sum") ?? quantity(.distanceSwimming, .meter(), "sum")
        stats["distance_m"] = distance
        stats["avg_hr"] = quantity(.heartRate, .count().unitDivided(by: .minute()), "avg")
        stats["max_hr"] = quantity(.heartRate, .count().unitDivided(by: .minute()), "max")
        if let elevation = workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity { stats["elevation_gain_m"] = elevation.doubleValue(for: .meter()) }
        if let distance, distance > 0 { stats["avg_pace_s_per_km"] = workout.duration / (distance / 1000) }
        record["stats"] = stats
        var activities = workout.workoutActivities.map { activity -> [String: Any] in
            var row: [String: Any] = ["type": Self.workoutNames[activity.workoutConfiguration.activityType.rawValue] ?? "other", "t0": HealthDates.timestamp(activity.startDate)]
            if let end = activity.endDate { row["t1"] = HealthDates.timestamp(end) }
            return row
        }
        if activities.isEmpty { activities = [["type": record["type"]!, "t0": record["t0"]!, "t1": record["t1"]!]] }
        record["activities"] = activities
        let heartRate = try await samples(type: HKObjectType.quantityType(forIdentifier: .heartRate)!, predicate: HKQuery.predicateForObjects(from: workout)).compactMap { $0 as? HKQuantitySample }
        record["heart_rate"] = heartRate.map { ["t": HealthDates.timestamp($0.startDate), "v": $0.quantity.doubleValue(for: .count().unitDivided(by: .minute()))] as [String: Any] }
        var route: [[String: Any]] = []
        if routesEnabled {
            let routes = try await samples(type: HKSeriesType.workoutRoute(), predicate: HKQuery.predicateForObjects(from: workout)).compactMap { $0 as? HKWorkoutRoute }
            for item in routes {
                let locations = try await routeLocations(item)
                route.append(contentsOf: locations.filter { $0.horizontalAccuracy >= 0 }.map { ["t": HealthDates.timestamp($0.timestamp), "lat": $0.coordinate.latitude, "lon": $0.coordinate.longitude, "alt_m": $0.altitude, "h_acc_m": $0.horizontalAccuracy] })
            }
        }
        record["route"] = route
        var meta: [String: Any] = ["route_detail_enabled": routesEnabled]
        if let indoor = workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool { meta["indoor"] = indoor }
        if let temperature = workout.metadata?[HKMetadataKeyWeatherTemperature] as? HKQuantity { meta["weather_temp_c"] = temperature.doubleValue(for: .degreeCelsius()) }
        record["meta"] = meta
        return record
    }
    private func routeLocations(_ route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await runHealthQuery(store: healthStore) { finish in
            var locations: [CLLocation] = []
            let query = HKWorkoutRouteQuery(route: route) { _, batch, done, error in
                if let error { finish(.failure(error)); return }
                locations.append(contentsOf: batch ?? [])
                if done { finish(.success(locations)) }
            }
            return query
        }
    }
    func ecgRecord(_ ecg: HKElectrocardiogram) async throws -> [String: Any] {
        let voltages: [Double] = try await runHealthQuery(store: healthStore) { finish in
            var values: [Double] = []
            let query = HKElectrocardiogramQuery(ecg) { _, result in
                switch result {
                case .measurement(let measurement):
                    if let value = measurement.quantity(for: .appleWatchSimilarToLeadI) { values.append(value.doubleValue(for: .voltUnit(with: .micro))) }
                case .done: finish(.success(values))
                case .error(let error): finish(.failure(error))
                @unknown default: finish(.failure(HealthMCPError.message("Unknown ECG response.")))
                }
            }
            return query
        }
        let names = [0: "notSet", 1: "sinusRhythm", 2: "atrialFibrillation", 3: "inconclusiveLowHeartRate", 4: "inconclusiveHighHeartRate", 5: "inconclusivePoorReading", 6: "inconclusiveOther", 100: "unrecognized"]
        var record: [String: Any] = ["id": ecg.uuid.uuidString.lowercased(), "t": HealthDates.timestamp(ecg.startDate), "classification": names[ecg.classification.rawValue] ?? "unrecognized", "voltage_uv": voltages]
        record["avg_hr"] = ecg.averageHeartRate?.doubleValue(for: .count().unitDivided(by: .minute()))
        record["sampling_hz"] = ecg.samplingFrequency?.doubleValue(for: .hertz())
        return record
    }
}
