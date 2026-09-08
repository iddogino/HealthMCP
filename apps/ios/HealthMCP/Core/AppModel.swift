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
            journal = try await SyncStore.open()
            history = try await journal!.history()
            for var interrupted in history where interrupted.status == "running" {
                interrupted.status = "interrupted"; interrupted.finishedAt = Date(); interrupted.stage = "Ready to resume"; try await journal!.save(interrupted)
            }
            history = try await journal!.history()
            let identity = try DeviceIdentity()
            let userID = try Keychain.read("user-id").flatMap { String(data: $0, encoding: .utf8) } ?? ""
            api = APIClient(identity: identity, userID: userID)
            if let saved = try Keychain.read("health-key"), let key = String(data: saved, encoding: .utf8) { privateKey = try HealthCrypto.normalize(key) }
            else { privateKey = try HealthCrypto.generateKey(); try Keychain.set("health-key", Data(privateKey.utf8)) }
            await reader.setRoutesEnabled(routesEnabled)
            sampleCount = try await journal!.totalSamples()
            if isDemo { configureDemo(); return }
            if let pending = try Keychain.read("pending-rotation"), let key = String(data: pending, encoding: .utf8), !userID.isEmpty { try await completeRotation(key) }
            if onboarded { await installObservers(); startSync(trigger: "App opened"); Task { await refreshStatus() } }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-device-e2e") { Task { await awaitSync(); await DeviceValidation.run(model:self) } }
            if ProcessInfo.processInfo.arguments.contains("-device-e2e-incremental") {
                Task {
                    for _ in 0..<120 {
                        await refreshStatus()
                        if seriesCount >= 3 { await DeviceValidation.run(model: self); break }
                        try? await Task.sleep(for: .seconds(5))
                    }
                }
            }
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
    func startFirstSync() async {
        onboardingStep = 3; UserDefaults.standard.set(3, forKey: "onboardingStep")
        await installObservers(); startSync(trigger: "Initial backfill")
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
    private func runSync() async {
        guard let journal, let client = api, let initial = currentRun else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        #if DEBUG
        let responsiveness = Task { @MainActor in
            var last = ContinuousClock.now, saved = ContinuousClock.now
            var maxGap = 0.0, ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
                let now = ContinuousClock.now, elapsed = last.duration(to: now).components
                maxGap = max(maxGap, Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15); last = now; ticks += 1
                if saved.duration(to: now) >= .seconds(5) {
                    let values: [String: Any] = ["updated_at": HealthDates.timestamp(Date()), "ticks": ticks, "maximum_main_actor_gap_ms": maxGap]
                    Task.detached(priority: .utility) { SyncDiagnostics.write(values, name: "responsiveness.json") }
                    saved = now
                }
            }
        }
        defer { responsiveness.cancel() }
        #endif
        let engine = SyncEngine(store: journal, reader: reader, client: client, key: privateKey, run: initial) { [weak self] run in
            self?.currentRun = run
        }
        let completed = await engine.sync(definitions: definitions)
        currentRun = completed
        if completed.status == "complete" { lastSyncedAt = Date() }
        if completed.status == "paused" || completed.status == "failed" { syncAgain = false }
        do { sampleCount = try await journal.totalSamples(); history = try await journal.history() }
        catch { self.error = error.localizedDescription }
        UIApplication.shared.isIdleTimerDisabled = false
        observerCompletions.forEach { $0() }; observerCompletions.removeAll()
        scheduleBackstop()
        await refreshStatus()
        if syncAgain { syncAgain = false; startSync(trigger: "Health data changed") }
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
                    try await journal?.clearSeries(series)
                }
                groups.remove(group)
            }
            UserDefaults.standard.set(Array(groups), forKey: "enabledGroups")
            try await reader.requestAuthorization(definitions: definitions)
            await installObservers(); startSync(trigger: "Data settings changed")
        } catch { self.error = error.localizedDescription }
    }
    func setRoutes(_ enabled: Bool) async {
        pauseSync(); await awaitSync(); busy = true; defer { busy = false }
        do {
            _ = try await api?.json("DELETE", "/v1/series?series=workouts")
            try await journal?.clearSeries("workouts")
            routesEnabled = enabled; await reader.setRoutesEnabled(enabled); UserDefaults.standard.set(enabled, forKey: "routesEnabled")
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
    private func installObservers() async {
        await reader.observe(definitions: definitions) { [weak self] completion in
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
        try await journal?.resetIndex(); Keychain.remove("pending-rotation"); connections = []; lastSyncedAt = nil
    }
    func deleteAccount() async {
        pauseSync(); await awaitSync(); busy = true; defer { busy = false }
        do {
            _ = try await api?.json("DELETE", "/v1/account")
            await reader.stopObservers(); BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: "cc.healthmcp.app.sync"); try await journal?.resetIndex(); try await journal?.execute("DELETE FROM history")
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
        if ProcessInfo.processInfo.arguments.contains("-ui-syncing") { run.status = "running"; run.trigger = "Initial backfill"; run.progress = 0.62; run.totalChunks = 320; run.uploadedChunks = 144; run.stage = "Encrypting and uploading"; run.phase = "streaming"; run.completedTypes = 17; run.totalTypes = 53; currentRun = run }
    }
}
