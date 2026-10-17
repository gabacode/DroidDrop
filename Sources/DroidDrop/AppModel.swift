import AppKit
import Foundation
import Observation

/// A standard folder shown in the sidebar for whichever volume is being browsed.
struct Place: Identifiable, Hashable {
    let folder: String
    let icon: String
    var id: String { folder }

    static let all = [
        Place(folder: "Download", icon: "arrow.down.circle"),
        Place(folder: "DCIM", icon: "camera"),
        Place(folder: "Pictures", icon: "photo"),
        Place(folder: "Movies", icon: "film"),
        Place(folder: "Music", icon: "music.note"),
        Place(folder: "Documents", icon: "doc"),
    ]
}

struct TransferState {
    enum Kind { case upload, download }

    let kind: Kind
    let totalFiles: Int?
    var currentFile = ""
    var percent = 0
    var filesStarted = 0

    /// 0...1 across the whole batch when the file count is known, else for the current file.
    var fraction: Double {
        let file = Double(percent) / 100
        guard let totalFiles, totalFiles > 0 else { return file }
        return min(1, (Double(max(filesStarted - 1, 0)) + file) / Double(totalFiles))
    }
}

@MainActor
@Observable
final class AppModel {
    var devices: [Device] = []
    var selectedSerial: String? {
        didSet {
            guard selectedSerial != oldValue else { return }
            backStack = []
            path = "/sdcard"
            volumes = []
            reload()
        }
    }

    var volumes: [StorageVolume] = []

    private(set) var path = "/sdcard"
    private var backStack: [String] = []
    var entries: [RemoteEntry] = []
    var selection = Set<RemoteEntry.ID>()
    var sortOrder = [KeyPathComparator(\RemoteEntry.name, comparator: .localizedStandard)]
    var showHidden = false {
        didSet { refresh() }
    }

    var isLoading = false
    var transfer: TransferState?
    var errorMessage: String?
    var notice: String?

    private var listTask: Task<Void, Never>?
    private var transferHandle: ADB.TransferHandle?

    var adbAvailable: Bool { ADB.executable != nil }
    var selectedDevice: Device? { devices.first { $0.serial == selectedSerial } }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoUp: Bool { path != "/" }

    var sortedEntries: [RemoteEntry] {
        let sorted = entries.sorted(using: sortOrder)
        return sorted.filter(\.isDirectory) + sorted.filter { !$0.isDirectory }
    }

    var selectedEntries: [RemoteEntry] {
        entries.filter { selection.contains($0.id) }
    }

    /// The volume the current folder lives on.
    var currentVolume: StorageVolume? {
        volumes
            .filter { path == $0.path || path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    var folderName: String {
        if let volume = volumes.first(where: { $0.path == path }) { return volume.name }
        return path == "/" ? "/" : (path as NSString).lastPathComponent
    }

    // MARK: - Devices

    func start() async {
        guard adbAvailable else { return }
        await ADB.startServer()
        while !Task.isCancelled {
            await pollDevices()
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    private func pollDevices() async {
        guard let list = try? await ADB.devices(), list != devices else { return }
        let wasReady = selectedDevice?.isReady ?? false
        devices = list
        if selectedDevice == nil {
            selectedSerial = list.first(where: \.isReady)?.serial ?? list.first?.serial
        } else if selectedDevice?.isReady == true, !wasReady {
            // The phone just accepted the debugging prompt.
            reload()
        }
        if selectedDevice?.isReady != true {
            entries = []
            volumes = []
        }
    }

    /// Refreshes the storage list (and free space) along with the current folder.
    func reload() {
        refresh()
        guard let device = selectedDevice, device.isReady else { return }
        Task {
            guard let list = try? await ADB.storageVolumes(device.serial, checking: Place.all.map(\.folder)),
                  device.serial == selectedSerial
            else { return }
            volumes = list
        }
    }

    // MARK: - Navigation

    func open(_ newPath: String) {
        guard newPath != path else { return refresh() }
        backStack.append(path)
        path = newPath
        refresh()
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        path = previous
        refresh()
    }

    func goUp() {
        let parent = (path as NSString).deletingLastPathComponent
        open(parent.isEmpty ? "/" : parent)
    }

    func activate(_ ids: Set<RemoteEntry.ID>) {
        let items = entries.filter { ids.contains($0.id) }
        if items.count == 1, let item = items.first, item.isDirectory {
            open(item.path)
        } else if !items.isEmpty {
            chooseDownloadFolder(for: items)
        }
    }

    func refresh() {
        listTask?.cancel()
        guard let device = selectedDevice, device.isReady else {
            entries = []
            return
        }
        let path = path, showHidden = showHidden
        isLoading = true
        listTask = Task {
            do {
                let result = try await ADB.list(device.serial, path: path, showHidden: showHidden)
                guard !Task.isCancelled else { return }
                entries = result
                selection = selection.filter { id in result.contains { $0.id == id } }
            } catch {
                guard !Task.isCancelled else { return }
                entries = []
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    // MARK: - File operations

    private func childPath(_ name: String) -> String {
        (path.hasSuffix("/") ? path : path + "/") + name
    }

    private func validName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/") else {
            errorMessage = "“\(name)” isn't a valid name."
            return nil
        }
        return trimmed
    }

    private func perform(_ operation: @escaping (String) async throws -> Void) {
        guard let serial = selectedDevice?.serial else { return }
        Task {
            do {
                try await operation(serial)
            } catch {
                errorMessage = error.localizedDescription
            }
            reload()
        }
    }

    func newFolder(named name: String) {
        guard let name = validName(name) else { return }
        let target = childPath(name)
        perform { serial in
            try await ADB.makeDirectory(serial, path: target)
            self.selection = [target]
        }
    }

    func rename(_ entry: RemoteEntry, to name: String) {
        guard let name = validName(name), name != entry.name else { return }
        let target = childPath(name)
        perform { serial in
            try await ADB.move(serial, from: entry.path, to: target)
            self.selection = [target]
        }
    }

    func delete(_ items: [RemoteEntry]) {
        guard !items.isEmpty else { return }
        perform { serial in
            try await ADB.delete(serial, paths: items.map(\.path))
            self.notice = items.count == 1 ? "Deleted “\(items[0].name)”" : "Deleted \(items.count) items"
        }
    }

    // MARK: - Transfers

    func chooseUploadFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to copy to “\(folderName)” on your phone"
        guard panel.runModal() == .OK else { return }
        upload(panel.urls)
    }

    func upload(_ urls: [URL]) {
        guard let serial = selectedDevice?.serial, transfer == nil, !urls.isEmpty else { return }
        let destination = path.hasSuffix("/") ? path : path + "/"
        let label = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
        Task {
            let total = await Task.detached { urls.reduce(0) { $0 + Self.fileCount(at: $1) } }.value
            runTransfer(
                TransferState(kind: .upload, totalFiles: total),
                args: ["-s", serial, "push"] + urls.map(\.path) + [destination]
            ) {
                self.notice = "Uploaded \(label) to \(self.folderName)"
                self.reload()
            }
        }
    }

    func chooseDownloadFolder(for items: [RemoteEntry]) {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = "Download Here"
        panel.message = items.count == 1 ? "Save “\(items[0].name)” to…" : "Save \(items.count) items to…"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        download(items, to: folder)
    }

    func download(_ items: [RemoteEntry], to folder: URL) {
        guard let serial = selectedDevice?.serial, transfer == nil, !items.isEmpty else { return }
        let total = items.contains(where: \.isDirectory) ? nil : items.count
        runTransfer(
            TransferState(kind: .download, totalFiles: total),
            args: ["-s", serial, "pull", "-a"] + items.map(\.path) + [folder.path]
        ) {
            self.notice = items.count == 1 ? "Downloaded “\(items[0].name)”" : "Downloaded \(items.count) items"
            NSWorkspace.shared.activateFileViewerSelecting(items.map { folder.appendingPathComponent($0.name) })
        }
    }

    func cancelTransfer() {
        transferHandle?.cancel()
    }

    private func runTransfer(_ state: TransferState, args: [String], onSuccess: @escaping () -> Void) {
        let handle = ADB.TransferHandle()
        transferHandle = handle
        transfer = state
        Task {
            do {
                try await ADB.transfer(args, handle: handle) { progress in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.update(progress) }
                    }
                }
                onSuccess()
            } catch is CancellationError {
                notice = "Transfer cancelled"
                reload()
            } catch {
                errorMessage = error.localizedDescription
                reload()
            }
            transfer = nil
            transferHandle = nil
        }
    }

    private func update(_ progress: TransferProgress) {
        guard var state = transfer else { return }
        let file = (progress.path as NSString).lastPathComponent
        if file != state.currentFile {
            state.currentFile = file
            state.filesStarted += 1
        }
        state.percent = progress.percent
        transfer = state
    }

    nonisolated private static func fileCount(at url: URL) -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return 1
        }
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        var count = 0
        while let file = enumerator?.nextObject() as? URL {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { count += 1 }
        }
        return count
    }
}
