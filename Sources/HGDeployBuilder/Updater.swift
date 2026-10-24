import AppKit
import BuilderKit
import Foundation
import Security
import SwiftUI

/// Checks the public hg-deploy-releases repo for a newer Builder and installs its .pkg.
///
/// Trust comes from Apple code signing, not from GitHub: an update is only
/// installed if the .pkg is signed with a Developer ID Installer certificate
/// from the same team that signed this copy, and Gatekeeper accepts it
/// (signed + notarized). Unsigned copies can't self-update.
@MainActor
final class Updater: ObservableObject {
    static let repo = "hoods-goods/hg-deploy-releases"

    struct Release: Equatable {
        var version: String
        var notes: String
        var pkgURL: URL
        var pkgName: String
        var pageURL: URL
    }

    enum Phase: Equatable {
        case idle, checking, upToDate, downloading, verifying, installing
        case available(Release)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var showSheet = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    let teamID: String? = Updater.ownTeamID()

    private var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: "updates.lastCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "updates.lastCheck") }
    }

    /// On launch, at most once every 20 hours; only shows the sheet if there's an update.
    func checkInBackgroundIfDue() async {
        if let last = lastCheck, Date().timeIntervalSince(last) < 20 * 60 * 60 { return }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool) async {
        if userInitiated { showSheet = true }
        phase = .checking
        do {
            let release = try await Self.latestRelease()
            lastCheck = Date()
            if let release, Self.isNewer(release.version, than: currentVersion) {
                phase = .available(release)
                showSheet = true
            } else {
                phase = .upToDate
            }
        } catch {
            phase = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func latestRelease() async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("HG Deploy Builder", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200 else { throw UpdateError(message: "GitHub answered \(code) when checking for updates.") }
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct GHRelease: Decodable { let tag_name: String; let body: String?; let html_url: URL; let assets: [Asset] }
        let r = try JSONDecoder().decode(GHRelease.self, from: data)
        guard let pkg = r.assets.first(where: { $0.name.lowercased().hasSuffix(".pkg") }) else { return nil }
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        return Release(version: version, notes: r.body ?? "", pkgURL: pkg.browser_download_url, pkgName: pkg.name, pageURL: r.html_url)
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    func install(_ release: Release) async {
        guard let teamID else {
            phase = .failed("This copy isn't signed with a Developer ID, so it can't verify updates. Download the installer from the release page instead.")
            return
        }
        do {
            phase = .downloading
            let (tmp, resp) = try await URLSession.shared.download(from: release.pkgURL)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError(message: "Download failed.") }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HGDeployBuilder-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pkg = dir.appendingPathComponent(release.pkgName.replacingOccurrences(of: "/", with: "_"))
            try FileManager.default.moveItem(at: tmp, to: pkg)

            phase = .verifying
            try await Self.verify(pkg: pkg.path, teamID: teamID)

            phase = .installing
            // The admin script itself quits this copy and opens the new one once
            // the installer succeeds, so the relaunch doesn't depend on the
            // password helper reporting back (it sometimes never does).
            let app = "/Applications/HG Deploy Builder.app"
            let pid = ProcessInfo.processInfo.processIdentifier
            let uid = getuid()
            let relaunchCmd = "sleep 2; kill -TERM \(pid) 2>/dev/null; sleep 2; kill -KILL \(pid) 2>/dev/null; /bin/launchctl asuser \(uid) /usr/bin/open \(Shell.quote(app))"
            let script = """
            /usr/sbin/installer -pkg \(Shell.quote(pkg.path)) -target / || exit 1
            /usr/bin/nohup /bin/bash -c \(Shell.quote(relaunchCmd)) </dev/null >/dev/null 2>&1 &
            exit 0
            """
            // Also watch the installed copy: as soon as Applications has the new
            // version, quit and open it, whether or not the password helper or
            // the script above ever report back.
            let watcher = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Self.installedVersion() == release.version {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)   // let the installer finish writing
                        self?.relaunch()
                        return
                    }
                }
            }
            let r = await Shell.runAsAdmin(script: script,
                                           prompt: "HG Deploy Builder wants to install version \(release.version).")
            if r.output.contains("Cancelled at the password prompt") { watcher.cancel(); phase = .available(release); return }
            guard r.ok else { watcher.cancel(); throw UpdateError(message: "The installer failed: \(r.output.suffix(400))") }
            try? FileManager.default.removeItem(at: dir)
            watcher.cancel()
            relaunch()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    static func verify(pkg: String, teamID: String) async throws {
        let sig = await Shell.run("/usr/sbin/pkgutil", ["--check-signature", pkg])
        guard sig.ok, let pkgTeam = installerTeamID(fromPkgutil: sig.output) else {
            throw UpdateError(message: "The update isn't signed with a Developer ID Installer certificate, so it wasn't installed.")
        }
        guard pkgTeam == teamID else {
            throw UpdateError(message: "The update is signed by a different team (\(pkgTeam)), so it wasn't installed.")
        }
        let gk = await Shell.run("/usr/sbin/spctl", ["--assess", "--type", "install", "-vv", pkg])
        guard gk.ok else { throw UpdateError(message: "macOS Gatekeeper rejected the update (\(gk.output)), so it wasn't installed.") }
    }

    nonisolated static func installerTeamID(fromPkgutil text: String) -> String? {
        for line in text.components(separatedBy: "\n") where line.contains("Developer ID Installer:") {
            guard let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close else { continue }
            let id = String(line[line.index(after: open)..<close])
            if id.count == 10, id.allSatisfy({ $0.isUppercase || $0.isNumber }) { return id }
        }
        return nil
    }

    nonisolated static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Version of the copy in /Applications (tells us the update has landed).
    nonisolated static func installedVersion() -> String? {
        let plist = URL(fileURLWithPath: "/Applications/HG Deploy Builder.app/Contents/Info.plist")
        guard let d = NSDictionary(contentsOf: plist) else { return nil }
        return d["CFBundleShortVersionString"] as? String
    }

    private var relaunching = false

    /// Opens the newly installed copy a moment after this one quits.
    private func relaunch() {
        guard !relaunching else { return }
        relaunching = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 2; /usr/bin/open '/Applications/HG Deploy Builder.app'"]
        try? p.run()
        NSApp.terminate(nil)
        // If something holds up a normal quit, don't leave the old copy running.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    }
}

struct UpdateView: View {
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text("You have version \(updater.currentVersion).").font(.callout).foregroundStyle(.secondary)
                }
            }
            switch updater.phase {
            case .available(let r):
                if !r.notes.isEmpty {
                    ScrollView {
                        Text(r.notes).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
                if model.isBusy {
                    Label("Installers are downloading or being built. Finish or cancel that first; updating now would stop it.",
                          systemImage: "hourglass").font(.caption).foregroundStyle(.orange)
                }
                if updater.teamID == nil {
                    Text("This copy isn't signed with a Developer ID, so it can't install updates itself. Download the installer from the release page.")
                        .font(.caption).foregroundStyle(.orange)
                }
            case .failed(let msg):
                Text(msg).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            case .checking, .downloading, .verifying, .installing:
                ProgressView().controlSize(.small)
            default:
                EmptyView()
            }
            HStack {
                if case .available(let r) = updater.phase {
                    Button("Release Page") { NSWorkspace.shared.open(r.pageURL) }
                }
                Spacer()
                Button(isBusy ? "Hide" : "Close") { updater.showSheet = false; dismiss() }
                if case .available(let r) = updater.phase, updater.teamID != nil {
                    Button("Install and Relaunch") { Task { await updater.install(r) } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                }
                if case .failed = updater.phase {
                    Button("Try Again") { Task { await updater.check(userInitiated: true) } }
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var isBusy: Bool {
        switch updater.phase {
        case .checking, .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    private var title: String {
        switch updater.phase {
        case .idle, .checking: return "Checking for updates…"
        case .upToDate: return "HG Deploy Builder is up to date"
        case .available(let r): return "HG Deploy Builder \(r.version) is available"
        case .downloading: return "Downloading…"
        case .verifying: return "Checking the signature…"
        case .installing: return "Installing…"
        case .failed: return "Update problem"
        }
    }
}
