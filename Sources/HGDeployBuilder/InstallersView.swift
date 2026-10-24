import BuilderKit
import SwiftUI
import UniformTypeIdentifiers

struct InstallersView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAllVersions = false
    @State private var importing = false
    @State private var removing: InstallerApp?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !model.isDeployDrive {
                    Label("Set the drive up on the Drive tab first.", systemImage: "info.circle").foregroundStyle(.secondary)
                }
                onDrive
                fromApple
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.applicationBundle, .package, UTType(filenameExtension: "pkg") ?? .data]) { result in
            if case .success(let url) = result { Task { await model.importInstaller(from: url) } }
        }
        .confirmationDialog("Remove \(removing?.title ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let r = removing { Task { await model.remove(r) } }
                removing = nil
            }
        } message: { Text("It's deleted from the drive.") }
    }

    private var header: some View {
        HStack {
            Text("Installers").font(.title2.bold())
            Spacer()
            Button("Import…") { importing = true }
                .help("Copy an Install macOS app, or install an InstallAssistant.pkg, onto the drive")
            Button("Update All") { model.updateAll() }
                .disabled(MacOS.majors.allSatisfy { model.update(for: $0) == nil })
            Button("Add Latest of Every macOS") { model.addLatestOfEvery() }
                .buttonStyle(.borderedProminent)
                .help("High Sierra through Tahoe, newest version of each")
        }
        .disabled(!model.isDeployDrive || model.catalog.isEmpty && model.catalogLoading)
    }

    private var onDrive: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("On this drive").font(.headline)
                    Spacer()
                    Text("\(formatBytes(model.driveFree)) free").foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
                if model.driveInstallers.isEmpty {
                    Text("No installers yet.").foregroundStyle(.secondary).padding(.vertical, 6)
                }
                ForEach(model.driveInstallers) { app in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.title).font(.body.weight(.medium))
                            Text(coverage(app.major)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if let problem = app.problem {
                            Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                        } else if app.beta {
                            Text("beta").font(.caption).foregroundStyle(.orange)
                        }
                        if let up = model.update(for: app.major), app == model.driveInstallers.first(where: { $0.major == app.major }) {
                            Button("Update to \(up.version)") { model.enqueue(up) }
                                .disabled(model.queue.contains(up))
                        }
                        Button(role: .destructive) { removing = app } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .disabled(model.job != nil)
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
                if model.isDeployDrive && !model.missingMajors.isEmpty {
                    let names = model.missingMajors.map { "\(MacOS.name($0).replacingOccurrences(of: "macOS ", with: "")) \($0)" }
                    Text("Not on the drive: \(names.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }
            }
            .padding(6)
        }
    }

    private var fromApple: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("From Apple").font(.headline)
                    if model.catalogLoading { ProgressView().controlSize(.small) }
                    Spacer()
                    Toggle("All versions", isOn: $showAllVersions).toggleStyle(.checkbox)
                    Button { Task { await model.loadCatalog() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Reload Apple's catalog")
                }
                .padding(.bottom, 8)
                if let err = model.catalogError {
                    Label(err, systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                }
                ForEach(rows) { product in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(product.title)
                            Text("\(formatBytes(product.totalSize)) · posted \(product.postDate.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.driveHas(product) {
                            Label("On drive", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                        } else if model.queue.contains(product) {
                            Text("Queued").foregroundStyle(.secondary)
                        } else {
                            Button("Add to Drive") { model.enqueue(product) }
                                .disabled(!model.isDeployDrive)
                        }
                    }
                    .padding(.vertical, 5)
                    Divider()
                }
            }
            .padding(6)
        }
    }

    private var rows: [CatalogInstaller] {
        if showAllVersions { return model.catalog }
        let latest = model.latestPerMajor
        return MacOS.majors.reversed().compactMap { latest[$0] }
    }

    /// "Newest macOS for: MacBook Pro (16-inch, 2019), iMac (Retina 5K, 27-inch, 2020)…"
    private func coverage(_ major: String) -> String {
        guard let models = model.models else { return "" }
        let ids = models.macsTopping(out: major)
        guard !ids.isEmpty else { return "Not the newest macOS for any Mac" }
        let names = Array(Set(ids.compactMap { models.models[$0]?.name })).sorted()
        let shown = names.prefix(4).joined(separator: ", ")
        return "Newest macOS for \(ids.count) models: \(shown)\(names.count > 4 ? ", …" : "")"
    }
}
