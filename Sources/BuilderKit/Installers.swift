import Foundation

/// An "Install macOS …" app on a drive (or anywhere).
public struct InstallerApp: Identifiable, Hashable, Sendable {
    public let url: URL
    public let version: String
    public let build: String?
    public let major: String
    public let beta: Bool
    public let problem: String?
    public var id: String { url.path }
    public var title: String {
        var t = "\(MacOS.name(major)) \(version)"
        if let build { t += " (\(build))" }
        if beta { t += " beta" }
        return t
    }
}

public enum InstallerInfo {
    /// Version, build and major of an installer app. Uses the drive manifest when
    /// it knows the app, otherwise reads the installer itself.
    public static func read(_ app: URL, manifest: Manifest? = nil) async -> InstallerApp? {
        let name = app.lastPathComponent
        let entry = manifest?.installers.first { ($0.path as NSString).lastPathComponent == name }
        var version = entry?.version
        var build = entry?.build
        if version == nil {
            if let v = oldStyleVersion(app) {
                version = v
            } else if let (v, b) = await sharedSupportVersion(app) {
                version = v; build = b
            }
        }
        if version == nil { version = versionFromName(name) }
        guard let version else { return nil }
        if build == nil { build = buildFromName(name) }
        let major = entry?.major ?? majorVersion(version)
        let beta = entry?.beta ?? (name.range(of: "beta", options: .caseInsensitive) != nil)
        return InstallerApp(url: app, version: version, build: build, major: major, beta: beta, problem: problem(app, major: major))
    }

    /// 10.13–10.15 installers: Contents/SharedSupport/InstallInfo.plist.
    static func oldStyleVersion(_ app: URL) -> String? {
        let url = app.appendingPathComponent("Contents/SharedSupport/InstallInfo.plist")
        guard let d = NSDictionary(contentsOf: url),
              let info = d["System Image Info"] as? [String: Any] else { return nil }
        return info["version"] as? String
    }

    /// Big Sur and later: the MobileAsset XML inside SharedSupport.dmg.
    static func sharedSupportVersion(_ app: URL) async -> (String, String?)? {
        let dmg = app.appendingPathComponent("Contents/SharedSupport/SharedSupport.dmg")
        guard FileManager.default.fileExists(atPath: dmg.path) else { return nil }
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("hgdeploy-ss-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let r = await Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path, dmg.path])
        guard r.ok else { return nil }
        defer {
            _ = Shell.runSync("/usr/bin/hdiutil", ["detach", "-force", mount.path])
            try? FileManager.default.removeItem(at: mount)
        }
        let xml = mount.appendingPathComponent("com_apple_MobileAsset_MacSoftwareUpdate/com_apple_MobileAsset_MacSoftwareUpdate.xml")
        guard let d = NSDictionary(contentsOf: xml),
              let assets = d["Assets"] as? [[String: Any]],
              let first = assets.first,
              let v = first["OSVersion"] as? String else { return nil }
        return (v, first["Build"] as? String)
    }

    static func versionFromName(_ name: String) -> String? {
        if let r = name.range(of: #"\b(1[0-9]|2[0-9])\.[0-9]+(\.[0-9]+)?"#, options: .regularExpression) {
            return String(name[r])
        }
        for (major, n) in MacOS.names where name.contains(" \(n)") { return major }
        if let r = name.range(of: #"macOS (1[0-9]|2[0-9])\b"#, options: .regularExpression) {
            return String(name[r]).replacingOccurrences(of: "macOS ", with: "")
        }
        return nil
    }

    static func buildFromName(_ name: String) -> String? {
        guard let r = name.range(of: #"-[0-9]{2}[A-Z][0-9]+[a-z]?"#, options: .regularExpression) else { return nil }
        return String(name[r].dropFirst())
    }

    public static func problem(_ app: URL, major: String) -> String? {
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/Resources/startosinstall").path) {
            return "startosinstall is missing"
        }
        let shared = app.appendingPathComponent("Contents/SharedSupport")
        if compareVersions(major, "11") != .orderedAscending {
            if !fm.fileExists(atPath: shared.appendingPathComponent("SharedSupport.dmg").path) { return "Incomplete: SharedSupport.dmg missing" }
        } else if !fm.fileExists(atPath: shared.appendingPathComponent("InstallESD.dmg").path) {
            return "Incomplete: InstallESD.dmg missing"
        }
        return nil
    }

    /// Installers on a drive, newest first.
    public static func onDrive(_ layout: DriveLayout) async -> [InstallerApp] {
        let manifest = layout.loadManifest()
        var found: [InstallerApp] = []
        for dir in [layout.installersDir, layout.root.appendingPathComponent("Applications")] {
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for item in items where item.lastPathComponent.hasPrefix("Install ") && item.pathExtension == "app" {
                if let app = await read(item, manifest: manifest) { found.append(app) }
            }
        }
        return found.sorted { compareVersions($0.version, $1.version) == .orderedDescending }
    }

    /// The file name an installer gets on the drive: "Install macOS Sequoia 15.7.1-24G231.app".
    public static func driveName(major: String, version: String, build: String?) -> String {
        var n = "Install \(MacOS.name(major)) \(version)"
        if let build, !build.isEmpty { n += "-\(build)" }
        return n + ".app"
    }
}
