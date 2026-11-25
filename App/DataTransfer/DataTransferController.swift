import AppKit
import Foundation
import MVLayout
import MVServices
import MVSettings
import UniformTypeIdentifiers
import os

/// 用户数据导出／导入界面流程、状态互斥与启动结果提示。
@MainActor
final class DataTransferController {
    /// 供 `stage`、`export`、`applyPendingImport` 共用的 App 侧 JSON 校验器，不依赖已建好的服务。
    nonisolated static let appValidators: UserDataValidators = [
        .session: { try JSONDocumentStore<SessionSnapshot>.validate($0, version: SessionStore.documentVersion) },
        .layout: { try JSONDocumentStore<DockLayout>.validate($0, version: DockCoordinator.layoutDocumentVersion) },
        .layoutSchemes: { try JSONDocumentStore<LayoutSchemesFile>.validate($0, version: DockCoordinator.schemesDocumentVersion) },
    ]

    private weak var app: AppDelegate?
    private let logger = Logger(category: "data-transfer")
    private var pendingOutcome: UserDataImportOutcome?
    private(set) var isBusy = false

    #if DEBUG
    var debugSaveDestination: (() -> URL?)?
    var debugOpenSource: (() -> URL?)?
    var debugOpenPanelInitialDirectory: URL?
    var debugOnSheetPresented: ((String, NSWindow, NSAlert?) -> Void)?
    var debugBeforeExportArchive: (() async -> Void)?
    var debugRelaunchArguments: (() -> [String])?
    var debugInterceptRelaunch: (([String]) -> Bool)?
    private(set) var debugActiveAlert: (tag: String, alert: NSAlert)?
    private(set) var debugProgressWindow: NSWindow?
    #endif

    init(app: AppDelegate, pendingOutcome: UserDataImportOutcome?) {
        self.app = app
        self.pendingOutcome = pendingOutcome
    }

    static func currentOrigin() -> UserDataOrigin {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let host = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostName = (host?.isEmpty == false ? host : nil) ?? ProcessInfo.processInfo.hostName
        return UserDataOrigin(appVersion: version, appBuild: build, host: hostName)
    }

    static func locations(supportDirectory: URL) -> UserDataLocations {
        UserDataLocations(supportDirectory: supportDirectory, layoutFile: DockCoordinator.defaultFileURL())
    }

    static func defaultExportFileName(on date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        return String(localized: "MacView 数据 \(day)") + "." + UserDataArchive.fileExtension
    }

    /// 优先显示相对 Application Support 的路径；隔离目录则以数据目录名开头，避免暴露完整本机路径。
    static func relativeDisplayPath(for url: URL, supportDirectory: URL) -> String {
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        let appSupport = URL.applicationSupportDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        if target.hasPrefix(appSupport + "/") {
            return String(target.dropFirst(appSupport.count + 1))
        }
        let support = supportDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let supportName = supportDirectory.lastPathComponent
        if target == support { return supportName }
        if target.hasPrefix(support + "/") {
            return supportName + "/" + String(target.dropFirst(support.count + 1))
        }
        return url.path
    }

    /// `.recoveryFailed` 时在建立服务前弹窗并结束，不启动主界面。
    static func presentRecoveryFailed(supportDirectory: URL) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "导入没有完成")
        let pathText = relativeDisplayPath(for: supportDirectory, supportDirectory: supportDirectory)
        alert.informativeText = String(localized: "原因：上次导入中断且无法恢复。\n数据目录：\(pathText)")
        alert.addButton(withTitle: String(localized: "好"))
        alert.runModal()
    }

    private var presentationWindow: NSWindow? {
        app?.activeReaderController?.window ?? app?.controllers.first?.window
    }

    var canStart: Bool {
        !isBusy && NSApp.modalWindow == nil && presentationWindow?.attachedSheet == nil
    }

    // MARK: 导出

    func exportUserData() {
        guard canStart, let app, app.services != nil, !app.isMock else { return }
        isBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            await self.runExport()
        }
    }

    private func runExport() async {
        guard let app, let services = app.services else { return }
        guard let destination = await chooseExportDestination() else { return }

        let sheet = presentExportProgressSheet()
        do {
            for controller in app.controllers { await controller.session.flush() }
            await app.flushSessionStore()
            await app.dock?.flush()
            try await services.flushPersistentState()
            #if DEBUG
            if let hook = debugBeforeExportArchive { await hook() }
            #endif
            let locations = Self.locations(supportDirectory: app.supportDirectory)
            _ = try await UserDataArchive.export(
                from: locations,
                origin: Self.currentOrigin(),
                appValidators: Self.appValidators,
                to: destination
            )
            dismissProgressSheet(sheet)
            await presentExportFinished(destination: destination)
        } catch {
            dismissProgressSheet(sheet)
            logger.error("导出用户数据失败：\(String(describing: error), privacy: .public)")
            await presentExportFailed(destination: destination, error: error)
        }
    }

    private func chooseExportDestination() async -> URL? {
        #if DEBUG
        if let hook = debugSaveDestination { return hook() }
        #endif
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: UserDataArchive.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.defaultExportFileName()
        return await presentFilePanel(panel, tag: "save-panel")
    }

    private func presentFilePanel(_ panel: NSSavePanel, tag: String) async -> URL? {
        if let window = presentationWindow {
            return await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
                #if DEBUG
                debugOnSheetPresented?(tag, panel, nil)
                #endif
            }
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func presentExportProgressSheet() -> (window: NSWindow, parent: NSWindow?) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 76),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = NSTextField(labelWithString: String(localized: "正在导出用户数据…"))
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor

        let subtitleLabel = NSTextField(labelWithString: String(localized: "设置、资料库、窗口、脚本与插件"))
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3

        let row = NSStackView(views: [spinner, textStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 76))
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            row.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
        panel.contentView = content

        let parent = presentationWindow
        if let parent {
            parent.beginSheet(panel, completionHandler: nil)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
        #if DEBUG
        debugProgressWindow = panel
        debugOnSheetPresented?("export-progress", panel, nil)
        #endif
        return (panel, parent)
    }

    private func dismissProgressSheet(_ sheet: (window: NSWindow, parent: NSWindow?)) {
        if let parent = sheet.parent {
            parent.endSheet(sheet.window)
        }
        sheet.window.orderOut(nil)
        #if DEBUG
        if debugProgressWindow === sheet.window { debugProgressWindow = nil }
        #endif
    }

    private func presentExportFinished(destination: URL) async {
        let folderName = FileManager.default.displayName(atPath: destination.deletingLastPathComponent().path)
        let displayLocation = "\(folderName) › \(destination.lastPathComponent)"
        let byteCount = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let sizeText = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "已导出用户数据")
        alert.informativeText = String(localized: "已保存为「\(displayLocation)」（\(sizeText)）。")
        alert.accessoryView = makeWrappingAccessory(NSAttributedString(
            string: String(localized: "文件里含来源密码等全部数据，请妥善保管。"),
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemRed]
        ))
        alert.addButton(withTitle: String(localized: "好"))
        alert.addButton(withTitle: String(localized: "在 Finder 中显示"))

        let response = await presentAlert(alert, tag: "export-done")
        if response == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    private func presentExportFailed(destination: URL, error: any Error) async {
        let folderName = FileManager.default.displayName(atPath: destination.deletingLastPathComponent().path)
        let reason = Self.trimTrailingPunctuation(Self.describeExportError(error))
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "导出没有完成")
        alert.informativeText = String(localized: "无法写入「\(folderName)」：\(reason)。没有留下不完整的文件。")
        alert.addButton(withTitle: String(localized: "好"))
        _ = await presentAlert(alert, tag: "export-failed")
    }

    // MARK: 导入

    func importUserData() {
        guard canStart, let app, app.services != nil, !app.isMock else { return }
        isBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let keepBusy = await self.runImport()
            if !keepBusy { self.isBusy = false }
        }
    }

    /// 返回 `true` 表示已发起重启，保持忙碌状态直到进程退出。
    private func runImport() async -> Bool {
        guard let app else { return false }
        guard let archive = await chooseImportSource() else { return false }
        let locations = Self.locations(supportDirectory: app.supportDirectory)

        let staged: StagedImport
        do {
            staged = try await UserDataArchive.stage(archive, for: locations, appValidators: Self.appValidators)
        } catch {
            logger.warning("无法暂存导入文件：\(String(describing: error), privacy: .public)")
            await presentImportError(archive: archive, error: error)
            return false
        }

        let confirmed = await presentImportConfirmation(manifest: staged.manifest, locations: locations)
        guard confirmed else {
            await discardStagedInBackground(locations: locations)
            return false
        }

        do {
            try UserDataArchive.commitStaged(staged, for: locations)
            #if DEBUG
            let arguments = debugRelaunchArguments?() ?? Array(ProcessInfo.processInfo.arguments.dropFirst())
            if let intercept = debugInterceptRelaunch, intercept(arguments) {
                return false
            }
            try AppRelauncher.relaunch(arguments: arguments)
            #else
            try AppRelauncher.relaunch()
            #endif
            return true
        } catch {
            logger.error("提交导入或重启失败：\(String(describing: error), privacy: .public)")
            await discardStagedInBackground(locations: locations)
            await presentRolledBackAlert(reason: ErrorText.describe(error))
            return false
        }
    }

    private func chooseImportSource() async -> URL? {
        #if DEBUG
        if let hook = debugOpenSource { return hook() }
        #endif
        let panel = NSOpenPanel()
        if let type = UTType(filenameExtension: UserDataArchive.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        #if DEBUG
        if let dir = debugOpenPanelInitialDirectory {
            panel.directoryURL = dir
        }
        #endif
        return await presentFilePanel(panel, tag: "open-panel")
    }

    private func presentImportConfirmation(manifest: UserDataManifest, locations: UserDataLocations) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "导入用户数据并重启 MacView？")
        let timeText = Self.formatTimestamp(manifest.createdAt)
        alert.informativeText = String(localized: "来自「\(manifest.host)」，\(timeText) 导出（MacView \(manifest.appVersion)）：")

        let backupPath = Self.relativeDisplayPath(
            for: UserDataArchive.backupURL(for: locations),
            supportDirectory: locations.supportDirectory
        )
        alert.accessoryView = makeImportConfirmationAccessory(summary: manifest.summary, backupDisplay: backupPath)

        // 默认按钮必须是「取消」，回车不触发导入。
        let cancelButton = alert.addButton(withTitle: String(localized: "取消"))
        let confirmButton = alert.addButton(withTitle: String(localized: "导入并重启"))
        cancelButton.keyEquivalent = "\r"
        confirmButton.keyEquivalent = ""

        let response = await presentAlert(alert, tag: "import-confirm")
        return response == .alertSecondButtonReturn
    }

    private func presentImportError(archive: URL, error: any Error) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "无法导入这个文件")
        alert.informativeText = Self.describeImportError(error, fileName: archive.lastPathComponent)
        alert.addButton(withTitle: String(localized: "好"))
        _ = await presentAlert(alert, tag: "import-error")
    }

    private func discardStagedInBackground(locations: UserDataLocations) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                UserDataArchive.discardStaged(for: locations)
                continuation.resume()
            }
        }
    }

    // MARK: 启动结果提示

    func presentStartupOutcomeIfNeeded() {
        guard let outcome = pendingOutcome else { return }
        pendingOutcome = nil
        isBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            switch outcome {
            case let .imported(manifest, backup):
                await self.presentImportDone(manifest: manifest, backup: backup)
            case let .rolledBack(reason):
                await self.presentRolledBackAlert(reason: reason)
            case .recoveryFailed:
                break
            }
        }
    }

    private func presentImportDone(manifest: UserDataManifest, backup: URL) async {
        guard let supportDirectory = app?.supportDirectory else { return }
        let backupPath = Self.relativeDisplayPath(for: backup, supportDirectory: supportDirectory)
        let timeText = Self.formatTimestamp(manifest.createdAt)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "已导入用户数据")
        alert.informativeText = String(localized: "已载入「\(manifest.host)」\(timeText) 导出的数据。")
        alert.accessoryView = makeWrappingAccessory(
            Self.attributedBackupNote(fullText: String(localized: "原来的数据备份在 \(backupPath)。"), highlightedPath: backupPath)
        )
        alert.addButton(withTitle: String(localized: "好"))
        alert.addButton(withTitle: String(localized: "显示备份"))

        let response = await presentAlert(alert, tag: "import-done")
        if response == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([backup])
        }
    }

    private func presentRolledBackAlert(reason: String) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "导入没有完成")
        let trimmed = Self.trimTrailingPunctuation(reason)
        alert.informativeText = String(localized: "本机数据没有改变。原因：\(trimmed)。")
        alert.addButton(withTitle: String(localized: "好"))
        _ = await presentAlert(alert, tag: "import-rolled-back")
    }

    // MARK: 弹窗与视图辅助

    private func presentAlert(_ alert: NSAlert, tag: String) async -> NSApplication.ModalResponse {
        #if DEBUG
        debugActiveAlert = (tag, alert)
        defer { if debugActiveAlert?.alert === alert { debugActiveAlert = nil } }
        #endif
        if let window = presentationWindow {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response)
                }
                #if DEBUG
                debugOnSheetPresented?(tag, alert.window, alert)
                #endif
            }
        }
        return alert.runModal()
    }

    private func makeWrappingAccessory(_ attributed: NSAttributedString, width: CGFloat = 300) -> NSView {
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = attributed
        label.preferredMaxLayoutWidth = width
        let size = label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        label.frame = NSRect(origin: .zero, size: NSSize(width: width, height: ceil(size.height)))
        return label
    }

    private func makeImportConfirmationAccessory(summary: UserDataSummary, backupDisplay: String) -> NSView {
        let width: CGFloat = 320
        let statsBox = StatsBoxView()
        let makeStatLabel: (String) -> NSTextField = { text in
            let label = NSTextField(labelWithString: text)
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .labelColor
            return label
        }
        let row1 = NSStackView(views: [
            makeStatLabel(String(localized: "历史 \(summary.history) 本")),
            makeStatLabel(String(localized: "书签 \(summary.bookmarks) 个")),
            makeStatLabel(String(localized: "播放列表 \(summary.playlists) 个")),
        ])
        row1.orientation = .horizontal
        row1.spacing = 12
        let row2 = NSStackView(views: [
            makeStatLabel(String(localized: "脚本 \(summary.scripts) 个")),
            makeStatLabel(String(localized: "插件 \(summary.plugins) 个")),
        ])
        row2.orientation = .horizontal
        row2.spacing = 12
        let statsStack = NSStackView(views: [row1, row2])
        statsStack.orientation = .vertical
        statsStack.alignment = .leading
        statsStack.spacing = 4
        statsStack.translatesAutoresizingMaskIntoConstraints = false
        statsBox.addSubview(statsStack)
        NSLayoutConstraint.activate([
            statsStack.leadingAnchor.constraint(equalTo: statsBox.leadingAnchor, constant: 10),
            statsStack.trailingAnchor.constraint(lessThanOrEqualTo: statsBox.trailingAnchor, constant: -10),
            statsStack.topAnchor.constraint(equalTo: statsBox.topAnchor, constant: 8),
            statsStack.bottomAnchor.constraint(equalTo: statsBox.bottomAnchor, constant: -8),
        ])

        let replaceLabel = NSTextField(wrappingLabelWithString: String(
            localized: "本机现有的全部 MacView 数据（设置、资料库、窗口、脚本与插件）会被替换，MacView 会重启。"
        ))
        replaceLabel.font = .systemFont(ofSize: 12)
        replaceLabel.textColor = .labelColor
        replaceLabel.preferredMaxLayoutWidth = width

        let backupLabel = NSTextField(wrappingLabelWithString: "")
        backupLabel.attributedStringValue = Self.attributedBackupNote(
            fullText: String(localized: "替换前先备份到 \(backupDisplay)，想恢复时导入它。"),
            highlightedPath: backupDisplay
        )
        backupLabel.preferredMaxLayoutWidth = width

        let stack = NSStackView(views: [statsBox, replaceLabel, backupLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statsBox.widthAnchor.constraint(equalToConstant: width),
            container.widthAnchor.constraint(equalToConstant: width),
        ])
        container.layoutSubtreeIfNeeded()
        container.frame = NSRect(origin: .zero, size: NSSize(width: width, height: ceil(container.fittingSize.height)))
        return container
    }

    private static func attributedBackupNote(fullText: String, highlightedPath: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: fullText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        let range = (fullText as NSString).range(of: highlightedPath)
        if range.location != NSNotFound {
            attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), range: range)
        }
        return attributed
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func describeExportError(_ error: any Error) -> String {
        if case let UserDataArchiveError.writeFailed(reason) = error { return reason }
        return ErrorText.describe(error)
    }

    private static func describeImportError(_ error: any Error, fileName: String) -> String {
        if let archiveError = error as? UserDataArchiveError {
            switch archiveError {
            case .notAnArchive:
                return String(localized: "「\(fileName)」不是 MacView 导出的数据文件。")
            case let .newerFormat(format):
                return String(localized: "这个文件来自更新版本的 MacView（数据格式 \(format)），请先升级 MacView。")
            case let .damaged(item?, _):
                return String(localized: "文件已损坏：\(item) 校验失败。")
            case let .damaged(nil, reason), let .writeFailed(reason):
                return String(localized: "文件已损坏：\(reason)")
            }
        }
        return String(localized: "文件已损坏：\(ErrorText.describe(error))")
    }

    private static func trimTrailingPunctuation(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("。") || result.hasSuffix(".") {
            result.removeLast()
        }
        return result
    }
}

private final class StatsBoxView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }
}
