import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    @State private var showHistory = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack { BrandMark(); Text("Health MCP").font(.headline); Spacer(); Image(systemName: "lock.shield.fill").foregroundStyle(Brand.accent) }.padding(.top, 14)
                    VStack(alignment: .leading, spacing: 8) { Eyebrow(text: "Your private health bridge"); Text("A little more\nconnected.").font(.system(size: 40, weight: .semibold, design: .rounded)).tracking(-1.3) }.padding(.top, 12)
                    if model.isSyncing, let run = model.currentRun {
                        SyncProgressCard(run: run)
                        Button("Pause sync") { model.pauseSync() }.buttonStyle(SecondaryButton()).accessibilityIdentifier("pause-sync")
                    } else {
                        Panel {
                            HStack(alignment: .top, spacing: 18) {
                                ZStack { Circle().stroke(Brand.accent.opacity(0.15), lineWidth: 5); Image(systemName: statusIcon).font(.system(size: 27, weight: .medium)).foregroundStyle(Brand.accent) }.frame(width: 64, height: 64)
                                VStack(alignment: .leading, spacing: 7) { Text(statusTitle).font(.title2.weight(.semibold)); if let date = model.lastSyncedAt { Text("Last complete sync \(date.formatted(.relative(presentation: .named)))").font(.subheadline).foregroundStyle(Brand.secondary) } else { Text("Your first backfill is ready to begin.").font(.subheadline).foregroundStyle(Brand.secondary) } }
                            }
                            if let run = model.currentRun, ["partial", "failed", "paused", "interrupted"].contains(run.status) { Text(run.stage).foregroundStyle(Brand.secondary).font(.subheadline).padding(.top, 14) }
                            Button { model.startSync(trigger: "Manual sync") } label: { Label(model.lastSyncedAt == nil ? "Resume backfill" : "Sync now", systemImage: "arrow.triangle.2.circlepath") }.buttonStyle(PrimaryButton()).padding(.top, 22).accessibilityIdentifier("sync-now")
                        }
                    }
                    HStack(spacing: 14) {
                        metric("DATA SERIES", value: model.seriesCount.formatted(), icon: "waveform.path.ecg", detail: "Available to agents")
                        metric("ENCRYPTED CACHE", value: ByteCountFormatter.string(fromByteCount: Int64(model.cloudBytes), countStyle: .file), icon: "externaldrive", detail: "\(model.cloudChunks.formatted()) chunks")
                    }
                    if model.sampleCount == 0 && !model.isSyncing { Panel { VStack(alignment: .leading, spacing: 8) { Label("No readable samples yet", systemImage: "heart.text.clipboard").font(.headline); Text("Apple Health may have no data, or some types may not be shared. Review access in Health → Sharing → Apps and Services → Health MCP.").font(.subheadline).foregroundStyle(Brand.secondary) } } }
                    HStack { Eyebrow(text: "Recent activity"); Spacer(); Button("See all") { showHistory = true }.font(.subheadline.weight(.semibold)).foregroundStyle(Brand.accent).accessibilityIdentifier("sync-history") }
                    if model.history.isEmpty { Panel { VStack(alignment: .leading, spacing: 8) { Text("Your story starts here.").font(.headline); Text("Completed, paused, and interrupted syncs will appear here.").font(.subheadline).foregroundStyle(Brand.secondary) } } }
                    else { Panel { VStack(spacing: 18) { ForEach(Array(model.history.prefix(3).enumerated()), id: \.element.id) { index, run in if index > 0 { Divider().overlay(Brand.border) }; SyncHistoryRow(run: run) } } } }
                    Button { model.selectedTab = 1 } label: { HStack(spacing: 15) { Image(systemName: "point.3.connected.trianglepath.dotted").font(.title2).foregroundStyle(Brand.accent); VStack(alignment: .leading, spacing: 5) { Text(model.connections.isEmpty ? "Connect your first agent" : "\(model.connections.count) connected \(model.connections.count == 1 ? "agent" : "agents")").font(.headline); Text("A private connection, on your terms.").font(.subheadline).foregroundStyle(Brand.secondary) }; Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(Brand.accent) }.padding(22).background(Brand.surface, in: RoundedRectangle(cornerRadius: 24)) }.buttonStyle(.plain)
                    Text("Apple Health stays the source of truth. Background sync depends on iOS; open the app whenever you need fresh data.").font(.footnote).foregroundStyle(Brand.secondary).padding(.bottom, 16)
                }.padding(.horizontal, 24)
            }.healthBackground().toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $showHistory) { SyncHistoryView() }
        }
    }
    private var statusTitle: String { if let run = model.currentRun, ["partial", "failed"].contains(run.status) { return "Needs a little attention" }; return model.lastSyncedAt == nil ? "Ready when you are" : "Privately in sync" }
    private var statusIcon: String { model.currentRun?.status == "failed" ? "exclamationmark.arrow.triangle.2.circlepath" : "checkmark.shield" }
    private func metric(_ title: String, value: String, icon: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) { Image(systemName: icon).foregroundStyle(Brand.accent); Text(title).font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(Brand.secondary); Text(value).font(.title2.weight(.semibold)).minimumScaleFactor(0.75).lineLimit(1); Text(detail).font(.caption).foregroundStyle(Brand.secondary) }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Brand.surface, in: RoundedRectangle(cornerRadius: 24))
    }
}
struct SyncProgressCard: View {
    let run: SyncRun
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Label(run.trigger == "Initial backfill" ? "First backfill" : "Sync in progress", systemImage: "arrow.triangle.2.circlepath").font(.headline).foregroundStyle(Brand.accent); Spacer(); Text(run.phase == "streaming" ? "LIVE" : "\(Int(run.progress * 100))%").font(.title2.monospacedDigit().weight(.semibold)) }
                ProgressView(value: run.progress).tint(Brand.accent).scaleEffect(x: 1, y: 1.6).accessibilityLabel("Sync progress").accessibilityValue("\(Int(run.progress * 100)) percent")
                Text(run.stage).font(.subheadline).foregroundStyle(Brand.secondary)
                    .lineLimit(2, reservesSpace: true).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("sync-stage")
                if run.phase == "streaming", let total = run.totalTypes {
                    Text("\(run.completedTypes ?? 0) of \(total) data types scanned · recent uploads are available as they finish").font(.caption).foregroundStyle(Brand.secondary)
                }
                HStack { VStack(alignment: .leading, spacing: 4) { Text(run.totalChunks == 0 ? run.sampleCount.formatted() : "\(run.uploadedChunks) / \(run.totalChunks)").font(.title3.monospacedDigit().weight(.semibold)); Text(run.totalChunks == 0 ? "samples scanned" : "chunks processed").font(.caption).foregroundStyle(Brand.secondary) }; Spacer(); VStack(alignment: .trailing, spacing: 4) { Text(ByteCountFormatter.string(fromByteCount: Int64(run.uploadedBytes), countStyle: .file)).font(.title3.weight(.semibold)); Text("encrypted & uploaded").font(.caption).foregroundStyle(Brand.secondary) } }
                if !run.errors.isEmpty { Text("\(run.errors.count) \(run.errors.count == 1 ? "item needs" : "items need") another attempt. Progress is saved.").font(.footnote).foregroundStyle(.orange) }
            }
        }
    }
}
struct SyncHistoryRow: View {
    let run: SyncRun
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: run.status == "complete" ? "checkmark.circle.fill" : run.status == "running" ? "arrow.triangle.2.circlepath.circle" : "pause.circle").font(.title3).foregroundStyle(run.status == "complete" ? Brand.accent : .orange)
            VStack(alignment: .leading, spacing: 5) { HStack { Text(run.trigger).font(.subheadline.weight(.semibold)); Spacer(); Text(run.startedAt, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(Brand.secondary) }; Text("\(run.status.capitalized) · \(run.uploadedChunks) chunks · \(Int(run.duration))s").font(.caption).foregroundStyle(Brand.secondary) }
        }
    }
}
struct SyncHistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView { LazyVStack(spacing: 16) { ForEach(model.history) { run in Panel { VStack(alignment: .leading, spacing: 12) { SyncHistoryRow(run: run); Text(run.startedAt, format: .dateTime.month().day().year()).font(.caption).foregroundStyle(Brand.secondary); Text(run.stage).font(.subheadline); if !run.errors.isEmpty { ForEach(Array(run.errors.prefix(20).enumerated()), id: \.offset) { _, message in Text(message).font(.footnote).foregroundStyle(.orange) }; if run.errors.count > 20 { Text("And \(run.errors.count-20) more. Retry sync to resume pending work.").font(.footnote) } } } } } }.padding(24) }.healthBackground().navigationTitle("Sync history").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }.tint(Brand.accent)
    }
}
