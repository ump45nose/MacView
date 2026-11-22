import AppKit
import MVLayout
import MVSettings
import SwiftUI

enum AppearanceSettingsSection: String {
    case theme
    case fonts
    case window
    case schemes
}

/// 设置 › 外观：主题、字体、窗口、布局方案。
struct AppearanceSettingsPage: View {
    let model: SettingsModel
    let scrollTarget: SettingsWindowState.ScrollTarget?

    @State private var fontRevision = 0
    @State private var renamingScheme: String?
    @State private var renameText = ""
    @State private var renameError: String?
    @State private var pendingDeleteScheme: String?
    @State private var showingSaveSheet = false
    @State private var saveNameText = ""
    @State private var saveError: String?
    @State private var actionError: String?
    @FocusState private var renameFieldFocused: Bool

    private static let availableFontFamilies: [String] = NSFontManager.shared.availableFontFamilies.sorted()
    #if DEBUG
    static let debugSchemeActionNotification = Notification.Name("MacView.Debug.AppearanceSchemeAction")
    #endif

    private static let modeOptions: [(String, AppearanceMode)] = [
        (String(localized: "跟随系统"), .system),
        (String(localized: "浅色"), .light),
        (String(localized: "深色"), .dark),
    ]

    private static let titleBarOptions: [(String, TitleBarMode)] = [
        (String(localized: "titlebar.mode.shown", defaultValue: "显示"), .shown),
        (String(localized: "自动隐藏"), .autoHide),
        (String(localized: "无边框"), .borderless),
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    themeSection
                        .id(AppearanceSettingsSection.theme.rawValue)
                    fontsSection
                        .id(AppearanceSettingsSection.fonts.rawValue)
                    windowSection
                        .id(AppearanceSettingsSection.window.rawValue)
                    schemesSection
                        .id(AppearanceSettingsSection.schemes.rawValue)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
            .onAppear {
                model.layoutSchemes.reload()
                scrollIfNeeded(proxy: proxy, target: scrollTarget)
            }
            .onChange(of: scrollTarget) { _, target in
                scrollIfNeeded(proxy: proxy, target: target)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Theme.fontsDidChange)) { _ in
            fontRevision &+= 1
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: Self.debugSchemeActionNotification)) { note in
            guard let action = note.userInfo?["action"] as? String,
                  let name = note.userInfo?["name"] as? String else { return }
            switch action {
            case "beginRename":
                beginRename(name)
            case "setRenameText":
                if let newName = note.userInfo?["newName"] as? String {
                    renameText = newName
                }
            case "commitRename":
                commitRename(from: name)
            case "cancelRename":
                cancelRename()
            case "replace":
                guard model.layoutSchemes.hasReaderWindow else { return }
                Task {
                    do {
                        try await model.layoutSchemes.replaceWithCurrent(named: name)
                        actionError = nil
                    } catch {
                        actionError = ErrorText.describe(error)
                    }
                }
            case "delete":
                pendingDeleteScheme = name
            default:
                break
            }
        }
        #endif
        .sheet(isPresented: $showingSaveSheet) {
            saveSchemeSheet
        }
        .alert(
            String(localized: "删除布局方案“\(pendingDeleteScheme ?? "")”？"),
            isPresented: Binding(
                get: { pendingDeleteScheme != nil },
                set: { if !$0 { pendingDeleteScheme = nil } }
            )
        ) {
            Button(String(localized: "取消"), role: .cancel) {
                pendingDeleteScheme = nil
            }
            Button(String(localized: "删除"), role: .destructive) {
                guard let target = pendingDeleteScheme else { return }
                pendingDeleteScheme = nil
                Task {
                    do {
                        try await model.layoutSchemes.delete(target)
                        actionError = nil
                    } catch {
                        actionError = ErrorText.describe(error)
                    }
                }
            }
        } message: {
            Text(String(localized: "删除后不能撤销。"))
        }
    }

    private func scrollIfNeeded(proxy: ScrollViewProxy, target: SettingsWindowState.ScrollTarget?) {
        guard let target else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(target.section, anchor: .top)
        }
    }

    // MARK: 1. 主题

    private var themeSection: some View {
        SettingsSection(title: String(localized: "主题")) {
            SettingsRow(title: String(localized: "外观")) {
                AppearanceModeSegments(
                    options: Self.modeOptions,
                    selection: global(model, \.appearance.mode),
                    identifierPrefix: "appearance.mode"
                )
            }
            SettingsDivider()
            SettingsRow(
                title: String(localized: "强调色"),
                detail: String(localized: "选中环、放置指示、开关和搜索高亮")
            ) {
                AccentModeSegments(selection: global(model, \.appearance.accent))
            }
        }
    }

    // MARK: 2. 字体

    private var fontsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSection(title: String(localized: "字体")) {
                fontRow(
                    role: .panels,
                    title: String(localized: "面板与列表"),
                    detail: String(localized: "停靠面板的标签、列表、表格与网格文字")
                )
                SettingsDivider()
                fontRow(
                    role: .overlays,
                    title: String(localized: "信息叠加层"),
                    detail: String(localized: "HUD、页码胶囊、状态栏、提示条、手势命令名")
                )
                SettingsDivider()
                fontRow(
                    role: .menus,
                    title: String(localized: "菜单"),
                    detail: String(localized: "主菜单下拉、右键菜单、面板与工具栏的下拉选择")
                )
            }
            Text(String(localized: "组内大小不同的文字按字号比例一起缩放。菜单栏顶层标题由系统绘制，不受影响。"))
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Theme.text2))
                .padding(.horizontal, 12)
        }
    }

    private func fontRow(role: FontRole, title: String, detail: String) -> some View {
        let spec = model.global.appearance.fonts[role]
        let defaultSize = Int(round(Theme.defaultSize(role)))
        let currentSize = Int(round(spec?.size ?? Double(defaultSize)))
        let isChanged = (spec?.family != nil && !spec!.family!.isEmpty) || spec?.size != nil
        let previewFont = previewFont(for: role, spec: spec, revision: fontRevision)

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.text2))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Text(String(localized: "示例 Aa 123"))
                    .font(Font(previewFont))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 96, alignment: .trailing)
                    .accessibilityIdentifier("appearance.font.\(role.rawValue).preview")

                FontFamilyPopUp(
                    families: Self.availableFontFamilies,
                    selection: fontFamilyBinding(for: role),
                    identifier: "appearance.font.\(role.rawValue).family"
                )
                .frame(width: 132, height: 22)
                .clipped()

                HStack(spacing: 4) {
                    Text("\(currentSize) pt")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Color(nsColor: Theme.text2))
                        .frame(minWidth: 34, alignment: .trailing)
                    Stepper(title, value: fontSizeBinding(for: role, defaultSize: defaultSize), in: 8...32)
                        .labelsHidden()
                        .controlSize(.small)
                        .accessibilityIdentifier("appearance.font.\(role.rawValue).stepper")
                }

                Group {
                    if isChanged {
                        SettingsIconButton(
                            systemImage: "arrow.counterclockwise",
                            fontSize: 11,
                            help: String(localized: "恢复默认")
                        ) {
                            model.updateGlobal { $0.appearance.fonts.removeValue(forKey: role) }
                        }
                        .accessibilityLabel(String(localized: "恢复默认"))
                        .accessibilityIdentifier("appearance.font.\(role.rawValue).reset")
                    } else {
                        Color.clear.frame(width: 22, height: 22)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
        .padding(.vertical, 4)
    }

    private func previewFont(for role: FontRole, spec: FontSpec?, revision _: Int) -> NSFont {
        if Theme.fonts[role] == spec {
            return Theme.font(role, size: Theme.defaultSize(role))
        }
        let targetSize = CGFloat(spec?.size ?? Double(Theme.defaultSize(role)))
        if let rawFamily = spec?.family?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawFamily.isEmpty,
           let custom = NSFontManager.shared.font(withFamily: rawFamily, traits: [], weight: 5, size: targetSize) {
            return custom
        }
        if role == .menus {
            return NSFont.menuFont(ofSize: targetSize)
        }
        return NSFont.systemFont(ofSize: targetSize)
    }

    private func fontFamilyBinding(for role: FontRole) -> Binding<String> {
        Binding(
            get: { model.global.appearance.fonts[role]?.family ?? "" },
            set: { newFamily in
                model.updateGlobal { settings in
                    var spec = settings.appearance.fonts[role] ?? FontSpec()
                    spec.family = newFamily.isEmpty ? nil : newFamily
                    if spec.family == nil && spec.size == nil {
                        settings.appearance.fonts.removeValue(forKey: role)
                    } else {
                        settings.appearance.fonts[role] = spec
                    }
                }
            }
        )
    }

    private func fontSizeBinding(for role: FontRole, defaultSize: Int) -> Binding<Int> {
        Binding(
            get: { Int(round(model.global.appearance.fonts[role]?.size ?? Double(defaultSize))) },
            set: { newSize in
                let clamped = min(max(newSize, 8), 32)
                model.updateGlobal { settings in
                    var spec = settings.appearance.fonts[role] ?? FontSpec()
                    spec.size = Double(clamped)
                    settings.appearance.fonts[role] = spec
                }
            }
        )
    }

    // MARK: 3. 窗口

    private var windowSection: some View {
        SettingsSection(title: String(localized: "窗口")) {
            SettingsRow(title: String(localized: "标题栏"), detail: titleBarDetail) {
                AppearanceModeSegments(
                    options: Self.titleBarOptions,
                    selection: global(model, \.appearance.window.titleBar),
                    identifierPrefix: "appearance.titlebar"
                )
            }
            SettingsDivider()
            SettingsRow(
                title: String(localized: "置顶"),
                detail: String(localized: "阅读窗口和浮动面板保持在其他应用的窗口之上")
            ) {
                SettingsSwitch(label: String(localized: "置顶"), isOn: global(model, \.appearance.window.keepOnTop))
                    .accessibilityIdentifier("appearance.keepOnTop")
            }
            SettingsDivider()
            SettingsRow(
                title: String(localized: "不透明度"),
                detail: String(localized: "整个窗口一起变淡，含图片；全屏时不生效")
            ) {
                HStack(spacing: 8) {
                    Slider(value: opacityPercentBinding, in: 30...100, step: 1)
                        .labelsHidden()
                        .controlSize(.small)
                        .tint(Color(nsColor: Theme.accent))
                        .frame(width: 148)
                        .accessibilityLabel(String(localized: "不透明度"))
                        .accessibilityIdentifier("appearance.opacity")
                    Text("\(Int(round(model.global.appearance.window.opacity * 100)))%")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Color(nsColor: Theme.text2))
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
    }

    private var titleBarDetail: String {
        switch model.global.appearance.window.titleBar {
        case .shown: String(localized: "标题栏和工具栏常驻")
        case .autoHide: String(localized: "指针移到窗口顶端时浮出")
        case .borderless: String(localized: "按住 ⌘ 拖画面移动窗口")
        }
    }

    private var opacityPercentBinding: Binding<Double> {
        Binding(
            get: { (model.global.appearance.window.opacity * 100).rounded() },
            set: { newPercent in
                let fraction = min(max(newPercent / 100.0, 0.3), 1.0)
                model.updateGlobalThrottled { $0.appearance.window.opacity = fraction }
            }
        )
    }

    // MARK: 4. 布局方案

    private var schemesSection: some View {
        let schemesModel = model.layoutSchemes
        return VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "布局方案"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: Theme.text2))
                .padding(.horizontal, 12)

            if schemesModel.problem != nil {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(String(localized: "layout-schemes.json 有错误，继续使用上一份可用的方案。"))
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(String(localized: "打开文件")) {
                        schemesModel.openSchemesFile()
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("appearance.schemes.openFile")
                }
                .foregroundStyle(Color(nsColor: Theme.danger))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: Theme.dangerSoft), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("appearance.schemes.error")
            }

            SettingsErrorBanner(message: actionError)

            SettingsCard {
                if schemesModel.schemes.isEmpty {
                    Text(String(localized: "还没有布局方案。调好停靠区后点“保存当前布局…”。"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: Theme.text2))
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 18)
                } else {
                    ForEach(Array(schemesModel.schemes.enumerated()), id: \.element.name) { index, scheme in
                        if index > 0 { SettingsDivider() }
                        schemeRow(scheme, hasReaderWindow: schemesModel.hasReaderWindow)
                    }
                }
                SettingsDivider()
                HStack {
                    Spacer()
                    Button(String(localized: "保存当前布局…")) {
                        saveNameText = ""
                        saveError = nil
                        showingSaveSheet = true
                    }
                    .controlSize(.small)
                    .disabled(!schemesModel.hasReaderWindow)
                    .accessibilityIdentifier("appearance.schemes.save")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Text(String(localized: "方案只保存停靠区和浮动面板的布局。也可从“窗口 › 布局方案”套用。"))
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Theme.text2))
                .padding(.horizontal, 12)
        }
    }

    private func schemeRow(_ scheme: LayoutScheme, hasReaderWindow: Bool) -> some View {
        let isEditing = renamingScheme == scheme.name
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    HStack(spacing: 6) {
                        TextField(String(localized: "方案名称"), text: $renameText)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .frame(maxWidth: 200)
                            .focused($renameFieldFocused)
                            .onSubmit { commitRename(from: scheme.name) }
                            .onExitCommand { cancelRename() }
                            .onChange(of: renameText) { _, _ in renameError = nil }
                            .accessibilityIdentifier("appearance.scheme.renameField")
                        if let renameError {
                            Text(renameError)
                                .font(.system(size: 11))
                                .foregroundStyle(Color(nsColor: Theme.danger))
                                .lineLimit(1)
                                .accessibilityIdentifier("appearance.scheme.renameError")
                        }
                    }
                } else {
                    Text(scheme.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                }
                Text(Self.summary(of: scheme.layout))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.text2))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard !isEditing, hasReaderWindow else { return }
                Task { _ = await model.layoutSchemes.apply(scheme.name) }
            }

            HStack(spacing: 6) {
                Button(String(localized: "套用")) {
                    Task { _ = await model.layoutSchemes.apply(scheme.name) }
                }
                .controlSize(.small)
                .disabled(!hasReaderWindow)
                .accessibilityIdentifier("appearance.scheme.\(scheme.name).apply")

                Menu {
                    Button(String(localized: "改名")) {
                        beginRename(scheme.name)
                    }
                    Button(String(localized: "用当前布局覆盖")) {
                        Task {
                            do {
                                try await model.layoutSchemes.replaceWithCurrent(named: scheme.name)
                                actionError = nil
                            } catch {
                                actionError = ErrorText.describe(error)
                            }
                        }
                    }
                    .disabled(!hasReaderWindow)
                    Divider()
                    Button(String(localized: "删除…"), role: .destructive) {
                        pendingDeleteScheme = scheme.name
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
                .accessibilityLabel(String(localized: "更多操作"))
                .accessibilityIdentifier("appearance.scheme.\(scheme.name).more")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
        .padding(.vertical, 3)
    }

    private func beginRename(_ name: String) {
        renamingScheme = name
        renameText = name
        renameError = nil
        DispatchQueue.main.async {
            renameFieldFocused = true
        }
    }

    private func cancelRename() {
        renamingScheme = nil
        renameText = ""
        renameError = nil
        renameFieldFocused = false
    }

    private func commitRename(from oldName: String) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            renameError = String(localized: "方案名称不能为空")
            return
        }
        if trimmed == oldName {
            cancelRename()
            return
        }
        if model.layoutSchemes.hasScheme(named: trimmed, excluding: oldName) {
            renameError = String(localized: "已有同名方案")
            return
        }
        Task {
            do {
                try await model.layoutSchemes.rename(oldName, to: trimmed)
                cancelRename()
                actionError = nil
            } catch {
                renameError = ErrorText.describe(error)
            }
        }
    }

    private var saveSchemeSheet: some View {
        let trimmed = saveNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDuplicate = model.layoutSchemes.hasScheme(named: trimmed)
        return VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "保存当前布局"))
                .font(.system(size: 14, weight: .semibold))
            Text(String(localized: "为当前阅读窗口的停靠布局输入一个名称。"))
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Theme.text2))
            TextField(String(localized: "方案名称"), text: $saveNameText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitSaveScheme() }
                .onChange(of: saveNameText) { _, _ in saveError = nil }
                .accessibilityIdentifier("appearance.saveSheet.nameField")
            if isDuplicate {
                Text(String(localized: "已有同名方案，继续将覆盖原有方案。"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.danger))
                    .accessibilityIdentifier("appearance.saveSheet.duplicate")
            } else if let saveError {
                Text(saveError)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.danger))
            }
            HStack {
                Spacer()
                Button(String(localized: "取消")) {
                    showingSaveSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button(isDuplicate ? String(localized: "覆盖") : String(localized: "保存")) {
                    commitSaveScheme()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty || !model.layoutSchemes.hasReaderWindow)
                .accessibilityIdentifier("appearance.saveSheet.confirm")
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func commitSaveScheme() {
        let trimmed = saveNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            saveError = String(localized: "方案名称不能为空")
            return
        }
        Task {
            do {
                try await model.layoutSchemes.saveCurrent(named: trimmed)
                showingSaveSheet = false
                actionError = nil
            } catch {
                saveError = ErrorText.describe(error)
            }
        }
    }

    static func summary(of layout: DockLayout) -> String {
        let separator = String(localized: "layout.scheme.panelSeparator", defaultValue: "、")
        func panelNames(in edge: DockEdge) -> String? {
            guard !layout[edge].isCollapsed else { return nil }
            let visible = layout.visiblePanels(in: edge)
            guard !visible.isEmpty else { return nil }
            let names = visible.map { DockPanels.type($0)?.title ?? $0.rawValue }.joined(separator: separator)
            return switch edge {
            case .left: String(localized: "左：\(names)")
            case .right: String(localized: "右：\(names)")
            case .bottom: String(localized: "下：\(names)")
            }
        }
        var parts: [String] = []
        if let left = panelNames(in: .left) { parts.append(left) }
        if let right = panelNames(in: .right) { parts.append(right) }
        if let bottom = panelNames(in: .bottom) { parts.append(bottom) }
        let floatingCount = layout.floating.filter { !$0.isHidden }.count
        if floatingCount > 0 {
            parts.append(String(localized: "浮动 \(floatingCount)"))
        }
        return parts.isEmpty ? String(localized: "全部隐藏") : parts.joined(separator: " · ")
    }
}

/// 带可选标识符的分段选择（外观、标题栏）。
private struct AppearanceModeSegments<Value: Hashable & RawRepresentable>: View where Value.RawValue == String {
    let options: [(String, Value)]
    @Binding var selection: Value
    let identifierPrefix: String

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
                    .accessibilityIdentifier("\(identifierPrefix).\(option.1.rawValue)")
            }
        }
        .padding(2)
        .background(Color(nsColor: Theme.well), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: Theme.line), lineWidth: 0.5))
        .fixedSize()
    }
}

/// 强调色两段选择：带色点（默认琥珀 / 跟随系统）。
private struct AccentModeSegments: View {
    @Binding var selection: AccentColorMode

    private static let claySwatch = Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)

    var body: some View {
        HStack(spacing: 2) {
            segmentButton(
                title: String(localized: "默认琥珀"),
                swatch: Self.claySwatch,
                mode: .clay
            )
            segmentButton(
                title: String(localized: "跟随系统"),
                swatch: Color(nsColor: .controlAccentColor),
                mode: .system
            )
        }
        .padding(2)
        .background(Color(nsColor: Theme.well), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: Theme.line), lineWidth: 0.5))
        .fixedSize()
    }

    private func segmentButton(title: String, swatch: Color, mode: AccentColorMode) -> some View {
        let isSelected = selection == mode
        return Button {
            selection = mode
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(swatch)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(Color(nsColor: Theme.lineStrong), lineWidth: 0.5))
                Text(title)
            }
            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(Color(nsColor: isSelected ? Theme.text : Theme.text2))
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(isSelected ? Color(nsColor: Theme.raised) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("appearance.accent.\(mode.rawValue)")
    }
}

/// 原生 `NSPopUpButton` 字体族选择：首项“系统字体”，已存但未安装的族显示为“<名>（未安装）”。
private struct FontFamilyPopUp: NSViewRepresentable {
    let families: [String]
    @Binding var selection: String
    let identifier: String

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.cell?.lineBreakMode = .byTruncatingTail
        button.cell?.truncatesLastVisibleLine = true
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        populate(button, current: selection)
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 132, height: proposal.height ?? 22)
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        populate(button, current: selection)
    }

    private func populate(_ button: NSPopUpButton, current: String) {
        let needsMissingItem = !current.isEmpty && !families.contains(current)
        let expectedCount = 1 + (needsMissingItem ? 1 : 0) + families.count
        let missingTag = needsMissingItem ? current : nil
        let existingMissing = button.itemArray.count > 1 && button.item(at: 1)?.representedObject as? String != families.first
            ? button.item(at: 1)?.representedObject as? String
            : nil
        if button.numberOfItems != expectedCount || existingMissing != missingTag {
            button.removeAllItems()
            let systemItem = NSMenuItem(title: String(localized: "系统字体"), action: nil, keyEquivalent: "")
            systemItem.representedObject = ""
            button.menu?.addItem(systemItem)
            if let missingTag {
                let missingItem = NSMenuItem(title: String(localized: "\(missingTag)（未安装）"), action: nil, keyEquivalent: "")
                missingItem.representedObject = missingTag
                button.menu?.addItem(missingItem)
            }
            for family in families {
                let item = NSMenuItem(title: family, action: nil, keyEquivalent: "")
                item.representedObject = family
                button.menu?.addItem(item)
            }
        }
        if let index = button.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) {
            button.selectItem(at: index)
        } else {
            button.selectItem(at: 0)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<String>

        init(selection: Binding<String>) {
            self.selection = selection
        }

        @objc func changed(_ sender: NSPopUpButton) {
            let value = (sender.selectedItem?.representedObject as? String) ?? ""
            selection.wrappedValue = value
        }
    }
}
