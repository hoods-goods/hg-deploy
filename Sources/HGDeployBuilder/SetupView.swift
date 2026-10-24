import BuilderKit
import SwiftUI

/// The defaults HG Deploy shows in Recovery. Every one can be changed per Mac there.
struct SetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Text("Saved on the drive and filled in for you in Recovery. You choose there, per Mac, whether to set the account up.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Full name", text: binding(\.account.fullName))
                TextField("Account name", text: binding(\.account.shortName))
                SecureField("Password", text: binding(\.account.password))
                Toggle("Administrator", isOn: binding(\.account.admin))
                Toggle("Log in automatically", isOn: binding(\.account.autoLogin))
                Toggle("Set up the account by default", isOn: binding(\.account.create))
                Text(model.config.account.create
                     ? "Recovery starts with account setup checked: the account is created and Setup Assistant is skipped. Uncheck it there for a Mac going to a customer."
                     : "Recovery starts with account setup unchecked: the Mac ends at the Setup Assistant (“Hello”) screen. Check it there to create this account instead.")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.config.account.password.isEmpty {
                    Text("The password is stored in plain text on the drive (HGDeploy/config.json) and briefly in the Mac's NVRAM during the install.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Account") }

            Section {
                TextField("Network name", text: binding(\.wifi.ssid), prompt: Text("Leave blank to skip"))
                SecureField("Password", text: binding(\.wifi.password))
                Text("HG Deploy joins this network when it opens in Recovery, so it can set the clock. Installing doesn't need a network, and the installed Mac isn't connected to it. The password is stored in plain text on the drive.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Wi-Fi in Recovery") }

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
