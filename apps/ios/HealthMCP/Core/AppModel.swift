import Foundation
import SwiftUI
import HealthKit
import BackgroundTasks
import UserNotifications
import LocalAuthentication

struct AgentConnection: Identifiable { let id: String, name: String; let createdAt: Date }
struct PairingPreview: Identifiable { let id: String, name: String, host: String, code: String }

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var initialized = false
    @Published var onboarded = UserDefaults.standard.bool(forKey: "onboarded")
    @Published var onboardingStep = UserDefaults.standard.integer(forKey: "onboardingStep")
    @Published var busy = false
    @Published var error: String?
    @Published var privateKey = ""
    @Published var keyVisible = false
    @Published var keySaved = false
    @Published var currentRun: SyncRun?
    @Published var history: [SyncRun] = []
    @Published var lastSyncedAt: Date?
    @Published var sampleCount = 0
    @Published var cloudBytes = 0
    @Published var cloudChunks = 0
    @Published var seriesCount = 0
    @Published var connections: [AgentConnection] = []
    @Published var pairingCode = ""
    @Published var pairingPreview: PairingPreview?
    @Published var selectedTab = 0
    @Published var groups = Set(UserDefaults.standard.stringArray(forKey: "enabledGroups") ?? [])
    @Published var routesEnabled = UserDefaults.standard.bool(forKey: "routesEnabled")
    @Published var pushStatus = "Not enabled"
    @Published var diagnosticResult: String?
    var api: APIClient?
    var journal: SyncStore?
    let reader = HealthReader()
    private var syncTask: Task<Void, Never>?
    private var observerCompletions: [() -> Void] = []
    private var syncAgain = false
    private var hasBootstrapped = false
    var isSyncing: Bool { currentRun?.status == "running" }
    var definitions: [SeriesDefinition] { SeriesDefinition.enabled(groups: groups) }
    var isDemo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
        #else
        false
        #endif
    }
    func bootstrap() async {
        guard !hasBootstrapped else { return }; hasBootstrapped = true
        defer { initialized = true }
        do {
            journal = try SyncStore()
            history = try journal!.history()
            for var interrupted in history where interrupted.status == "running" {
                interrupted.status = "interrupted"; interrupted.finishedAt = Date(); interrupted.stage = "Ready to resume"; try journal!.save(interrupted)
            }
            history = try journal!.history()
            let identity = try DeviceIdentity()
            let userID = try Keychain.read("user-id").flatMap { String(data: $0, encoding: .utf8) } ?? ""
            api = APIClient(identity: identity, userID: userID)
            if let saved = try Keychain.read("health-key"), let key = String(data: saved, encoding: .utf8) { privateKey = try HealthCrypto.normalize(key) }
            else { privateKey = try HealthCrypto.generateKey(); try Keychain.set("health-key", Data(privateKey.utf8)) }
            reader.routesEnabled = routesEnabled
            sampleCount = try journal!.totalSamples()
            if isDemo { configureDemo(); return }
            if let pending = try Keychain.read("pending-rotation"), let key = String(data: pending, encoding: .utf8), !userID.isEmpty { try await completeRotation(key) }
            if onboarded { installObservers(); await refreshStatus(); startSync(trigger: "App opened") }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-device-e2e") { Task { await awaitSync(); await DeviceValidation.run(model:self) } }
            if ProcessInfo.processInfo.arguments.contains("-device-e2e-finish") { Task { await DeviceValidation.finish(model:self) } }
            #endif
        } catch { self.error = error.localizedDescription }
    }
    func prepareHealth() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            guard var client = api else { throw HealthMCPError.message("Secure storage is not ready. Restart the app after unlocking your iPhone.") }
            if client.userID.isEmpty {
                let result = try await client.json("POST", "/v1/register", ["device_pubkey": client.identity.publicKey.base64EncodedString()])
                guard let id = result["id"] as? String else { throw HealthMCPError.message("Device registration failed.") }
                client.userID = id; api = client; try Keychain.set("user-id", Data(id.utf8))
            }
            try await reader.requestAuthorization(definitions: definitions)
            onboardingStep = 1; UserDefaults.standard.set(1, forKey: "onboardingStep"); keyVisible = true
        } catch { self.error = error.localizedDescription }
    }
    func acceptKey() { keyVisible = false; onboardingStep = 2; UserDefaults.standard.set(2, forKey: "onboardingStep") }
    func startFirstSync() {
        onboardingStep = 3; UserDefaults.standard.set(3, forKey: "onboardingStep")
        installObservers(); startSync(trigger: "Initial backfill")
    }
    func finishOnboarding() { onboarded = true; UserDefaults.standard.set(true, forKey: "onboarded"); keyVisible = false }
    func foreground() {
        guard initialized, onboarded, !isDemo else { return }
        startSync(trigger: "App opened"); Task { await refreshStatus() }
    }
    func startSync(trigger: String) {
        guard !isDemo, api?.userID.isEmpty == false else { return }
        if isSyncing { if trigger != "App opened" { syncAgain = true }; return }
        currentRun = SyncRun(trigger: trigger)
        syncTask = Task { await runSync() }
    }
    func pauseSync() { syncAgain = false; syncTask?.cancel() }
    func awaitSync() async { await syncTask?.value }
    private func recordProgress() throws {
        if let currentRun { try journal?.save(currentRun) }
    }
    private func runSync() async {
        guard let journal, let client = api else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        var failedSeries = Set<String>()
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            observerCompletions.forEach { $0() }; observerCompletions.removeAll()
            scheduleBackstop()
            if syncAgain { syncAgain = false; startSync(trigger: "Health data changed") }
        }
        do {
            try recordProgress()
            currentRun?.stage = "Checking your private key"
            _ = try await client.upload(series: "check", period: "single", plaintext: Data("\"ok\"".utf8), key: privateKey)
            let defs = definitions
            let grouped = Dictionary(grouping: defs.compactMap { definition -> (HKSampleType, SeriesDefinition)? in guard let type = definition.sampleType else { return nil }; return (type, definition) }, by: { $0.0.identifier })
            let typeNames = grouped.keys.sorted()
            for (offset, typeName) in typeNames.enumerated() {
                try Task.checkCancellation()
                guard let entries = grouped[typeName], let type = entries.first?.0 else { continue }
                currentRun?.stage = "Reading \(entries[0].1.title)"
                currentRun?.progress = 0.35 * Double(offset) / Double(max(1, typeNames.count))
                do {
                    var anchor = try journal.anchor(for: typeName)
                    while true {
                        let (samples, deleted, next) = try await reader.anchored(type: type, anchor: anchor)
                        let indexed = entries.flatMap { entry in samples.map { reader.index($0, definition: entry.1) } }
                        try journal.applyPage(type: typeName, samples: indexed, deleted: deleted.map(\.uuid), anchor: next)
                        anchor = next; currentRun?.sampleCount += samples.count
                        try recordProgress(); try Task.checkCancellation()
                        if samples.count + deleted.count < 1000 { break }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    if SyncInterruption.isHealthDataLocked(error) { throw SyncInterruption.healthDataLocked }
                    failedSeries.formUnion(entries.map { $0.1.id }); currentRun?.errors.append("\(entries[0].1.title): \(error.localizedDescription)")
                }
            }
            sampleCount = try journal.totalSamples()
            try journal.markDirty("daily_summary", HealthDates.month(Date()))
            try journal.markDirty("activity_rings", HealthDates.month(Date()))
            let profile = try reader.json(reader.profile())
            let profileBytes = try await client.upload(series: "profile", period: "single", plaintext: profile, key: privateKey)
            currentRun?.uploadedBytes += profileBytes
            try journal.recordDerived(series: "profile", period: "single", count: 1, first: HealthDates.day(Date()), last: HealthDates.day(Date()))
            let chunks = try journal.dirtyChunks()
            currentRun?.totalChunks = chunks.count; currentRun?.stage = "Encrypting and uploading"; currentRun?.progress = 0.35
            for offset in stride(from: 0, to: chunks.count, by: 4) {
                try Task.checkCancellation()
                let batch = Array(chunks[offset..<min(offset+4, chunks.count)])
                var healthDataLocked = false
                await withTaskGroup(of: (String, String?, Bool).self) { group in
                    for chunk in batch { group.addTask { await self.syncChunk(chunk, definitions: defs, client: client) } }
                    for await (series, error, locked) in group {
                        if locked { healthDataLocked = true; group.cancelAll() }
                        if let error { failedSeries.insert(series); currentRun?.errors.append(error) }
                    }
                }
                if healthDataLocked { throw SyncInterruption.healthDataLocked }
                try Task.checkCancellation()
                currentRun?.progress = 0.35 + 0.60 * Double(min(offset+4, chunks.count)) / Double(max(1, chunks.count))
                try recordProgress()
            }
            currentRun?.stage = "Updating your catalog"
            for series in Set(defs.map(\.id) + ["profile", "daily_summary", "activity_rings"]) where !failedSeries.contains(series) {
                let summary = try journal.summary(series)
                let derived = try journal.derivedSummary(series)
                let count = summary?.0 ?? derived?.0 ?? 0
                let first = summary.map { HealthDates.day($0.1) } ?? derived?.1 ?? HealthDates.day(Date())
                let last = summary.map { HealthDates.day($0.2) } ?? derived?.2 ?? first
                _ = try await client.json("PUT", "/v1/series", ["series": series, "first_day": first, "last_day": last, "total_samples": count])
            }
            if currentRun?.errors.isEmpty == true {
                _ = try await client.json("POST", "/v1/sync/complete", [:]); lastSyncedAt = Date()
                currentRun?.status = "complete"; currentRun?.stage = sampleCount == 0 ? "No readable health samples yet" : "Your encrypted cache is up to date"; currentRun?.progress = 1
            } else { currentRun?.status = "partial"; currentRun?.stage = "Some data needs another attempt" }
        } catch where SyncInterruption.isHealthDataLocked(error) {
            syncAgain = false
            currentRun?.pauseForProtectedData()
        } catch is CancellationError { currentRun?.status = "paused"; currentRun?.stage = "Progress saved. Ready to resume." }
        catch { currentRun?.status = "failed"; currentRun?.stage = "Sync needs attention"; currentRun?.errors.append(error.localizedDescription) }
        currentRun?.finishedAt = Date()
        do { try recordProgress(); history = try journal.history() } catch { self.error = error.localizedDescription }
        await refreshStatus()
    }
    private func syncChunk(_ chunk: DirtyChunk, definitions: [SeriesDefinition], client: APIClient) async -> (String, String?, Bool) {
        do {
            try Task.checkCancellation()
            currentRun?.stage = "Syncing \(chunk.series.replacingOccurrences(of: "_", with: " ")) · \(chunk.period.prefix(10))"
            let (plaintext, count) = try await reader.chunk(chunk, definitions: definitions)
            var uploadedBytes = 0
            for attempt in 0..<3 {
                do {
                    if count == 0 { try await client.delete(series: chunk.series, period: chunk.period) }
                    else { uploadedBytes = try await client.upload(series: chunk.series, period: chunk.period, plaintext: plaintext, key: privateKey) }
                    break
                } catch {
                    if attempt == 2 || Task.isCancelled { throw error }
                    try await Task.sleep(for: .seconds(Double(1 << attempt)))
                }
            }
            if ["daily_summary", "activity_rings"].contains(chunk.series) {
                let rows = (try JSONSerialization.jsonObject(with: plaintext)) as? [[String: Any]] ?? []
                let days = rows.compactMap { $0["d"] as? String }.sorted()
                try journal?.recordDerived(series: chunk.series, period: chunk.period, count: count, first: days.first ?? chunk.period+"-01", last: days.last ?? chunk.period+"-01")
            }
            try journal?.clearDirty(chunk)
            currentRun?.uploadedChunks += 1; currentRun?.uploadedBytes += uploadedBytes
            try recordProgress()
            return (chunk.series, nil, false)
        } catch is CancellationError { return (chunk.series, nil, false) }
        catch {
            if SyncInterruption.isHealthDataLocked(error) { return (chunk.series, nil, true) }
            return (chunk.series, "\(chunk.series) \(chunk.period): \(error.localizedDescription)", false)
        }
    }
    func refreshStatus() async {
        guard let client = api, !client.userID.isEmpty, !isDemo else { return }
        do {
            let result = try await client.json("GET", "/v1/status")
            if let timestamp = result["last_synced_at"] as? Double { lastSyncedAt = Date(timeIntervalSince1970: timestamp) }
            let usage = result["usage"] as? [String: Any]; cloudBytes = usage?["bytes"] as? Int ?? 0; cloudChunks = usage?["chunks"] as? Int ?? 0
            seriesCount = (result["series"] as? [Any])?.count ?? 0
            pushStatus = result["push_registered"] as? Bool == true ? "Device registered" : "Not enabled"
            let response = try await client.json("GET", "/v1/connections")
            connections = (response["connections"] as? [[String: Any]] ?? []).compactMap { row in guard let id = row["id"] as? String, let name = row["client_name"] as? String, let date = row["created_at"] as? Double else { return nil }; return AgentConnection(id: id, name: name, createdAt: Date(timeIntervalSince1970: date)) }
        } catch { if !isSyncing { pushStatus = "Service unavailable" } }
    }
    func previewPairing() async {
        busy = true; defer { busy = false }
        do {
            guard let result = try await api?.json("POST", "/v1/pair/preview", ["code": pairingCode]), let id = result["pairing_id"] as? String, let name = result["client_name"] as? String, let host = result["redirect_host"] as? String else { throw HealthMCPError.message("Pairing could not be verified.") }
            pairingPreview = PairingPreview(id: id, name: name, host: host, code: pairingCode)
        } catch { self.error = error.localizedDescription }
    }
    func approvePairing() async {
        guard let preview = pairingPreview else { return }; busy = true; defer { busy = false }
        do { _ = try await api?.json("POST", "/v1/pair/approve", ["code": preview.code, "pairing_id": preview.id]); pairingPreview = nil; pairingCode = ""; await refreshStatus() } catch { self.error = error.localizedDescription }
    }
    func revoke(_ connection: AgentConnection) async {
        do { _ = try await api?.json("DELETE", "/v1/connections/"+connection.id); await refreshStatus() } catch { self.error = error.localizedDescription }
    }
    func handleURL(_ url: URL) {
        guard (url.scheme == "healthmcp" && url.host == "pair") || (["healthmcp.cc", "mcp.healthmcp.cc"].contains(url.host ?? "") && url.path == "/pair"), let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value, code.count == 6, code.allSatisfy(\.isNumber) else { return }
        pairingCode = code; selectedTab = 1
    }
    func revealKey() async {
        do { let context = LAContext(); let allowed = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Reveal your Health MCP private key"); keyVisible = allowed } catch { self.error = error.localizedDescription }
    }
    func enableNotifications() async {
        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]); UIApplication.shared.registerForRemoteNotifications() } catch { self.error = error.localizedDescription }
    }
    func setGroup(_ group: String, enabled: Bool) async {
        pauseSync(); await awaitSync(); busy = true; defer { busy = false }
        do {
            if enabled { groups.insert(group) }
            else {
                for series in Set(SeriesDefinition.all.filter { $0.group == group }.map(\.id)) {
                    _ = try await api?.json("DELETE", "/v1/series?series="+series)
                    try journal?.clearSeries(series)
                }
                groups.remove(group)
            }
            UserDefaults.standard.set(Array(groups), forKey: "enabledGroups")
            try await reader.requestAuthorization(definitions: definitions)
            installObservers(); startSync(trigger: "Data settings changed")
        } catch { self.error = error.localizedDescription }
    }
    func setRoutes(_ enabled: Bool) async {
        pauseSync(); await awaitSync(); busy = true; defer { busy = false }
        do {
            _ = try await api?.json("DELETE", "/v1/series?series=workouts")
            try journal?.clearSeries("workouts")
            routesEnabled = enabled; reader.routesEnabled = enabled; UserDefaults.standard.set(enabled, forKey: "routesEnabled")
            try await reader.requestAuthorization(definitions: definitions)
            startSync(trigger: "Workout detail changed")
        } catch { self.error = error.localizedDescription }
    }
    func registerPush(_ token: Data) async {
        guard let api, !api.userID.isEmpty else { return }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        do { _ = try await api.json("POST", "/v1/apns", ["token": token.map { String(format: "%02x", $0) }.joined(), "environment": environment]); pushStatus = "Device registered" } catch { pushStatus = "Registration failed" }
    }
    private func installObservers() {
        reader.observe(definitions: definitions) { [weak self] completion in
            guard let self else { completion(); return }
            self.observerCompletions.append(completion)
            if self.isSyncing { self.syncAgain = true }
            else if let last = self.lastSyncedAt, Date().timeIntervalSince(last) < 600 {
                self.scheduleBackstop(after: 600); self.observerCompletions.forEach { $0() }; self.observerCompletions.removeAll()
            } else { self.startSync(trigger: "Health data changed") }
        }
        UIApplication.shared.registerForRemoteNotifications()
        scheduleBackstop()
    }
    func scheduleBackstop(after delay: TimeInterval? = nil) {
        let request = BGProcessingTaskRequest(identifier: "cc.healthmcp.app.sync")
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = delay.map { Date().addingTimeInterval($0) } ?? Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 2), matchingPolicy: .nextTime)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: request.identifier)
        try? BGTaskScheduler.shared.submit(request)
    }
    func rotateKey() async {
        pauseSync(); await awaitSync(); busy = true; defer { busy = false }
        do { let key = try HealthCrypto.generateKey(); try Keychain.set("pending-rotation", Data(key.utf8)); try await completeRotation(key); keyVisible = true; keySaved = false; startSync(trigger: "Key rotation backfill") } catch { self.error = error.localizedDescription }
    }
    private func completeRotation(_ key: String) async throws {
        _ = try await api?.json("POST", "/v1/cache/reset", [:])
        try Keychain.set("health-key", Data(key.utf8)); privateKey = key
        try journal?.resetIndex(); Keychain.remove("pending-rotation"); connections = []; lastSyncedAt = nil
    }
    func deleteAccount() async {
        pauseSync(); await awaitSync(); busy = true; defer { busy = false }
        do {
            _ = try await api?.json("DELETE", "/v1/account")
            reader.stopObservers(); BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: "cc.healthmcp.app.sync"); try journal?.resetIndex(); try journal?.execute("DELETE FROM history")
            for name in ["user-id", "health-key", "device-key", "simulator-device-key", "pending-rotation"] { Keychain.remove(name) }
            for name in ["onboarded", "onboardingStep", "enabledGroups", "routesEnabled"] { UserDefaults.standard.removeObject(forKey: name) }
            onboarded = false; onboardingStep = 0; history = []; currentRun = nil; connections = []; sampleCount = 0; hasBootstrapped = false
            groups = []; routesEnabled = false; lastSyncedAt = nil; cloudBytes = 0; cloudChunks = 0; seriesCount = 0; keyVisible = false; keySaved = false
            await bootstrap()
        } catch { self.error = error.localizedDescription }
    }
    private func configureDemo() {
        onboarded = !ProcessInfo.processInfo.arguments.contains("-onboarding")
        onboardingStep = 0; privateKey = "0123456789ABCDEF" + String(try! HealthCrypto.checksum("0123456789ABCDEF"))
        lastSyncedAt = Date().addingTimeInterval(-240); sampleCount = 24836; cloudChunks = 186; cloudBytes = 1843200; seriesCount = 24
        var run = SyncRun(trigger: "Health data changed"); run.startedAt = Date().addingTimeInterval(-285); run.finishedAt = Date().addingTimeInterval(-240); run.status = "complete"; run.stage = "Your encrypted cache is up to date"; run.uploadedChunks = 18; run.totalChunks = 18; run.uploadedBytes = 182400; run.progress = 1
        history = [run]; pushStatus = "Device registered"
        if ProcessInfo.processInfo.arguments.contains("-ui-syncing") { run.status = "running"; run.trigger = "Initial backfill"; run.progress = 0.62; run.totalChunks = 320; run.uploadedChunks = 144; run.stage = "Encrypting and uploading"; currentRun = run }
    }
}
