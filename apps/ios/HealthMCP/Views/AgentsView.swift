import SwiftUI

struct AgentsView: View {
    @EnvironmentObject var model: AppModel
    @State private var toRevoke: AgentConnection?
    @State private var copied = false
    @FocusState private var pairingCodeFocused: Bool
    @State private var pairingFieldFrame = CGRect.zero
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Eyebrow(text: "Choose your connections")
                    Text("Connect your agent to HealthMCP").font(.system(size: 36, weight: .semibold, design: .rounded)).tracking(-1)
                    Text("Export the trusted client from Settings and connect it to your assistant. Approve its pairing code here, then save your key privately on your computer.").foregroundStyle(Brand.secondary)
                    Panel {
                        VStack(alignment: .leading, spacing: 16) {
                            Eyebrow(text: "01 / Connect your client")
                            Text("Start with Settings → Export trusted client. The remote endpoint is also available for independently trusted integrations.").font(.subheadline).foregroundStyle(Brand.secondary)
                            Text("https://mcp.healthmcp.cc/mcp").font(.system(.subheadline, design: .monospaced)).foregroundStyle(Brand.accent).textSelection(.enabled)
                            Button { UIPasteboard.general.string = "https://mcp.healthmcp.cc/mcp"; copied = true } label: { Label(copied ? "Server URL copied" : "Copy server URL", systemImage: copied ? "checkmark" : "doc.on.doc") }.buttonStyle(SecondaryButton())
                        }
                    }
                    Panel {
                        VStack(alignment: .leading, spacing: 18) {
                            Eyebrow(text: "02 / Enter the pairing code")
                            TextField("000000", text: $model.pairingCode).font(.system(size: 36, weight: .medium, design: .monospaced)).tracking(8).keyboardType(.numberPad).textContentType(.oneTimeCode).multilineTextAlignment(.center).padding(16).background(Brand.background, in: RoundedRectangle(cornerRadius: 16)).accessibilityLabel("Six-digit pairing code").accessibilityIdentifier("pairing-code")
                                .focused($pairingCodeFocused)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { pairingFieldFrame = $0 }
                                .onChange(of: model.pairingCode) { _, value in model.pairingCode = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6)) }
                                .onSubmit { reviewConnection() }
                            Button { reviewConnection() } label: { HStack { if model.busy { ProgressView().tint(Brand.background) }; Text("Review connection"); Image(systemName: "arrow.right") } }.buttonStyle(PrimaryButton()).disabled(model.pairingCode.count != 6 || model.busy).opacity(model.pairingCode.count == 6 ? 1 : 0.45)
                        }
                    }
                    HStack { Eyebrow(text: "Connected agents"); Spacer(); Text(model.connections.count.formatted()).font(.subheadline.monospacedDigit()).foregroundStyle(Brand.secondary) }
                    if model.connections.isEmpty { Panel { VStack(alignment: .leading, spacing: 10) { Image(systemName: "person.crop.circle.badge.plus").font(.title).foregroundStyle(Brand.accent); Text("Your circle starts with you.").font(.headline); Text("No agents have access to your encrypted cache yet.").font(.subheadline).foregroundStyle(Brand.secondary) } } }
                    ForEach(model.connections) { connection in Panel { VStack(alignment: .leading, spacing: 14) { HStack { Image(systemName: "checkmark.shield").foregroundStyle(Brand.accent); Text(connection.name).font(.headline); Spacer() }; Text("Connected \(connection.createdAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(Brand.secondary); Button("Revoke access", role: .destructive) { toRevoke = connection }.font(.subheadline.weight(.semibold)) } } }
                    Link("Connection guide", destination: URL(string: "https://healthmcp.cc/connect")!).font(.headline).foregroundStyle(Brand.accent).padding(.bottom, 20)
                }.padding(24)
            }.healthBackground().navigationTitle("Agents").navigationBarTitleDisplayMode(.inline)
                .scrollDismissesKeyboard(.interactively)
                .contentShape(Rectangle())
                .simultaneousGesture(SpatialTapGesture(coordinateSpace: .global).onEnded { tap in
                    if !pairingFieldFrame.contains(tap.location) { pairingCodeFocused = false }
                })
                .onDisappear { pairingCodeFocused = false }
                .refreshable { await model.refreshStatus() }
                .sheet(item: $model.pairingPreview, onDismiss: { pairingCodeFocused = false }) { preview in PairingConsentView(preview: preview) }
                .confirmationDialog("Revoke \(toRevoke?.name ?? "this agent")?", isPresented: Binding(get: { toRevoke != nil }, set: { if !$0 { toRevoke = nil } }), titleVisibility: .visible) { Button("Revoke access", role: .destructive) { if let connection = toRevoke { Task { await model.revoke(connection); toRevoke = nil } } } } message: { Text("This stops future downloads immediately. Data the agent has already downloaded cannot be recalled.") }
        }
    }
    private func reviewConnection() {
        pairingCodeFocused = false
        guard model.pairingCode.count == 6, !model.busy else { return }
        Task { await model.previewPairing() }
    }
}
struct PairingConsentView: View {
    @EnvironmentObject var model: AppModel
    let preview: PairingPreview
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 24) {
            BrandMark(size: 60)
            Text("Allow \(preview.name)?").font(.largeTitle.bold())
            Text("This client can access your shared health series and request a fresh sync. With your private key, it can decrypt that data and pass it to the third-party AI assistant you connect. That provider’s privacy and retention terms then apply.").foregroundStyle(Brand.secondary)
            Panel { VStack(alignment: .leading, spacing: 12) { Eyebrow(text: "Return address"); Text(preview.host).font(.system(.body, design: .monospaced)); Label("Your private key is never shared here.", systemImage: "lock.shield").font(.subheadline).foregroundStyle(Brand.accent) } }
            Text("Shared data: profile, everyday health and fitness" + (model.groups.isEmpty ? "" : ", " + model.groups.sorted().joined(separator: ", ")) + (model.routesEnabled ? ", and precise workout routes." : ".")).font(.subheadline).foregroundStyle(Brand.secondary)
            Text("Approve only if you started this connection and recognize this agent and its return address.").font(.subheadline).foregroundStyle(Brand.secondary)
            Button { Task { await model.approvePairing() } } label: { Text("Approve connection") }.buttonStyle(PrimaryButton()).disabled(model.busy)
            Button("Cancel") { model.pairingPreview = nil }.buttonStyle(SecondaryButton())
        }.padding(28).frame(maxWidth: .infinity, alignment: .leading) }.healthBackground().presentationDetents([.large])
    }
}
