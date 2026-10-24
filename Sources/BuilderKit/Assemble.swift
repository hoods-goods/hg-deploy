import Foundation

/// Turns downloaded catalog packages into an "Install macOS ….app" on the drive,
/// entirely as the signed-in user (no administrator step). Apple's `installer`
/// runs as root through the password helper, and macOS doesn't let that process
/// read an external drive, so it reported "package path specified was invalid".
///
/// - Big Sur and later: `pkgutil --expand-full InstallAssistant.pkg` gives the
///   app; InstallAssistant.pkg itself is the app's SharedSupport.dmg (Apple's
///   postinstall just copies it there), so it's moved into place.
/// - High Sierra–Catalina: InstallAssistantAuto.pkg gives the app shell, and the
///   downloaded disk images go into its SharedSupport folder.
///
/// The result is checked (startosinstall present, and for Big Sur+ the
/// SharedSupport.dmg mounts and reports the expected version) before it's
/// moved into Installers/.
public enum Assembler {
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Builds the app from a product's staging folder and moves it into Installers/.
    /// `replacing` apps are deleted after the new one is in place. Returns the final app.
    @discardableResult
    public static func build(product: CatalogInstaller, staging: URL, layout: DriveLayout,
                             replacing: [URL] = [], progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let legacy = product.major.hasPrefix("10.")
        let mainPkg = staging.appendingPathComponent(legacy ? "InstallAssistantAuto.pkg" : "InstallAssistant.pkg")
        let app = try await expandApp(from: mainPkg, workDir: staging.appendingPathComponent("expanded"), progress: progress)
        let shared = app.appendingPathComponent("Contents/SharedSupport")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)

        if legacy {
            progress("Adding the disk images…")
            try place(staging.appendingPathComponent("InstallESDDmg.pkg"), at: shared.appendingPathComponent("InstallESD.dmg"), required: true)
            for f in ["BaseSystem.dmg", "BaseSystem.chunklist", "AppleDiagnostics.dmg", "AppleDiagnostics.chunklist", "InstallInfo.plist"] {
                try place(staging.appendingPathComponent(f), at: shared.appendingPathComponent(f), required: false)
            }
            fixInstallInfo(shared.appendingPathComponent("InstallInfo.plist"))
        } else {
            let dmg = shared.appendingPathComponent("SharedSupport.dmg")
            if !FileManager.default.fileExists(atPath: dmg.path) {
                progress("Adding SharedSupport.dmg…")
                try place(mainPkg, at: dmg, required: true)
            }
        }

        progress("Checking the installer…")
        do {
            try await verify(app: app, product: product)
        } catch {
            // Put the downloads back so a retry (or Resume) has them, and drop the half-built app.
            if legacy {
                try? place(shared.appendingPathComponent("InstallESD.dmg"), at: staging.appendingPathComponent("InstallESDDmg.pkg"), required: false)
                for f in ["BaseSystem.dmg", "BaseSystem.chunklist", "AppleDiagnostics.dmg", "AppleDiagnostics.chunklist"] {
                    try? place(shared.appendingPathComponent(f), at: staging.appendingPathComponent(f), required: false)
                }
            } else {
                try? place(shared.appendingPathComponent("SharedSupport.dmg"), at: mainPkg, required: false)
            }
            try? FileManager.default.removeItem(at: app)
            throw error
        }

        let final = layout.installersDir.appendingPathComponent(
            InstallerInfo.driveName(major: product.major, version: product.version, build: product.build))
        try FileManager.default.createDirectory(at: layout.installersDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
        try FileManager.default.moveItem(at: app, to: final)
        for old in replacing where old.path != final.path { try? FileManager.default.removeItem(at: old) }
        try? FileManager.default.removeItem(at: staging)
        try? FileManager.default.removeItem(at: layout.stagingDir)   // only when empty
        return final
    }

    /// Builds the app from a standalone InstallAssistant.pkg (Import…). The pkg is copied, not moved.
    public static func buildFromPackage(_ pkg: URL, layout: DriveLayout, progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let work = layout.stagingDir.appendingPathComponent("import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let app = try await expandApp(from: pkg, workDir: work.appendingPathComponent("expanded"), progress: progress)
        let shared = app.appendingPathComponent("Contents/SharedSupport")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let dmg = shared.appendingPathComponent("SharedSupport.dmg")
        if !FileManager.default.fileExists(atPath: dmg.path) {
            progress("Copying SharedSupport.dmg…")
            let r = await Shell.run("/bin/cp", [pkg.path, dmg.path])
            if !r.ok { throw Failure(message: "Couldn't copy the package: \(r.output)") }
        }
        guard let (version, build) = await InstallerInfo.sharedSupportVersion(app) else {
            throw Failure(message: "\(pkg.lastPathComponent) didn't produce a working installer (SharedSupport.dmg won't mount).")
        }
        let major = majorVersion(version)
        let final = layout.installersDir.appendingPathComponent(InstallerInfo.driveName(major: major, version: version, build: build))
        try FileManager.default.createDirectory(at: layout.installersDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
        try FileManager.default.moveItem(at: app, to: final)
        try? FileManager.default.removeItem(at: layout.stagingDir)
        return final
    }

    /// `pkgutil --expand-full` the package and return the Install macOS app inside its payload.
    static func expandApp(from pkg: URL, workDir: URL, progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pkg.path) else { throw Failure(message: "\(pkg.lastPathComponent) is missing from the download.") }
        try? fm.removeItem(at: workDir)
        try fm.createDirectory(at: workDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        progress("Expanding \(pkg.lastPathComponent)…")
        let r = await Shell.run("/usr/sbin/pkgutil", ["--expand-full", pkg.path, workDir.path])
        guard r.ok else { throw Failure(message: "pkgutil couldn't expand \(pkg.lastPathComponent): \(r.output.suffix(300))") }
        guard let app = findInstallerApp(in: workDir) else {
            throw Failure(message: "No Install macOS app inside \(pkg.lastPathComponent).")
        }
        // Move the app next to the work folder so deleting the expansion leaves it alone.
        let out = workDir.deletingLastPathComponent().appendingPathComponent(app.lastPathComponent)
        try? fm.removeItem(at: out)
        try fm.moveItem(at: app, to: out)
        try? fm.removeItem(at: workDir)
        return out
    }

    /// First "Install ….app" within a few levels (…/Payload/Applications/Install macOS X.app).
    public static func findInstallerApp(in dir: URL, depth: Int = 0) -> URL? {
        guard depth < 5 else { return nil }
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        if let app = items.first(where: { $0.pathExtension == "app" && $0.lastPathComponent.hasPrefix("Install ") }) { return app }
        for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && item.pathExtension != "app" {
            if let found = findInstallerApp(in: item, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Moves (same volume, instant) or copies a file into the app.
    static func place(_ src: URL, at dst: URL, required: Bool) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else {
            if required { throw Failure(message: "\(src.lastPathComponent) is missing from the download.") }
            return
        }
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        do { try fm.moveItem(at: src, to: dst) } catch { try fm.copyItem(at: src, to: dst) }
    }

    /// Points InstallInfo.plist at the local InstallESD.dmg instead of the chunklisted download.
    static func fixInstallInfo(_ url: URL) {
        guard let d = NSMutableDictionary(contentsOf: url),
              let payload = (d["Payload Image Info"] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary else { return }
        payload.removeObject(forKey: "chunklistURL")
        payload.removeObject(forKey: "chunklistid")
        payload["URL"] = "InstallESD.dmg"
        payload["id"] = "com.apple.dmg.InstallESD"
        d["Payload Image Info"] = payload
        d.write(to: url, atomically: true)
    }

    static func verify(app: URL, product: CatalogInstaller) async throws {
        if let problem = InstallerInfo.problem(app, major: product.major) {
            throw Failure(message: "The assembled \(product.title) isn't complete: \(problem).")
        }
        if !product.major.hasPrefix("10.") {
            guard let (version, _) = await InstallerInfo.sharedSupportVersion(app) else {
                throw Failure(message: "The assembled \(product.title) has a SharedSupport.dmg that won't mount.")
            }
            if majorVersion(version) != product.major {
                throw Failure(message: "The assembled installer reports macOS \(version), expected \(product.version).")
            }
        }
    }
}
