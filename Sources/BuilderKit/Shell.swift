import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let output: String
    public var ok: Bool { status == 0 }
}

/// Runs command-line tools off the main thread.
public enum Shell {
    public static func run(_ path: String, _ args: [String], input: String? = nil) async -> ShellResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(path, args, input: input))
            }
        }
    }

    public static func runSync(_ path: String, _ args: [String], input: String? = nil, separateStderr: Bool = false) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = separateStderr ? FileHandle.nullDevice : out
        let inPipe = input == nil ? nil : Pipe()
        p.standardInput = inPipe ?? FileHandle.nullDevice
        do { try p.run() } catch {
            return ShellResult(status: -1, output: "could not run \(path): \(error.localizedDescription)")
        }
        if let inPipe, let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ShellResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// Runs a tool that prints a property list on stdout and parses it.
    public static func plist(_ path: String, _ args: [String]) async -> Any? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let r = runSync(path, args, separateStderr: true)
                let obj = try? PropertyListSerialization.propertyList(from: Data(r.output.utf8), format: nil)
                cont.resume(returning: obj)
            }
        }
    }

    /// Single-quotes a string for /bin/bash.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a bash script as root, after the standard macOS administrator
    /// password prompt. One prompt per call, so batch work into one script.
    public static func runAsAdmin(script: String, prompt: String) async -> ShellResult {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hgdeploy-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scriptURL = dir.appendingPathComponent("task.sh")
        let logURL = dir.appendingPathComponent("task.log")
        do {
            try ("#!/bin/bash\n" + script).write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            return ShellResult(status: -1, output: "couldn't write the admin script: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let cmd = "/bin/bash \(quote(scriptURL.path)) > \(quote(logURL.path)) 2>&1; echo $?"
        let apple = "do shell script \(appleScriptString(cmd)) with prompt \(appleScriptString(prompt)) with administrator privileges"
        let r = await run("/usr/bin/osascript", ["-e", apple])
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        if !r.ok {
            // -128: the user cancelled the password prompt.
            let cancelled = r.output.contains("-128")
            return ShellResult(status: -1, output: cancelled ? "Cancelled at the password prompt." : r.output + log)
        }
        let code = Int32(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        return ShellResult(status: code, output: log)
    }

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
