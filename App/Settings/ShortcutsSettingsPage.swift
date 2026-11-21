import AppKit
import Carbon.HIToolbox
import MVCommands
import MVSettings
import Observation
import SwiftUI

/// 快捷键设置页的数据与录制状态。
@MainActor
@Observable
final class ShortcutsModel {
    struct RowID: Hashable {
        var command: CommandID
        var scope: InputScope
    }

    struct Row: Identifiable {
        var id: RowID { RowID(command: command, scope: scope) }
        var command: CommandID
        var title: String
        var scope: InputScope
        var bindings: [KeyBinding]
        var isModified: Bool
    }

    struct Section: Identifiable {
        var id: InputScope { scope }
        var scope: InputScope
        var title: String
        var rows: [Row]
    }

    struct PendingConflict: Equatable {
        var target: RowID
        var candidate: KeyBinding
        var conflicts: [KeyBinding]
    }

    static let scopeOrder: [InputScope] = [.viewer, .global, .list, .classify]

    var searchText = ""
    var scopeFilter: InputScope?
    private(set) var file: KeyBindingsFile
    private(set) var recordingTarget: RowID?
    private(set) var recordedChords: [KeyChord] = []
    private(set) var pendingConflict: PendingConflict?
    private(set) var errorMessage: String?

    @ObservationIgnored private let store: JSONDocumentStore<KeyBindingsFile>?
    @ObservationIgnored private let descriptors: [CommandDescriptor]
    @ObservationIgnored private let descriptorsByID: [CommandID: CommandDescriptor]
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    @ObservationIgnored private var sequenceTimer: Task<Void, Never>?
    @ObservationIgnored private let maxSequenceLength = 4

    init(store: JSONDocumentStore<KeyBindingsFile>?) {
        self.store = store
        self.file = store?.value() ?? KeyBindingsFile()
        let all = CoreCommands.all + CommandCatalog.appCommands
        self.descriptors = all
        self.descriptorsByID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let store {
            let changes = store.changes()
            changesTask = Task { [weak self] in
                for await change in changes {
                    guard let self, !Task.isCancelled else { return }
                    if case .reloaded = change {
                        self.file = store.value()
                    }
                }
            }
        }
    }

    deinit {
        changesTask?.cancel()
        sequenceTimer?.cancel()
    }

    func reload() {
        if let store {
            file = store.value()
        }
    }

    var effectiveBindings: [KeyBinding] {
        KeyBinding.effective(defaults: descriptors, user: file.bindings).filter { !$0.sequence.isEmpty }
    }

    var hasAnyCustomBindings: Bool {
        !file.bindings.isEmpty
    }

    var sections: [Section] {
        let effective = effectiveBindings
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let compactQuery = query.replacingOccurrences(of: " ", with: "")
        let activeScopes = scopeFilter.map { [$0] } ?? Self.scopeOrder

        var grouped: [InputScope: [Row]] = [:]
        for descriptor in descriptors {
            let title = commandTitle(of: descriptor.id)
            let cmdEffective = effective.filter { $0.command == descriptor.id }
            let cmdDefaults = descriptor.defaultBindings
            let scopes = scopesForCommand(descriptor, effective: cmdEffective)

            for scope in scopes where activeScopes.contains(scope) {
                let rowBindings = cmdEffective.filter { $0.scope == scope }
                let defaultRowBindings = cmdDefaults.filter { $0.scope == scope }
                let modified = Set(rowBindings) != Set(defaultRowBindings)

                if !query.isEmpty {
                    let matchesTitle = title.lowercased().contains(query)
                    let matchesID = descriptor.id.rawValue.lowercased().contains(query)
                    let matchesKey = rowBindings.contains { binding in
                        let display = Self.displayText(for: binding.sequence).lowercased()
                        return display.contains(query) || display.replacingOccurrences(of: " ", with: "").contains(compactQuery)
                    }
                    guard matchesTitle || matchesID || matchesKey else { continue }
                }

                grouped[scope, default: []].append(Row(
                    command: descriptor.id,
                    title: title,
                    scope: scope,
                    bindings: rowBindings,
                    isModified: modified
                ))
            }
        }

        return activeScopes.compactMap { scope in
            guard let rows = grouped[scope], !rows.isEmpty else { return nil }
            return Section(scope: scope, title: Self.scopeTitle(for: scope), rows: rows)
        }
    }

    // MARK: 录制

    func startRecording(command: CommandID, scope: InputScope) {
        sequenceTimer?.cancel()
        sequenceTimer = nil
        pendingConflict = nil
        recordedChords = []
        recordingTarget = RowID(command: command, scope: scope)
    }

    func cancelRecording() {
        sequenceTimer?.cancel()
        sequenceTimer = nil
        recordingTarget = nil
        recordedChords = []
    }

    func handleRecordedEvent(_ event: NSEvent) -> Bool {
        guard recordingTarget != nil, event.type == .keyDown else { return false }
        let modifiers = KeyMapping.modifiers(for: event.modifierFlags)
        if Int(event.keyCode) == kVK_Escape && modifiers.isEmpty {
            if recordedChords.isEmpty {
                cancelRecording()
            } else {
                finishRecording()
            }
            return true
        }
        guard let chord = KeyMapping.chord(for: event) else { return true }
        recordedChords.append(chord)
        sequenceTimer?.cancel()
        if recordedChords.count >= maxSequenceLength {
            finishRecording()
        } else {
            sequenceTimer = Task { [weak self] in
                try? await Task.sleep(for: CommandCatalog.sequenceTimeout)
                guard let self, !Task.isCancelled else { return }
                self.finishRecording()
            }
        }
        return true
    }

    func finishRecording() {
        sequenceTimer?.cancel()
        sequenceTimer = nil
        guard let target = recordingTarget else { return }
        let sequence = recordedChords
        recordingTarget = nil
        recordedChords = []
        guard !sequence.isEmpty else { return }
        proposeBinding(sequence: sequence, for: target.command, scope: target.scope)
    }

    // MARK: 冲突与写回

    func proposeBinding(sequence: [KeyChord], for command: CommandID, scope: InputScope) {
        let candidate = KeyBinding(sequence: sequence, command: command, scope: scope)
        let current = effectiveBindings
        if current.contains(where: { $0.command == command && $0.scope == scope && $0.sequence == sequence }) {
            pendingConflict = nil
            return
        }

        let conflicts = BindingResolver.conflicts(in: current + [candidate]).compactMap { conflict -> KeyBinding? in
            if conflict.first == candidate, conflict.second != candidate {
                return conflict.second
            }
            if conflict.second == candidate, conflict.first != candidate {
                return conflict.first
            }
            return nil
        }

        if !conflicts.isEmpty {
            pendingConflict = PendingConflict(
                target: RowID(command: command, scope: scope),
                candidate: candidate,
                conflicts: conflicts
            )
            return
        }

        pendingConflict = nil
        applyCommandChanges { bindings in
            var list = bindings[command] ?? []
            list.append(candidate)
            bindings[command] = list
        }
    }

    func resolveConflictByReplacing() {
        guard let pending = pendingConflict else { return }
        pendingConflict = nil
        let conflicts = Set(pending.conflicts)
        let candidate = pending.candidate
        applyCommandChanges { bindings in
            for conflict in conflicts {
                bindings[conflict.command]?.removeAll { $0 == conflict }
            }
            var targetList = bindings[candidate.command] ?? []
            if !targetList.contains(candidate) {
                targetList.append(candidate)
            }
            bindings[candidate.command] = targetList
        }
    }

    func dismissConflict() {
        pendingConflict = nil
    }

    func removeBinding(_ binding: KeyBinding) {
        pendingConflict = nil
        applyCommandChanges { bindings in
            bindings[binding.command]?.removeAll { $0 == binding }
        }
    }

    func resetCommand(_ command: CommandID, scope: InputScope) {
        pendingConflict = nil
        let defaultsForScope = descriptorsByID[command]?.defaultBindings.filter { $0.scope == scope } ?? []
        applyCommandChanges { bindings in
            var list = (bindings[command] ?? []).filter { $0.scope != scope }
            list.append(contentsOf: defaultsForScope)
            bindings[command] = list
        }
    }

    func resetAll() {
        cancelRecording()
        pendingConflict = nil
        persist(bindings: [])
    }

    func conflictDescription(for conflict: PendingConflict) -> String {
        let keyText = Self.displayText(for: conflict.candidate.sequence)
        guard let first = conflict.conflicts.first else { return "" }
        let title = commandTitle(of: first.command)
        let scope = Self.scopeTitle(for: first.scope)
        if conflict.conflicts.count == 1 {
            return String(localized: "“\(keyText)”已用于“\(title)”（\(scope)）")
        }
        return String(localized: "“\(keyText)”与“\(title)”等 \(conflict.conflicts.count) 项绑定冲突（\(scope)）")
    }

    func commandTitle(of id: CommandID) -> String {
        if id == .fileRename { return String(localized: "重命名…") }
        if id == .searchIndexFolder { return String(localized: "为此文件夹建立索引") }
        return descriptorsByID[id].map { String(localized: $0.title) } ?? id.rawValue
    }

    static func displayText(for sequence: [KeyChord]) -> String {
        sequence.map(KeyMapping.displayName(for:)).joined(separator: " ")
    }

    static func scopeTitle(for scope: InputScope) -> String {
        switch scope {
        case .global: String(localized: "全局")
        case .viewer: String(localized: "查看器")
        case .list: String(localized: "列表")
        case .classify: String(localized: "分类")
        case .textInput: String(localized: "文本输入")
        }
    }

    // MARK: 内部辅助

    private func scopesForCommand(_ descriptor: CommandDescriptor, effective: [KeyBinding]) -> [InputScope] {
        var scopes: [InputScope] = []
        for binding in descriptor.defaultBindings + effective where !scopes.contains(binding.scope) && binding.scope != .textInput {
            scopes.append(binding.scope)
        }
        if scopes.isEmpty {
            let inferred: InputScope = switch descriptor.category {
            case "window", "other", "search", "edit": .global
            default: .viewer
            }
            scopes.append(inferred)
        }
        return scopes
    }

    private func applyCommandChanges(_ mutate: (inout [CommandID: [KeyBinding]]) -> Void) {
        let currentEffective = effectiveBindings
        var byCommand: [CommandID: [KeyBinding]] = [:]
        for descriptor in descriptors {
            byCommand[descriptor.id] = currentEffective.filter { $0.command == descriptor.id }
        }
        let before = byCommand
        mutate(&byCommand)

        var nextUser = file.bindings
        for (command, nextList) in byCommand where before[command] != nextList {
            nextUser.removeAll { $0.command == command }
            let defaults = descriptorsByID[command]?.defaultBindings ?? []
            if Set(nextList) == Set(defaults) {
                continue
            }
            if nextList.isEmpty {
                if let fallbackScope = defaults.first?.scope {
                    nextUser.append(KeyBinding(sequence: [], command: command, scope: fallbackScope))
                }
            } else {
                nextUser.append(contentsOf: nextList)
            }
        }
        persist(bindings: nextUser)
    }

    private func persist(bindings: [KeyBinding]) {
        file.bindings = bindings
        guard let store else { return }
        Task { [weak self] in
            do {
                try await store.update { $0.bindings = bindings }
                self?.errorMessage = nil
            } catch {
                self?.errorMessage = ErrorText.describe(error)
            }
        }
    }
}

// MARK: - 快捷键设置页视图

struct ShortcutsSettingsPage: View {
    @Bindable var model: ShortcutsModel

    private static var scopeOptions: [(String, InputScope?)] {
        [(String(localized: "全部作用域"), nil)] + ShortcutsModel.scopeOrder.map { (ShortcutsModel.scopeTitle(for: $0), $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("每个命令可以有多个快捷键，支持多键序列（依次按下）。改动立即生效并写入 keybindings.json。")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Theme.text2))

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: Theme.text2))
                    TextField(String(localized: "搜索命令或按键"), text: $model.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 8)
                .frame(width: 220, height: 24)
                .background(Color(nsColor: Theme.raised), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: Theme.line), lineWidth: 0.5))

                SettingsPopup(
                    label: String(localized: "作用域"),
                    options: Self.scopeOptions,
                    selection: $model.scopeFilter
                )

                Spacer()

                Button(String(localized: "全部恢复默认")) {
                    model.resetAll()
                }
                .controlSize(.small)
                .disabled(!model.hasAnyCustomBindings)
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.danger))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: Theme.dangerSoft), in: RoundedRectangle(cornerRadius: 6))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let sections = model.sections
                    if sections.isEmpty {
                        Text("没有匹配的命令")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(nsColor: Theme.text2))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 32)
                    } else {
                        ForEach(sections) { section in
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(nsColor: Theme.text2))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color(nsColor: Theme.well))

                            ForEach(section.rows) { row in
                                SettingsDivider()
                                ShortcutRowView(row: row, model: model)
                            }
                        }
                    }
                }
                .background(Color(nsColor: Theme.raised))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: Theme.line), lineWidth: 0.5))
            }

            Text("点按键标签可删除；“＋”开始录制，1 秒内继续按键组成序列，Esc 结束录制。恢复默认按钮可还原这一项的默认值。")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Theme.text2))
        }
        .padding(16)
        .background(
            KeyCaptureView(isRecording: model.recordingTarget != nil) { event in
                model.handleRecordedEvent(event)
            }
            .frame(width: 0, height: 0)
        )
        .onAppear { model.reload() }
        .onDisappear { model.cancelRecording() }
    }
}

private struct ShortcutRowView: View {
    let row: ShortcutsModel.Row
    let model: ShortcutsModel

    private var isRecording: Bool {
        model.recordingTarget == row.id
    }

    private var conflict: ShortcutsModel.PendingConflict? {
        model.pendingConflict?.target == row.id ? model.pendingConflict : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text(row.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(nsColor: Theme.text))
                        .lineLimit(1)
                    if row.isModified {
                        Text(String(localized: "· 已改"))
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: Theme.text2))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    if row.bindings.isEmpty && !isRecording {
                        Text("未设置")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: Theme.text2))
                    }
                    ForEach(row.bindings, id: \.self) { binding in
                        Button {
                            model.removeBinding(binding)
                        } label: {
                            HStack(spacing: 3) {
                                ForEach(Array(binding.sequence.enumerated()), id: \.offset) { _, chord in
                                    KeyCapLabel(text: KeyMapping.displayName(for: chord))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "点击删除"))
                    }

                    if isRecording {
                        let text = model.recordedChords.isEmpty
                            ? String(localized: "按下新的按键…")
                            : ShortcutsModel.displayText(for: model.recordedChords) + " …"
                        Text(text)
                            .font(.system(size: 11, design: model.recordedChords.isEmpty ? .default : .monospaced))
                            .foregroundStyle(Color(nsColor: Theme.text))
                            .padding(.horizontal, 6)
                            .frame(height: 22)
                            .background(Color(nsColor: Theme.accentSoft), in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: Theme.accent), lineWidth: 1.5))
                    } else {
                        Button {
                            model.startRecording(command: row.command, scope: row.scope)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color(nsColor: Theme.text2))
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "添加快捷键"))
                    }
                }
                .frame(minWidth: 200, alignment: .trailing)

                Group {
                    if row.isModified {
                        Button {
                            model.resetCommand(row.command, scope: row.scope)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(nsColor: Theme.text2))
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "恢复默认"))
                    } else {
                        Color.clear.frame(width: 22, height: 22)
                    }
                }
            }

            if let conflict {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(model.conflictDescription(for: conflict))
                        .font(.system(size: 11))
                    Spacer(minLength: 4)
                    Button(String(localized: "替换")) {
                        model.resolveConflictByReplacing()
                    }
                    .controlSize(.mini)
                    Button(String(localized: "取消")) {
                        model.dismissConflict()
                    }
                    .controlSize(.mini)
                }
                .foregroundStyle(Color(nsColor: Theme.danger))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(nsColor: Theme.dangerSoft), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minHeight: 30)
    }
}

private struct KeyCapLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color(nsColor: Theme.text))
            .padding(.horizontal, 5)
            .frame(minHeight: 20)
            .background(Color(nsColor: Theme.ground), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: Theme.line), lineWidth: 1))
    }
}

/// 录制快捷键时成为第一响应者，捕获普通按键与带修饰键的组合键。
private struct KeyCaptureView: NSViewRepresentable {
    var isRecording: Bool
    var onKeyDown: (NSEvent) -> Bool

    func makeNSView(context: Context) -> CaptureNSView {
        let view = CaptureNSView()
        view.isRecording = isRecording
        view.onKeyDown = onKeyDown
        return view
    }

    func updateNSView(_ nsView: CaptureNSView, context: Context) {
        nsView.isRecording = isRecording
        nsView.onKeyDown = onKeyDown
        if isRecording, let window = nsView.window, window.firstResponder !== nsView {
            window.makeFirstResponder(nsView)
        }
    }

    final class CaptureNSView: NSView {
        var isRecording = false
        var onKeyDown: ((NSEvent) -> Bool)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if isRecording, let window, window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return super.performKeyEquivalent(with: event) }
            return onKeyDown?(event) ?? false
        }

        override func keyDown(with event: NSEvent) {
            if isRecording, onKeyDown?(event) == true {
                return
            }
            super.keyDown(with: event)
        }
    }
}
