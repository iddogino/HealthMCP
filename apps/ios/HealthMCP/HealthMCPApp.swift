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
                task.expirationHandler = { Task { @MainActor in model.pauseSync() } }
                await model.bootstrap(); model.startSync(trigger: "Background backstop"); await model.awaitSync()
                task.setTaskCompleted(success: model.currentRun?.status == "complete")
            }
        }
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) { Task { await model.bootstrap(); await model.registerPush(deviceToken) } }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) { model.pushStatus = "Unavailable on this device" }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            await model.bootstrap(); model.startSync(trigger: "Agent requested sync"); await model.awaitSync()
            completionHandler(model.currentRun?.status == "complete" ? .newData : .failed)
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async { await model.bootstrap(); model.startSync(trigger: "Notification opened") }
}
