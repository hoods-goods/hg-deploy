import Foundation

/// HGDeploy/config.json — the defaults HG Deploy shows in Recovery.
/// Keys must match what Deploy/AppDelegate.m reads.
public struct DeployConfig: Codable, Equatable, Sendable {
    public struct Account: Codable, Equatable, Sendable {
        public var create = false
        public var fullName = ""
        public var shortName = ""
        public var password = ""
        public var admin = true
        public var autoLogin = false
        public init() {}
    }
    /// Wi-Fi HG Deploy joins when it opens in Recovery (to set the clock).
    public struct WiFi: Codable, Equatable, Sendable {
        public var ssid = ""
        public var password = ""
        public init() {}
    }
    public var account = Account()
    public var wifi = WiFi()
    public var computerName = ""
    public var enableSSH = false
    public var eraseByDefault = true
    public var volumeName = "Macintosh HD"
    public init() {}

    public init(from decoder: Decoder) throws {
        // Tolerate missing keys so older/newer drives still load.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        account = (try? c.decode(Account.self, forKey: .account)) ?? Account()
        wifi = (try? c.decode(WiFi.self, forKey: .wifi)) ?? WiFi()
        computerName = (try? c.decode(String.self, forKey: .computerName)) ?? ""
        enableSSH = (try? c.decode(Bool.self, forKey: .enableSSH)) ?? false
        eraseByDefault = (try? c.decode(Bool.self, forKey: .eraseByDefault)) ?? true
        volumeName = (try? c.decode(String.self, forKey: .volumeName)) ?? "Macintosh HD"
    }
}

extension DeployConfig.WiFi {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ssid = (try? c.decode(String.self, forKey: .ssid)) ?? ""
        password = (try? c.decode(String.self, forKey: .password)) ?? ""
    }
}

extension DeployConfig.Account {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        create = (try? c.decode(Bool.self, forKey: .create)) ?? false
        fullName = (try? c.decode(String.self, forKey: .fullName)) ?? ""
        shortName = (try? c.decode(String.self, forKey: .shortName)) ?? ""
        password = (try? c.decode(String.self, forKey: .password)) ?? ""
        admin = (try? c.decode(Bool.self, forKey: .admin)) ?? true
        autoLogin = (try? c.decode(Bool.self, forKey: .autoLogin)) ?? false
    }
}

/// HGDeploy/installers.json — exact versions of the installers on the drive.
public struct Manifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var path: String          // relative to the drive root
        public var version: String
        public var build: String?
        public var major: String
        public var beta: Bool
        public var productID: String?
        public var id: String { path }
        public init(path: String, version: String, build: String?, major: String, beta: Bool = false, productID: String? = nil) {
            self.path = path; self.version = version; self.build = build
            self.major = major; self.beta = beta; self.productID = productID
        }
    }
    public var installers: [Entry] = []
    public init(installers: [Entry] = []) { self.installers = installers }
}

/// Where everything lives on an HG Deploy drive.
public struct DriveLayout: Sendable {
    public let root: URL   // /Volumes/HGDeploy

    public init(root: URL) { self.root = root }

    public var toolDir: URL { root.appendingPathComponent("HGDeploy") }
    public var deployApp: URL { toolDir.appendingPathComponent("HG Deploy.app") }
    public var firstBootPkg: URL { toolDir.appendingPathComponent("HGFirstBoot.pkg") }
    public var configFile: URL { toolDir.appendingPathComponent("config.json") }
    public var manifestFile: URL { toolDir.appendingPathComponent("installers.json") }
    public var versionFile: URL { toolDir.appendingPathComponent("version.json") }
    public var logsDir: URL { toolDir.appendingPathComponent("Logs") }
    public var packagesDir: URL { toolDir.appendingPathComponent("Packages") }
    public var installersDir: URL { root.appendingPathComponent("Installers") }
    public var stagingDir: URL { root.appendingPathComponent(".hgdeploy-staging") }
    public var runScript: URL { root.appendingPathComponent("run") }
    public var readme: URL { root.appendingPathComponent("READ ME.txt") }

    public var command: String { "\(root.path)/run" }
    public var isDeployDrive: Bool { FileManager.default.fileExists(atPath: deployApp.path) }

    public func toolVersion() -> String? {
        guard let d = try? Data(contentsOf: versionFile),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j["version"] as? String
    }

    public func loadConfig() -> DeployConfig? {
        guard let d = try? Data(contentsOf: configFile) else { return nil }
        return try? JSONDecoder().decode(DeployConfig.self, from: d)
    }

    public func save(_ config: DeployConfig) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: toolDir, withIntermediateDirectories: true)
        try enc.encode(config).write(to: configFile, options: .atomic)
    }

    public func loadManifest() -> Manifest {
        guard let d = try? Data(contentsOf: manifestFile),
              let m = try? JSONDecoder().decode(Manifest.self, from: d) else { return Manifest() }
        return m
    }

    public func save(_ manifest: Manifest) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: toolDir, withIntermediateDirectories: true)
        try enc.encode(manifest).write(to: manifestFile, options: .atomic)
    }

    /// The Recovery launcher. Recovery has no `dirname`, so the drive path comes from $0.
    public static let runScriptContents = """
    #!/bin/bash
    # HG Deploy launcher.
    # Boot the Intel Mac to Recovery (Command-R), open Utilities > Terminal and type:
    #     /Volumes/<drive name>/run
    dir=$(echo "$0" | /usr/bin/sed 's|/run$||')
    case "$dir" in /*) ;; *) dir="$(pwd)/$dir" ;; esac

    if [ "$(/usr/bin/arch 2>/dev/null)" = "arm64" ]; then
        echo "This is an Apple silicon Mac. HG Deploy is for Intel Macs."
        exit 1
    fi
    # HG Deploy needs Recovery from macOS 10.11 or later.
    osv=$(/usr/bin/sw_vers -productVersion 2>/dev/null)
    major=${osv%%.*}; rest=${osv#*.}; minor=${rest%%.*}
    if [ "$major" = "10" ] && [ -n "$minor" ] && [ "$minor" -lt 11 ] 2>/dev/null; then
        echo "This Recovery is macOS $osv, which is too old for HG Deploy."
        echo "Restart holding Option-Command-R (Internet Recovery) and run this again."
        exit 1
    fi
    APP="$dir/HGDeploy/HG Deploy.app/Contents/MacOS/HG Deploy"
    if [ ! -x "$APP" ]; then
        echo "HG Deploy isn't on this drive ($APP missing). Rebuild it with HG Deploy Builder."
        exit 1
    fi
    echo "Starting HG Deploy..."
    "$APP" --drive "$dir" 2>&1 | /usr/bin/grep --line-buffered -v -e ViewBridge -e IMKClient -e IMKInputSession
    """

    public static func readmeContents(volumeName: String) -> String {
        """
        HG Deploy drive
        ===============

        To install macOS on an Intel Mac:
          1. Plug in this drive and start the Mac in Recovery (hold Command-R,
             or Option-Command-R for Internet Recovery).
          2. Open Utilities > Terminal.
          3. Type:  /Volumes/\(volumeName)/run   and press Return.

        HG Deploy shows the Mac's model and the newest macOS it supports, then
        erases the internal disk and installs. Logs are saved in HGDeploy/Logs.

        Manage installers and defaults with HG Deploy Builder on a Mac.
        """
    }
}
