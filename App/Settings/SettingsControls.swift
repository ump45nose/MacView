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
