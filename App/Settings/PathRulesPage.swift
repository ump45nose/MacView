import AppKit
import MVFoundation
import MVSettings
import SwiftUI

/// 路径规则：左边是规则列表，右边编辑选中的规则。
struct PathRulesPage: View {
    let model: SettingsModel
    @State private var selection: UUID?

    private var selected: PathRule? {
        model.rules.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("为一个文件夹里的所有书设默认值。多条规则同时匹配时，路径越具体越优先；书自己的设置仍优先于规则。")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Theme.text2))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                ruleList
                if let rule = selected {
                    RuleEditor(model: model, rule: rule)
                        .id(rule.id)
                } else {
                    Text("选择或添加一条规则")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: Theme.text2))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            HStack {
                Text("规则保存在 path-rules.json，可以直接编辑，保存后自动重载。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.text2))
                Spacer()
                Button("在访达中显示") { revealInFinder(model.supportDirectory.appending(path: "path-rules.json")) }
                    .controlSize(.small)
            }
        }
        .padding(16)
        .onAppear { if selection == nil { selection = model.displayedRules.first?.rule.id } }
    }

    private var ruleList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.displayedRules, id: \.rule.id) { item in
                        Button { selection = item.rule.id } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.rule.name).font(.system(size: 13, weight: item.rule.id == selection ? .semibold : .regular))
                                Text(String(localized: "\(OverrideField.all.filter { $0.isSet(item.rule.settings) }.count) 项"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(nsColor: Theme.text2))
                            }
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 8 + CGFloat(item.depth) * 16)
                            .padding(.trailing, 8)
                            .padding(.vertical, 5)
                            .background(item.rule.id == selection ? Color(nsColor: Theme.selected) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
            SettingsDivider()
            HStack(spacing: 2) {
                Button {
                    chooseFolder { url in
                        Task { if let id = await model.addRule(folder: url) { selection = id } }
                    }
                } label: {
                    Image(systemName: "plus").frame(width: 24, height: 22).contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "添加规则"))
                Button {
                    if let selection { model.delete(selection) }
                    selection = model.displayedRules.first?.rule.id
                } label: {
                    Image(systemName: "minus").frame(width: 24, height: 22).contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "删除所选规则"))
                .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.plain)
            .padding(4)
        }
        .frame(width: 180)
        .background(Color(nsColor: Theme.raised), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: Theme.line), lineWidth: 0.5))
    }
}

/// 选目录。
@MainActor
private func chooseFolder(_ done: @escaping (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.begin { response in
        if response == .OK, let url = panel.url { done(url) }
    }
}

private struct RuleEditor: View {
    let model: SettingsModel
    let rule: PathRule
    @State private var name = ""

    private var overrides: [OverrideField] {
        OverrideField.all.filter { $0.isSet(rule.settings) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("名称").font(.system(size: 13)).frame(width: 48, alignment: .leading)
                    TextField(String(localized: "名称"), text: $name)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(maxWidth: 220)
                        .onSubmit { commitName() }
                }
                HStack(alignment: .top) {
                    Text("文件夹").font(.system(size: 13)).frame(width: 48, alignment: .leading)
                    Text(rule.prefix.description)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(nsColor: Theme.text2))
                        .textSelection(.enabled)
                    Spacer()
                    Button("选择…") {
                        chooseFolder { url in
                            Task { await model.setFolder(of: rule.id, to: url) }
                        }
                    }
                    .controlSize(.small)
                }
                HStack {
                    Text("覆盖的设置").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(nsColor: Theme.text2))
                    Text("没有列出的项沿用上一层").font(.system(size: 11)).foregroundStyle(Color(nsColor: Theme.text2))
                }
                VStack(spacing: 0) {
                    if overrides.isEmpty {
                        Text("没有覆盖项。这条规则下的书沿用上一层的设置。")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(nsColor: Theme.text2))
                            .padding(14)
                    }
                    ForEach(Array(overrides.enumerated()), id: \.element.id) { index, field in
                        if index > 0 { SettingsDivider() }
                        overrideRow(field)
                    }
                }
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: Theme.raised), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: Theme.line), lineWidth: 0.5))
                Menu("添加覆盖项") {
                    ForEach(OverrideField.all.filter { !$0.isSet(rule.settings) }) { field in
                        Button(field.title) {
                            let inherited = model.inherited(by: rule)
                            model.updateOverrides(of: rule.id) { field.seed(&$0, inherited) }
                        }
                    }
                }
                .controlSize(.small)
                .fixedSize()
                .disabled(overrides.count == OverrideField.all.count)
            }
            .padding(.vertical, 2)
        }
        .onAppear { name = rule.name }
        .onDisappear(perform: commitName)
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            name = rule.name
        } else if trimmed != rule.name {
            model.rename(rule.id, to: trimmed)
        }
    }

    private func overrideRow(_ field: OverrideField) -> some View {
        HStack(spacing: 10) {
            Text(field.title).font(.system(size: 12)).frame(width: 64, alignment: .leading)
            control(field)
            Text(model.origin(of: field, in: rule))
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Theme.text2))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                model.updateOverrides(of: rule.id) { field.clear(&$0) }
            } label: {
                Image(systemName: "xmark").font(.system(size: 9)).frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "移除覆盖：\(field.title)"))
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 38)
    }

    @ViewBuilder
    private func control(_ field: OverrideField) -> some View {
        let resolved = model.resolved(for: rule)
        switch field.control {
        case let .choice(options):
            Menu(field.text(resolved)) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Button(option.title) { model.updateOverrides(of: rule.id, option.apply) }
                }
            }
            .controlSize(.small)
            .fixedSize()
        case let .toggle(get, set):
            Toggle(field.title, isOn: Binding(
                get: { get(resolved) },
                set: { value in model.updateOverrides(of: rule.id) { set(&$0, value) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
    }
}
