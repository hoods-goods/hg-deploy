import SwiftUI

@main
struct BuilderApp: App {
    @StateObject private var auth = Auth()
    @StateObject private var updater = Updater()
    @StateObject private var model = AppModel()

    var body: some Scene {
        // A single Window (not a WindowGroup): clicking the Dock icon or
        // Window ▸ HG Deploy Builder reopens it after it's closed.
        Window("HG Deploy Builder", id: "main") {
            RootView()
                .environmentObject(auth)
                .environmentObject(updater)
                .environmentObject(model)
                .frame(minWidth: 880, minHeight: 600)
                .task { await updater.checkInBackgroundIfDue() }
                .sheet(isPresented: $updater.showSheet) { UpdateView().environmentObject(updater).environmentObject(model) }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await updater.check(userInitiated: true) } }
                if auth.user != nil {
                    Button("Sign Out") { auth.signOut() }
                }
            }
        }
    }
}

/// Sign-in gate: the Builder (and everything it starts) only exists once HG SSO says yes.
struct RootView: View {
    @EnvironmentObject var auth: Auth
    var body: some View {
        switch auth.state {
        case .checking:
            ProgressView("Checking your HG sign-in…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedOut:
            SignInView()
        case .signedIn:
            SignedInView()
        }
    }
}

struct SignedInView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ContentView().task { model.start() }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case drive = "Drive"
    case installers = "Installers"
    case setup = "Setup Defaults"
    case activity = "Activity"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .drive: return "externaldrive"
        case .installers: return "square.and.arrow.down.on.square"
        case .setup: return "person.crop.circle.badge.checkmark"
        case .activity: return "list.bullet.rectangle"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var auth: Auth
    @State private var section: SidebarItem? = .drive

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            Group {
                switch section ?? .drive {
                case .drive: DriveView()
                case .installers: InstallersView()
                case .setup: SetupView()
                case .activity: ActivityView()
                }
            }
            .safeAreaInset(edge: .bottom) { JobBar() }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { DrivePicker() }
            ToolbarItem {
                Button { Task { await model.refreshDisks() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Look for drives again")
            }
            ToolbarItem {
                Menu {
                    if let u = auth.user { Text("Signed in as \(u.name) (\(u.username))") }
                    Button("Sign Out") { auth.signOut() }
                        .disabled(model.job != nil)
                } label: {
                    Label(auth.user?.name ?? "Account", systemImage: "person.crop.circle")
                }
                .help("HG account")
            }
        }
        .alert("HG Deploy Builder", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
    }
}

struct DrivePicker: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Picker("Drive", selection: $model.selectedDiskID) {
            if model.disks.isEmpty { Text("No external drive").tag(String?.none) }
            ForEach(model.disks) { d in
                Text(d.volumes.contains { $0.isDeployDrive } ? "\(d.label) · HG Deploy" : d.label).tag(Optional(d.id))
            }
        }
        .frame(minWidth: 280)
        .disabled(model.job != nil)
    }
}

struct JobBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let job = model.job {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(job.title).font(.callout.weight(.medium))
                    Spacer()
                    if !model.queue.isEmpty {
                        Text("\(model.queue.count) queued").font(.caption).foregroundStyle(.secondary)
                        Button("Cancel") { model.cancelQueue() }.controlSize(.small)
                    }
                }
                if let f = job.fraction {
                    ProgressView(value: f)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if !job.detail.isEmpty {
                    Text(job.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(12)
            .background(.bar)
        }
    }
}

struct ActivityView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Activity").font(.title2.bold())
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.log.joined(separator: "\n"), forType: .string)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: model.log.count) { _, n in proxy.scrollTo(n - 1) }
            }
        }
        .padding(20)
    }
}
