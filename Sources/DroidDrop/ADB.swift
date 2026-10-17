import Darwin
import Foundation

struct ADBError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Device: Identifiable, Hashable {
    enum State: String {
        case device, unauthorized, offline, other
    }

    let serial: String
    let state: State
    let model: String

    var id: String { serial }
    var isReady: Bool { state == .device }

    var statusText: String {
        switch state {
        case .device: "Connected"
        case .unauthorized: "Waiting for permission"
        case .offline: "Offline"
        case .other: "Unavailable"
        }
    }
}

struct RemoteEntry: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date

    var id: String { path }
}

struct StorageVolume: Identifiable, Hashable {
    enum Kind { case internalStorage, sdCard, usbDrive }

    let kind: Kind
    let name: String
    let path: String
    let totalBytes: Int64
    let freeBytes: Int64
    /// Which of the requested standard folders exist at the volume root.
    let folders: [String]

    var id: String { path }

    var icon: String {
        switch kind {
        case .internalStorage: "internaldrive"
        case .sdCard: "sdcard"
        case .usbDrive: "externaldrive"
        }
    }
}

struct TransferProgress: Equatable {
    let percent: Int
    let path: String
}

/// Thin async wrapper around the `adb` command-line tool.
enum ADB {
    static let executable: String? = {
        let env = ProcessInfo.processInfo.environment
        var candidates = ["ANDROID_HOME", "ANDROID_SDK_ROOT"].compactMap { env[$0] }.map { $0 + "/platform-tools/adb" }
        candidates += [
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String

        var errorText: String {
            let text = stderr.isEmpty ? stdout : stderr
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func run(_ args: [String]) async throws -> Output {
        guard let executable else { throw ADBError(message: "adb is not installed.") }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // Drain stderr on another thread so a full pipe can't deadlock us.
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: Output(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }

    /// Starts the adb server with no pipes attached. The daemon adb forks inherits its
    /// parent's file descriptors, which would otherwise keep `run`'s pipes open forever.
    static func startServer() async {
        guard let executable else { return }
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["start-server"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume() }
        }
    }

    static func devices() async throws -> [Device] {
        let output = try await run(["devices", "-l"])
        return output.stdout.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("List of"), !line.hasPrefix("*") else { return nil }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { return nil }
            let model = fields.first { $0.hasPrefix("model:") }
                .map { $0.dropFirst("model:".count).replacingOccurrences(of: "_", with: " ") }
            return Device(
                serial: String(fields[0]),
                state: Device.State(rawValue: String(fields[1])) ?? .other,
                model: model ?? String(fields[0])
            )
        }
    }

    /// Quotes a string for the device's `sh`.
    static func quote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func shell(_ serial: String, _ command: String) async throws -> Output {
        try await run(["-s", serial, "shell", command])
    }

    private static func check(_ output: Output) throws {
        guard output.status == 0 else {
            throw ADBError(message: output.errorText.isEmpty ? "The phone reported an error." : output.errorText)
        }
    }

    static func list(_ serial: String, path: String, showHidden: Bool) async throws -> [RemoteEntry] {
        let globs = showHidden ? "* .[!.]* ..?*" : "*"
        // toybox `stat` gives a machine-readable line per entry; -L follows symlinks like /sdcard.
        let command = "cd \(quote(path)) 2>/dev/null || { echo __NODIR__; exit 0; }; "
            + "stat -L -c '%F|%s|%Y|%n' -- \(globs) 2>/dev/null; exit 0"
        let output = try await shell(serial, command)
        if output.stdout.hasPrefix("__NODIR__") {
            throw ADBError(message: "Couldn't open \(path). It may not exist, or Android may not allow access to it.")
        }
        try check(output)
        let base = path.hasSuffix("/") ? path : path + "/"
        return output.stdout.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4 else { return nil }
            let name = String(fields[3])
            return RemoteEntry(
                name: name,
                path: base + name,
                isDirectory: fields[0] == "directory",
                size: Int64(fields[1]) ?? 0,
                modified: Date(timeIntervalSince1970: TimeInterval(fields[2]) ?? 0)
            )
        }
    }

    /// Internal storage plus any SD cards or USB drives Android has mounted under /storage.
    static func storageVolumes(_ serial: String, checking folders: [String]) async throws -> [StorageVolume] {
        let script = """
            for d in /sdcard /storage/*; do
              case "${d##*/}" in emulated|self) continue;; esac
              [ -d "$d" ] || continue
              set -- $(df -k "$d" 2>/dev/null | tail -n 1)
              found=""
              for f in \(folders.map(quote).joined(separator: " ")); do [ -d "$d/$f" ] && found="$found$f/"; done
              echo "V|$d|$2|$4|$found"
            done
            sm list-volumes public 2>/dev/null
            exit 0
            """
        let output = try await shell(serial, script)
        try check(output)
        let lines = output.stdout.split(whereSeparator: \.isNewline)

        // `sm` lines look like "public:179,1 mounted 69EE-78C8". Block major 8 is a
        // SCSI disk (USB drive); SD cards are usually mmc (179).
        var majors: [String: String] = [:]
        for line in lines where line.hasPrefix("public:") {
            let fields = line.split(separator: " ")
            if fields.count >= 3, let major = fields[0].dropFirst("public:".count).split(separator: ",").first {
                majors[String(fields[2])] = String(major)
            }
        }

        let parsed: [(kind: StorageVolume.Kind, path: String, total: Int64, free: Int64, folders: [String])] =
            lines.compactMap { line in
                let fields = line.split(separator: "|", omittingEmptySubsequences: false)
                guard fields.count == 5, fields[0] == "V" else { return nil }
                let path = String(fields[1])
                let kind: StorageVolume.Kind =
                    path == "/sdcard" ? .internalStorage
                    : majors[(path as NSString).lastPathComponent] == "8" ? .usbDrive : .sdCard
                return (kind, path, (Int64(fields[2]) ?? 0) * 1024, (Int64(fields[3]) ?? 0) * 1024,
                        fields[4].split(separator: "/").map(String.init))
            }

        return parsed.map { volume in
            var name = switch volume.kind {
            case .internalStorage: "Internal Storage"
            case .sdCard: "SD Card"
            case .usbDrive: "USB Drive"
            }
            if parsed.filter({ $0.kind == volume.kind }).count > 1 {
                name += " (\((volume.path as NSString).lastPathComponent))"
            }
            return StorageVolume(kind: volume.kind, name: name, path: volume.path,
                                 totalBytes: volume.total, freeBytes: volume.free, folders: volume.folders)
        }
    }

    static func makeDirectory(_ serial: String, path: String) async throws {
        try check(await shell(serial, "mkdir -p -- \(quote(path))"))
    }

    static func move(_ serial: String, from: String, to: String) async throws {
        let command = "[ -e \(quote(to)) ] && { echo 'An item with that name already exists.' >&2; exit 1; }; "
            + "mv -- \(quote(from)) \(quote(to))"
        try check(await shell(serial, command))
    }

    static func delete(_ serial: String, paths: [String]) async throws {
        try check(await shell(serial, "rm -rf -- " + paths.map(quote).joined(separator: " ")))
    }

    // MARK: - Transfers

    final class TransferHandle: @unchecked Sendable {
        fileprivate let process = Process()
        private(set) var isCancelled = false

        func cancel() {
            isCancelled = true
            if process.isRunning { process.terminate() }
        }
    }

    /// Runs `adb push` or `adb pull`. adb only prints its per-file "[ 42%] path" progress
    /// when attached to a terminal, so it gets a pseudo-terminal instead of a pipe.
    static func transfer(
        _ args: [String],
        handle: TransferHandle,
        progress: @escaping (TransferProgress) -> Void
    ) async throws {
        guard let executable else { throw ADBError(message: "adb is not installed.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try runTransfer(executable: executable, args: args, handle: handle, progress: progress)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runTransfer(
        executable: String,
        args: [String],
        handle: TransferHandle,
        progress: (TransferProgress) -> Void
    ) throws {
        var master: Int32 = -1, slave: Int32 = -1
        // Wide enough that adb never elides file names in the middle.
        var size = winsize(ws_row: 50, ws_col: 1000, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw ADBError(message: "Couldn't start the transfer.")
        }
        defer { close(master) }

        let process = handle.process
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm"
        process.environment = environment
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardOutput = terminal
        process.standardError = terminal
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            close(slave)
            throw error
        }
        // Drop our copy of the terminal so reads end once adb exits.
        close(slave)

        var output = ""
        var last: TransferProgress?
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(master, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            output += String(decoding: buffer[0..<count], as: UTF8.self)
            if output.utf8.count > 16384 { output = String(output.suffix(4096)) }
            if let current = parseProgress(output), current != last {
                last = current
                progress(current)
            }
        }
        process.waitUntilExit()

        if handle.isCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            throw ADBError(message: errorLine(in: output) ?? "adb failed (exit code \(process.terminationStatus)).")
        }
    }

    private static let progressPattern = try! Regex(#"\[\s*(\d+)%\]\s+([^\r\n\x1B]+)"#)
        .matchingSemantics(.unicodeScalar)

    static func parseProgress(_ text: String) -> TransferProgress? {
        guard let match = text.matches(of: progressPattern).last,
              let percent = match.output[1].substring.flatMap({ Int($0) }),
              let path = match.output[2].substring
        else { return nil }
        return TransferProgress(percent: percent, path: path.trimmingCharacters(in: .whitespaces))
    }

    private static func errorLine(in output: String) -> String? {
        let lines = output
            .replacingOccurrences(of: "\u{1B}[K", with: "")
            .split(whereSeparator: \.isNewline)
        guard let line = lines.last(where: { $0.contains("error:") }) ?? lines.last else { return nil }
        return line.replacingOccurrences(of: "adb: error: ", with: "").trimmingCharacters(in: .whitespaces)
    }
}
