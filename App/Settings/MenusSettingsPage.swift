import AppKit
import MVCommands
import MVSettings
import Observation
import SwiftUI

/// 可编辑菜单树节点，供 `NSOutlineView` 保持展开与选中身份。
@MainActor
final class EditableMenuNode: Identifiable {
    enum Kind: Equatable {
        case command(CommandID)
        case separator
        case dynamic(DynamicMenuID)
        case submenu(titleKey: String)
    }

    let id: UUID
    var kind: Kind
    var children: [EditableMenuNode]

    init(id: UUID = UUID(), kind: Kind, children: [EditableMenuNode] = []) {
        self.id = id
        self.kind = kind
        self.children = children
    }

    convenience init(node: MenuNode) {
        switch node {
        case let .command(id): self.init(kind: .command(id))
        case .separator: self.init(kind: .separator)
        case let .dynamic(id): self.init(kind: .dynamic(id))
        case let .submenu(titleKey, children):
            self.init(kind: .submenu(titleKey: titleKey), children: children.map(EditableMenuNode.init(node:)))
        }
    }

    var isSubmenu: Bool {
        if case .submenu = kind { return true }
        return false
    }

    func toMenuNode() -> MenuNode {
        switch kind {
        case let .command(id): .command(id)
        case .separator: .separator
        case let .dynamic(id): .dynamic(id)
        case let .submenu(titleKey): .submenu(titleKey: titleKey, children: children.map { $0.toMenuNode() })
        }
    }
}

/// 菜单与工具栏设置页的数据模型。
@MainActor
@Observable
final class MenusModel {
    enum Tab: String, CaseIterable, Hashable { case viewerContext, mainMenu, toolbar }

    struct PaletteItem: Identifiable, Hashable {
        enum Source: Hashable {
            case command(CommandID)
            case dynamic(DynamicMenuID)
        }

        let source: Source
        let title: String
        let detail: String
        let symbol: String

        var isDynamic: Bool {
            if case .dynamic = source { true } else { false }
        }

        var id: String { pasteboardString }
        var pasteboardString: String {
            switch source {
            case let .command(id): "\(MenusModel.commandPasteboardPrefix)\(id.rawValue)"
            case let .dynamic(id): "\(MenusModel.dynamicPasteboardPrefix)\(id.rawValue)"
            }
        }
    }

    struct ToolbarPreviewItem: Identifiable, Equatable {
        let offset: Int
        let itemID: ToolbarItemID
        let title: String
        let symbol: String
        let isSpacer: Bool
        var id: String { "\(offset)-\(itemID.rawValue)" }
    }

    nonisolated static let nodePasteboardPrefix = "macview.menu.node:"
    nonisolated static let commandPasteboardPrefix = "macview.menu.command:"
    nonisolated static let dynamicPasteboardPrefix = "macview.menu.dynamic:"

    var selectedTab: Tab = .viewerContext {
        didSet {
            guard selectedTab != oldValue else { return }
            selectedNodeID = nil
            treeVersion &+= 1
        }
    }
    var searchText = ""
    var selectedNodeID: UUID?
    private(set) var treeVersion = 0
    private(set) var file: MenuFile
    private(set) var errorMessage: String?
    private(set) var canCustomizeToolbar = false
    private(set) var viewerNodes: [EditableMenuNode] = []
    private(set) var mainMenuNodes: [EditableMenuNode] = []

    @ObservationIgnored private var bridge: DocumentStoreBridge<MenuFile>?
    @ObservationIgnored private var windowTasks: [Task<Void, Never>] = []

    private static let builtInSubmenuKeys: Set<String> = {
        func collect(from nodes: [MenuNode], into result: inout Set<String>) {
            for node in nodes {
                if case let .submenu(titleKey, children) = node {
                    result.insert(titleKey)
                    collect(from: children, into: &result)
                }
            }
        }
        var keys: Set<String> = []
        collect(from: CommandCatalog.defaultMainMenu().roots, into: &keys)
        collect(from: CoreCommands.defaultViewerContextMenu, into: &keys)
        return keys
    }()

    init(store: JSONDocumentStore<MenuFile>?) {
        let initial = store?.value() ?? MenuFile()
        self.file = initial
        self.viewerNodes = initial.resolvedViewerContextMenu.map(EditableMenuNode.init(node:))
        self.mainMenuNodes = (initial.mainMenu ?? CommandCatalog.defaultMainMenu().roots).map(EditableMenuNode.init(node:))
        refreshReaderWindowAvailability()

        self.bridge = DocumentStoreBridge(
            store: store,
            onSync: { [weak self] in self?.applyExternalReload($0) },
            onError: { [weak self] in self?.errorMessage = $0 }
        )
        observeReaderWindows()
    }

    deinit {
        windowTasks.forEach { $0.cancel() }
    }

    func reload() {
        bridge?.reload()
        refreshReaderWindowAvailability()
    }

    var currentTreeRoots: [EditableMenuNode] {
        switch selectedTab {
        case .viewerContext: viewerNodes
        case .mainMenu: mainMenuNodes
        case .toolbar: []
        }
    }

    var isCurrentTabModified: Bool {
        switch selectedTab {
        case .viewerContext: file.viewerContextMenu != nil
        case .mainMenu: file.mainMenu != nil
        case .toolbar: file.toolbar != nil
        }
    }

    var targetReaderController: ReaderWindowController? {
        guard let app = NSApp.delegate as? AppDelegate else { return nil }
        return app.mainController ?? app.controllers.first
    }

    func refreshReaderWindowAvailability(excluding closingWindow: NSWindow? = nil) {
        guard let app = NSApp.delegate as? AppDelegate else { canCustomizeToolbar = false; return }
        canCustomizeToolbar = app.controllers.contains { closingWindow == nil || $0.window !== closingWindow }
    }

    func customizeToolbar() {
        guard let target = targetReaderController else { return }
        target.window?.makeKeyAndOrderFront(nil)
        target.runToolbarCustomization()
    }

    func isBuiltInSubmenu(_ node: EditableMenuNode) -> Bool {
        if case let .submenu(titleKey) = node.kind {
            return Self.builtInSubmenuKeys.contains(titleKey)
        }
        return false
    }

    // MARK: 标题与图标

    static func dynamicTitle(of id: DynamicMenuID) -> String {
        switch id {
        case .openWith: String(localized: "用指定应用打开")
        case .moveTo: String(localized: "移动到")
        case .copyTo: String(localized: "复制到")
        case .displayProfiles: String(localized: "套用显示配置")
        case .rating: String(localized: "评分")
        case .layoutSchemes: String(localized: "布局方案")
        case .scripts: String(localized: "脚本")
        case .sources: String(localized: "打开来源")
        case .pluginPanels: String(localized: "插件面板")
        }
    }

    func nodeTitle(of node: EditableMenuNode) -> String {
        switch node.kind {
        case let .command(id): SettingsCommandCatalog.title(of: id)
        case .separator: String(localized: "分隔线")
        case let .dynamic(id): Self.dynamicTitle(of: id)
        case let .submenu(titleKey): Bundle.main.localizedString(forKey: titleKey, value: nil, table: nil)
        }
    }

    func nodeSymbol(of node: EditableMenuNode) -> String {
        switch node.kind {
        case let .command(id): SettingsCommandCatalog.symbol(of: id)
        case .separator: "minus"
        case .dynamic: "sparkles"
        case .submenu: "folder"
        }
    }

    var filteredPaletteItems: [PaletteItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = SettingsCommandCatalog.all.map {
            PaletteItem(source: .command($0.id), title: SettingsCommandCatalog.title(of: $0.id), detail: $0.id.rawValue, symbol: SettingsCommandCatalog.symbol(of: $0.id))
        } + DynamicMenuID.allCases.map {
            PaletteItem(source: .dynamic($0), title: Self.dynamicTitle(of: $0), detail: $0.rawValue, symbol: "sparkles")
        }
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(query) || $0.detail.lowercased().contains(query) }
    }

    var toolbarPreviewItems: [ToolbarPreviewItem] {
        file.resolvedToolbar.enumerated().map { offset, itemID in
            let info = toolbarItemDisplay(for: itemID)
            return ToolbarPreviewItem(offset: offset, itemID: itemID, title: info.title, symbol: info.symbol, isSpacer: info.isSpacer)
        }
    }

    private func toolbarItemDisplay(for itemID: ToolbarItemID) -> (title: String, symbol: String, isSpacer: Bool) {
        switch itemID {
        case .flexibleSpace: return (String(localized: "弹性空白"), "arrow.left.and.right", true)
        case .space: return (String(localized: "空白"), "space", true)
        case .dockLeft: return (SettingsCommandCatalog.title(of: .dockLeftToggle), "sidebar.left", false)
        case .dockRight: return (SettingsCommandCatalog.title(of: .dockRightToggle), "sidebar.right", false)
        case .bookTitle: return (String(localized: "书名"), "text.alignleft", false)
        case .viewWaterfallOptions: return (String(localized: "瀑布流选项"), "arrow.up.arrow.down", false)
        case .viewBrowse: return (String(localized: "浏览方式"), "square.grid.2x2", false)
        case .viewOptions: return (String(localized: "显示"), "slider.horizontal.3", false)
        case .windowFullScreen: return (SettingsCommandCatalog.title(of: .fullScreenToggle), "arrow.up.left.and.arrow.down.right", false)
        case ToolbarItemID(command: .effectsToggle): return (SettingsCommandCatalog.title(of: .effectsToggle), "circle.lefthalf.filled", false)
        default:
            let commandID = CommandID(itemID.rawValue)
            return (SettingsCommandCatalog.title(of: commandID), SettingsCommandCatalog.symbol(of: commandID), false)
        }
    }

    // MARK: 树编辑

    @discardableResult
    func insertNode(_ menuNode: MenuNode, parentID: UUID? = nil, at index: Int? = nil) -> EditableMenuNode? {
        guard selectedTab != .toolbar else { return nil }
        let newNode = EditableMenuNode(node: menuNode)

        if let parentID {
            guard let parent = locate(id: parentID, in: currentTreeRoots)?.node, parent.isSubmenu else { return nil }
            parent.children.insert(newNode, at: clamped(index ?? parent.children.count, count: parent.children.count))
        } else if let index {
            insertAtRoot(newNode, at: index)
        } else if let selectedID = selectedNodeID, let loc = locate(id: selectedID, in: currentTreeRoots) {
            if loc.node.isSubmenu {
                loc.node.children.append(newNode)
            } else if let parent = loc.ancestors.last {
                parent.children.insert(newNode, at: loc.index + 1)
            } else {
                insertAtRoot(newNode, at: loc.index + 1)
            }
        } else if selectedTab == .mainMenu, !newNode.isSubmenu, let firstSubmenu = mainMenuNodes.first(where: \.isSubmenu) {
            firstSubmenu.children.append(newNode)
        } else {
            insertAtRoot(newNode, at: currentTreeRoots.count)
        }

        selectedNodeID = newNode.id
        commitCurrentMenuTree()
        return newNode
    }

    func addSeparator() { _ = insertNode(.separator) }
    func addSubmenu(title: String = String(localized: "新建子菜单")) { _ = insertNode(.submenu(titleKey: title, children: [])) }

    func addPaletteItem(_ item: PaletteItem) {
        switch item.source {
        case let .command(id): _ = insertNode(.command(id))
        case let .dynamic(id): _ = insertNode(.dynamic(id))
        }
    }

    func renameSubmenu(id: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let node = locate(id: id, in: currentTreeRoots)?.node,
              !isBuiltInSubmenu(node),
              case let .submenu(currentTitle) = node.kind,
              trimmed != currentTitle, trimmed != nodeTitle(of: node) else { return }
        node.kind = .submenu(titleKey: trimmed)
        commitCurrentMenuTree()
    }

    func removeNode(id: UUID) {
        guard selectedTab != .toolbar, removeNodeRecursive(id: id) != nil else { return }
        if selectedNodeID == id { selectedNodeID = nil }
        commitCurrentMenuTree()
    }

    func removeSelectedNode() {
        if let id = selectedNodeID { removeNode(id: id) }
    }

    @discardableResult
    func moveNode(id: UUID, toParentID: UUID?, index: Int) -> Bool {
        guard selectedTab != .toolbar,
              let source = locate(id: id, in: currentTreeRoots) else { return false }
        if let toParentID {
            if toParentID == id || locate(id: toParentID, in: source.node.children) != nil { return false }
            guard let targetParent = locate(id: toParentID, in: currentTreeRoots)?.node, targetParent.isSubmenu else { return false }
        }

        var adjustedIndex = index
        if source.ancestors.last?.id == toParentID, source.index < adjustedIndex { adjustedIndex -= 1 }
        guard let removed = removeNodeRecursive(id: id) else { return false }

        if let toParentID, let targetParent = locate(id: toParentID, in: currentTreeRoots)?.node {
            targetParent.children.insert(removed, at: clamped(adjustedIndex, count: targetParent.children.count))
        } else {
            insertAtRoot(removed, at: clamped(adjustedIndex, count: currentTreeRoots.count))
        }

        selectedNodeID = removed.id
        commitCurrentMenuTree()
        return true
    }

    func resetCurrentTab() {
        selectedNodeID = nil
        switch selectedTab {
        case .viewerContext:
            viewerNodes = CoreCommands.defaultViewerContextMenu.map(EditableMenuNode.init(node:))
            treeVersion &+= 1
            persist { $0.viewerContextMenu = nil }
        case .mainMenu:
            mainMenuNodes = CommandCatalog.defaultMainMenu().roots.map(EditableMenuNode.init(node:))
            treeVersion &+= 1
            persist { $0.mainMenu = nil }
        case .toolbar:
            persist { $0.toolbar = nil }
        }
    }

    func locate(
        id: UUID,
        in nodes: [EditableMenuNode],
        ancestors: [EditableMenuNode] = []
    ) -> (node: EditableMenuNode, ancestors: [EditableMenuNode], index: Int)? {
        for (index, node) in nodes.enumerated() {
            if node.id == id { return (node, ancestors, index) }
            if let found = locate(id: id, in: node.children, ancestors: ancestors + [node]) { return found }
        }
        return nil
    }

    // MARK: 内部辅助

    private func insertAtRoot(_ node: EditableMenuNode, at index: Int) {
        if selectedTab == .viewerContext {
            viewerNodes.insert(node, at: clamped(index, count: viewerNodes.count))
        } else {
            mainMenuNodes.insert(node, at: clamped(index, count: mainMenuNodes.count))
        }
    }

    private func removeNodeRecursive(id: UUID) -> EditableMenuNode? {
        selectedTab == .viewerContext ? remove(id: id, from: &viewerNodes) : remove(id: id, from: &mainMenuNodes)
    }

    private func remove(id: UUID, from list: inout [EditableMenuNode]) -> EditableMenuNode? {
        if let index = list.firstIndex(where: { $0.id == id }) { return list.remove(at: index) }
        for node in list {
            if let removed = remove(id: id, from: &node.children) { return removed }
        }
        return nil
    }

    private func clamped(_ index: Int, count: Int) -> Int { max(0, min(index, count)) }

    private func commitCurrentMenuTree() {
        treeVersion &+= 1
        if selectedTab == .viewerContext {
            let serialized = viewerNodes.map { $0.toMenuNode() }
            persist { $0.viewerContextMenu = serialized }
        } else {
            let serialized = mainMenuNodes.map { $0.toMenuNode() }
            persist { $0.mainMenu = serialized }
        }
    }

    private func applyExternalReload(_ next: MenuFile) {
        file = next
        let nextViewer = next.resolvedViewerContextMenu
        if viewerNodes.map({ $0.toMenuNode() }) != nextViewer {
            viewerNodes = nextViewer.map(EditableMenuNode.init(node:))
            treeVersion &+= 1
        }
        let nextMain = next.mainMenu ?? CommandCatalog.defaultMainMenu().roots
        if mainMenuNodes.map({ $0.toMenuNode() }) != nextMain {
            mainMenuNodes = nextMain.map(EditableMenuNode.init(node:))
            treeVersion &+= 1
        }
    }

    private func persist(_ mutate: @escaping @Sendable (inout MenuFile) -> Void) {
        mutate(&file)
        bridge?.persist(mutate)
    }

    private func observeReaderWindows() {
        let names: [Notification.Name] = [NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification]
        windowTasks = names.map { name in
            Task { [weak self] in
                for await notification in NotificationCenter.default.notifications(named: name) {
                    guard let self, !Task.isCancelled else { return }
                    let closing = name == NSWindow.willCloseNotification ? (notification.object as? NSWindow) : nil
                    self.refreshReaderWindowAvailability(excluding: closing)
                }
            }
        }
    }
}

// MARK: - 菜单与工具栏设置页视图

struct MenusSettingsPage: View {
    @Bindable var model: MenusModel

    private static let tabs: [(String, MenusModel.Tab)] = [
        (String(localized: "右键菜单"), .viewerContext),
        (String(localized: "主菜单"), .mainMenu),
        (String(localized: "工具栏"), .toolbar),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SettingsSegments(label: String(localized: "菜单与工具栏分段"), options: Self.tabs, selection: $model.selectedTab)
                Spacer()
                Button(String(localized: "恢复默认")) { model.resetCurrentTab() }
                    .controlSize(.small)
                    .disabled(!model.isCurrentTabModified)
            }

            SettingsErrorBanner(message: model.errorMessage)

            switch model.selectedTab {
            case .viewerContext, .mainMenu: menuEditorContent
            case .toolbar: toolbarContent
            }
        }
        .padding(16)
        .onAppear { model.reload() }
    }

    private var menuEditorContent: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "当前菜单"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Theme.text2))

                MenuTreeOutlineView(model: model, treeVersion: model.treeVersion)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: Theme.raised), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: Theme.line), lineWidth: 0.5))

                HStack(spacing: 6) {
                    Button { model.addSubmenu() } label: { Label(String(localized: "子菜单"), systemImage: "plus") }
                        .controlSize(.small)
                    Button { model.addSeparator() } label: { Label(String(localized: "分隔线"), systemImage: "plus") }
                        .controlSize(.small)
                    Spacer()
                    Button(String(localized: "移除")) { model.removeSelectedNode() }
                        .controlSize(.small)
                        .disabled(model.selectedNodeID == nil)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "全部命令"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Theme.text2))

                SettingsSearchField(placeholder: String(localized: "搜索命令"), text: $model.searchText)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        let items = model.filteredPaletteItems
                        if items.isEmpty {
                            Text("没有匹配的命令")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(nsColor: Theme.text2))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 24)
                        } else {
                            ForEach(items) { paletteRow($0) }
                        }
                    }
                    .padding(6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: Theme.well), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: Theme.line), lineWidth: 0.5))

                Text("拖到左侧加入菜单，或双击直接加入；拖动左侧条目可调整顺序与层级。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.text2))
            }
            .frame(width: 256)
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func paletteRow(_ item: MenusModel.PaletteItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.symbol).font(.system(size: 11)).foregroundStyle(Color(nsColor: Theme.text2)).frame(width: 16)
            Text(item.title).font(.system(size: 12)).foregroundStyle(Color(nsColor: Theme.text)).lineLimit(1)
            Spacer(minLength: 4)
            if item.isDynamic {
                Text(String(localized: "动态"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.text2))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color(nsColor: Theme.raised), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: Theme.line), lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(Color(nsColor: Theme.raised).opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.addPaletteItem(item) }
        .onDrag { NSItemProvider(object: item.pasteboardString as NSString) }
    }

    private var toolbarContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettingsSection(title: String(localized: "工具栏预览")) {
                    ToolbarPreviewFlow(spacing: 6) {
                        ForEach(model.toolbarPreviewItems) { toolbarChip($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }

                HStack(spacing: 10) {
                    Button { model.customizeToolbar() } label: {
                        Text(String(localized: "自定义工具栏…"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(nsColor: Theme.ground))
                            .padding(.horizontal, 12).frame(height: 26)
                            .background(Color(nsColor: Theme.text), in: RoundedRectangle(cornerRadius: 6))
                            .opacity(model.canCustomizeToolbar ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canCustomizeToolbar)
                    .accessibilityIdentifier("menus.customizeToolbarButton")

                    if !model.canCustomizeToolbar {
                        Text("需要至少打开一个查看器窗口才能自定义工具栏。")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: Theme.text2))
                    }
                }

                Text("点“自定义工具栏…”打开系统自定义面板拖放条目，结果自动保存到 menus.json。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.text2))
                    .padding(.horizontal, 4)
            }
        }
    }

    private func toolbarChip(_ item: MenusModel.ToolbarPreviewItem) -> some View {
        HStack(spacing: 5) {
            Image(systemName: item.symbol).font(.system(size: 11)).foregroundStyle(Color(nsColor: Theme.text2))
            Text(item.title).font(.system(size: 12)).foregroundStyle(Color(nsColor: item.isSpacer ? Theme.text2 : Theme.text)).lineLimit(1)
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(Color(nsColor: item.isSpacer ? Theme.well : Theme.ground), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: Theme.line), style: item.isSpacer ? StrokeStyle(lineWidth: 1, dash: [3, 2]) : StrokeStyle(lineWidth: 0.75))
        )
    }
}

/// 自适应换行容器，展示工具栏条目预览。
private struct ToolbarPreviewFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, usedW: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth { x = 0; y += lineH + spacing; lineH = 0 }
            x += size.width + spacing
            usedW = max(usedW, min(x - spacing, maxWidth))
            lineH = max(lineH, size.height)
        }
        return CGSize(width: proposal.width ?? usedW, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += lineH + spacing; lineH = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineH = max(lineH, size.height)
        }
    }
}

// MARK: - 菜单树 OutlineView

private struct MenuTreeOutlineView: NSViewRepresentable {
    let model: MenusModel
    let treeVersion: Int

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let outline = NSOutlineView()
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.rowHeight = 26
        outline.indentationPerLevel = 16
        outline.selectionHighlightStyle = .regular
        outline.allowsMultipleSelection = false
        outline.setAccessibilityIdentifier("menus.treeOutline")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("menuNode"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.registerForDraggedTypes([.string])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)

        scroll.documentView = outline
        context.coordinator.outlineView = outline
        context.coordinator.reload(version: treeVersion, expandTopLevel: true)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.reload(version: treeVersion, expandTopLevel: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
        var model: MenusModel
        weak var outlineView: NSOutlineView?
        private var lastVersion = -1
        private var lastTab: MenusModel.Tab?
        private var isSyncingSelection = false

        init(model: MenusModel) { self.model = model }

        func reload(version: Int, expandTopLevel: Bool) {
            guard let outlineView else { return }
            let tabChanged = lastTab != model.selectedTab
            guard version != lastVersion || tabChanged else { syncSelection(in: outlineView); return }
            lastVersion = version
            lastTab = model.selectedTab
            outlineView.reloadData()
            if expandTopLevel || tabChanged {
                for node in model.currentTreeRoots where node.isSubmenu { outlineView.expandItem(node) }
            }
            syncSelection(in: outlineView)
        }

        private func syncSelection(in outlineView: NSOutlineView) {
            isSyncingSelection = true
            defer { isSyncingSelection = false }
            guard let selectedID = model.selectedNodeID,
                  let loc = model.locate(id: selectedID, in: model.currentTreeRoots) else {
                if outlineView.selectedRow >= 0 { outlineView.deselectAll(nil) }
                return
            }
            if outlineView.row(forItem: loc.node) < 0 {
                for ancestor in loc.ancestors { outlineView.expandItem(ancestor) }
            }
            let row = outlineView.row(forItem: loc.node)
            if row >= 0, outlineView.selectedRow != row {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? EditableMenuNode else { return model.currentTreeRoots.count }
            return node.isSubmenu ? node.children.count : 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? EditableMenuNode else { return model.currentTreeRoots[index] }
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? EditableMenuNode)?.isSubmenu ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
            guard let node = item as? EditableMenuNode else { return nil }
            let pbItem = NSPasteboardItem()
            pbItem.setString("\(MenusModel.nodePasteboardPrefix)\(node.id.uuidString)", forType: .string)
            return pbItem
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard let payload = info.draggingPasteboard.string(forType: .string) else { return [] }
            let targetNode = item as? EditableMenuNode
            if let targetNode, !targetNode.isSubmenu { return [] }

            if payload.hasPrefix(MenusModel.nodePasteboardPrefix) {
                let uuidString = String(payload.dropFirst(MenusModel.nodePasteboardPrefix.count))
                guard let movingID = UUID(uuidString: uuidString),
                      let movingNode = model.locate(id: movingID, in: model.currentTreeRoots)?.node else { return [] }
                if let targetNode, targetNode.id == movingID || model.locate(id: targetNode.id, in: movingNode.children) != nil { return [] }
                return .move
            }
            if payload.hasPrefix(MenusModel.commandPasteboardPrefix) || payload.hasPrefix(MenusModel.dynamicPasteboardPrefix) {
                return .copy
            }
            return []
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            guard let payload = info.draggingPasteboard.string(forType: .string) else { return false }
            let parentNode = item as? EditableMenuNode
            let targetIndex = index == NSOutlineViewDropOnItemIndex ? (parentNode?.children.count ?? model.currentTreeRoots.count) : index

            var succeeded = false
            if payload.hasPrefix(MenusModel.nodePasteboardPrefix) {
                if let movingID = UUID(uuidString: String(payload.dropFirst(MenusModel.nodePasteboardPrefix.count))) {
                    succeeded = model.moveNode(id: movingID, toParentID: parentNode?.id, index: targetIndex)
                }
            } else if payload.hasPrefix(MenusModel.commandPasteboardPrefix) {
                let rawID = String(payload.dropFirst(MenusModel.commandPasteboardPrefix.count))
                succeeded = model.insertNode(.command(CommandID(rawID)), parentID: parentNode?.id, at: targetIndex) != nil
            } else if payload.hasPrefix(MenusModel.dynamicPasteboardPrefix),
                      let dynamicID = DynamicMenuID(rawValue: String(payload.dropFirst(MenusModel.dynamicPasteboardPrefix.count))) {
                succeeded = model.insertNode(.dynamic(dynamicID), parentID: parentNode?.id, at: targetIndex) != nil
            }
            if succeeded, let parentNode { outlineView.expandItem(parentNode) }
            return succeeded
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let outlineView else { return }
            let row = outlineView.selectedRow
            model.selectedNodeID = row >= 0 ? (outlineView.item(atRow: row) as? EditableMenuNode)?.id : nil
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? EditableMenuNode else { return nil }
            let cell = NSTableCellView()
            let stack = NSStackView()
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 6
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])

            stack.addArrangedSubview(symbolImageView("line.3.horizontal", pointSize: 10, width: 12))

            if node.kind == .separator {
                let line = NSBox()
                line.boxType = .separator
                line.setContentHuggingPriority(.defaultLow, for: .horizontal)
                let tag = NSTextField(labelWithString: String(localized: "分隔线"))
                tag.font = .systemFont(ofSize: 10)
                tag.textColor = Theme.text2
                stack.addArrangedSubview(line)
                stack.addArrangedSubview(tag)
                return cell
            }

            stack.addArrangedSubview(symbolImageView(model.nodeSymbol(of: node), pointSize: 11, width: 14))

            let titleField = NSTextField(labelWithString: model.nodeTitle(of: node))
            titleField.font = .systemFont(ofSize: 12, weight: node.isSubmenu ? .medium : .regular)
            titleField.textColor = Theme.text
            titleField.lineBreakMode = .byTruncatingTail
            titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            if node.isSubmenu && !model.isBuiltInSubmenu(node) {
                titleField.isEditable = true
                titleField.isSelectable = true
                titleField.delegate = self
                titleField.identifier = NSUserInterfaceItemIdentifier(node.id.uuidString)
            }
            stack.addArrangedSubview(titleField)
            cell.textField = titleField

            if case .dynamic = node.kind {
                let spacer = NSView()
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                let badge = NSTextField(labelWithString: String(localized: "动态"))
                badge.font = .systemFont(ofSize: 10, weight: .medium)
                badge.textColor = Theme.text2
                badge.wantsLayer = true
                badge.layer?.backgroundColor = Theme.well.cgColor
                badge.layer?.cornerRadius = 4
                badge.layer?.borderWidth = 0.5
                badge.layer?.borderColor = Theme.line.cgColor
                badge.alignment = .center
                badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
                stack.addArrangedSubview(spacer)
                stack.addArrangedSubview(badge)
            }
            return cell
        }

        private func symbolImageView(_ name: String, pointSize: CGFloat, width: CGFloat) -> NSImageView {
            let view = NSImageView()
            view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            view.contentTintColor = Theme.text2
            view.symbolConfiguration = .init(pointSize: pointSize, weight: .regular)
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
            return view
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField,
                  let rawID = field.identifier?.rawValue,
                  let id = UUID(uuidString: rawID) else { return }
            model.renameSubmenu(id: id, to: field.stringValue)
        }
    }
}
