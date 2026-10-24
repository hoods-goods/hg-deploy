import XCTest
@testable import BuilderKit

final class BuilderKitTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testVersions() {
        XCTAssertEqual(compareVersions("10.13", "10.15.7"), .orderedAscending)
        XCTAssertEqual(compareVersions("10.15.7", "11"), .orderedAscending)
        XCTAssertEqual(compareVersions("15.7.1", "26"), .orderedAscending)
        XCTAssertEqual(majorVersion("10.15.7"), "10.15")
        XCTAssertEqual(majorVersion("15.7.1"), "15")
        XCTAssertEqual(majorVersion("26.0"), "26")
        XCTAssertTrue(MacOS.isIntelMajor("26"))
        XCTAssertFalse(MacOS.isIntelMajor("27"))
    }

    func testCatalogCandidates() throws {
        let c = try Catalog.candidates(fromCatalog: fixture("catalog.plist"))
        XCTAssertEqual(Set(c.map(\.id)), ["072-11111", "041-22222"])   // the Safari update is ignored
        let seq = try XCTUnwrap(c.first { $0.id == "072-11111" })
        XCTAssertEqual(seq.packages.map(\.filename), ["InstallAssistant.pkg", "BuildManifest.plist"])
        XCTAssertEqual(seq.packages.first?.size, 15_000_000_000)
    }

    func testDistribution() throws {
        let text = String(decoding: try fixture("sequoia.dist"), as: UTF8.self)
        let vb = try XCTUnwrap(Catalog.versionAndBuild(fromDistribution: text))
        XCTAssertEqual(vb.version, "15.7.1")
        XCTAssertEqual(vb.build, "24G231")
    }

    func testLatestPerMajor() {
        let u = URL(string: "https://example.com/a.dist")!
        let list = [
            CatalogInstaller(id: "a", version: "15.6", build: "24G84", postDate: .distantPast, distributionURL: u, packages: []),
            CatalogInstaller(id: "b", version: "15.7.1", build: "24G231", postDate: .distantPast, distributionURL: u, packages: []),
            CatalogInstaller(id: "c", version: "10.15.7", build: "19H2", postDate: .distantPast, distributionURL: u, packages: []),
        ]
        let latest = Catalog.latestPerMajor(list)
        XCTAssertEqual(latest["15"]?.id, "b")
        XCTAssertEqual(latest["10.15"]?.id, "c")
        XCTAssertEqual(Catalog.sort(list).map(\.id), ["b", "a", "c"])
    }

    func testInstallerNames() {
        XCTAssertEqual(InstallerInfo.driveName(major: "15", version: "15.7.1", build: "24G231"), "Install macOS Sequoia 15.7.1-24G231.app")
        XCTAssertEqual(InstallerInfo.versionFromName("Install macOS Sonoma 14.0-23A344.app"), "14.0")
        XCTAssertEqual(InstallerInfo.versionFromName("Install macOS High Sierra 10.13.6-17G66.app"), "10.13.6")
        XCTAssertEqual(InstallerInfo.versionFromName("Install macOS 15 beta.app"), "15")
        XCTAssertEqual(InstallerInfo.buildFromName("Install macOS Big Sur 11.7.10-20G1427.app"), "20G1427")
    }

    func testModelsFile() throws {
        // Shared/models.json ships inside both apps; make sure it parses and is sane.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Shared/models.json")
        let table = try ModelTable(data: Data(contentsOf: url))
        XCTAssertGreaterThan(table.models.count, 80)
        for (id, m) in table.models {
            XCTAssertTrue(MacOS.isIntelMajor(m.min), "\(id) min \(m.min)")
            XCTAssertTrue(MacOS.isIntelMajor(m.max), "\(id) max \(m.max)")
            XCTAssertNotEqual(compareVersions(m.min, m.max), .orderedDescending, id)
        }
        XCTAssertEqual(table.models["MacBookPro16,1"]?.max, "26")
        XCTAssertEqual(table.models["MacBookPro16,3"]?.max, "15")
        XCTAssertEqual(table.models["MacBookAir8,1"]?.max, "14")
        XCTAssertEqual(Set(table.macsTopping(out: "26")), ["MacBookPro16,1", "MacBookPro16,2", "MacBookPro16,4", "iMac20,1", "iMac20,2", "MacPro7,1"])
    }

    func testConfigRoundTripAndTolerance() throws {
        var c = DeployConfig()
        c.account.create = true
        c.account.shortName = "hg"
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(DeployConfig.self, from: data), c)
        let partial = try JSONDecoder().decode(DeployConfig.self, from: Data(#"{"account":{"create":true}}"#.utf8))
        XCTAssertTrue(partial.account.create)
        XCTAssertTrue(partial.account.admin)
        XCTAssertEqual(partial.volumeName, "Macintosh HD")
        XCTAssertEqual(partial.wifi.ssid, "")
        let withWiFi = try JSONDecoder().decode(DeployConfig.self, from: Data(#"{"wifi":{"ssid":"HG-Shop","password":"pw"}}"#.utf8))
        XCTAssertEqual(withWiFi.wifi.ssid, "HG-Shop")
        // The Recovery app reads config["wifi"]["ssid"] / ["password"].
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(withWiFi)) as? [String: Any]
        XCTAssertEqual((json?["wifi"] as? [String: String])?["ssid"], "HG-Shop")
    }

    func testInstallScript() {
        let layout = DriveLayout(root: URL(fileURLWithPath: "/Volumes/HG Deploy"))
        let p = CatalogInstaller(id: "072-11111", version: "15.7.1", build: "24G231", postDate: .distantPast,
                                 distributionURL: URL(string: "https://example.com/072-11111.English.dist")!, packages: [])
        let s = InstallerBuilder.installScript(
            staged: [(p, URL(fileURLWithPath: "/Volumes/HG Deploy/.hgdeploy-staging/072-11111/072-11111.English.dist"),
                      [URL(fileURLWithPath: "/Volumes/HG Deploy/Installers/Install macOS Sequoia 15.6-24G84.app")])],
            layout: layout)
        XCTAssertTrue(s.contains("installer -pkg '/Volumes/HG Deploy/.hgdeploy-staging/072-11111/072-11111.English.dist'"))
        XCTAssertTrue(s.contains("'/Volumes/HG Deploy/Installers/Install macOS Sequoia 15.7.1-24G231.app'"))
        XCTAssertTrue(s.contains("rm -rf '/Volumes/HG Deploy/Installers/Install macOS Sequoia 15.6-24G84.app'"))
        XCTAssertTrue(s.contains("INSTALLED 072-11111"))
    }

    func testShellQuote() {
        XCTAssertEqual(Shell.quote("it's"), #"'it'\''s'"#)
    }

    func testSSOTokenExpiryAndConfig() {
        // header.payload.signature with payload {"id":1,"exp":1760043200}
        let payload = Data(#"{"id":1,"exp":1760043200}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let token = "eyJhbGciOiJIUzI1NiJ9.\(payload).sig"
        XCTAssertEqual(SSOClient.expiry(ofToken: token), Date(timeIntervalSince1970: 1760043200))
        XCTAssertNil(SSOClient.expiry(ofToken: "garbage"))
        XCTAssertFalse(SSOClient(appSecret: nil).isConfigured)
        XCTAssertFalse(SSOClient(appSecret: "").isConfigured)
        XCTAssertTrue(SSOClient(appSecret: "abc").isConfigured)
        XCTAssertTrue(SSOClient.friendly("User does not have access to this app", code: 403).contains("access to HG Deploy"))
    }
}
