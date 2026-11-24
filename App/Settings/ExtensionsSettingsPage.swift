import AppKit
import Foundation
import MVCommands
import MVScripting
import MVSettings
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// 设置 › 扩展 页的模型：桥接脚本列表、运行状态、外部命令与输出日志。
@MainActor
@Observable
final class ExtensionsSettingsModel {
    private(set) var scripts: [ScriptInfo] = []
    private(set) var externalCommands: [ExternalCommand] = []
    private(set) var runStates: [String: ScriptRunState] = [:]
    private(set) var logEntries: [ScriptLogEntry] = []
    private(set) var externalCommandsProblem: String?
    private(set) var writeError: String?

    @ObservationIgnored private weak var extensions: ExtensionCommands?
    @ObservationIgnored private let supportDirectory: URL
    @ObservationIgnored private var runStatesTask: Task<Void, Never>?
    @ObservationIgnored private var logTask: Task<Void, Never>?

    var scriptsDirectory: URL {
        extensions?.scriptsDirectory ?? supportDirectory.appending(path: "Scripts", directoryHint: .isDirectory)
    }

    var externalCommandsFileURL: URL {
        supportDirectory.appending(path: "external-commands.json")
    }

    var hasRunningScripts: Bool {
        runStates.values.contains { state in
            switch state {
            case .running, .queued: true
            case .idle: false
            }
        }
    }

    init(extensions: ExtensionCommands?, supportDirectory: URL) {
        self.extensions = extensions
        self.supportDirectory = supportDirectory
        extensions?.onChange = { [weak self] in
            self?.syncFromExtensions()
        }
        reload()
        observeRuntime()
        observeLog()
    }

    deinit {
        runStatesTask?.cancel()
        logTask?.cancel()
    }

    func reload() {
        syncFromExtensions()
        if let runtime = extensions?.scriptRuntime {
            runStates = runtime.runStates()
        }
        if let log = extensions?.scriptLog {
            logEntries = log.entries()
        }
    }

    private func syncFromExtensions() {
        scripts = extensions?.allScripts ?? []
        externalCommands = extensions?.externalItems ?? []
        externalCommandsProblem = extensions?.externalCommandsProblem
    }

    private func observeRuntime() {
        guard let runtime = extensions?.scriptRuntime else { return }
        let stream = runtime.runStateChanges()
        runStates = runtime.runStates()
        runStatesTask = Task { [weak self] in
            for await states in stream {
                guard let self, !Task.isCancelled else { return }
                self.runStates = states
            }
        }
    }

    private func observeLog() {
        guard let log = extensions?.scriptLog else { return }
        let stream = log.changes()
        logEntries = log.entries()
        logTask = Task { [weak self] in
            for await entries in stream {
                guard let self, !Task.isCancelled else { return }
                self.logEntries = entries
            }
        }
    }

    // MARK: - 脚本操作

    func runScript(_ info: ScriptInfo) {
        extensions?.runScript(info)
    }

    func stopScript(_ id: String) {
        extensions?.scriptRuntime?.stop(id)
    }

    func stopAllScripts() {
        extensions?.scriptRuntime?.stopAll()
    }

    func openScriptInEditor(_ info: ScriptInfo) {
        NSWorkspace.shared.open(info.fileURL)
    }

    func revealScriptsFolder() {
        revealInFinder(scriptsDirectory)
    }

    // MARK: - 外部命令操作

    func saveExternalCommand(_ command: ExternalCommand) async -> Bool {
        guard let store = extensions?.externalCommandsStore else { return false }
        do {
            try await store.update { file in
                if let index = file.commands.firstIndex(where: { $0.id == command.id }) {
                    file.commands[index] = command
                } else {
                    file.commands.append(command)
                }
            }
            writeError = nil
            return true
        } catch {
            writeError = ErrorText.describe(error)
            return false
        }
    }

    func deleteExternalCommand(id: String) async {
        guard let store = extensions?.externalCommandsStore else { return }
        do {
            try await store.update { file in
                file.commands.removeAll { $0.id == id }
            }
            writeError = nil
        } catch {
            writeError = ErrorText.describe(error)
        }
    }

    func openExternalCommandsFile() {
        let url = externalCommandsFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
            return
        }
        guard let store = extensions?.externalCommandsStore, externalCommandsProblem == nil else {
            revealInFinder(supportDirectory)
            return
        }
        Task {
            try? await store.update { _ in }
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 日志

    func clearLog() {
        extensions?.scriptLog?.clear()
    }
}

/// 外部命令行内编辑表单的草稿状态。
private struct ExternalCommandDraft: Equatable {
    var id: String
    var isNew: Bool
    var name: String
    var kind: ExternalCommand.Kind
    var program: String
    var arguments: String
    var workingDirectory: String
    var showOutput: Bool
    var validationError: String?

    static func new() -> ExternalCommandDraft {
        ExternalCommandDraft(
            id: UUID().uuidString.lowercased(),
            isNew: true,
            name: "",
            kind: .shell,
            program: "",
            arguments: "",
            workingDirectory: "",
            showOutput: false,
            validationError: nil
        )
    }

    init(command: ExternalCommand) {
        self.id = command.id
        self.isNew = false
        self.name = command.name
        self.kind = command.kind
        self.program = command.program ?? ""
        self.arguments = command.arguments
        self.workingDirectory = command.workingDirectory ?? ""
        self.showOutput = command.showOutput
        self.validationError = nil
    }

    private init(
        id: String, isNew: Bool, name: String, kind: ExternalCommand.Kind,
        program: String, arguments: String, workingDirectory: String, showOutput: Bool, validationError: String?
    ) {
        self.id = id
        self.isNew = isNew
        self.name = name
        self.kind = kind
        self.program = program
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.showOutput = showOutput
        self.validationError = validationError
    }
}

/// 设置 › 扩展：脚本、外部命令、输出。
struct ExtensionsSettingsPage: View {
    let model: ExtensionsSettingsModel
    let shortcuts: ShortcutsModel

    @State private var editing: ExternalCommandDraft?
    @State private var confirmingDeleteID: String?
    @State private var pinnedToBottom = true

    private static let readyDotColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x9C / 255, green: 0xC4 / 255, blue: 0x90 / 255, alpha: 1)
            : NSColor(srgbRed: 0x4F / 255, green: 0x7A / 255, blue: 0x4A / 255, alpha: 1)
    }

    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let kindOptions: [(String, ExternalCommand.Kind)] = [
        (String(localized: "应用"), .application),
        (String(localized: "程序"), .program),
        ("Shell", .shell),
    ]

    var body: some View {
        VStack(spacing: 0) {
            if let problem = model.externalCommandsProblem {
                jsonErrorBanner(problem: problem)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    scriptsSection
                    externalCommandsSection
                    outputSection
                }
                .padding(16)
            }
        }
        .onAppear {
            model.reload()
        }
    }

    // MARK: - 顶部 JSON 错误横幅

    private func jsonErrorBanner(problem: String) -> some View {
        HStack(spacing: 12) {
            Text(String(localized: "external-commands.json \(problem)。仍在使用上一份可用的外部命令。"))
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Theme.danger))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { model.openExternalCommandsFile() }) {
                Text(String(localized: "打开文件")).underline()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Color(nsColor: Theme.danger))
            .accessibilityIdentifier("settings.extensions.jsonError.openFile")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: Theme.dangerSoft))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.extensions.jsonError")
    }

    // MARK: - 1. 脚本

    private var scriptsSection: some View {
        sectionContainer(
            title: String(localized: "脚本"),
            aside: String(localized: "一个 .js 文件是一条命令，保存后自动重载")
        ) {
            if model.scripts.isEmpty {
                VStack(spacing: 4) {
                    Text(String(localized: "还没有脚本"))
                        .font(Font(Theme.serif(14, weight: .semibold)))
                        .foregroundStyle(Color(nsColor: Theme.text))
                    Text(String(localized: "把 .js 文件放进脚本文件夹，这里会马上列出来。文件开头用 // @name、// @event 写名称和事件。"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: Theme.text2))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
                .accessibilityIdentifier("settings.extensions.scripts.empty")
            } else {
                ForEach(Array(model.scripts.enumerated()), id: \.element.id) { index, script in
                    if index > 0 { SettingsDivider() }
                    scriptRow(script)
                }
            }
            SettingsDivider()
            HStack(spacing: 8) {
                Text(abbreviatedPath(model.scriptsDirectory))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(nsColor: Theme.text2))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(model.scriptsDirectory.path(percentEncoded: false))
                Button(String(localized: "在 Finder 中显示")) {
                    model.revealScriptsFolder()
                }
                .controlSize(.small)
                .accessibilityIdentifier("settings.extensions.scripts.reveal")
                Button(String(localized: "全部停止")) {
                    model.stopAllScripts()
                }
                .controlSize(.small)
                .disabled(!model.hasRunningScripts)
                .accessibilityIdentifier("settings.extensions.scripts.stopAll")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func scriptRow(_ script: ScriptInfo) -> some View {
        let runState = model.runStates[script.id] ?? .idle
        let shortcutText = firstShortcutText(for: ExtensionCommands.scriptCommandID(for: script.id))
        let filename = script.fileURL.lastPathComponent
        let subtitle: String
        let isError = script.problem != nil

        if let problem = script.problem {
            if let line = problem.line {
                subtitle = String(localized: "\(filename) 第 \(line) 行：\(problem.message)")
            } else {
                subtitle = String(localized: "\(filename)：\(problem.message)")
            }
        } else if let summary = script.summary, !summary.isEmpty {
            subtitle = "\(filename) · \(summary)"
        } else if !script.events.isEmpty {
            let names = script.events.map(Self.eventDisplayName).joined(separator: "、")
            subtitle = "\(filename) · " + String(localized: "事件：\(names)")
        } else {
            subtitle = filename
        }

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(script.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.text))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: isError ? Theme.danger : Theme.text2))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(subtitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let shortcutText {
                chip(shortcutText)
            }
            if !isError, let firstEvent = script.events.first {
                chip(firstEvent.rawValue)
            }

            if isError {
                Text(String(localized: "语法错误"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.danger))
                    .fixedSize()
                    .accessibilityIdentifier("settings.extensions.script.\(script.id).status")
            } else {
                switch runState {
                case let .running(since):
                    TimelineView(.periodic(from: .now, by: 1.0)) { context in
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.75)
                                .frame(width: 12, height: 12)
                            Text(String(localized: "运行中 \(Self.elapsedText(since: since, now: context.date))"))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Color(nsColor: Theme.text))
                                .fixedSize()
                        }
                    }
                    .accessibilityIdentifier("settings.extensions.script.\(script.id).status")
                    Button(String(localized: "停止")) {
                        model.stopScript(script.id)
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.extensions.script.\(script.id).stop")
                case .queued:
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.75)
                            .frame(width: 12, height: 12)
                        Text(String(localized: "排队中"))
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: Theme.text))
                            .fixedSize()
                    }
                    .accessibilityIdentifier("settings.extensions.script.\(script.id).status")
                    Button(String(localized: "停止")) {
                        model.stopScript(script.id)
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.extensions.script.\(script.id).stop")
                case .idle:
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(nsColor: Self.readyDotColor))
                            .frame(width: 6, height: 6)
                        Text(String(localized: "就绪"))
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: Theme.text2))
                            .fixedSize()
                    }
                    .accessibilityIdentifier("settings.extensions.script.\(script.id).status")
                    SettingsIconButton(
                        systemImage: "play.fill",
                        fontSize: 10,
                        help: String(localized: "运行")
                    ) {
                        model.runScript(script)
                    }
                    .accessibilityIdentifier("settings.extensions.script.\(script.id).run")
                }
            }

            SettingsIconButton(
                systemImage: "pencil",
                help: String(localized: "在编辑器中打开")
            ) {
                model.openScriptInEditor(script)
            }
            .accessibilityIdentifier("settings.extensions.script.\(script.id).open")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.extensions.script.\(script.id)")
    }

    // MARK: - 2. 外部命令

    private var externalCommandsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(
                title: String(localized: "外部命令"),
                aside: String(localized: "对选中项运行；没有选中项时对当前页")
            )
            SettingsErrorBanner(message: model.writeError)
            SettingsCard {
                if model.externalCommands.isEmpty && editing?.isNew != true {
                    Text(String(localized: "还没有外部命令。点下方“新建外部命令”添加。"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: Theme.text2))
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 16)
                        .accessibilityIdentifier("settings.extensions.external.empty")
                } else {
                    ForEach(Array(model.externalCommands.enumerated()), id: \.element.id) { index, command in
                        if index > 0 { SettingsDivider() }
                        externalCommandRow(command)
                        if editing?.id == command.id && editing?.isNew == false {
                            SettingsDivider()
                            externalCommandEditor
                        }
                    }
                }
                if editing?.isNew == true {
                    if !model.externalCommands.isEmpty { SettingsDivider() }
                    externalCommandEditor
                }
                SettingsDivider()
                HStack(spacing: 8) {
                    Button(String(localized: "＋ 新建外部命令")) {
                        confirmingDeleteID = nil
                        editing = ExternalCommandDraft.new()
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.extensions.external.add")
                    Spacer()
                    Button(String(localized: "打开 external-commands.json")) {
                        model.openExternalCommandsFile()
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.extensions.external.openFile")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private func externalCommandRow(_ command: ExternalCommand) -> some View {
        let isConfirmingDelete = confirmingDeleteID == command.id
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.text))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    Text(Self.kindTitle(command.kind) + " ·")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: Theme.text2))
                        .fixedSize()
                    Text(Self.commandSubtitleDetail(command))
                        .font(command.kind == .application ? .system(size: 11) : .system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(nsColor: Theme.text2))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isConfirmingDelete {
                Text(String(localized: "删除？"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.danger))
                    .fixedSize()
                Button(String(localized: "取消")) {
                    confirmingDeleteID = nil
                }
                .controlSize(.small)
                .accessibilityIdentifier("settings.extensions.external.\(command.id).cancelDelete")
                Button(String(localized: "确认删除")) {
                    confirmingDeleteID = nil
                    if editing?.id == command.id { editing = nil }
                    Task { await model.deleteExternalCommand(id: command.id) }
                }
                .controlSize(.small)
                .foregroundStyle(Color(nsColor: Theme.danger))
                .accessibilityIdentifier("settings.extensions.external.\(command.id).confirmDelete")
            } else {
                if command.kind != .application && command.showOutput {
                    chip(String(localized: "显示输出"))
                }
                SettingsIconButton(
                    systemImage: "pencil",
                    help: String(localized: "编辑")
                ) {
                    confirmingDeleteID = nil
                    if editing?.id == command.id && editing?.isNew == false {
                        editing = nil
                    } else {
                        editing = ExternalCommandDraft(command: command)
                    }
                }
                .accessibilityIdentifier("settings.extensions.external.\(command.id).edit")
                SettingsIconButton(
                    systemImage: "minus",
                    help: String(localized: "删除")
                ) {
                    confirmingDeleteID = command.id
                }
                .accessibilityIdentifier("settings.extensions.external.\(command.id).delete")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.extensions.external.\(command.id)")
    }

    @ViewBuilder
    private var externalCommandEditor: some View {
        if editing != nil {
            let nameBinding = Binding<String>(
                get: { editing?.name ?? "" },
                set: { editing?.name = $0; editing?.validationError = nil }
            )
            let kindBinding = Binding<ExternalCommand.Kind>(
                get: { editing?.kind ?? .shell },
                set: { editing?.kind = $0; editing?.validationError = nil }
            )
            let programBinding = Binding<String>(
                get: { editing?.program ?? "" },
                set: { editing?.program = $0; editing?.validationError = nil }
            )
            let argumentsBinding = Binding<String>(
                get: { editing?.arguments ?? "" },
                set: { editing?.arguments = $0; editing?.validationError = nil }
            )
            let workingDirBinding = Binding<String>(
                get: { editing?.workingDirectory ?? "" },
                set: { editing?.workingDirectory = $0 }
            )
            let showOutputBinding = Binding<Bool>(
                get: { editing?.showOutput ?? false },
                set: { editing?.showOutput = $0 }
            )
            let kind = editing?.kind ?? .shell

            VStack(alignment: .leading, spacing: 8) {
                formRow(label: String(localized: "名称")) {
                    TextField(String(localized: "名称"), text: nameBinding)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .accessibilityIdentifier("settings.extensions.form.name")
                }

                formRow(label: String(localized: "类型")) {
                    SettingsSegments(
                        label: String(localized: "类型"),
                        options: Self.kindOptions,
                        selection: kindBinding
                    )
                    .accessibilityIdentifier("settings.extensions.form.kind")
                }

                if kind != .shell {
                    formRow(label: String(localized: "程序")) {
                        HStack(spacing: 6) {
                            TextField(
                                kind == .application ? "/System/Applications/Preview.app" : "/opt/homebrew/bin/exiftool",
                                text: programBinding
                            )
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .font(.system(size: 11.5, design: .monospaced))
                            .accessibilityIdentifier("settings.extensions.form.program")
                            Button(String(localized: "选择…")) {
                                chooseProgram(kind: kind) { url in
                                    editing?.program = url.path(percentEncoded: false)
                                    editing?.validationError = nil
                                }
                            }
                            .controlSize(.small)
                            .accessibilityIdentifier("settings.extensions.form.chooseProgram")
                        }
                    }
                }

                if kind != .application {
                    formRow(label: kind == .shell ? String(localized: "命令") : String(localized: "参数")) {
                        TextField(
                            kind == .shell ? "sips -g pixelWidth {file}" : "-s -ImageSize {files}",
                            text: argumentsBinding
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11.5, design: .monospaced))
                        .accessibilityIdentifier("settings.extensions.form.arguments")
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Spacer().frame(width: 84)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "占位符：{file} 第一个目标  {files} 全部目标  {folder} 所在文件夹  {name} 文件名  {book} 当前书  {page} 页码（从 1 起）"))
                                .font(.system(size: 11))
                                .foregroundStyle(Color(nsColor: Theme.text2))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(
                                kind == .shell
                                    ? String(localized: "替换时自动加引号，不要自己加。用登录 Shell 执行，能找到 Homebrew 装的工具。")
                                    : String(localized: "按空白拆成参数，引号内不拆；{files} 单独成一个参数时展开成多个。")
                            )
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: Theme.text2))
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    formRow(label: String(localized: "工作目录")) {
                        TextField(String(localized: "第一个目标所在文件夹"), text: workingDirBinding)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .accessibilityIdentifier("settings.extensions.form.workingDirectory")
                    }

                    formRow(label: String(localized: "显示输出")) {
                        HStack(spacing: 8) {
                            SettingsSwitch(label: String(localized: "显示输出"), isOn: showOutputBinding)
                                .accessibilityIdentifier("settings.extensions.form.showOutput")
                            Text(String(localized: "标准输出进输出区，最后一行显示在状态栏"))
                                .font(.system(size: 11))
                                .foregroundStyle(Color(nsColor: Theme.text2))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }

                SettingsErrorBanner(message: editing?.validationError)

                HStack(spacing: 6) {
                    Spacer()
                    Button(String(localized: "取消")) {
                        editing = nil
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.extensions.form.cancel")

                    Button(action: commitDraft) {
                        Text(String(localized: "存储"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(nsColor: Theme.onPrimary))
                            .padding(.horizontal, 12)
                            .frame(height: 24)
                            .background(Color(nsColor: Theme.primary), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.extensions.form.save")
                }
                .padding(.top, 2)
            }
            .padding(12)
            .background(Color(nsColor: Theme.well))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.extensions.form")
        }
    }

    private func formRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Theme.text2))
                .frame(width: 84, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func commitDraft() {
        guard var draft = editing else { return }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            draft.validationError = String(localized: "名称不能为空")
            editing = draft
            return
        }

        let program: String?
        if draft.kind == .shell {
            program = nil
        } else {
            let trimmed = draft.program.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                draft.validationError = String(localized: "请选择或填写程序路径")
                editing = draft
                return
            }
            let expanded = (trimmed as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                draft.validationError = String(localized: "程序路径不存在")
                editing = draft
                return
            }
            program = expanded
        }

        let arguments: String
        let workingDirectory: String?
        let showOutput: Bool
        if draft.kind == .application {
            arguments = ""
            workingDirectory = nil
            showOutput = false
        } else {
            if draft.kind == .shell, draft.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.validationError = String(localized: "命令不能为空")
                editing = draft
                return
            }
            arguments = draft.arguments
            let trimmedWD = draft.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            workingDirectory = trimmedWD.isEmpty ? nil : trimmedWD
            showOutput = draft.showOutput
        }

        let command = ExternalCommand(
            id: draft.id,
            name: name,
            kind: draft.kind,
            program: program,
            arguments: arguments,
            workingDirectory: workingDirectory,
            showOutput: showOutput
        )
        Task {
            if await model.saveExternalCommand(command) {
                editing = nil
            }
        }
    }

    private func chooseProgram(kind: ExternalCommand.Kind, done: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if kind == .application {
            panel.allowedContentTypes = [.applicationBundle]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
        }
        panel.begin { response in
            if response == .OK, let url = panel.url {
                done(url)
            }
        }
    }

    // MARK: - 3. 输出

    private var outputSection: some View {
        sectionContainer(
            title: String(localized: "输出"),
            aside: String(localized: "脚本的 console 输出、错误与外部命令结果")
        ) {
            ScrollViewReader { proxy in
                ScrollView {
                    if model.logEntries.isEmpty {
                        Text(String(localized: "暂无输出"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(nsColor: Theme.text2))
                            .frame(maxWidth: .infinity, minHeight: 116)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.logEntries) { entry in
                                logLine(entry)
                                    .id(entry.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .textSelection(.enabled)
                    }
                }
                .frame(height: 132)
                .background(Color(nsColor: Theme.well))
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let maxOffset = max(0, geometry.contentSize.height - geometry.containerSize.height)
                    return geometry.contentOffset.y >= maxOffset - 16
                } action: { _, isAtBottom in
                    pinnedToBottom = isAtBottom
                }
                .onAppear {
                    if let lastID = model.logEntries.last?.id {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
                .onChange(of: model.logEntries.last?.id) { _, lastID in
                    guard pinnedToBottom, let lastID else { return }
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
            .accessibilityIdentifier("settings.extensions.log")

            SettingsDivider()
            HStack {
                Spacer()
                Button(String(localized: "清空")) {
                    model.clearLog()
                }
                .controlSize(.small)
                .disabled(model.logEntries.isEmpty)
                .accessibilityIdentifier("settings.extensions.log.clear")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func logLine(_ entry: ScriptLogEntry) -> some View {
        let time = Self.logTimeFormatter.string(from: entry.date)
        let isError = entry.level == .error
        let timeText = Text(verbatim: time)
            .foregroundStyle(Color(nsColor: isError ? Theme.danger : Theme.text2).opacity(isError ? 0.85 : 0.75))
        let sourceText = Text(verbatim: " [\(entry.source)] ")
            .foregroundStyle(Color(nsColor: isError ? Theme.danger : Theme.text2))
        let bodyText = Text(verbatim: entry.text)
            .foregroundStyle(Color(nsColor: isError ? Theme.danger : Theme.text))
        return Text("\(timeText)\(sourceText)\(bodyText)")
            .font(.system(size: 11, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 公共小组件与格式化

    private func sectionHeader(title: String, aside: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: Theme.text2))
            Spacer(minLength: 8)
            Text(aside)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Theme.text2))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
    }

    private func sectionContainer<Content: View>(
        title: String,
        aside: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(title: title, aside: aside)
            SettingsCard {
                content()
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Color(nsColor: Theme.text2))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color(nsColor: Theme.well), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: Theme.line), lineWidth: 0.5))
            .fixedSize()
    }

    private func firstShortcutText(for commandID: CommandID) -> String? {
        guard let binding = shortcuts.effectiveBindings.first(where: { $0.command == commandID }) else {
            return nil
        }
        return ShortcutsModel.displayText(for: binding.sequence)
    }

    private func abbreviatedPath(_ url: URL) -> String {
        (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    private static func elapsedText(since: Date, now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(since)))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private static func eventDisplayName(_ event: ScriptEventName) -> String {
        switch event {
        case .startup: String(localized: "启动")
        case .bookOpened: String(localized: "打开书")
        case .pageChanged: String(localized: "翻页")
        case .pageEnd: String(localized: "越过首末页")
        case .windowStateChanged: String(localized: "窗口状态变化")
        }
    }

    private static func kindTitle(_ kind: ExternalCommand.Kind) -> String {
        switch kind {
        case .application: String(localized: "应用")
        case .program: String(localized: "程序")
        case .shell: "Shell"
        }
    }

    private static func commandSubtitleDetail(_ command: ExternalCommand) -> String {
        switch command.kind {
        case .application:
            return (command.program as NSString?)?.lastPathComponent ?? ""
        case .program:
            let base = (command.program as NSString?)?.lastPathComponent ?? ""
            let args = command.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            return args.isEmpty ? base : "\(base) \(args)"
        case .shell:
            return command.arguments
        }
    }
}
