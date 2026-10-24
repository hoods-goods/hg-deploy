import AppKit
import BuilderKit
import Foundation

/// Something long-running the Builder is doing (shown in the bar at the bottom).
struct Job: Equatable {
    var title: String
    var detail: String = ""
    var fraction: Double? = nil   // nil = indeterminate
}

@MainActor
final class AppModel: ObservableObject {
    // Drives
    @Published var disks: [ExternalDisk] = []
    @Published var selectedDiskID: String? { didSet { if oldValue != selectedDiskID { Task { await driveChanged() } } } }
    @Published var driveInstallers: [InstallerApp] = []
    @Published var driveFree: Int64 = 0

    // Apple's catalog
    @Published var catalog: [CatalogInstaller] = []
    @Published var catalogLoading = false
    @Published var catalogError: String?
    @Published var queue: [CatalogInstaller] = []
    /// Downloads left in the drive's staging folder by an update, crash or unplugged drive.
    @Published var unfinished: [Unfinished] = []

    struct Unfinished: Identifiable, Equatable {
        let id: String              // product ID = staging folder name
        let product: CatalogInstaller?
        let downloaded: Int64
        var title: String { product?.title ?? "Unknown installer (\(id))" }
    }

    /// True while something is downloading or installing (updates wait for it).
    var isBusy: Bool { job != nil || !queue.isEmpty || queueTask != nil }

    // Defaults written to the drive
    @Published var config = DeployConfig()
    @Published var configSaved = true

    @Published var job: Job?
    @Published var log: [String] = []
    @Published var alert: String?

    let models: ModelTable?
    private var queueTask: Task<Void, Never>?

    init() {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Payload/models.json"),
           let data = try? Data(contentsOf: url) {
            models = try? ModelTable(data: data)
        } else {
            models = nil
        }
        if let d = UserDefaults.standard.data(forKey: "defaultConfig"),
           let c = try? JSONDecoder().decode(DeployConfig.self, from: d) {
            config = c
        }
    }

    private var started = false

    /// Called once someone has signed in. The model lives as long as the app,
    /// so closing and reopening the window keeps downloads and state.
    func start() {
        guard !started else { return }
        started = true
        Task {
            await refreshDisks()
            await loadCatalog()
        }
    }

    // MARK: - Paths & versions

    var builderVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var payload: URL? {
        guard let u = Bundle.main.resourceURL?.appendingPathComponent("Payload"),
              FileManager.default.fileExists(atPath: u.appendingPathComponent("HG Deploy.app").path) else { return nil }
        return u
    }

    var selectedDisk: ExternalDisk? { disks.first { $0.id == selectedDiskID } }

    /// The mounted volume on the selected disk we work with (the HG Deploy one if there is one).
    var volume: ExternalDisk.Volume? {
        guard let d = selectedDisk else { return nil }
        let mounted = d.volumes.filter { $0.mountPoint != nil }
        return mounted.first { $0.isDeployDrive } ?? mounted.first
    }

    var layout: DriveLayout? {
        guard let mp = volume?.mountPoint else { return nil }
        return DriveLayout(root: URL(fileURLWithPath: mp))
    }

    var isDeployDrive: Bool { layout?.isDeployDrive ?? false }

    func say(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(line)")
    }

    // MARK: - Drives

    func refreshDisks() async {
        let found = await Disks.external()
        disks = found
        if selectedDiskID == nil || !found.contains(where: { $0.id == selectedDiskID }) {
            selectedDiskID = found.first(where: { $0.volumes.contains { $0.isDeployDrive } })?.id ?? found.first?.id
        } else {
            await driveChanged()
        }
    }

    func driveChanged() async {
        driveInstallers = []
        guard let layout else { driveFree = 0; return }
        driveFree = Disks.freeSpace(at: layout.root)
        if layout.isDeployDrive, let c = layout.loadConfig() {
            config = c
            configSaved = true
        }
        await refreshInstallers()
    }

    func refreshInstallers() async {
        guard let layout else { return }
        driveInstallers = await InstallerInfo.onDrive(layout)
        driveFree = Disks.freeSpace(at: layout.root)
        // Keep installers.json in step with what's really on the drive so
        // HG Deploy in Recovery sees exact versions and builds.
        guard layout.isDeployDrive else { return }
        let old = layout.loadManifest()
        let entries = driveInstallers.map { app -> Manifest.Entry in
            let rel = app.url.path.replacingOccurrences(of: layout.root.path + "/", with: "")
            let prior = old.installers.first { ($0.path as NSString).lastPathComponent == app.url.lastPathComponent }
            return Manifest.Entry(path: rel, version: app.version, build: app.build, major: app.major,
                                  beta: app.beta, productID: prior?.productID)
        }
        let manifest = Manifest(installers: entries)
        if manifest != old { try? layout.save(manifest) }
        scanUnfinished()
    }

    /// Finds staging folders that aren't part of the current queue.
    func scanUnfinished() {
        guard let layout, layout.isDeployDrive else { unfinished = []; return }
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: layout.stagingDir, includingPropertiesForKeys: nil)) ?? []
        let active = Set(queue.map(\.id))
        unfinished = dirs.compactMap { dir in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let id = dir.lastPathComponent
            guard !active.contains(id), queueTask == nil else { return nil }
            let size = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return Unfinished(id: id, product: catalog.first { $0.id == id }, downloaded: size)
        }
    }

    func resumeUnfinished() {
        for u in unfinished { if let p = u.product { enqueue(p) } }
        unfinished.removeAll { $0.product != nil }
    }

    func discardUnfinished() async {
        guard let layout else { return }
        for u in unfinished {
            let dir = layout.stagingDir.appendingPathComponent(u.id)
            do { try FileManager.default.removeItem(at: dir) } catch {
                _ = await Shell.runAsAdmin(script: "rm -rf \(Shell.quote(dir.path))", prompt: "HG Deploy Builder needs to delete an unfinished download.")
            }
        }
        try? FileManager.default.removeItem(at: layout.stagingDir)   // only succeeds when empty
        say("Discarded unfinished downloads")
        unfinished = []
        driveFree = Disks.freeSpace(at: layout.root)
    }

    /// Erases the selected disk and makes it an HG Deploy drive.
    func buildDrive(name: String) async {
        guard let disk = selectedDisk else { return }
        guard payload != nil else { alert = "This copy of HG Deploy Builder is missing the HG Deploy payload. Install a release build."; return }
        job = Job(title: "Erasing \(disk.mediaName)…")
        say("Erasing \(disk.id) as \(name) (Mac OS Extended, GUID)")
        let r = await Disks.eraseForDeploy(disk: disk.id, name: name)
        say(r.output.trimmingCharacters(in: .whitespacesAndNewlines))
        guard r.ok else {
            job = nil
            alert = "Erasing the drive failed:\n\(r.output)"
            return
        }
        await refreshDisks()
        selectedDiskID = disk.id
        await installTool()
    }

    /// Copies (or updates) HG Deploy, the first-boot package and the launcher onto the drive.
    func installTool() async {
        guard let layout, let payload else {
            alert = payload == nil ? "This copy of HG Deploy Builder is missing the HG Deploy payload." : "No drive selected."
            return
        }
        job = Job(title: "Putting HG Deploy on \(layout.root.lastPathComponent)…")
        let version = builderVersion
        let cfg = config
        let result: String? = await Task.detached {
            let fm = FileManager.default
            do {
                for dir in [layout.toolDir, layout.installersDir, layout.logsDir, layout.packagesDir] {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                // ditto keeps the app bundle intact (symlinks, permissions, signature).
                try? fm.removeItem(at: layout.deployApp)
                let d = Shell.runSync("/usr/bin/ditto", [payload.appendingPathComponent("HG Deploy.app").path, layout.deployApp.path])
                if !d.ok { return "Copying HG Deploy failed: \(d.output)" }
                try? fm.removeItem(at: layout.firstBootPkg)
                try fm.copyItem(at: payload.appendingPathComponent("HGFirstBoot.pkg"), to: layout.firstBootPkg)

                try DriveLayout.runScriptContents.write(to: layout.runScript, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.runScript.path)
                try DriveLayout.readmeContents(volumeName: layout.root.lastPathComponent)
                    .write(to: layout.readme, atomically: true, encoding: .utf8)
                let v = try JSONSerialization.data(withJSONObject: ["version": version, "updated": ISO8601DateFormatter().string(from: Date())],
                                                   options: [.prettyPrinted])
                try v.write(to: layout.versionFile)
                if layout.loadConfig() == nil { try layout.save(cfg) }
                // Keep Spotlight and Time Machine off the drive.
                fm.createFile(atPath: layout.root.appendingPathComponent(".metadata_never_index").path, contents: nil)
                fm.createFile(atPath: layout.root.appendingPathComponent(".com.apple.timemachine.donotpresent").path, contents: nil)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        job = nil
        if let result {
            alert = "Setting up the drive failed: \(result)"
            say("Tool install failed: \(result)")
        } else {
            say("HG Deploy \(version) is on \(layout.root.path). In Recovery run: \(layout.command)")
        }
        await refreshDisks()
    }

    /// Renames the drive's volume (no erase) and refreshes the READ ME with the new command.
    func renameDrive(to name: String) async {
        guard let vol = volume, let mp = vol.mountPoint else { return }
        guard name != vol.name else { return }
        job = Job(title: "Renaming \(vol.name) to \(name)…")
        let r = await Shell.run("/usr/sbin/diskutil", ["rename", mp, name])
        say(r.output.trimmingCharacters(in: .whitespacesAndNewlines))
        job = nil
        guard r.ok else { alert = "Renaming failed:\n\(r.output)"; return }
        await refreshDisks()
        if let layout, layout.isDeployDrive {
            try? DriveLayout.readmeContents(volumeName: layout.root.lastPathComponent)
                .write(to: layout.readme, atomically: true, encoding: .utf8)
            say("In Recovery run: \(layout.command)")
        }
    }

    func showInFinder() {
        guard let layout else { return }
        NSWorkspace.shared.activateFileViewerSelecting([layout.root])
    }

    // MARK: - Defaults

    func saveConfig() {
        guard let layout, layout.isDeployDrive else { return }
        do {
            try layout.save(config)
            configSaved = true
            if let d = try? JSONEncoder().encode(config) { UserDefaults.standard.set(d, forKey: "defaultConfig") }
            say("Saved setup defaults to the drive")
        } catch {
            alert = "Couldn't save: \(error.localizedDescription)"
        }
    }

    // MARK: - Catalog

    func loadCatalog() async {
        catalogLoading = true
        catalogError = nil
        do {
            catalog = try await Catalog.fetch()
            say("Apple catalog: \(catalog.count) Intel installers")
            scanUnfinished()
        } catch {
            catalogError = error.localizedDescription
            say("Catalog failed: \(error.localizedDescription)")
        }
        catalogLoading = false
    }

    var latestPerMajor: [String: CatalogInstaller] { Catalog.latestPerMajor(catalog) }

    func driveHas(_ product: CatalogInstaller) -> Bool {
        driveInstallers.contains { $0.version == product.version && ($0.build == nil || $0.build == product.build) }
    }

    func newestOnDrive(major: String) -> InstallerApp? {
        driveInstallers.filter { $0.major == major && !$0.beta }.first
    }

    /// The newer catalog version for a major, when the drive's copy is older (or a beta).
    func update(for major: String) -> CatalogInstaller? {
        guard let latest = latestPerMajor[major] else { return nil }
        let onDrive = driveInstallers.filter { $0.major == major }
        guard !onDrive.isEmpty else { return nil }
        if onDrive.contains(where: { !$0.beta && compareVersions($0.version, latest.version) != .orderedAscending }) { return nil }
        return latest
    }

    var missingMajors: [String] {
        MacOS.majors.reversed().filter { m in !driveInstallers.contains { $0.major == m && !$0.beta } }
    }

    func enqueue(_ product: CatalogInstaller) {
        guard !queue.contains(product), !driveHas(product) else { return }
        queue.append(product)
        say("Queued \(product.title)")
        startQueue()
    }

    func addLatestOfEvery() {
        for m in MacOS.majors.reversed() {
            if let p = latestPerMajor[m], newestOnDrive(major: m) == nil || update(for: m) != nil { enqueue(p) }
        }
    }

    func updateAll() {
        for m in MacOS.majors { if let p = update(for: m) { enqueue(p) } }
    }

    func cancelQueue() {
        queueTask?.cancel()
    }

    private func startQueue() {
        guard queueTask == nil else { return }
        queueTask = Task { await runQueue(); queueTask = nil; scanUnfinished() }
    }

    /// Downloads everything queued (no password needed), then installs all of
    /// it onto the drive with one administrator prompt.
    private func runQueue() async {
        guard let layout, layout.isDeployDrive else {
            alert = "Set the drive up as an HG Deploy drive first (Drive tab)."
            queue = []
            return
        }
        var staged: [(product: CatalogInstaller, dist: URL, replacing: [URL])] = []
        while let product = queue.first {
            if Task.isCancelled { break }
            job = Job(title: "Downloading \(product.title)", detail: "", fraction: 0)
            say("Downloading \(product.title) (\(formatBytes(product.totalSize)))")
            do {
                let dist = try await InstallerBuilder.stage(product, layout: layout) { detail, fraction in
                    Task { @MainActor in
                        self.job = Job(title: "Downloading \(product.title)", detail: detail, fraction: fraction)
                    }
                }
                let replacing = driveInstallers.filter { $0.major == product.major }.map(\.url)
                staged.append((product, dist, replacing))
            } catch is CancellationError {
                say("Cancelled")
                break
            } catch {
                say("Download of \(product.title) failed: \(error.localizedDescription)")
                alert = "Download of \(product.title) failed: \(error.localizedDescription)"
            }
            queue.removeFirst()
        }
        if Task.isCancelled { queue = [] }
        guard !staged.isEmpty else { job = nil; return }

        // Build each installer as this user: no admin step reads the drive
        // (macOS blocks that), so there's no password prompt either.
        var manifest = layout.loadManifest()
        var failures: [String] = []
        for (product, dist, replacing) in staged {
            job = Job(title: "Building \(product.title) on the drive…")
            say("Building \(product.title)")
            do {
                let final = try await Assembler.build(product: product, staging: dist.deletingLastPathComponent(), layout: layout,
                                                      replacing: replacing) { detail in
                    Task { @MainActor in self.job = Job(title: "Building \(product.title) on the drive…", detail: detail) }
                }
                manifest.installers.removeAll { ($0.path as NSString).lastPathComponent == final.lastPathComponent }
                manifest.installers.append(.init(path: "Installers/\(final.lastPathComponent)", version: product.version,
                                                 build: product.build, major: product.major, productID: product.id))
                try? layout.save(manifest)
                say("Added \(product.title)")
            } catch {
                say("\(product.title) failed: \(error.localizedDescription)")
                failures.append("\(product.title): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { alert = "Some installers didn't finish:\n" + failures.joined(separator: "\n") }
        try? layout.save(manifest)
        job = nil
        await refreshInstallers()
        if !queue.isEmpty { await runQueue() }
    }

    // MARK: - Removing & importing

    func remove(_ app: InstallerApp) async {
        job = Job(title: "Removing \(app.title)…")
        do {
            try FileManager.default.removeItem(at: app.url)
        } catch {
            let r = await Shell.runAsAdmin(script: "rm -rf \(Shell.quote(app.url.path))", prompt: "HG Deploy Builder needs to remove an installer.")
            if !r.ok { alert = "Couldn't remove \(app.title): \(r.output)" }
        }
        say("Removed \(app.title)")
        job = nil
        await refreshInstallers()
    }

    /// Copies an "Install macOS ….app" or installs an InstallAssistant.pkg onto the drive.
    func importInstaller(from url: URL) async {
        guard let layout, layout.isDeployDrive else { alert = "Set the drive up first (Drive tab)."; return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        if url.pathExtension == "pkg" {
            job = Job(title: "Building an installer from \(url.lastPathComponent)…")
            do {
                let final = try await Assembler.buildFromPackage(url, layout: layout) { detail in
                    Task { @MainActor in self.job = Job(title: "Building an installer from \(url.lastPathComponent)…", detail: detail) }
                }
                say("Imported \(final.lastPathComponent)")
            } catch {
                alert = "Import failed: \(error.localizedDescription)"
            }
            job = nil
            await refreshInstallers()
            return
        }

        guard let info = await InstallerInfo.read(url) else {
            alert = "\(url.lastPathComponent) doesn't look like a macOS installer."
            return
        }
        if let problem = info.problem { alert = "\(info.title): \(problem)"; return }
        guard MacOS.isIntelMajor(info.major) else { alert = "\(info.title) doesn't run on Intel Macs."; return }
        let dest = layout.installersDir.appendingPathComponent(
            InstallerInfo.driveName(major: info.major, version: info.version, build: info.build))
        job = Job(title: "Copying \(info.title)…", detail: "", fraction: 0)
        let total = Self.size(of: url)
        let poll = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let got = Self.size(of: dest)
                job = Job(title: "Copying \(info.title)…", detail: "\(formatBytes(got)) of \(formatBytes(total))",
                          fraction: total > 0 ? min(Double(got) / Double(total), 1) : nil)
            }
        }
        try? FileManager.default.removeItem(at: dest)
        let r = await Shell.run("/usr/bin/ditto", [url.path, dest.path])
        poll.cancel()
        job = nil
        if r.ok {
            var manifest = layout.loadManifest()
            manifest.installers.removeAll { ($0.path as NSString).lastPathComponent == dest.lastPathComponent }
            manifest.installers.append(.init(path: "Installers/\(dest.lastPathComponent)", version: info.version,
                                             build: info.build, major: info.major, beta: info.beta))
            try? layout.save(manifest)
            say("Imported \(info.title)")
        } else {
            alert = "Copy failed: \(r.output)"
        }
        await refreshInstallers()
    }

    nonisolated static func size(of url: URL) -> Int64 {
        let r = Shell.runSync("/usr/bin/du", ["-sk", url.path])
        return (Int64(r.output.split(separator: "\t").first ?? "0") ?? 0) * 1024
    }
}
