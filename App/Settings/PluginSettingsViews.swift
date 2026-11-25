import AppKit
import Foundation
import MVPlugins
import SwiftUI

/// 设置 › 扩展 页的「插件」一节：插件列表、状态、开关、⋯ 菜单、嵌套来源实例与目录页脚。
struct PluginsSettingsSection: View {
    let model: ExtensionsSettingsModel

    @State private var confirmingDeleteSourceID: UUID?
    var onRequestConsent: ((PluginInfo) -> Void)?
    var onRequestAddSource: ((PluginInfo, PluginSourceDeclaration) -> Void)?
    var onRequestEditSource: ((PluginInfo, PluginSourceDeclaration, SourceInstance) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(localized: "插件"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Theme.text2))
                Spacer(minLength: 8)
                Text(String(localized: "一个文件夹一个插件，放进插件目录后自动加载"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.text2))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)

            SettingsErrorBanner(message: model.pluginWriteError)

            SettingsCard {
                if model.plugins.isEmpty {
                    VStack(spacing: 4) {
                        Text(String(localized: "还没有插件"))
                            .font(Font(Theme.serif(14, weight: .semibold)))
                            .foregroundStyle(Color(nsColor: Theme.text))
                        Text(String(localized: "把包含 manifest.json 的插件文件夹放进插件目录，这里会马上列出来。"))
                            .font(.system(size: 12))
                            .foregroundStyle(Color(nsColor: Theme.text2))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                    .accessibilityIdentifier("settings.extensions.plugins.empty")
                } else {
                    ForEach(Array(model.plugins.enumerated()), id: \.element.id) { index, info in
                        if index > 0 { SettingsDivider() }
                        pluginBlock(info, isFirst: index == 0)
                    }
                }

                SettingsDivider()
                HStack(spacing: 8) {
                    Text(abbreviatedPath(model.pluginsDirectory))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(nsColor: Theme.text2))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(model.pluginsDirectory.path(percentEncoded: false))
                    Button(String(localized: "在 Finder 中显示")) {
                        model.revealPluginsFolder()
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.extensions.plugins.reveal")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.extensions.plugins")
    }

    // MARK: - 单个插件块（主行 + 可选来源实例）

    @ViewBuilder
    private func pluginBlock(_ info: PluginInfo, isFirst: Bool) -> some View {
        let status = model.pluginStatus(for: info)
        pluginRow(info, status: status, isFirst: isFirst)
        if let manifest = info.manifest, !manifest.sources.isEmpty {
            SettingsDivider()
            nestedSourcesBlock(info: info, manifest: manifest, status: status)
        }
    }

    private func pluginRow(_ info: PluginInfo, status: PluginStatus, isFirst: Bool) -> some View {
        let isInvalid: Bool = if case .invalid = status { true } else { false }
        let title = info.manifest?.name ?? info.id
        let subtitle = Self.subtitleText(for: info)
        let isRunning: Bool = if case .running = status { true } else { false }
        let isSwitchOn: Bool = switch status {
        case .ready, .running, .failed: true
        case .disabled, .needsConsent, .invalid: false
        }

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.text))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: isInvalid ? Theme.danger : Theme.text2))
                    .lineLimit(isInvalid ? 2 : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: isInvalid)
                    .help(subtitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let manifest = info.manifest {
                capabilityChips(for: manifest)
            }

            statusView(for: info, status: status)

            if !isInvalid {
                SettingsSwitch(
                    label: title,
                    isOn: Binding(
                        get: { isSwitchOn },
                        set: { newValue in
                            if newValue {
                                onRequestConsent?(info)
                            } else {
                                Task { await model.disablePlugin(info.id) }
                            }
                        }
                    )
                )
                .accessibilityIdentifier("settings.extensions.plugin.\(info.id).toggle")
            }

            moreMenu(for: info, isRunning: isRunning)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .padding(.vertical, 4)
        .background(isInvalid ? Color(nsColor: Theme.dangerSoft) : .clear)
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: isInvalid && isFirst ? 10 : 0,
            topTrailingRadius: isInvalid && isFirst ? 10 : 0
        ))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.extensions.plugin.\(info.id)")
    }

    @ViewBuilder
    private func capabilityChips(for manifest: PluginManifest) -> some View {
        if !manifest.sources.isEmpty {
            chip(String(localized: "来源"))
        }
        if !manifest.filters.isEmpty {
            chip(String(localized: "滤镜"))
        }
        if !manifest.commands.isEmpty {
            chip(String(localized: "命令 \(manifest.commands.count)"))
        }
    }

    @ViewBuilder
    private func statusView(for info: PluginInfo, status: PluginStatus) -> some View {
        switch status {
        case .disabled:
            HStack(spacing: 5) {
                Circle()
                    .fill(Color(nsColor: Theme.lineStrong))
                    .frame(width: 6, height: 6)
                Text(String(localized: "未启用"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.text2))
                    .fixedSize()
            }
            .accessibilityIdentifier("settings.extensions.plugin.\(info.id).status")

        case .ready:
            HStack(spacing: 5) {
                Circle()
                    .fill(Color(nsColor: ExtensionsSettingsPage.readyDotColor))
                    .frame(width: 6, height: 6)
                Text(String(localized: "就绪"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.text2))
                    .fixedSize()
            }
            .accessibilityIdentifier("settings.extensions.plugin.\(info.id).status")

        case let .running(since):
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.75)
                        .frame(width: 12, height: 12)
                    Text(String(localized: "运行中 \(ExtensionsSettingsPage.elapsedText(since: since, now: context.date))"))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Color(nsColor: Theme.text))
                        .fixedSize()
                }
            }
            .accessibilityIdentifier("settings.extensions.plugin.\(info.id).status")
            Button(String(localized: "停止")) {
                model.stopPlugin(info.id)
            }
            .controlSize(.small)
            .accessibilityIdentifier("settings.extensions.plugin.\(info.id).stop")

        case .needsConsent:
            Text(String(localized: "权限有变，需重新同意"))
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Theme.text2))
                .fixedSize()
                .accessibilityIdentifier("settings.extensions.plugin.\(info.id).status")
            Button(String(localized: "查看…")) {
                onRequestConsent?(info)
            }
            .controlSize(.small)
            .accessibilityIdentifier("settings.extensions.plugin.\(info.id).review")

        case .invalid:
            Text(String(localized: "清单错误"))
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Theme.danger))
                .fixedSize()
                .accessibilityIdentifier("settings.extensions.plugin.\(info.id).status")

        case let .failed(message):
            Text(String(localized: "运行出错"))
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Theme.danger))
                .fixedSize()
                .help(message)
                .accessibilityIdentifier("settings.extensions.plugin.\(info.id).status")
        }
    }

    private func moreMenu(for info: PluginInfo, isRunning: Bool) -> some View {
        Menu {
            Button(String(localized: "在 Finder 中显示")) {
                model.revealPluginFolder(info)
            }
            Button(String(localized: "打开 manifest.json")) {
                model.openPluginManifest(info)
            }
            if isRunning {
                Divider()
                Button(String(localized: "停止")) {
                    model.stopPlugin(info.id)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Theme.text2))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("settings.extensions.plugin.\(info.id).menu")
    }

    // MARK: - 嵌套来源实例

    private func nestedSourcesBlock(info: PluginInfo, manifest: PluginManifest, status: PluginStatus) -> some View {
        let isEnabled: Bool = switch status {
        case .ready, .running, .failed: true
        case .disabled, .needsConsent, .invalid: false
        }
        let instances = model.sources(for: info.id)

        return VStack(spacing: 0) {
            ForEach(Array(instances.enumerated()), id: \.element.id) { index, instance in
                if index > 0 { SettingsDivider() }
                sourceRow(info: info, manifest: manifest, instance: instance, isEnabled: isEnabled)
            }
            if !instances.isEmpty {
                SettingsDivider()
            }
            HStack(spacing: 8) {
                if !isEnabled {
                    Text(String(localized: "请先启用插件再添加或打开来源"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: Theme.text2))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                addSourceButton(info: info, declarations: manifest.sources)
            }
            .padding(.vertical, 6)
        }
        .padding(.leading, 28)
        .padding(.trailing, 12)
        .padding(.vertical, 2)
        .background(Color(nsColor: Theme.well))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.extensions.plugin.\(info.id).sources")
    }

    private func sourceRow(
        info: PluginInfo,
        manifest: PluginManifest,
        instance: SourceInstance,
        isEnabled: Bool
    ) -> some View {
        let declaration = manifest.sources.first { $0.id == instance.type }
        let summary = Self.sourceSummary(instance: instance, declaration: declaration)
        let isConfirmingDelete = confirmingDeleteSourceID == instance.id
        let idString = instance.id.uuidString

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.text))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(nsColor: Theme.text2))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(summary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isConfirmingDelete {
                Text(String(localized: "删除？"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.danger))
                    .fixedSize()
                Button(String(localized: "取消")) {
                    confirmingDeleteSourceID = nil
                }
                .controlSize(.small)
                .accessibilityIdentifier("settings.extensions.source.\(idString).cancelDelete")
                Button(String(localized: "确认删除")) {
                    confirmingDeleteSourceID = nil
                    Task { await model.deleteSource(id: instance.id) }
                }
                .controlSize(.small)
                .foregroundStyle(Color(nsColor: Theme.danger))
                .accessibilityIdentifier("settings.extensions.source.\(idString).confirmDelete")
            } else {
                Button(String(localized: "打开")) {
                    model.openSource(instance.id)
                }
                .controlSize(.small)
                .disabled(!isEnabled)
                .accessibilityIdentifier("settings.extensions.source.\(idString).open")

                if let declaration {
                    SettingsIconButton(
                        systemImage: "pencil",
                        help: String(localized: "编辑")
                    ) {
                        confirmingDeleteSourceID = nil
                        onRequestEditSource?(info, declaration, instance)
                    }
                    .accessibilityIdentifier("settings.extensions.source.\(idString).edit")
                }

                SettingsIconButton(
                    systemImage: "minus",
                    help: String(localized: "删除")
                ) {
                    confirmingDeleteSourceID = instance.id
                }
                .accessibilityIdentifier("settings.extensions.source.\(idString).delete")
            }
        }
        .frame(minHeight: 36)
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.extensions.source.\(idString)")
    }

    @ViewBuilder
    private func addSourceButton(info: PluginInfo, declarations: [PluginSourceDeclaration]) -> some View {
        if declarations.count == 1, let only = declarations.first {
            Button(String(localized: "＋ 添加来源")) {
                confirmingDeleteSourceID = nil
                onRequestAddSource?(info, only)
            }
            .controlSize(.small)
            .accessibilityIdentifier("settings.extensions.plugin.\(info.id).addSource")
        } else {
            Menu(String(localized: "＋ 添加来源")) {
                ForEach(declarations) { declaration in
                    Button(declaration.name) {
                        confirmingDeleteSourceID = nil
                        onRequestAddSource?(info, declaration)
                    }
                }
            }
            .controlSize(.small)
            .fixedSize()
            .accessibilityIdentifier("settings.extensions.plugin.\(info.id).addSource")
        }
    }

    // MARK: - 小组件与格式化

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

    private func abbreviatedPath(_ url: URL) -> String {
        (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    static func subtitleText(for info: PluginInfo) -> String {
        if let problem = info.problem {
            return formatProblem(problem)
        }
        guard let manifest = info.manifest else {
            return info.id
        }
        let runtimeText: String = switch manifest.runtime {
        case .javascript: "JavaScript"
        case .process: String(localized: "外部程序")
        }
        var parts = [info.id, manifest.version, runtimeText]
        if let desc = manifest.description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            parts.append(desc)
        }
        return parts.joined(separator: " · ")
    }

    static func formatProblem(_ problem: PluginProblem) -> String {
        if let line = problem.line, let column = problem.column {
            return String(localized: "\(problem.file) 第 \(line) 行，第 \(column) 列：\(problem.message)")
        }
        if let line = problem.line {
            return String(localized: "\(problem.file) 第 \(line) 行：\(problem.message)")
        }
        return String(localized: "\(problem.file)：\(problem.message)")
    }

    static func sourceSummary(instance: SourceInstance, declaration: PluginSourceDeclaration?) -> String {
        if let declaration {
            let parts = declaration.fields.compactMap { field -> String? in
                guard field.type != .password else { return nil }
                let value = instance.values[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return value.isEmpty ? nil : value
            }
            return parts.joined(separator: " · ")
        }
        return instance.values
            .sorted { $0.key < $1.key }
            .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
