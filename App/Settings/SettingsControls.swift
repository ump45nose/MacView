import AppKit
import SwiftUI

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
            VStack(spacing: 0) {
                content
            }
            .background(Color(nsColor: Theme.raised), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: Theme.line), lineWidth: 0.5))
        }
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

/// 分段选择。
struct SettingsSegments<Value: Hashable>: View {
    let label: String
    let options: [(String, Value)]
    @Binding var selection: Value

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(options, id: \.1) { Text($0.0).tag($0.1) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
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
            .labelsHidden()
            .controlSize(.small)
    }
}

/// 数字步进：前后缀文字，加减按钮。
struct SettingsStepper: View {
    var prefix: String?
    let suffix: String
    let range: ClosedRange<Int>
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 6) {
            if let prefix { Text(prefix) }
            Text("\(value)")
                .font(.system(size: 12).monospacedDigit())
                .frame(minWidth: 18, alignment: .trailing)
            Text(suffix)
            Stepper(prefix ?? suffix, value: $value, in: range)
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
