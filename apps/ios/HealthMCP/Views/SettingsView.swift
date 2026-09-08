import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var showKey = false
    @State private var confirmRotation = false
    @State private var confirmDelete = false
    private let optionalGroups = [("nutrition", "Nutrition", "Energy, macros, water & caffeine", "fork.knife"), ("reproductive", "Reproductive health", "Cycle data & reproductive events", "calendar"), ("symptoms", "Symptoms", "The symptoms you log in Health", "cross.case"), ("audio", "Audio exposure", "Environmental & headphone levels", "ear"), ("ecg", "ECG records", "Full voltage recordings; larger uploads", "waveform.path.ecg")]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Eyebrow(text: "You’re in control")
                    Panel { VStack(alignment: .leading, spacing: 18) { Label("Your private key", systemImage: "key.horizontal").font(.title3.weight(.semibold)).foregroundStyle(Brand.accent); Text("Saved securely on this iPhone. Reveal it to configure a new agent.").font(.subheadline).foregroundStyle(Brand.secondary); Button("Reveal private key") { Task { await model.revealKey(); if model.keyVisible { showKey = true } } }.buttonStyle(SecondaryButton()) } }
                    Panel {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("Trusted client & helpers", systemImage: "desktopcomputer").font(.headline)
                            Text("Export the client included with this signed app. It keeps decryption on your computer and works with agents that support local MCP servers.").font(.subheadline).foregroundStyle(Brand.secondary)
                            if let url = Bundle.main.url(forResource: "HealthMCP-Private-Client", withExtension: "zip") {
                                ShareLink(item: url) { Label("Export trusted client", systemImage: "square.and.arrow.up") }.buttonStyle(SecondaryButton()).accessibilityIdentifier("export-trusted-client")
                            }
                        }
                    }
                    Eyebrow(text: "Health data")
                    Panel { VStack(alignment: .leading, spacing: 15) { Label("Everyday health & fitness", systemImage: "heart.text.clipboard").font(.headline); Text("Heart, sleep, movement, body measurements, workouts, activity rings, and daily summaries sync when readable in Apple Health.").font(.subheadline).foregroundStyle(Brand.secondary); Button("Review Apple Health access") { Task { do { try await model.reader.requestAuthorization(definitions: model.definitions) } catch { model.error = error.localizedDescription } } }.font(.subheadline.weight(.semibold)).foregroundStyle(Brand.accent) } }
                    Panel { VStack(spacing: 20) { ForEach(optionalGroups, id: \.0) { group in Toggle(isOn: Binding(get: { model.groups.contains(group.0) }, set: { enabled in Task { await model.setGroup(group.0, enabled: enabled) } })) { HStack(alignment: .top, spacing: 12) { Image(systemName: group.3).foregroundStyle(Brand.accent).frame(width: 22); VStack(alignment: .leading, spacing: 4) { Text(group.1).font(.subheadline.weight(.semibold)); Text(group.2).font(.caption).foregroundStyle(Brand.secondary) } } }.tint(Brand.accent).disabled(model.busy || model.pendingPrivacy != nil) }; Divider(); Toggle(isOn: Binding(get: { model.routesEnabled }, set: { enabled in Task { await model.setRoutes(enabled) } })) { VStack(alignment: .leading, spacing: 4) { Text("Workout GPS routes").font(.subheadline.weight(.semibold)); Text("Precise locations, always encrypted").font(.caption).foregroundStyle(Brand.secondary) } }.tint(Brand.accent).disabled(model.busy || model.pendingPrivacy != nil) } }
                    Text("Optional groups are off by default. Turning one off removes its encrypted copies. Apple Health data stays on your device.").font(.footnote).foregroundStyle(Brand.secondary)
                    Panel { VStack(alignment: .leading, spacing: 14) { Label("Freshness requests", systemImage: "bell.badge").font(.headline); Text("\(model.pushStatus). Allow notifications so an agent can ask you to open the app when a background sync doesn’t arrive.").font(.subheadline).foregroundStyle(Brand.secondary); Button("Enable sync notifications") { Task { await model.enableNotifications() } }.buttonStyle(SecondaryButton()) } }
                    Eyebrow(text: "Privacy & storage")
                    Panel { VStack(alignment: .leading, spacing: 20) { Link("Privacy policy", destination: URL(string: "https://healthmcp.cc/privacy")!); Link("Help & connection guide", destination: URL(string: "https://healthmcp.cc/connect")!); Divider(); Button("Rotate private key") { confirmRotation = true }; Button("Delete account & encrypted cache", role: .destructive) { confirmDelete = true } }.font(.subheadline.weight(.semibold)).foregroundStyle(Brand.accent) }
                    Text("Health MCP · Version 1.0\nApple Health is always the source of truth.").font(.caption).foregroundStyle(Brand.secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.bottom, 20)
                }.padding(24)
            }.healthBackground().navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showKey, onDismiss: { model.keyVisible = false }) { ScrollView { VStack(alignment: .leading, spacing: 24) { Text("Your private key").font(.largeTitle.bold()); if model.keyVisible { PrivateKeyView(key: model.privateKey) } else { Text("Key hidden. Unlock again to reveal it.").foregroundStyle(Brand.secondary) }; Text("Store it in a password manager and your trusted client’s private configuration.").foregroundStyle(Brand.secondary); Button("Done") { showKey = false }.buttonStyle(PrimaryButton()) }.padding(28).frame(maxWidth: .infinity, alignment: .leading) }.healthBackground() }
                .confirmationDialog("Rotate your private key?", isPresented: $confirmRotation, titleVisibility: .visible) { Button("Rotate key & rebuild cache", role: .destructive) { Task { await model.rotateKey(); if model.keyVisible { showKey = true } } } } message: { Text("This revokes connected agents, deletes the encrypted cache, and starts a fresh backfill. Save the new key and reconnect your agents. Apple Health is unchanged.") }
                .confirmationDialog("Delete your Health MCP account?", isPresented: $confirmDelete, titleVisibility: .visible) { Button("Delete account & cache", role: .destructive) { Task { await model.deleteAccount() } } } message: { Text("Your encrypted cloud cache, local key, and agent connections will be deleted. Apple Health stays on your iPhone. You can set up a new account later.") }
        }
    }
}
