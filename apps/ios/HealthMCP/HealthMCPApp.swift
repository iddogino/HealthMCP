import SwiftUI
import BackgroundTasks
import UserNotifications

@main struct HealthMCPApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).preferredColorScheme(.dark)
                .overlay { if scenePhase != .active { Brand.background.ignoresSafeArea().overlay(BrandMark(size: 64)) } }
                .task { await model.bootstrap() }
                .onOpenURL { model.handleURL($0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { if let url = $0.webpageURL { model.handleURL(url) } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { UIApplication.shared.isIdleTimerDisabled = model.isSyncing; model.foreground() }
                    else { model.keyVisible = false; UIApplication.shared.isIdleTimerDisabled = false }
                }
        }
    }
}
@MainActor final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel.shared
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "cc.healthmcp.app.sync", using: nil) { [weak self] task in
            Task { @MainActor in
                guard let model = self?.model else { task.setTaskCompleted(success: false); return }
                var expired = false
                task.expirationHandler = { Task { @MainActor in expired = true; model.pauseSync() } }
                await model.bootstrap()
                guard !expired else { task.setTaskCompleted(success: false); return }
                model.startSync(trigger: "Background backstop"); await model.awaitSync()
                task.setTaskCompleted(success: model.currentRun?.status == "complete")
            }
        }
        return true
    }
    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        if application.applicationState == .active { model.foreground() }
        else { Task { await model.bootstrap() } }
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) { Task { await model.bootstrap(); await model.registerPush(deviceToken) } }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) { model.pushStatus = "Unavailable on this device" }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        #if DEBUG
        try? DeviceValidation.write(["received_at": HealthDates.timestamp(Date()), "kind": "remote-notification"], name: "push.json")
        #endif
        model.backgroundSync(trigger: "Agent requested sync") { completionHandler($0 ? .newData : .noData) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async { await model.bootstrap(); model.startSync(trigger: "Notification opened") }
}

// A push has a short wall-clock budget. Completion must not wait for a stalled
// HealthKit query or network cleanup; both continue to respect cancellation.
@MainActor final class BackgroundSyncSlice {
    private var finished = false
    private var workTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private let completion: (Bool) -> Void
    private init(completion: @escaping (Bool) -> Void) { self.completion = completion }
    static func run(budget: Duration, work: @escaping @MainActor () async -> Bool, expired: @escaping @MainActor () -> Void, completion: @escaping (Bool) -> Void) {
        let slice = BackgroundSyncSlice(completion: completion)
        slice.workTask = Task { let result = await work(); slice.finish(result) }
        slice.deadlineTask = Task {
            do { try await Task.sleep(for: budget) } catch { return }
            guard !slice.finished else { return }
            expired(); slice.finish(false)
        }
    }
    private func finish(_ success: Bool) {
        guard !finished else { return }; finished = true
        workTask?.cancel(); deadlineTask?.cancel()
        workTask = nil; deadlineTask = nil
        completion(success)
    }
}
