import Foundation

/// Numeric macOS version compare: "10.13" < "10.15.7" < "11" < "26".
public func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
    a.compare(b, options: .numeric)
}

/// "10.15.7" -> "10.15", "15.7.1" -> "15".
public func majorVersion(_ version: String) -> String {
    let parts = version.split(separator: ".").map(String.init)
    guard let first = parts.first else { return version }
    if first == "10", parts.count > 1 { return "10.\(parts[1])" }
    return first
}

public enum MacOS {
    /// Every macOS HG Deploy installs, oldest first. Tahoe 26 is the last for Intel.
    public static let majors = ["10.13", "10.14", "10.15", "11", "12", "13", "14", "15", "26"]

    public static let names: [String: String] = [
        "10.13": "High Sierra", "10.14": "Mojave", "10.15": "Catalina", "11": "Big Sur",
        "12": "Monterey", "13": "Ventura", "14": "Sonoma", "15": "Sequoia", "26": "Tahoe",
    ]

    /// "macOS Sequoia"
    public static func name(_ major: String) -> String {
        names[major].map { "macOS \($0)" } ?? "macOS \(major)"
    }

    /// Majors HG Deploy handles (Intel). macOS 27 and later are Apple silicon only.
    public static func isIntelMajor(_ major: String) -> Bool { majors.contains(major) }
}

public struct MacModel: Codable, Hashable, Sendable {
    public let name: String
    public let min: String
    public let max: String
    public let note: String?
}

/// Shared/models.json: every Intel Mac that runs 10.13 or later.
public struct ModelTable: Sendable {
    public let models: [String: MacModel]

    public init(models: [String: MacModel]) { self.models = models }

    public init(data: Data) throws {
        struct File: Decodable { let models: [String: MacModel] }
        self.models = try JSONDecoder().decode(File.self, from: data).models
    }

    /// Mac model identifiers whose newest supported macOS is `major`.
    public func macsTopping(out major: String) -> [String] {
        models.filter { $0.value.max == major }.map(\.key).sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    /// Distinct model names that can run `major`.
    public func macsSupporting(_ major: String) -> [MacModel] {
        models.values
            .filter { compareVersions(major, $0.min) != .orderedAscending && compareVersions(major, $0.max) != .orderedDescending }
            .sorted { $0.name < $1.name }
    }
}
