import Foundation

/// A full macOS installer listed in Apple's software update catalog.
public struct CatalogInstaller: Identifiable, Hashable, Sendable {
    public let id: String            // product ID, e.g. 072-12345
    public let version: String       // 15.7.1
    public let build: String         // 24G231
    public let postDate: Date
    public let distributionURL: URL
    public let packages: [Package]
    public var major: String { majorVersion(version) }
    public var name: String { MacOS.name(major) }
    public var title: String { "\(name) \(version) (\(build))" }
    public var totalSize: Int64 { packages.reduce(0) { $0 + $1.size } }

    public struct Package: Hashable, Sendable {
        public let url: URL
        public let size: Int64
        public var filename: String { url.lastPathComponent }
    }

    public init(id: String, version: String, build: String, postDate: Date, distributionURL: URL, packages: [Package]) {
        self.id = id; self.version = version; self.build = build
        self.postDate = postDate; self.distributionURL = distributionURL; self.packages = packages
    }
}

/// Reads Apple's public software update catalog — the same source Apple's
/// own `softwareupdate --fetch-full-installer` and MDS use.
public enum Catalog {
    public static let urls = [
        "https://swscan.apple.com/content/catalogs/others/index-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog",
        "https://swscan.apple.com/content/catalogs/others/index-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog",
    ].compactMap(URL.init(string:))

    /// A product from the catalog before its distribution file has been read.
    public struct Candidate: Sendable {
        public let id: String
        public let postDate: Date
        public let distributionURL: URL
        public let packages: [CatalogInstaller.Package]
    }

    /// Products that are full macOS installers (they carry InstallAssistantPackageIdentifiers).
    public static func candidates(fromCatalog data: Data) throws -> [Candidate] {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let products = root["Products"] as? [String: Any] else {
            throw CatalogError.badCatalog
        }
        var out: [Candidate] = []
        for (id, value) in products {
            guard let p = value as? [String: Any],
                  let meta = p["ExtendedMetaInfo"] as? [String: Any],
                  let ids = meta["InstallAssistantPackageIdentifiers"] as? [String: Any],
                  ids["OSInstall"] as? String == "com.apple.mpkg.OSInstall" || ids["SharedSupport"] != nil,
                  let dists = p["Distributions"] as? [String: Any],
                  let distString = (dists["English"] ?? dists["en"]) as? String,
                  let distURL = URL(string: distString),
                  let pkgs = p["Packages"] as? [[String: Any]] else { continue }
            let packages: [CatalogInstaller.Package] = pkgs.compactMap { pkg in
                guard let s = pkg["URL"] as? String, let u = URL(string: s) else { return nil }
                let size = (pkg["Size"] as? NSNumber)?.int64Value ?? 0
                return .init(url: u, size: size)
            }
            guard !packages.isEmpty else { continue }
            out.append(Candidate(id: id, postDate: p["PostDate"] as? Date ?? .distantPast,
                                 distributionURL: distURL, packages: packages))
        }
        return out
    }

    /// Pulls VERSION and BUILD out of a product's .dist file.
    public static func versionAndBuild(fromDistribution text: String) -> (version: String, build: String)? {
        func value(_ key: String) -> String? {
            let pattern = "<key>\(key)</key>\\s*<string>([^<]+)</string>"
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r]).trimmingCharacters(in: .whitespaces)
        }
        guard let v = value("VERSION"), let b = value("BUILD") else { return nil }
        return (v, b)
    }

    /// Downloads the catalog and every installer's .dist file. Intel majors only, newest first.
    public static func fetch(session: URLSession = .shared) async throws -> [CatalogInstaller] {
        var candidates: [String: Candidate] = [:]
        var lastError: Error?
        for url in urls {
            do {
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                for c in try Self.candidates(fromCatalog: data) where candidates[c.id] == nil { candidates[c.id] = c }
                if !candidates.isEmpty { break }
            } catch { lastError = error }
        }
        if candidates.isEmpty { throw lastError ?? CatalogError.badCatalog }

        let found = await withTaskGroup(of: CatalogInstaller?.self) { group in
            for c in candidates.values {
                group.addTask {
                    guard let (data, _) = try? await session.data(from: c.distributionURL),
                          let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                          let vb = versionAndBuild(fromDistribution: text) else { return nil }
                    return CatalogInstaller(id: c.id, version: vb.version, build: vb.build, postDate: c.postDate,
                                            distributionURL: c.distributionURL, packages: c.packages)
                }
            }
            var all: [CatalogInstaller] = []
            for await i in group { if let i { all.append(i) } }
            return all
        }
        return sort(found.filter { MacOS.isIntelMajor($0.major) })
    }

    public static func sort(_ list: [CatalogInstaller]) -> [CatalogInstaller] {
        list.sorted {
            let c = compareVersions($0.version, $1.version)
            if c != .orderedSame { return c == .orderedDescending }
            return $0.postDate > $1.postDate
        }
    }

    /// The newest installer for each major.
    public static func latestPerMajor(_ list: [CatalogInstaller]) -> [String: CatalogInstaller] {
        var out: [String: CatalogInstaller] = [:]
        for i in sort(list) where out[i.major] == nil { out[i.major] = i }
        return out
    }
}

public enum CatalogError: LocalizedError {
    case badCatalog
    public var errorDescription: String? { "Apple's software catalog couldn't be read." }
}
