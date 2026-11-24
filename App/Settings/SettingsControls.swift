import AppKit
import MVCommands
import MVSettings
import Observation
import SwiftUI

@MainActor
@Observable
private final class SettingsCommandCatalogStore {
    var descriptors: [CommandDescriptor] = CommandCatalog.builtInCommands
    var byID: [CommandID: CommandDescriptor] = Dictionary(
        CommandCatalog.builtInCommands.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
    )
}

/// 设置页共享的命令清单与标题/图标查找，避免各页重复构建全量字典。
@MainActor
enum SettingsCommandCatalog {
    private static let store = SettingsCommandCatalogStore()

    static var all: [CommandDescriptor] { store.descriptors }

    static func reload(from registry: CommandRegistry?) {
        let list = registry?.descriptors() ?? []
        let effective = list.isEmpty ? CommandCatalog.builtInCommands : list
        store.descriptors = effective
        store.byID = Dictionary(effective.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func descriptor(of id: CommandID) -> CommandDescriptor? { store.byID[id] }

    static func title(of id: CommandID) -> String {
        if let descriptor = store.byID[id] ?? CommandCatalog.builtInDescriptor(id) {
            return CommandCatalog.displayTitle(for: descriptor)
        }
        return id.rawValue
    }

    static func symbol(of id: CommandID) -> String {
        if let symbol = (store.byID[id] ?? CommandCatalog.builtInDescriptor(id))?.symbol, !symbol.isEmpty { return symbol }
        return "command"
    }
}

/// 串行持久化与外部重载桥接：按顺序落盘，写入失败时从 store 回滚内存状态并报告错误。
@MainActor
final class DocumentStoreBridge<Value: Codable & Sendable> {
    private let store: JSONDocumentStore<Value>?
    private let onSync: @MainActor (Value) -> Void
    private let onError: @MainActor (String?) -> Void
    private var changesTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var pendingWrites = 0

    init(
        store: JSONDocumentStore<Value>?,
        onSync: @escaping @MainActor (Value) -> Void,
        onError: @escaping @MainActor (String?) -> Void
    ) {
        self.store = store
        self.onSync = onSync
        self.onError = onError
        if let store {
            let changes = store.changes()
            changesTask = Task { [weak self] in
                for await change in changes {
                    guard let self, !Task.isCancelled else { return }
                    if case .reloaded = change, self.pendingWrites == 0 {
                        self.onSync(store.value())
                    }
                }
            }
        }
    }

    deinit { changesTask?.cancel() }

    func reload() {
        if let store, pendingWrites == 0 { onSync(store.value()) }
    }

    func persist(_ mutate: @escaping @Sendable (inout Value) -> Void) {
        guard let store else { return }
        pendingWrites += 1
        let previous = persistTask
        persistTask = Task { [weak self] in
            _ = await previous?.value
            do {
                try await store.update(mutate)
                guard let self else { return }
                self.pendingWrites -= 1
                self.onError(nil)
            } catch {
                guard let self else { return }
                self.pendingWrites -= 1
                self.onError(ErrorText.describe(error))
                if self.pendingWrites == 0 {
                    self.onSync(store.value())
                }
            }
        }
    }
}

/// 设置页卡片内错误提示条。
struct SettingsErrorBanner: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Theme.danger))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: Theme.dangerSoft), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// 设置页搜索输入框。
struct SettingsSearchField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Theme.text2))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: 24)
        .background(Color(nsColor: Theme.raised), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: Theme.line), lineWidth: 0.5))
    }
}

/// 设置页行内 22×22 小图标按钮。
struct SettingsIconButton: View {
    let systemImage: String
    var fontSize: CGFloat = 11
    var weight: Font.Weight = .regular
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: fontSize, weight: weight))
                .foregroundStyle(Color(nsColor: Theme.text2))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 绑定冲突提示条（带替换与取消操作）。
struct SettingsConflictBanner: View {
    let message: String
    var replaceDisabled = false
    let onReplace: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
            Text(message)
                .font(.system(size: 11))
            Spacer(minLength: 4)
            Button(String(localized: "替换"), action: onReplace)
                .controlSize(.mini)
                .disabled(replaceDisabled)
            Button(String(localized: "取消"), action: onCancel)
                .controlSize(.mini)
        }
        .foregroundStyle(Color(nsColor: Theme.danger))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: Theme.dangerSoft), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// 设置页的分组：小标题加圆角卡片。
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: Theme.text2))
                .padding(.horizontal, 12)
            SettingsCard { content }
        }
    }
}

/// 没有小标题的卡片。
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color(nsColor: Theme.raised), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: Theme.line), lineWidth: 0.5))
    }
}

/// 一行设置：左边是名称和说明，右边是控件。
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: Theme.text2))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
        .padding(.vertical, 2)
    }
}

/// 卡片内的分隔线。
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Color(nsColor: Theme.line)).frame(height: 0.5)
    }
}

/// 分段选择：凹槽里选中项是抬起的底。
struct SettingsSegments<Value: Hashable>: View {
    let label: String
    let options: [(String, Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.1) { option in
                let isSelected = option.1 == selection
                Button(option.0) { selection = option.1 }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Color(nsColor: isSelected ? Theme.text : Theme.text2))
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(isSelected ? Color(nsColor: Theme.raised) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color(nsColor: Theme.well), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: Theme.line), lineWidth: 0.5))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// 下拉选择。
struct SettingsPopup<Value: Hashable>: View {
    let label: String
    let options: [(String, Value)]
    @Binding var selection: Value

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(options, id: \.1) { Text($0.0).tag($0.1) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
    }
}

/// 开关。
struct SettingsSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.switch)
            .tint(Color(nsColor: Theme.accent))
            .labelsHidden()
            .controlSize(.small)
    }
}

/// 数字步进：前缀文字、带单位的数值，加减按钮。
struct SettingsStepper: View {
    var prefix: String?
    let format: (Int) -> String
    let range: ClosedRange<Int>
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 6) {
            if let prefix { Text(prefix) }
            Text(format(value))
                .font(.system(size: 12).monospacedDigit())
            Stepper(prefix ?? format(value), value: $value, in: range)
                .labelsHidden()
                .controlSize(.small)
        }
        .font(.system(size: 12))
        .foregroundStyle(Color(nsColor: Theme.text2))
    }
}

/// 字节预算的选项；当前值不在列表里时补进去，外部改过文件也能显示。
func budgetOptions(_ bytes: [Int64], current: Int64) -> [(String, Int64)] {
    let values = bytes.contains(current) ? bytes : (bytes + [current]).sorted()
    return values.map { (ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary), $0) }
}

/// 在访达中显示。
func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}
