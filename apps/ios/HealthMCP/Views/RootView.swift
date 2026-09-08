import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group {
            if !model.initialized { VStack(spacing: 24) { BrandMark(size: 72); ProgressView().tint(Brand.accent); Text("Opening your private health bridge").foregroundStyle(Brand.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity).healthBackground() }
            else if !model.onboarded { OnboardingView() }
            else {
                TabView(selection: $model.selectedTab) {
                    OverviewView().tabItem { Label("Overview", systemImage: "square.grid.2x2") }.tag(0)
                    AgentsView().tabItem { Label("Agents", systemImage: "point.3.connected.trianglepath.dotted") }.tag(1)
                    SettingsView().tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag(2)
                }.tint(Brand.accent)
            }
        }
        .alert("Something needs attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK", role: .cancel) { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack { BrandMark(); Text("Health MCP").font(.headline); Spacer(); Text("\(min(model.onboardingStep + 1, 4)) / 4").font(.subheadline.monospacedDigit()).foregroundStyle(Brand.secondary) }.padding(.top, 20)
                HStack(spacing: 6) { ForEach(0..<4) { index in Capsule().fill(index <= model.onboardingStep ? Brand.accent : Brand.raised).frame(height: 3) } }.padding(.bottom, 18)
                switch model.onboardingStep {
                case 0:
                    Eyebrow(text: "A private connection")
                    Text("Your health.\nIn your hands.").font(.system(size: 44, weight: .semibold, design: .rounded)).tracking(-1.7).fixedSize(horizontal: false, vertical: true)
                    Text("Give your AI agents the context to understand you. Keep control of every connection.").font(.title3).foregroundStyle(Brand.secondary)
                    Panel {
                        VStack(alignment: .leading, spacing: 24) {
                            feature("heart.text.clipboard", "Start with Apple Health", "Choose which data your agents can access.")
                            feature("lock.shield", "Encrypted on your iPhone", "Your private key stays with you.")
                            feature("person.crop.circle.badge.checkmark", "Every agent needs approval", "Connect with a code. Revoke at any time.")
                        }
                    }
                    Button { Task { await model.prepareHealth() } } label: { HStack { if model.busy { ProgressView().tint(Brand.background) }; Text("Connect Apple Health"); Image(systemName: "arrow.right") } }.buttonStyle(PrimaryButton()).disabled(model.busy).accessibilityIdentifier("begin-onboarding")
                    Text("Read-only access. No passwords. No health data written back.").font(.footnote).foregroundStyle(Brand.secondary)
                case 1:
                    Eyebrow(text: "Only you hold the key")
                    Text("Make it yours.\nKeep it safe.").font(.largeTitle.bold()).tracking(-1)
                    Text("Save this private key in your password manager. Your agent will use it in its secure sandbox to decrypt your data.").foregroundStyle(Brand.secondary)
                    Panel { if model.keyVisible { PrivateKeyView(key: model.privateKey) } else { Button("Reveal private key") { Task { await model.revealKey() } }.buttonStyle(SecondaryButton()) } }
                    Text("We cannot recover this key. Never paste it into a website or ordinary chat.").font(.subheadline).foregroundStyle(Brand.secondary)
                    Toggle("I have saved my private key", isOn: $model.keySaved).tint(Brand.accent)
                    Button("Continue") { model.acceptKey() }.buttonStyle(PrimaryButton()).disabled(!model.keySaved).opacity(model.keySaved ? 1 : 0.4)
                case 2:
                    Eyebrow(text: "Your first sync")
                    Text("Bring your\nhistory with you.").font(.system(size: 40, weight: .semibold, design: .rounded)).tracking(-1)
                    Text("We’ll build an encrypted copy of the Apple Health history you’ve shared. The first backfill can take a while; future syncs only catch up on changes.").font(.title3).foregroundStyle(Brand.secondary)
                    Panel { VStack(alignment: .leading, spacing: 24) { feature("wifi", "A little time, a good connection", "Keep the app open and your iPhone charged for the fastest first sync."); feature("arrow.trianglehead.2.clockwise.rotate.90", "Built to resume", "If you leave or pause, your progress is saved."); feature("chart.bar.doc.horizontal", "Follow every step", "See what’s syncing now and review each run later.") } }
                    Button { model.startFirstSync() } label: { Label("Start first sync", systemImage: "arrow.up.circle") }.buttonStyle(PrimaryButton()).accessibilityIdentifier("start-first-sync")
                default:
                    Eyebrow(text: "Building your private history")
                    Text(model.isSyncing ? "Your health,\non its way." : "Your bridge\nis ready.").font(.system(size: 40, weight: .semibold, design: .rounded)).tracking(-1)
                    if let run = model.currentRun { SyncProgressCard(run: run) }
                    else { Panel { Text("Your saved progress is ready to resume.").foregroundStyle(Brand.secondary) } }
                    Text("You can open the dashboard while the backfill continues. Your agents will see how fresh each data series is.").foregroundStyle(Brand.secondary)
                    Button("Open dashboard") { model.finishOnboarding() }.buttonStyle(PrimaryButton())
                    if !model.isSyncing && model.currentRun?.status != "complete" { Button("Resume first sync") { model.startSync(trigger: "Initial backfill resumed") }.buttonStyle(SecondaryButton()) }
                }
                HStack { Image(systemName: "lock.fill"); Text("Private by design. Yours by default.") }.font(.caption).foregroundStyle(Brand.secondary).frame(maxWidth: .infinity).padding(.vertical, 12)
            }.padding(.horizontal, 26).padding(.bottom, 24)
        }.healthBackground()
    }
    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 15) { Image(systemName: symbol).font(.title3).foregroundStyle(Brand.accent).frame(width: 24); VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(detail).font(.subheadline).foregroundStyle(Brand.secondary) } }
    }
}
