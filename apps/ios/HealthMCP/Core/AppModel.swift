import Foundation
import SwiftUI
import HealthKit
import BackgroundTasks
import UserNotifications
import LocalAuthentication

struct AgentConnection: Identifiable { let id: String, name: String; let createdAt: Date }
struct PairingPreview: Identifiable { let id: String, name: String, host: String, code: String }

struct PrivacyOperation: Codable, Sendable {
    enum Kind: String, Codable { case group, routes, rotate, deleteAccount }
    var id = UUID().uuidString
    let kind: Kind
    var group: String? = nil
    var enabled = false
    var newKey: String? = nil
    var remoteConfirmed = false
}

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var initialized = false
    @Published var onboarded: Bool
    @Published var onboardingStep: Int
    @Published var busy = false
    @Published var error: String?
    @Published var privateKey = ""
    @Published var keyVisible = false
    @Published var keySaved = false
    @Published var currentRun: SyncRun?
    @Published var history: [SyncRun] = []
    @Published var lastSyncedAt: Date?
    @Published var syncAvailability: SyncAvailability?
    @Published var sampleCount = 0
    @Published var cloudBytes = 0
    @Published var cloudChunks = 0
    @Published var seriesCount = 0
    @Published var connections: [AgentConnection] = []
    @Published var pairingCode = ""
    @Published var pairingPreview: PairingPreview?
    @Published var selectedTab = 0
    @Published var groups: Set<String>
    @Published var routesEnabled: Bool
    @Published var pushStatus = "Not enabled"
    @Published var diagnosticResult: String?
    var api: APIClient?
    var journal: SyncStore?
    let reader = HealthReader()
    private var syncTask: Task<Void, Never>?
    private var observerCompletions: [() -> Void] = []
    private var syncAgain = false
    private var bootstrapTask: Task<Void, Never>?
    @Published private(set) var startupError: String?
    @Published private(set) var pendingPrivacy: PrivacyOperation?
    private var privacyExecuting = false
    private let preferences: UserDefaults
    private let secureStorage: any SecureStoring
    private let journalURL: URL?
    private let apiBaseURL: URL
    private let apiSession: URLSession
    private let allowsBackgroundWork: Bool
    init(preferences: UserDefaults = .standard, secureStorage: any SecureStoring = KeychainStore(), journalURL: URL? = nil, apiBaseURL: URL = APIClient.production, apiSession: URLSession = .shared, allowsBackgroundWork: Bool = true) {
        self.preferences = preferences; self.secureStorage = secureStorage; self.journalURL = journalURL
        self.apiBaseURL = apiBaseURL; self.apiSession = apiSession; self.allowsBackgroundWork = allowsBackgroundWork
        onboarded = preferences.bool(forKey: "onboarded"); onboardingStep = preferences.integer(forKey: "onboardingStep")
        groups = Set(preferences.stringArray(forKey: "enabledGroups") ?? []); routesEnabled = preferences.bool(forKey: "routesEnabled")
    }
    var isSyncing: Bool { currentRun?.status == "running" }
    var definitions: [SeriesDefinition] { SeriesDefinition.enabled(groups: groups) + (routesEnabled ? [.workoutRoutes] : []) }
    var isDemo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
        #else
        false
        #endif
    }
    func bootstrap() async {
        if let task = bootstrapTask { await task.value; return }
        guard !initialized else { return }
        startupError = nil
        let task = Task { await initialize() }
        bootstrapTask = task
        await task.value
        bootstrapTask = nil
    }
    private func initialize() async {
        do {
            journal = try await SyncStore.open(url: journalURL)
            if let data = try secureStorage.read("privacy-operation") { pendingPrivacy = try JSONDecoder().decode(PrivacyOperation.self, from: data) }
            // A confirmed deletion must finish even if a crash removed only some credentials.
            if pendingPrivacy?.kind == .deleteAccount, pendingPrivacy?.remoteConfirmed == true { try await clearLocalAccount() }
            history = try await journal!.history()
            for var interrupted in history where interrupted.status == "running" {
                interrupted.status = "interrupted"; interrupted.finishedAt = Date(); interrupted.stage = "Ready to resume"; try await journal!.save(interrupted)
            }
            history = try await journal!.history()
            #if targetEnvironment(simulator)
            let identityExists = try secureStorage.read("simulator-device-key") != nil
            #else
            let identityExists = try secureStorage.read("device-key") != nil
            #endif
            var userID = try secureStorage.read("user-id").flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // Preferences can migrate to a new phone; ThisDeviceOnly credentials cannot.
            if !identityExists || userID.isEmpty {
                guard pendingPrivacy == nil else { throw HealthMCPError.message("Privacy cleanup needs this device's original credentials. Please contact support@healthmcp.cc.") }
                userID = ""; try secureStorage.remove("user-id")
                onboarded = false; onboardingStep = 0
                preferences.set(false, forKey: "onboarded"); preferences.set(0, forKey: "onboardingStep")
                try await journal!.resetIndex()
            }
            let identity = try DeviceIdentity(storage: secureStorage)
            api = APIClient(identity: identity, userID: userID, baseURL: apiBaseURL, session: apiSession)
            if let saved = try secureStorage.read("health-key"), let key = String(data: saved, encoding: .utf8) { privateKey = try HealthCrypto.normalize(key) }
            else if userID.isEmpty { privateKey = try HealthCrypto.generateKey(); try secureStorage.set("health-key", Data(privateKey.utf8)) }
            else if pendingPrivacy == nil { try savePrivacy(PrivacyOperation(kind: .rotate, newKey: HealthCrypto.generateKey())) }
            if pendingPrivacy == nil, let legacy = try secureStorage.read("pending-rotation"), let key = String(data: legacy, encoding: .utf8) { try savePrivacy(PrivacyOperation(kind: .rotate, newKey: HealthCrypto.normalize(key))) }
            await reader.setRoutesEnabled(routesEnabled)
            sampleCount = try await journal!.totalSamples()
            if pendingPrivacy == nil { syncAvailability = try await journal!.availability(for: definitions) }
            if isDemo { configureDemo(); initialized = true; return }
            if pendingPrivacy != nil { await retryPrivacy() }
            if api == nil { await initialize(); return }
            initialized = true
            if pendingPrivacy == nil, onboarded, allowsBackgroundWork { await installObservers(); if UIApplication.shared.applicationState == .active { startSync(trigger: "App opened"); Task { await refreshStatus() } } }
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
        } catch { startupError = error.localizedDescription; initialized = false }
    }
    func prepareHealth() async {
        guard !busy, pendingPrivacy == nil else { return }; busy = true; defer { busy = false }
        do {
            guard var client = api else { throw HealthMCPError.message("Secure storage is not ready. Restart the app after unlocking your iPhone.") }
            if client.userID.isEmpty {
                let result = try await client.json("POST", "/v1/register", ["device_pubkey": client.identity.publicKey.base64EncodedString()])
                guard let id = result["id"] as? String else { throw HealthMCPError.message("Device registration failed.") }
                client.userID = id; api = client; try secureStorage.set("user-id", Data(id.utf8))
            }
            try await reader.requestAuthorization(definitions: definitions)
            onboardingStep = 1; preferences.set(1, forKey: "onboardingStep"); keyVisible = true
        } catch { self.error = error.localizedDescription }
    }
    func acceptKey() { keyVisible = false; onboardingStep = 2; preferences.set(2, forKey: "onboardingStep") }
    func startFirstSync() async {
        onboardingStep = 3; preferences.set(3, forKey: "onboardingStep")
        await installObservers(); startSync(trigger: "Initial backfill")
    }
    func finishOnboarding() { onboarded = true; preferences.set(true, forKey: "onboarded"); keyVisible = false }
    func foreground() {
        guard !isDemo else { return }
        Task {
            await bootstrap()
            guard initialized else { return }
            if pendingPrivacy != nil { await retryPrivacy(); return }
            if onboarded, allowsBackgroundWork { startSync(trigger: "App opened"); await refreshStatus() }
        }
    }
    func startSync(trigger: String) {
        guard initialized, !isDemo, api?.userID.isEmpty == false else { return }
        guard pendingPrivacy == nil, !privacyExecuting else { return }
        if syncTask != nil { if trigger != "App opened" { syncAgain = true }; return }
        currentRun = SyncRun(trigger: trigger)
        syncTask = Task { await runSync() }
    }
    func backgroundSync(trigger: String, completion: @escaping (Bool) -> Void) {
        let existingRun = isSyncing ? currentRun?.id : nil
        var ownedRun: String?
        BackgroundSyncSlice.run(budget: .seconds(23), work: { [weak self] in
            guard let self else { return false }
            await self.bootstrap()
            guard !Task.isCancelled, self.initialized else { return false }
            self.startSync(trigger: trigger)
            if existingRun == nil { ownedRun = self.currentRun?.id }
            await self.awaitSync()
            return self.currentRun?.status == "complete"
        }, expired: { [weak self] in
            guard let self else { return }
            if UIApplication.shared.applicationState != .active, let ownedRun, self.currentRun?.id == ownedRun { self.pauseSync() }
            self.scheduleBackstop(after: 60)
        }, completion: completion)
    }
    func pauseSync() { syncAgain = false; syncTask?.cancel() }
    func awaitSync() async { await syncTask?.value }
    private func runSync() async {
        guard let journal, let client = api, let initial = currentRun else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        // Refresh the server's totals independently of HealthKit reads and uploads.
        // One request at a time, only for the lifetime of this sync.
        let liveStatus = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                guard !Task.isCancelled else { break }
                await refreshStatus(includeConnections: false)
            }
        }
        defer { liveStatus.cancel() }
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
        let completed: SyncRun
        do {
            let syncClient = try await client.forSync()
            try Task.checkCancellation()
            let engine = SyncEngine(store: journal, reader: reader, client: syncClient, key: privateKey, run: initial) { [weak self] run in
                self?.currentRun = run
                if self?.pendingPrivacy == nil { self?.syncAvailability = run.availability }
            }
            completed = await engine.sync(definitions: definitions)
        } catch {
            var failed = initial; failed.status = Task.isCancelled ? "paused" : "failed"
            failed.stage = "Progress saved. Resume when the service is available."; failed.finishedAt = Date()
            if !Task.isCancelled { failed.errors = [error.localizedDescription] }
            try? await journal.save(failed); completed = failed
        }
        liveStatus.cancel()
        await liveStatus.value
        currentRun = completed
        if completed.status == "complete" { lastSyncedAt = Date() }
        if completed.status == "paused" || completed.status == "failed" { syncAgain = false }
        do { sampleCount = try await journal.totalSamples(); history = try await journal.history() }
        catch { self.error = error.localizedDescription }
        UIApplication.shared.isIdleTimerDisabled = false
        observerCompletions.forEach { $0() }; observerCompletions.removeAll()
        scheduleBackstop()
        if !Task.isCancelled { await refreshStatus() }
        syncTask = nil
        if syncAgain { syncAgain = false; startSync(trigger: "Health data changed") }
    }
    func refreshStatus(includeConnections: Bool = true) async {
        guard let client = api, !client.userID.isEmpty, !isDemo else { return }
        do {
            let result = try await client.json("GET", "/v1/status")
            try Task.checkCancellation()
            guard api?.userID == client.userID else { return }
            if let timestamp = result["last_synced_at"] as? Double { lastSyncedAt = Date(timeIntervalSince1970: timestamp) }
            let usage = result["usage"] as? [String: Any]; cloudBytes = usage?["bytes"] as? Int ?? 0; cloudChunks = usage?["chunks"] as? Int ?? 0
            seriesCount = (result["series"] as? [Any])?.count ?? 0
            pushStatus = result["push_registered"] as? Bool == true ? "Device registered" : "Not enabled"
            #if DEBUG
            let snapshot: [String: Any] = ["updated_at": HealthDates.timestamp(Date()), "series_count": seriesCount, "cloud_bytes": cloudBytes, "cloud_chunks": cloudChunks, "sync_running": isSyncing, "sync_run_id": currentRun?.id ?? ""]
            Task.detached(priority: .utility) { SyncDiagnostics.write(snapshot, name: "status.json") }
            #endif
            guard includeConnections else { return }
            let response = try await client.json("GET", "/v1/connections")
            try Task.checkCancellation()
            guard api?.userID == client.userID else { return }
            connections = (response["connections"] as? [[String: Any]] ?? []).compactMap { row in guard let id = row["id"] as? String, let name = row["client_name"] as? String, let date = row["created_at"] as? Double else { return nil }; return AgentConnection(id: id, name: name, createdAt: Date(timeIntervalSince1970: date)) }
        } catch { if !Task.isCancelled, !isSyncing { pushStatus = "Service unavailable" } }
    }
    func previewPairing() async {
        guard !busy, pendingPrivacy == nil else { return }
        if isDemo { pairingPreview = PairingPreview(id: "demo-pairing", name: "Demo Agent", host: "localhost", code: pairingCode); return }
        busy = true; defer { busy = false }
        do {
            guard let result = try await api?.json("POST", "/v1/pair/preview", ["code": pairingCode]), let id = result["pairing_id"] as? String, let name = result["client_name"] as? String, let host = result["redirect_host"] as? String else { throw HealthMCPError.message("Pairing could not be verified.") }
            pairingPreview = PairingPreview(id: id, name: name, host: host, code: pairingCode)
        } catch { self.error = error.localizedDescription }
    }
    func approvePairing() async {
        guard !busy, pendingPrivacy == nil, let preview = pairingPreview else { return }; busy = true; defer { busy = false }
        if isDemo { connections = [AgentConnection(id: preview.id, name: preview.name, createdAt: Date())]; pairingPreview = nil; pairingCode = ""; return }
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
        await performPrivacy(PrivacyOperation(kind: .group, group: group, enabled: enabled))
    }
    func setRoutes(_ enabled: Bool) async { await performPrivacy(PrivacyOperation(kind: .routes, enabled: enabled)) }
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
        guard allowsBackgroundWork, pendingPrivacy == nil else { return }
        await reader.observe(definitions: definitions) { [weak self] completion in
            guard let self else { completion(); return }
            guard self.pendingPrivacy == nil, !self.privacyExecuting else { completion(); return }
            if UIApplication.shared.applicationState != .active {
                self.backgroundSync(trigger: "Health data changed") { _ in completion() }
                return
            }
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
        guard allowsBackgroundWork, onboarded else { return }
        let request = BGProcessingTaskRequest(identifier: "cc.healthmcp.app.sync")
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = delay.map { Date().addingTimeInterval($0) } ?? Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 2), matchingPolicy: .nextTime)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: request.identifier)
        try? BGTaskScheduler.shared.submit(request)
    }
    func rotateKey() async {
        do { await performPrivacy(PrivacyOperation(kind: .rotate, newKey: try HealthCrypto.generateKey())) }
        catch { self.error = error.localizedDescription }
    }
    func deleteAccount() async { await performPrivacy(PrivacyOperation(kind: .deleteAccount)) }
    private func savePrivacy(_ operation: PrivacyOperation) throws {
        try secureStorage.set("privacy-operation", JSONEncoder().encode(operation))
        pendingPrivacy = operation
    }
    private func performPrivacy(_ operation: PrivacyOperation) async {
        guard !busy, !privacyExecuting, pendingPrivacy == nil else { return }
        // Acquire the gate and journal intent before the first suspension point.
        do { try savePrivacy(operation) } catch { self.error = error.localizedDescription; return }
        await retryPrivacy()
    }
    func retryPrivacy() async {
        guard !privacyExecuting, var operation = pendingPrivacy else { return }
        privacyExecuting = true; busy = true
        defer { privacyExecuting = false; busy = false }
        pauseSync(); await awaitSync()
        syncAvailability = nil
        do {
            guard let client = api, let journal else { throw HealthMCPError.message("Secure storage is not ready. Unlock your iPhone and retry.") }
            switch operation.kind {
            case .group:
                guard let group = operation.group, group != "default" else { throw HealthMCPError.message("Invalid data setting.") }
                if operation.enabled { groups.insert(group) }
                else {
                    for series in Set(SeriesDefinition.all.filter { $0.group == group }.map(\.id)).sorted() {
                        _ = try await client.json("DELETE", "/v1/series?series=" + series)
                        try await journal.clearSeries(series)
                    }
                    groups.remove(group)
                }
                preferences.set(Array(groups), forKey: "enabledGroups")
                if operation.enabled, allowsBackgroundWork { try await reader.requestAuthorization(definitions: definitions) }
            case .routes:
                _ = try await client.json("DELETE", "/v1/series?series=workouts")
                try await journal.clearSeries("workouts"); try await journal.clearSeries("_workout_routes")
                routesEnabled = operation.enabled; preferences.set(routesEnabled, forKey: "routesEnabled")
                await reader.setRoutesEnabled(routesEnabled)
                if routesEnabled, allowsBackgroundWork { try await reader.requestAuthorization(definitions: definitions) }
            case .rotate:
                guard let key = operation.newKey else { throw HealthMCPError.message("Key rotation could not be restored.") }
                if !operation.remoteConfirmed {
                    _ = try await client.json("POST", "/v1/cache/reset", ["operation_id": operation.id])
                    operation.remoteConfirmed = true; try savePrivacy(operation)
                }
                try secureStorage.set("health-key", Data(key.utf8)); privateKey = key
                try await journal.resetIndex(); try secureStorage.remove("pending-rotation")
                connections = []; lastSyncedAt = nil; keyVisible = true; keySaved = false
            case .deleteAccount:
                if !operation.remoteConfirmed {
                    _ = try await client.json("DELETE", "/v1/account")
                    operation.remoteConfirmed = true; try savePrivacy(operation)
                }
                try await clearLocalAccount()
            }
            if operation.kind != .deleteAccount { try secureStorage.remove("privacy-operation"); pendingPrivacy = nil }
            error = nil
            privacyExecuting = false; busy = false
            if operation.kind == .deleteAccount {
                // initialize() will create fresh credentials after cleanup, without self-awaiting its task.
                if bootstrapTask == nil { await bootstrap() }
            } else if initialized, allowsBackgroundWork { await installObservers(); startSync(trigger: "Privacy settings updated") }
        } catch {
            self.error = error.localizedDescription
            observerCompletions.forEach { $0() }; observerCompletions.removeAll()
            // Keep durable intent and the sync gate until every remote and local step succeeds.
        }
    }
    private func clearLocalAccount() async throws {
        await reader.stopObservers()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: "cc.healthmcp.app.sync")
        try await journal?.resetIndex(); try await journal?.execute("DELETE FROM history")
        for name in ["user-id", "health-key", "device-key", "simulator-device-key", "pending-rotation"] { try secureStorage.remove(name) }
        for name in ["onboarded", "onboardingStep", "enabledGroups", "routesEnabled"] { preferences.removeObject(forKey: name) }
        try secureStorage.remove("privacy-operation"); pendingPrivacy = nil
        initialized = false; api = nil; privateKey = ""
        onboarded = false; onboardingStep = 0; history = []; currentRun = nil; connections = []; sampleCount = 0
        groups = []; routesEnabled = false; lastSyncedAt = nil; syncAvailability = nil; cloudBytes = 0; cloudChunks = 0; seriesCount = 0; keyVisible = false; keySaved = false
    }
    private func configureDemo() {
        onboarded = !ProcessInfo.processInfo.arguments.contains("-onboarding")
        let demoPayload = String(HealthCrypto.alphabet.prefix(26))
        onboardingStep = 0; privateKey = demoPayload + String(try! HealthCrypto.checksum(demoPayload))
        if ProcessInfo.processInfo.arguments.contains("-onboarding-key") { onboarded = false; onboardingStep = 1; keyVisible = true }
        if ProcessInfo.processInfo.arguments.contains("-ui-pairing") { selectedTab = 1 }
        lastSyncedAt = Date().addingTimeInterval(-240); sampleCount = 24836; cloudChunks = 186; cloudBytes = 1843200; seriesCount = 24
        syncAvailability = SyncAvailability(since: try! HealthDates.bounds("2024-01-01").0, refreshedAt: lastSyncedAt!, scope: SyncAvailability.scope(for: definitions), historyComplete: true, hasSamples: true)
        var run = SyncRun(trigger: "Health data changed"); run.startedAt = Date().addingTimeInterval(-285); run.finishedAt = Date().addingTimeInterval(-240); run.status = "complete"; run.stage = "Your encrypted cache is up to date"; run.uploadedChunks = 18; run.totalChunks = 18; run.uploadedBytes = 182400; run.progress = 1
        history = [run]; pushStatus = "Device registered"
        if ProcessInfo.processInfo.arguments.contains("-ui-syncing") { run.status = "running"; run.trigger = "Initial backfill"; run.progress = 0.62; run.totalChunks = 320; run.uploadedChunks = 144; run.stage = "Encrypting and uploading"; run.phase = "streaming"; run.completedTypes = 17; run.totalTypes = 53; currentRun = run }
        if ProcessInfo.processInfo.arguments.contains("-ui-syncing") { syncAvailability?.since = BackfillPlan.recentStart(now: Date()); syncAvailability?.historyComplete = false; lastSyncedAt = nil }
        if ProcessInfo.processInfo.arguments.contains("-ui-recent-pending") { syncAvailability = nil; currentRun?.phase = "recent"; currentRun?.stage = "Checking recent workouts"; cloudChunks = 0; seriesCount = 0 }
        if ProcessInfo.processInfo.arguments.contains("-ui-paused") { currentRun?.status = "paused"; currentRun?.stage = "Progress saved. Completed uploads are available to your agents." }
        if ProcessInfo.processInfo.arguments.contains("-ui-long-stage") { currentRun?.stage = "Reading Dietary Polyunsaturated Fat · uploads continue between pages while older health history is indexed" }
        currentRun?.availability = syncAvailability
    }
}
