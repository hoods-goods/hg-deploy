import BuilderKit
import SwiftUI

/// The defaults HG Deploy shows in Recovery. Every one can be changed per Mac there.
struct SetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Create an account and skip Setup Assistant", isOn: binding(\.account.create))
                Text("Off: the Mac starts at the Setup Assistant (“Hello”) screen, ready for a customer.")
                    .font(.caption).foregroundStyle(.secondary)
                Group {
                    TextField("Full name", text: binding(\.account.fullName))
                    TextField("Account name", text: binding(\.account.shortName))
                    SecureField("Password", text: binding(\.account.password))
                    Toggle("Administrator", isOn: binding(\.account.admin))
                    Toggle("Log in automatically", isOn: binding(\.account.autoLogin))
                }
                .disabled(!model.config.account.create)
                if model.config.account.create && !model.config.account.password.isEmpty {
                    Text("The password is stored in plain text on the drive (HGDeploy/config.json) and briefly in the Mac's NVRAM during the install.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Account") }

            Section {
                TextField("Computer name", text: binding(\.computerName), prompt: Text("Leave blank for the default"))
                Text("{serial} and {model} are filled in, e.g. HG-{serial}").font(.caption).foregroundStyle(.secondary)
                Toggle("Turn on Remote Login (SSH)", isOn: binding(\.enableSSH))
            } header: { Text("After install") }

            Section {
                Toggle("Erase the disk by default", isOn: binding(\.eraseByDefault))
                TextField("Volume name", text: binding(\.volumeName))
            } header: { Text("Disk") }

            HStack {
                Spacer()
                if !model.configSaved { Text("Not saved").foregroundStyle(.secondary) }
                Button("Save to Drive") { model.saveConfig() }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isDeployDrive)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Setup Defaults")
    }

    private func binding<T>(_ path: WritableKeyPath<DeployConfig, T>) -> Binding<T> {
        Binding(get: { model.config[keyPath: path] },
                set: { model.config[keyPath: path] = $0; model.configSaved = false })
    }
}
