import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            DetailView(model: model)
        }
        .task { await model.start() }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: Binding(
            get: { model.selectedDevice?.isReady == true ? model.path : nil },
            set: { if let path = $0 { model.open(path) } }
        )) {
            Section("Devices") {
                if model.devices.isEmpty {
                    Text("No phone connected")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.devices) { device in
                    Button {
                        model.selectedSerial = device.serial
                    } label: {
                        DeviceRow(device: device, isSelected: device.serial == model.selectedSerial)
                    }
                    .buttonStyle(.plain)
                }
            }
            if model.selectedDevice?.isReady == true {
                Section("Storage") {
                    ForEach(model.volumes) { volume in
                        VolumeRow(volume: volume)
                            .tag(volume.path)
                    }
                }
                if let volume = model.currentVolume ?? model.volumes.first {
                    Section("\(volume.name) Folders") {
                        ForEach(Place.all.filter { volume.folders.contains($0.folder) }) { place in
                            Label(place.folder, systemImage: place.icon)
                                .tag(volume.path + "/" + place.folder)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct VolumeRow: View {
    let volume: StorageVolume

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(volume.name)
                if volume.totalBytes > 0 {
                    Gauge(value: Double(volume.totalBytes - volume.freeBytes), in: 0...Double(volume.totalBytes)) {}
                        .gaugeStyle(.accessoryLinearCapacity)
                        .controlSize(.mini)
                        .tint(volume.freeBytes < volume.totalBytes / 10 ? .orange : .accentColor)
                    Text("\(volume.freeBytes.formatted(.byteCount(style: .file))) free of \(volume.totalBytes.formatted(.byteCount(style: .file)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        } icon: {
            Image(systemName: volume.icon)
        }
    }
}

struct DeviceRow: View {
    let device: Device
    let isSelected: Bool

    private var statusColor: Color {
        switch device.state {
        case .device: .green
        case .unauthorized: .orange
        default: .red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "smartphone")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.model)
                    .fontWeight(isSelected ? .semibold : .regular)
                HStack(spacing: 4) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(device.statusText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Detail

struct DetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if !model.adbAvailable {
                ContentUnavailableView {
                    Label("adb isn't installed", systemImage: "wrench.and.screwdriver")
                } description: {
                    Text("DroidDrop uses Android's adb tool to talk to your phone. Install it with Homebrew:\n\n`brew install android-platform-tools`\n\nthen reopen DroidDrop.")
                }
            } else if let device = model.selectedDevice {
                switch device.state {
                case .device:
                    FileBrowser(model: model)
                case .unauthorized:
                    ContentUnavailableView {
                        Label("Allow access on your phone", systemImage: "hand.tap")
                    } description: {
                        Text("Unlock your phone and tap **Allow** on the “Allow USB debugging?” prompt. Tick “Always allow from this computer” so you only have to do this once.\n\nNo prompt? Unplug the cable and plug it back in.")
                    }
                default:
                    ContentUnavailableView {
                        Label("\(device.model) is offline", systemImage: "cable.connector.slash")
                    } description: {
                        Text("Unplug the cable and plug it back in. If that doesn't help, try another USB port or cable.")
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Connect your Android phone", systemImage: "cable.connector")
                } description: {
                    Text("Plug it in with a USB cable, then turn on USB debugging:\n\n1. **Settings → About phone** → tap **Build number** 7 times\n2. **Settings → System → Developer options** → turn on **USB debugging**")
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - File browser

struct FileBrowser: View {
    @Bindable var model: AppModel

    @State private var isDropTargeted = false
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var renaming: RemoteEntry?
    @State private var renameText = ""
    @State private var pendingDelete: [RemoteEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            PathBar(model: model)
            Divider()
            table
            if let transfer = model.transfer {
                Divider()
                TransferBar(transfer: transfer) { model.cancelTransfer() }
            }
        }
        .overlay {
            if isDropTargeted {
                DropHighlight(folder: model.folderName)
            }
        }
        .overlay(alignment: .bottom) {
            NoticeToast(notice: $model.notice)
                .padding(.bottom, model.transfer == nil ? 16 : 80)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .navigationTitle(model.folderName)
        .navigationSubtitle(model.selectedDevice?.model ?? "")
        .toolbar { toolbar }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { model.newFolder(named: newFolderName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let renaming { model.rename(renaming, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            pendingDelete.count == 1 ? "Delete “\(pendingDelete[0].name)”?" : "Delete \(pendingDelete.count) items?",
            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })
        ) {
            Button("Delete", role: .destructive) { model.delete(pendingDelete) }
        } message: {
            Text("This permanently removes them from your phone. It can't be undone.")
        }
    }

    private var table: some View {
        Table(model.sortedEntries, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { entry in
                Label {
                    Text(entry.name)
                } icon: {
                    Image(systemName: icon(for: entry))
                        .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                }
            }
            .width(min: 200, ideal: 340)
            TableColumn("Size", value: \.size) { entry in
                Text(entry.isDirectory ? "--" : entry.size.formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Date Modified", value: \.modified) { entry in
                Text(entry.modified.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170)
        }
        .contextMenu(forSelectionType: RemoteEntry.ID.self) { ids in
            contextMenu(for: model.entries.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            model.activate(ids)
        }
        .onDeleteCommand { pendingDelete = model.selectedEntries }
        .overlay {
            if model.entries.isEmpty && !model.isLoading {
                ContentUnavailableView {
                    Label("Empty folder", systemImage: "tray")
                } description: {
                    Text("Drag files here from Finder to copy them to your phone.")
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for items: [RemoteEntry]) -> some View {
        if items.isEmpty {
            Button("Upload Files…") { model.chooseUploadFiles() }
            Button("New Folder…") { startNewFolder() }
            Divider()
            Button("Refresh") { model.reload() }
        } else {
            if items.count == 1, items[0].isDirectory {
                Button("Open") { model.open(items[0].path) }
            }
            Button("Download to Mac…") { model.chooseDownloadFolder(for: items) }
                .disabled(model.transfer != nil)
            if items.count == 1 {
                Button("Rename…") {
                    renameText = items[0].name
                    renaming = items[0]
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = items }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back")

            Button { model.goUp() } label: {
                Label("Enclosing Folder", systemImage: "arrow.up")
            }
            .disabled(!model.canGoUp)
            .keyboardShortcut(.upArrow, modifiers: .command)
            .help("Enclosing folder")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { startNewFolder() } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .help("New folder")

            Button { model.chooseDownloadFolder(for: model.selectedEntries) } label: {
                Label("Download", systemImage: "square.and.arrow.down")
            }
            .disabled(model.selection.isEmpty || model.transfer != nil)
            .keyboardShortcut("d", modifiers: .command)
            .help("Download selected items to your Mac")

            Button { model.chooseUploadFiles() } label: {
                Label("Upload", systemImage: "square.and.arrow.up")
            }
            .disabled(model.transfer != nil)
            .keyboardShortcut("u", modifiers: .command)
            .help("Upload files from your Mac to this folder")

            Toggle(isOn: $model.showHidden) {
                Label("Show Hidden Files", systemImage: model.showHidden ? "eye" : "eye.slash")
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .help("Show hidden files")

            Button { model.reload() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh")
        }
    }

    private func startNewFolder() {
        newFolderName = "untitled folder"
        isCreatingFolder = true
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.transfer == nil else { return false }
        var urls: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { model.upload(urls) }
        return true
    }

    private func icon(for entry: RemoteEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        switch (entry.name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp", "dng": return "photo"
        case "mp4", "mov", "mkv", "webm", "avi", "3gp": return "film"
        case "mp3", "m4a", "flac", "wav", "ogg", "opus", "aac": return "music.note"
        case "apk", "apks", "xapk": return "shippingbox"
        case "zip", "7z", "rar", "tar", "gz": return "doc.zipper"
        case "pdf": return "doc.richtext"
        case "txt", "md", "log", "json", "xml": return "doc.text"
        default: return "doc"
        }
    }
}

// MARK: - Pieces

struct PathBar: View {
    @Bindable var model: AppModel

    private var crumbs: [(name: String, path: String)] {
        var result: [(String, String)]
        var current: String
        var rest: Substring
        if let volume = model.currentVolume {
            result = [(volume.name, volume.path)]
            current = volume.path
            rest = model.path.dropFirst(volume.path.count)
        } else {
            result = [("/", "/")]
            current = ""
            rest = Substring(model.path)
        }
        for part in rest.split(separator: "/") {
            current += "/" + part
            result.append((String(part), current))
        }
        return result
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button(crumb.name) { model.open(crumb.path) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                        .fontWeight(index == crumbs.count - 1 ? .medium : .regular)
                }
                if model.isLoading {
                    ProgressView().controlSize(.small).padding(.leading, 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }
}

struct TransferBar: View {
    let transfer: TransferState
    let cancel: () -> Void

    private var title: String {
        let verb = transfer.kind == .upload ? "Uploading" : "Downloading"
        return transfer.currentFile.isEmpty ? "\(verb)…" : "\(verb) \(transfer.currentFile)"
    }

    private var detail: String {
        var parts: [String] = []
        if let total = transfer.totalFiles, total > 1 {
            parts.append("File \(max(transfer.filesStarted, 1)) of \(total)")
        }
        parts.append("\(transfer.percent)%")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.kind == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(detail).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.callout)
                ProgressView(value: transfer.fraction)
            }
            Button("Cancel", action: cancel)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct DropHighlight: View {
    let folder: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.08))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 5]))
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 40))
                Text("Drop to copy to “\(folder)”")
                    .font(.headline)
            }
            .foregroundStyle(Color.accentColor)
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(8)
        .allowsHitTesting(false)
    }
}

struct NoticeToast: View {
    @Binding var notice: String?

    var body: some View {
        if let notice {
            Label(notice, systemImage: "checkmark.circle.fill")
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4, y: 2)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { self.notice = nil }
                }
        }
    }
}
