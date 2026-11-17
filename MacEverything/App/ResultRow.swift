import SwiftUI
import AppKit
import Quartz
import UniformTypeIdentifiers

/// Returns generic type icons synchronously and loads app-specific icons off the UI thread.
final class FileIconCache: ObservableObject {
    static let shared = FileIconCache()
    private let cache = NSCache<NSString, NSImage>()
    private let appIconQueue = DispatchQueue(label: "com.maceverything.app-icons", qos: .utility)
    private var loadingAppKeys: Set<String> = []
    private let loadingAppKeysLock = NSLock()
    @Published private(set) var revision: UInt64 = 0

    private init() {
        cache.countLimit = 500
    }

    func icon(for item: FileItem) -> NSImage {
        if item.isApplication {
            return appIcon(forPath: item.fullPath)
        }

        if item.isFolder {
            return genericIcon(key: "type:folder", contentType: .folder)
        }

        return extensionIcon((item.name as NSString).pathExtension.lowercased())
    }

    func icon(forPath path: String) -> NSImage {
        if path.lowercased().hasSuffix(".app") {
            return appIcon(forPath: path)
        }
        let ext = (path as NSString).pathExtension.lowercased()
        return extensionIcon(ext)
    }

    private func extensionIcon(_ ext: String) -> NSImage {
        let key = "ext:" + (ext.isEmpty ? "__no_ext__" : ext)
        let contentType = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        return genericIcon(key: key, contentType: contentType)
    }

    private func genericIcon(key: String, contentType: UTType) -> NSImage {
        let key = key as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let image = sizedCopy(of: NSWorkspace.shared.icon(for: contentType))
        cache.setObject(image, forKey: key)
        return image
    }

    private func appIcon(forPath path: String) -> NSImage {
        let key = "app:" + path
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        let placeholder = genericIcon(key: "type:application", contentType: .applicationBundle)
        loadingAppKeysLock.lock()
        let inserted = loadingAppKeys.insert(key).inserted
        loadingAppKeysLock.unlock()
        guard inserted else { return placeholder }

        appIconQueue.async { [weak self] in
            guard let self else { return }
            let image = self.sizedCopy(of: NSWorkspace.shared.icon(forFile: path))
            self.cache.setObject(image, forKey: key as NSString)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loadingAppKeysLock.lock()
                self.loadingAppKeys.remove(key)
                self.loadingAppKeysLock.unlock()
                self.revision &+= 1
            }
        }
        return placeholder
    }

    private func sizedCopy(of source: NSImage) -> NSImage {
        let image = (source.copy() as? NSImage) ?? source
        image.size = NSSize(width: 24, height: 24)
        return image
    }
}

struct ResultRow: View {
    private static let columnDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
    let item: FileItem
    let layoutWidth: CGFloat
    let hints: [HighlightHint]
    let isSelected: Bool
    let requestedRename: Bool
    let selectedItems: [FileItem]
    let onSelect: (_ extending: Bool, _ toggling: Bool) -> Void
    var onRenameComplete: (() -> Void)?
    var onRenameSuccess: ((_ oldID: String, _ newName: String) -> Void)?
    var onDeleteItems: ((_ ids: [String]) -> Void)?
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var iconCache = FileIconCache.shared
    @ObservedObject private var thumbnailService = ThumbnailService.shared
    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func columnDate(_ date: Date) -> String {
        (settings.showDateTime ? Self.columnDateFormatter : Self.dateOnlyFormatter).string(from: date)
    }

    @EnvironmentObject private var columnLayout: ResultColumnLayout
    @EnvironmentObject private var theme: ThemeManager
    @State private var isHovered = false
    @State private var localRenaming = false
    @State private var editingName = ""
    @State private var renameError: String?
    @State private var showRenameError = false

    var body: some View {
        let rowHeight = ResultRowMetrics.effectiveHeight(
            configuredHeight: settings.resultRowHeight,
            fontLineHeight: theme.bodyNSFont.ascender - theme.bodyNSFont.descender + theme.bodyNSFont.leading
        )
        GeometryReader { proxy in
            rowContent(rowHeight: rowHeight, widths: columnLayout.resolvedWidths(
                showName: settings.showName,
                showPath: settings.showPath,
                showExtension: settings.showExtension,
                showSize: settings.showSize,
                showCreated: settings.showCreatedDate,
                showModified: settings.showModifiedDate,
                showTime: settings.showDateTime,
                availableWidth: layoutWidth > 0 ? layoutWidth : proxy.size.width
            ))
        }
        .frame(height: rowHeight)
        .clipped()
        .accessibilityIdentifier("resultRow")
    }

    private func rowContent(rowHeight: CGFloat, widths: ResolvedResultColumnWidths) -> some View {
        let iconSize = min(rowHeight - 8, 32)
        let highlighted = highlightCrossMatches(
            path: item.path, name: item.name, hints: hints,
            nameFont: theme.bodyFont, nameColor: theme.resolvedTextColor,
            pathFont: theme.bodyFont, pathColor: .secondary)

        return HStack(spacing: 10) {
            if settings.showName {
            HStack(spacing: 8) {
                fileVisual(for: item, pixelSize: iconSize)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconSize, height: iconSize)
                if isActivelyRenaming {
                    RenameTextField(text: $editingName,
                                    onCommit: { commitRename() },
                                    onCancel: { cancelRename() })
                } else {
                    highlighted.nameText.lineLimit(1)
                        .help(item.name)
                }
            }
            .frame(width: widths.name, alignment: .leading)
            }

            if settings.showPath {
                highlighted.pathText
                    .lineLimit(1)
                    .help(item.path)
                    .frame(width: widths.path, alignment: .leading)
            }

            if settings.showExtension {
                Text(item.fileExtension)
                    .font(theme.bodyFont)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .help(item.fileExtension)
                    .frame(width: widths.ext, alignment: .leading)
            }

            if settings.showSize {
                Text(item.isRegularFile && item.size > 0 ? formatSize(item.size) : "")
                    .font(theme.bodyFont)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: widths.size, alignment: .trailing)
            }

            if settings.showCreatedDate {
            Text((try? URL(fileURLWithPath: item.fullPath).resourceValues(forKeys: [.creationDateKey]).creationDate).map(columnDate) ?? "—")
                .font(theme.bodyFont).foregroundColor(.secondary).lineLimit(1)
                .frame(width: widths.created, alignment: .leading)
            }
            if settings.showModifiedDate {
            Text(columnDate(Date(timeIntervalSince1970: TimeInterval(item.modTime))))
                .font(theme.bodyFont).foregroundColor(.secondary).lineLimit(1)
                .frame(width: widths.modified, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, max(2, (rowHeight - iconSize) / 2))
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            FileItemContextMenu(
                item: item,
                actionItems: contextActionItems,
                onRename: startRename,
                onDeleteItems: onDeleteItems
            )
        }
        .onDrag {
            let fullPath = item.path + "/" + item.name
            return NSItemProvider(object: NSURL(fileURLWithPath: fullPath))
        }
        .background(
            ResultClickMonitor(enabled: !isActivelyRenaming) { clickCount, modifiers in
                handleClick(clickCount: clickCount, modifiers: modifiers)
            }
        )
        .onChange(of: requestedRename) {
            if requestedRename {
                startRename()
            }
        }
        .alert(L10n.tr("Rename Failed"), isPresented: $showRenameError) {
            Button("OK") {}
        } message: {
            Text(renameError ?? "")
        }
    }

    private func fileVisual(for item: FileItem, pixelSize: CGFloat) -> Image {
        _ = iconCache.revision
        if settings.showThumbnails && !item.isFolder && !item.isApplication {
            _ = thumbnailService.revision
            if let thumb = thumbnailService.thumbnail(for: item.fullPath, modTime: item.modTime, pixelSize: pixelSize) {
                return Image(nsImage: thumb)
            }
        }
        return Image(nsImage: iconCache.icon(for: item))
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.24)
        }
        return isHovered ? Color.accentColor.opacity(0.12) : Color.clear
    }

    private var contextActionItems: [FileItem] {
        selectedItems.isEmpty || !isSelected
            ? [item]
            : selectedItems
    }

    private func formatSize(_ bytes: UInt64) -> String {
        L10n.formatByteCount(bytes)
    }

    private func formatDate(_ modTime: time_t) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(modTime))
        return L10n.formatDate(date)
    }

    private func handleClick(clickCount: Int, modifiers: NSEvent.ModifierFlags) {
        let actions = ResultClickResolver.actions(
            clickCount: clickCount,
            modifiers: modifiers,
            supportsSelection: true
        )
        for action in actions {
            switch action {
            case .selectExclusive:
                onSelect(false, false)
            case .selectRange:
                onSelect(true, false)
            case .toggleSelection:
                onSelect(false, true)
            case .open:
                FileActions.open(item)
            case .reveal:
                FileActions.revealInFinder(item)
            }
        }
    }

    private var isActivelyRenaming: Bool {
        localRenaming || requestedRename
    }

    private func startRename() {
        editingName = item.name
        localRenaming = true
    }

    private func cancelRename() {
        localRenaming = false
        onRenameComplete?()
    }

    private func commitRename() {
        localRenaming = false
        onRenameComplete?()
        let newName = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != item.name else { return }
        if newName.contains("/") || newName.contains("\0") {
            NSSound.beep()
            renameError = L10n.tr("Filename cannot contain / or null characters")
            showRenameError = true
            return
        }
        if newName.hasPrefix(".") {
            let oldHasPrefix = item.name.hasPrefix(".")
            if !oldHasPrefix {
                // Allow but don't block — user may intentionally hide a file
            }
        }
        let oldPath = item.path + "/" + item.name
        let newPath = item.path + "/" + newName
        do {
            try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
            onRenameSuccess?(item.id, newName)
        } catch {
            NSSound.beep()
            renameError = error.localizedDescription
            showRenameError = true
        }
    }

}

struct ResolvedResultColumnWidths {
    let name: CGFloat
    let path: CGFloat
    let ext: CGFloat
    let size: CGFloat
    let created: CGFloat
    let modified: CGFloat
}

final class ResultColumnLayout: ObservableObject {
    static let nameWidthRange: ClosedRange<CGFloat> = 80...1000
    static let pathWidthRange: ClosedRange<CGFloat> = 80...1600
    static let extWidthRange: ClosedRange<CGFloat> = 40...120
    static let sizeWidthRange: ClosedRange<CGFloat> = 55...150
    static let modifiedWidthRange: ClosedRange<CGFloat> = 90...240

    @Published var nameWidth: CGFloat = 260
    @Published var pathWidth: CGFloat = 400
    @Published var extWidth: CGFloat = 40
    @Published var sizeWidth: CGFloat = 60
    @Published var createdWidth: CGFloat = 90
    @Published var modifiedWidth: CGFloat = 90

    func resolvedWidths(showName: Bool, showPath: Bool, showExtension: Bool,
                        showSize: Bool, showCreated: Bool, showModified: Bool, showTime: Bool,
                        availableWidth: CGFloat) -> ResolvedResultColumnWidths {
        let count = [showName, showPath, showExtension, showSize, showCreated, showModified].filter { $0 }.count
        let space = CGFloat(max(0, count - 1)) * 10
        let created = showTime ? max(createdWidth, 140) : createdWidth
        let modified = showTime ? max(modifiedWidth, 140) : modifiedWidth
        let fixed = (showExtension ? extWidth : 0) + (showSize ? sizeWidth : 0)
            + (showCreated ? created : 0) + (showModified ? modified : 0)
        let remaining = max(0, availableWidth - 12 - space - fixed)
        let resolvedPath = showPath ? (showName ? min(pathWidth, max(0, remaining - 80)) : remaining) : 0
        let resolvedName = showName ? max(0, remaining - resolvedPath) : 0
        return ResolvedResultColumnWidths(name: resolvedName, path: resolvedPath,
                                          ext: extWidth, size: sizeWidth, created: created, modified: modified)
    }
}

@MainActor
final class QuickLookPreviewController: NSObject,
    @preconcurrency QLPreviewPanelDataSource,
    QLPreviewPanelDelegate {
    static let shared = QuickLookPreviewController()
    private var urls: [URL] = []

    func open(urls: [URL]) {
        guard !urls.isEmpty else { return }
        self.urls = urls
        let panel = QLPreviewPanel.shared()!
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }
}

/// NSTextField wrapper that commits on focus loss and cancels on Escape.
/// Uses a local mouse-down event monitor to detect clicks outside the field.
private struct RenameTextField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        field.focusRingType = .exterior
        field.delegate = context.coordinator
        field.stringValue = text
        context.coordinator.field = field
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
            context.coordinator.installClickMonitor()
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.removeClickMonitor()
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameTextField
        weak var field: NSTextField?
        private var didEnd = false
        private var clickMonitor: Any?

        init(_ parent: RenameTextField) { self.parent = parent }

        func installClickMonitor() {
            guard clickMonitor == nil else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let field = self.field, !self.didEnd else { return event }
                let locationInField = field.convert(event.locationInWindow, from: nil)
                if !field.bounds.contains(locationInField) {
                    self.parent.text = field.stringValue
                    self.finish(commit: true)
                }
                return event
            }
        }

        func removeClickMonitor() {
            if let monitor = clickMonitor {
                NSEvent.removeMonitor(monitor)
                clickMonitor = nil
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            let isCancel = (obj.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.cancel.rawValue
            finish(commit: !isCancel)
        }

        private func finish(commit: Bool) {
            guard !didEnd else { return }
            didEnd = true
            removeClickMonitor()
            if commit {
                parent.onCommit()
            } else {
                parent.onCancel()
            }
        }

        deinit {
            removeClickMonitor()
        }
    }
}
