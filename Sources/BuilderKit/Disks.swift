import Foundation

/// An external physical disk and the volumes on it.
public struct ExternalDisk: Identifiable, Hashable, Sendable {
    public let id: String            // disk4
    public let mediaName: String
    public let size: Int64
    public let bus: String
    public let volumes: [Volume]
    public var label: String { "\(mediaName) — \(formatBytes(size)) (\(id))" }

    public struct Volume: Hashable, Sendable, Identifiable {
        public let id: String        // disk4s2
        public let name: String
        public let mountPoint: String?
        public let filesystem: String
        public let size: Int64
        public let free: Int64
        public var isDeployDrive: Bool {
            guard let mountPoint else { return false }
            return DriveLayout(root: URL(fileURLWithPath: mountPoint)).isDeployDrive
        }
    }
}

public func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

public enum Disks {
    static let diskutil = "/usr/sbin/diskutil"

    /// External physical disks (USB / Thunderbolt), with their mounted volumes.
    public static func external() async -> [ExternalDisk] {
        guard let list = await Shell.plist(diskutil, ["list", "-plist", "external", "physical"]) as? [String: Any],
              let whole = list["WholeDisks"] as? [String] else { return [] }
        var disks: [ExternalDisk] = []
        for ident in whole {
            guard let info = await Shell.plist(diskutil, ["info", "-plist", ident]) as? [String: Any] else { continue }
            if (info["BusProtocol"] as? String) == "Disk Image" { continue }
            disks.append(ExternalDisk(
                id: ident,
                mediaName: (info["MediaName"] as? String) ?? (info["IORegistryEntryName"] as? String) ?? "Disk",
                size: (info["TotalSize"] as? NSNumber ?? info["Size"] as? NSNumber)?.int64Value ?? 0,
                bus: (info["BusProtocol"] as? String) ?? "",
                volumes: await volumes(on: ident)))
        }
        return disks
    }

    static func volumes(on disk: String) async -> [ExternalDisk.Volume] {
        guard let list = await Shell.plist(diskutil, ["list", "-plist", disk]) as? [String: Any],
              let all = list["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        var out: [ExternalDisk.Volume] = []
        for entry in all {
            let parts = (entry["Partitions"] as? [[String: Any]] ?? []) + (entry["APFSVolumes"] as? [[String: Any]] ?? [])
            for p in parts {
                guard let id = p["DeviceIdentifier"] as? String else { continue }
                let content = p["Content"] as? String ?? ""
                if content == "EFI" || content == "Apple_Boot" { continue }
                let info = await Shell.plist(diskutil, ["info", "-plist", id]) as? [String: Any] ?? [:]
                out.append(.init(
                    id: id,
                    name: (p["VolumeName"] as? String) ?? "Untitled",
                    mountPoint: p["MountPoint"] as? String,
                    filesystem: (info["FilesystemUserVisibleName"] as? String) ?? content,
                    size: (p["Size"] as? NSNumber)?.int64Value ?? 0,
                    free: ((info["FreeSpace"] ?? info["APFSContainerFree"]) as? NSNumber)?.int64Value ?? 0))
            }
        }
        return out
    }

    /// Erases a whole external disk as one Mac OS Extended (Journaled) volume.
    /// HFS+ because every Recovery from High Sierra on can read it.
    public static func eraseForDeploy(disk: String, name: String) async -> ShellResult {
        await Shell.run(diskutil, ["eraseDisk", "JHFS+", name, "GPT", disk])
    }

    public static func freeSpace(at url: URL) -> Int64 {
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(v?.volumeAvailableCapacity ?? 0)
    }
}
