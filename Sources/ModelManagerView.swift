import SwiftUI
import UniformTypeIdentifiers

/// Settings window: currently the single Models tab (§5 model manager).
struct SettingsView: View {
    var body: some View {
        TabView {
            ModelManagerView()
                .tabItem { Label("Models", systemImage: "square.stack.3d.up") }
        }
        .frame(width: 560)
    }
}

/// Settings → Models: one row per model rendering the §4.3 state machine —
/// install / pause / resume / remove / retry / import, live progress, size on
/// disk, and total library usage.
struct ModelManagerView: View {
    @Environment(AppRuntime.self) private var runtime
    @State private var importTarget: ModelID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ModelID.allCases) { model in
                ModelRow(model: model, importTarget: $importTarget)
                if model != ModelID.allCases.last {
                    Divider().padding(.leading, 16)
                }
            }
            Divider()
            footer
        }
        .padding(.vertical, 8)
        .fileImporter(isPresented: importPresented, allowedContentTypes: [.folder]) { result in
            if let target = importTarget, case .success(let url) = result {
                runtime.importWeights(target, from: url)
            }
            importTarget = nil
        }
    }

    private var importPresented: Binding<Bool> {
        Binding(get: { importTarget != nil },
                set: { if !$0 { importTarget = nil } })
    }

    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 3)) { _ in
            HStack(spacing: 6) {
                Image(systemName: "internaldrive").foregroundStyle(.secondary)
                Text("Model library: \(OnboardingView.gb(ModelStore.totalBytesOnDisk())) on disk · \(OnboardingView.gb(DiskSpace.free())) free")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

/// One §4.3 machine, rendered. Every state maps to exactly one control set.
private struct ModelRow: View {
    @Environment(AppRuntime.self) private var runtime
    let model: ModelID
    @Binding var importTarget: ModelID?

    private var catalog: CatalogModel { ModelCatalog.model(model) }
    private var state: ModelInstallState { runtime.state.installState(model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(catalog.displayName).font(.body.weight(.medium))
                    Text(catalog.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                controls
            }
            statusLine
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: controls per state

    @ViewBuilder
    private var controls: some View {
        switch state {
        case .notInstalled:
            Menu {
                Button("Download (\(OnboardingView.gb(catalog.totalBytes)))") {
                    runtime.install(model)
                }
                Button("Import weights folder…") { importTarget = model }
            } label: {
                Text("Install")
            }
            .fixedSize()

        case .queued:
            Text("Waiting…").font(.caption).foregroundStyle(.secondary)

        case .downloading:
            Button("Pause") { runtime.pauseInstall(model) }

        case .paused:
            Button("Resume") { runtime.resumeInstall(model) }

        case .verifying:
            ProgressView().controlSize(.small)

        case .installed:
            Button("Remove", role: .destructive) { runtime.removeInstall(model) }

        case .failed:
            HStack(spacing: 8) {
                Button("Import…") { importTarget = model }
                Button("Retry") { runtime.retryInstall(model) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: status per state

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .notInstalled:
            Label("Not installed · \(OnboardingView.gb(catalog.totalBytes)) download",
                  systemImage: "arrow.down.circle.dotted")
                .font(.caption).foregroundStyle(.tertiary)

        case .queued:
            Label("Queued — one download at a time", systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)

        case .downloading(let p):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: p.fraction)
                    .progressViewStyle(.linear)
                Text("File \(p.fileIndex) of \(p.fileCount) — \(p.currentFileName) · \(OnboardingView.gb(p.totalBytes)) of \(OnboardingView.gb(p.totalExpected))")
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    .lineLimit(1)
            }

        case .paused(let bytes):
            Label("Paused · \(OnboardingView.gb(bytes)) of \(OnboardingView.gb(catalog.totalBytes)) kept — resumes where it stopped",
                  systemImage: "pause.circle")
                .font(.caption).foregroundStyle(.secondary)

        case .verifying:
            Label("Verifying checksums…", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)

        case .installed:
            Label("Installed · \(OnboardingView.gb(ModelStore.bytesOnDisk(model))) on disk",
                  systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .lineLimit(2)
        }
    }
}
