import AppKit
import MVFoundation
import MVIO
import MVReading
import MVServices
import MVSettings

/// 书架和页面列表的视图设置，存进 layout.json。旧文件只有 `style`，其余取默认值。
struct CollectionPanelSettings: Codable, Equatable {
    var style: CollectionStyle = .list
    var itemExtent: Double = PanelExtent.standard
    /// 页面列表：nil 时跟随书的顺序。书架：nil 时按名称。
    var sort: SortSpec?

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = try container.decodeIfPresent(CollectionStyle.self, forKey: .style) ?? .list
        itemExtent = try container.decodeIfPresent(Double.self, forKey: .itemExtent) ?? PanelExtent.standard
        sort = try container.decodeIfPresent(SortSpec.self, forKey: .sort)
    }
}

/// 书架和页面列表共用的部分：样式、尺寸、排序的控件与菜单。内容由子类提供。
///
/// 集合组件在第一次绑定窗口时创建，它需要管线。
@MainActor
class CollectionPanel: DockPanel {
    typealias Settings = CollectionPanelSettings

    private(set) var settings: CollectionPanelSettings
    var onSettingsChange: (() -> Void)?
    private(set) weak var owner: ReaderWindowController?
    private(set) var collection: CollectionView?
    private let host = CollectionPanelView()
    /// 面板不在窗口里时不更新内容，回到窗口时一次补上。
    private var isStale = false

    var view: NSView { host }
    var boundSession: SessionID? { owner?.session.id }

    /// 排序菜单是否有「跟随书」。
    var followsBook: Bool { false }
    var secondColumnTitle: String { String(localized: "尺寸") }
    var thumbSize: CGSize { CGSize(width: 40, height: 40) }
    var defaultSort: SortSpec { SortSpec(key: .name) }

    init(settings: CollectionPanelSettings?) {
        self.settings = settings ?? CollectionPanelSettings()
        host.onStyle = { [weak self] in self?.setStyle($0) }
        host.onExtent = { [weak self] in self?.setItemExtent($0) }
        host.onSortMenu = { [weak self] in self?.sortMenu() }
        host.onWindowChange = { [weak self] in
            guard let self, host.window != nil, isStale else { return }
            refresh()
        }
        host.render(self.settings, sortTitle: sortTitle)
    }

    func bind(to window: ReaderWindowController?) {
        guard window !== owner || collection == nil else { return }
        owner = window
        if let window, collection == nil {
            let collection = CollectionView(
                pipeline: window.services.pipeline, style: settings.style, itemExtent: settings.itemExtent,
                secondColumn: secondColumnTitle, thumbSize: thumbSize
            )
            collection.onActivate = { [weak self] in self?.activate($0) }
            collection.onDoubleClick = { [weak self] in self?.doubleClicked($0) }
            collection.onVisibleRangeChange = { [weak self] in self?.visibleRangeChanged($0) }
            collection.onItemExtentChange = { [weak self] extent in
                guard let self else { return }
                settings.itemExtent = extent
                host.render(settings, sortTitle: sortTitle)
                onSettingsChange?()
            }
            self.collection = collection
            host.setCollection(collection)
        }
        collection?.onVisibleThumbnails = { [weak self] in self?.visibleThumbnailsArrived() }
        windowChanged()
    }

    /// 可见项都有缩略图。子类用来记首屏用时。
    func visibleThumbnailsArrived() {}

    /// 改变样式；样式控件、⋯ 菜单和自检共用。
    func setStyle(_ style: CollectionStyle) {
        guard style != settings.style else { return }
        settings.style = style
        collection?.style = style
        host.render(settings, sortTitle: sortTitle)
        onSettingsChange?()
    }

    func setItemExtent(_ extent: Double) {
        let extent = min(max(extent, PanelExtent.range.lowerBound), PanelExtent.range.upperBound)
        guard extent != settings.itemExtent else { return }
        settings.itemExtent = extent
        collection?.itemExtent = extent
        host.render(settings, sortTitle: sortTitle)
        onSettingsChange?()
    }

    /// 改变排序；排序菜单和自检共用。`nil` 表示跟随书（书架是默认排序）。
    func setSort(_ sort: SortSpec?) {
        guard sort != settings.sort else { return }
        settings.sort = sort
        host.render(settings, sortTitle: sortTitle)
        onSettingsChange?()
        sortChanged()
    }

    /// 显示在排序按钮上的文字。
    private var sortTitle: String {
        guard let sort = settings.sort ?? (followsBook ? nil : defaultSort) else { return String(localized: "跟随书") }
        return SortMenu.title(sort.key)
    }

    private func sortMenu() -> NSMenu {
        SortMenu.make(current: settings.sort, base: defaultSort, followsBook: followsBook) { [weak self] in self?.setSort($0) }
    }

    /// 刷新内容；面板不在窗口里时记下，回到窗口时补上。
    final func refresh() {
        guard host.window != nil else {
            isStale = true
            return
        }
        isStale = false
        reload()
    }

    /// 路径或信息行。
    final func setInfo(path: String?, count: String, canGoUp: Bool, onUp: (() -> Void)?) {
        host.setInfo(path: path, count: count, canGoUp: canGoUp, onUp: onUp)
    }

    // MARK: ⋯ 菜单

    func addOptions(to menu: NSMenu) {
        for style in CollectionStyle.allCases {
            let item = MenuAction(style.title) { [weak self] in self?.setStyle(style) }.item
            item.state = settings.style == style ? .on : .off
            menu.addItem(item)
        }
        let sort = NSMenuItem(title: String(localized: "排序"), action: nil, keyEquivalent: "")
        sort.submenu = sortMenu()
        menu.addItem(sort)
    }

    // MARK: 子类实现

    func windowChanged() {}
    func reload() {}
    func sortChanged() {}
    func activate(_ index: Int) {}
    func doubleClicked(_ index: Int) {}
    func visibleRangeChanged(_ range: Range<Int>) {}
}

/// 排序菜单：键、方向、文件夹位置；页面列表多一项「跟随书」。
@MainActor
enum SortMenu {
    static func title(_ key: SortKey) -> String {
        switch key {
        case .name: String(localized: "名称")
        case .modified: String(localized: "修改时间")
        case .created: String(localized: "创建时间")
        case .size: String(localized: "大小")
        case .type: String(localized: "类型")
        case .random: String(localized: "随机")
        }
    }

    static func make(current: SortSpec?, base: SortSpec, followsBook: Bool, pick: @escaping (SortSpec?) -> Void) -> NSMenu {
        let menu = NSMenu()
        let shown = current ?? base
        let isFollowing = followsBook && current == nil
        func add(_ title: String, on: Bool, _ change: @escaping (inout SortSpec) -> Void) {
            let item = MenuAction(title) {
                var next = shown
                change(&next)
                pick(next)
            }.item
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        if followsBook {
            let item = MenuAction(String(localized: "跟随书")) { pick(nil) }.item
            item.state = isFollowing ? .on : .off
            menu.addItem(item)
            menu.addItem(.separator())
        }
        for key in [SortKey.name, .modified, .created, .size, .type, .random] {
            add(title(key), on: !isFollowing && shown.key == key) { sort in
                sort.key = key
                // 随机排序每次选都换一个种子；JSON 数字是双精度，种子不超过 53 位。
                sort.randomSeed = key == .random ? UInt64.random(in: 0..<(1 << 53)) : nil
            }
        }
        menu.addItem(.separator())
        add(String(localized: "升序"), on: !isFollowing && shown.ascending) { $0.ascending = true }
        add(String(localized: "降序"), on: !isFollowing && !shown.ascending) { $0.ascending = false }
        menu.addItem(.separator())
        add(String(localized: "文件夹在前"), on: !isFollowing && shown.foldersFirst) { $0.foldersFirst = true }
        add(String(localized: "与文件混排"), on: !isFollowing && !shown.foldersFirst) { $0.foldersFirst = false }
        return menu
    }
}

/// 面板的外框：样式按钮与排序、路径或信息行、尺寸滑块（网格和瀑布流），下面是集合。
private final class CollectionPanelView: NSView {
    var onStyle: ((CollectionStyle) -> Void)?
    var onExtent: ((Double) -> Void)?
    var onSortMenu: (() -> NSMenu?)?
    var onWindowChange: (() -> Void)?

    private var styleButtons: [CollectionStyle: NSButton] = [:]
    private let sortButton = NSButton()
    private let upButton = NSButton()
    private let pathLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let smallIcon = NSImageView()
    private let largeIcon = NSImageView()
    private let slider = NSSlider()
    private var collection: CollectionView?
    private var showsSlider = false
    private var showsUp = false
    private var onUp: (() -> Void)?

    private static let controlHeight: CGFloat = 32
    private static let infoHeight: CGFloat = 26
    private static let sliderHeight: CGFloat = 24

    init() {
        super.init(frame: .zero)
        for style in CollectionStyle.allCases {
            let button = Self.iconButton(symbol: style.symbol, label: style.title)
            button.target = self
            button.action = #selector(styleClicked(_:))
            button.tag = CollectionStyle.allCases.firstIndex(of: style)!
            styleButtons[style] = button
            addSubview(button)
        }
        sortButton.isBordered = false
        sortButton.font = .systemFont(ofSize: 11)
        sortButton.imagePosition = .imageTrailing
        sortButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        sortButton.symbolConfiguration = .init(pointSize: 8, weight: .medium)
        sortButton.contentTintColor = Theme.text2
        sortButton.toolTip = String(localized: "排序")
        sortButton.target = self
        sortButton.action = #selector(sortClicked(_:))
        addSubview(sortButton)

        upButton.isBordered = false
        upButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: String(localized: "上一级目录"))
        upButton.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        upButton.contentTintColor = Theme.text2
        upButton.toolTip = String(localized: "上一级目录")
        upButton.target = self
        upButton.action = #selector(upClicked(_:))
        addSubview(upButton)
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.textColor = Theme.text2
        pathLabel.lineBreakMode = .byTruncatingHead
        addSubview(pathLabel)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = Theme.text2
        countLabel.alignment = .right
        addSubview(countLabel)

        for (icon, symbol) in [(smallIcon, "photo"), (largeIcon, "photo.fill")] {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: icon === smallIcon ? 8 : 12, weight: .regular)
            icon.contentTintColor = Theme.text2
            addSubview(icon)
        }
        slider.minValue = PanelExtent.range.lowerBound
        slider.maxValue = PanelExtent.range.upperBound
        slider.controlSize = .small
        slider.trackFillColor = Theme.accent
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.setAccessibilityLabel(String(localized: "缩略图尺寸"))
        addSubview(slider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func iconButton(symbol: String, label: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        button.contentTintColor = Theme.text2
        button.toolTip = label
        return button
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }

    func setCollection(_ view: CollectionView) {
        collection?.removeFromSuperview()
        collection = view
        addSubview(view, positioned: .below, relativeTo: nil)
        needsLayout = true
    }

    func render(_ settings: CollectionPanelSettings, sortTitle: String) {
        for (style, button) in styleButtons {
            let isOn = style == settings.style
            button.contentTintColor = isOn ? Theme.text : Theme.text2
            effectiveAppearance.performAsCurrentDrawingAppearance {
                button.layer?.backgroundColor = isOn ? Theme.selected.cgColor : NSColor.clear.cgColor
            }
            button.setAccessibilityValue(isOn ? String(localized: "已选中") : nil)
        }
        sortButton.attributedTitle = NSAttributedString(string: sortTitle + " ", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.text2])
        slider.doubleValue = settings.itemExtent
        showsSlider = settings.style.usesCanvas
        for view in [slider, smallIcon, largeIcon] { view.isHidden = !showsSlider }
        needsLayout = true
    }

    func setInfo(path: String?, count: String, canGoUp: Bool, onUp: (() -> Void)?) {
        pathLabel.stringValue = path ?? ""
        countLabel.stringValue = count
        upButton.isEnabled = canGoUp
        showsUp = onUp != nil
        upButton.isHidden = !showsUp
        self.onUp = onUp
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        var x: CGFloat = 8
        for style in CollectionStyle.allCases {
            styleButtons[style]?.frame = CGRect(x: x, y: 5, width: 24, height: 22)
            x += 25
        }
        let sortWidth = min(ceil(sortButton.intrinsicContentSize.width) + 4, max(width - x - 12, 0))
        sortButton.frame = CGRect(x: width - sortWidth - 8, y: 5, width: sortWidth, height: 22)

        var y = Self.controlHeight
        let countWidth = min(ceil(countLabel.intrinsicContentSize.width) + 2, width / 2)
        countLabel.frame = CGRect(x: width - countWidth - 10, y: y + 5, width: countWidth, height: 15)
        let pathX: CGFloat = showsUp ? 34 : 12
        upButton.frame = CGRect(x: 8, y: y + 1, width: 24, height: 22)
        pathLabel.frame = CGRect(x: pathX, y: y + 4, width: max(width - pathX - countWidth - 16, 0), height: 16)
        y += Self.infoHeight
        if showsSlider {
            smallIcon.frame = CGRect(x: 10, y: y + 4, width: 14, height: 14)
            largeIcon.frame = CGRect(x: width - 26, y: y + 3, width: 16, height: 16)
            slider.frame = CGRect(x: 28, y: y + 2, width: max(width - 58, 0), height: 18)
            y += Self.sliderHeight
        }
        collection?.frame = CGRect(x: 0, y: y, width: width, height: max(bounds.height - y, 0))
    }

    @objc private func styleClicked(_ sender: NSButton) {
        onStyle?(CollectionStyle.allCases[sender.tag])
    }

    @objc private func sortClicked(_ sender: NSButton) {
        onSortMenu?()?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func upClicked(_ sender: NSButton) {
        onUp?()
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        onExtent?(sender.doubleValue)
    }
}
