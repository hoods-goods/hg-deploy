import BuilderKit
import SwiftUI

struct DriveView: View {
    @EnvironmentObject var model: AppModel
    @State private var newName = "r"
    @State private var renaming = false
    @State private var renameTo = "r"
    @State private var confirmErase = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Drive").font(.title2.bold())
                if model.payload == nil {
                    Label("This copy of Builder doesn't include the HG Deploy payload, so it can't set up drives. Use a release build.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let disk = model.selectedDisk {
                    status(disk)
                    usage
                    build(disk)
                } else {
                    ContentUnavailableView("No external drive",
                                           systemImage: "externaldrive.badge.xmark",
                                           description: Text("Plug in the SSD you want to use, then click Refresh."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .alert("Rename the drive", isPresented: $renaming) {
            TextField("Name", text: $renameTo)
            Button("Rename") {
                let name = renameTo.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { Task { await model.renameDrive(to: name) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Recovery command becomes /Volumes/<name>/run. Nothing on the drive is erased.")
        }
    }

    @ViewBuilder
    private func status(_ disk: ExternalDisk) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let layout = model.layout, model.isDeployDrive {
                    Label("HG Deploy drive", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.headline)
                    LabeledContent("Volume", value: layout.root.path)
                    LabeledContent("HG Deploy on drive", value: layout.toolVersion() ?? "unknown")
                    LabeledContent("This Builder", value: model.builderVersion)
                    LabeledContent("Installers", value: "\(model.driveInstallers.count)")
                    LabeledContent("Free space", value: formatBytes(model.driveFree))
                    HStack {
                        Button(layout.toolVersion() == model.builderVersion ? "Reinstall HG Deploy on Drive" : "Update HG Deploy on Drive") {
                            Task { await model.installTool() }
                        }
                        .disabled(model.job != nil || model.payload == nil)
                        Button("Rename…") { renameTo = "r"; renaming = true }
                            .disabled(model.job != nil)
                            .help("A short name means a short command in Recovery")
                        Button("Show in Finder") { model.showInFinder() }
                        Button { Task { await model.eject() } } label: { Label("Eject", systemImage: "eject") }
                            .disabled(model.isBusy)
                    }
                } else if let vol = model.volume {
                    Label("Not an HG Deploy drive yet", systemImage: "externaldrive").font(.headline)
                    LabeledContent("Volume", value: "\(vol.name) (\(vol.filesystem))")
                    LabeledContent("Free space", value: formatBytes(model.driveFree))
                    Text("Erase and build it below, or put HG Deploy on it as-is (keeps the files on it).")
                        .foregroundStyle(.secondary)
                    Button("Put HG Deploy on “\(vol.name)” Without Erasing") { Task { await model.installTool() } }
                        .disabled(model.job != nil || model.payload == nil)
                } else {
                    Label("No mounted volume on \(disk.label)", systemImage: "externaldrive.badge.questionmark").font(.headline)
                    Text("Erase and build it below.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    @ViewBuilder
    private var usage: some View {
        if let layout = model.layout, model.isDeployDrive {
            GroupBox("Using it") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Plug the drive into the Intel Mac and start it in Recovery (hold ⌘R, or ⌥⌘R for Internet Recovery).")
                    Text("2. Open Utilities ▸ Terminal.")
                    HStack {
                        Text("3. Type")
                        Text(layout.command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: 4))
                        Text("and press Return.")
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(layout.command, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy")
                    }
                    Text("Which Recovery: ⌥⌘R (Internet Recovery) gives the newest macOS the Mac supports, which is usually what you want. To install an older version than the Mac's Recovery, use ⇧⌥⌘R; an installer older than the Recovery won't install.")
                        .font(.caption).foregroundStyle(.secondary)
                    if layout.root.lastPathComponent.count > 3 {
                        Text("Tip: rename the drive to “r” (Rename… above) and the command is just /Volumes/r/run.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("HG Deploy opens, picks the newest macOS the Mac supports, and erases and installs. Logs are saved on the drive in HGDeploy/Logs.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
        }
    }

    private func build(_ disk: ExternalDisk) -> some View {
        GroupBox("Build a new drive") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Erases **\(disk.label)** and sets it up as an HG Deploy drive (Mac OS Extended, so every Recovery can read it). Then add installers on the Installers tab.")
                HStack {
                    Text("Name:")
                    TextField("r", text: $newName).frame(width: 200)
                    if newName.contains(" ") {
                        Text("Use a short name without spaces: it is typed in Terminal.").font(.caption).foregroundStyle(.orange)
                    }
                }
                Button("Erase & Build…", role: .destructive) { confirmErase = true }
                    .disabled(model.job != nil || model.payload == nil || newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .confirmationDialog("Erase \(disk.label)?", isPresented: $confirmErase) {
            Button("Erase & Build", role: .destructive) {
                Task { await model.buildDrive(name: newName.trimmingCharacters(in: .whitespaces)) }
            }
        } message: {
            Text("Everything on this drive will be deleted.")
        }
    }
}
