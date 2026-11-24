import AppKit
import MVFoundation
import MVMedia
import MVSettings
import SwiftUI

/// 设置窗口的各页。
enum SettingsPage: String, CaseIterable, Identifiable {
    case browse, display, cache, rules, files, shortcuts, pointer, menus, appearance, extensions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browse: String(localized: "浏览")
        case .display: String(localized: "显示")
        case .cache: String(localized: "缓存")
        case .rules: String(localized: "路径规则")
        case .files: String(localized: "文件")
        case .shortcuts: String(localized: "快捷键")
        case .pointer: String(localized: "鼠标与触控板")
        case .menus: String(localized: "菜单与工具栏")
        case .appearance: String(localized: "外观")
        case .extensions: String(localized: "扩展")
        }
    }
}

/// 窗口内容：顶部是分类页签，下面是页面，错误显示在最上面。
struct SettingsRootView: View {
    @Bindable var state: SettingsWindowState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(SettingsPage.allCases) { page in
                    Button(page.title) { state.page = page }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: state.page == page ? .semibold : .regular))
                        .foregroundStyle(Color(nsColor: state.page == page ? Theme.text : Theme.text2))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(state.page == page ? Color(nsColor: Theme.selected) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("settings.tab.\(page.rawValue)")
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            SettingsDivider()
            if let error = state.model.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: Theme.danger))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: Theme.dangerSoft))
            }
            Group {
                switch state.page {
                case .browse: BrowseSettingsPage(model: state.model, onEditRules: { state.page = .rules })
                case .display: DisplaySettingsPage(model: state.model)
                case .cache: CacheSettingsPage(model: state.model)
                case .rules: PathRulesPage(model: state.model)
                case .files: FileSettingsPage(model: state.model)
                case .shortcuts: ShortcutsSettingsPage(model: state.model.shortcuts)
                case .pointer: PointerSettingsPage(model: state.model.pointer)
                case .menus: MenusSettingsPage(model: state.model.menus)
                case .appearance: AppearanceSettingsPage(model: state.model, scrollTarget: state.scrollTarget)
                case .extensions: ExtensionsSettingsPage(model: state.model.extensions, shortcuts: state.model.shortcuts)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(Color(nsColor: Theme.text))
        .background(Color(nsColor: Theme.ground))
    }
}

/// 全局默认书设置的绑定。
@MainActor
private func book<Value>(_ model: SettingsModel, _ path: WritableKeyPath<ResolvedBookSettings, Value>) -> Binding<Value> {
    Binding(
        get: { model.global.defaultBook[keyPath: path] },
        set: { value in model.updateGlobal { $0.defaultBook[keyPath: path] = value } }
    )
}

/// 全局默认的浏览方式：分页的单页、双页和三种连续方式，与工具栏一致。
struct BrowseChoice: Hashable {
    var browseMode: BrowseMode
    var pageMode: PageMode?

    static let options: [(String, BrowseChoice)] = [
        (String(localized: "单页"), BrowseChoice(browseMode: .paged, pageMode: .single)),
        (String(localized: "双页"), BrowseChoice(browseMode: .paged, pageMode: .double)),
        (String(localized: "瀑布"), BrowseChoice(browseMode: .waterfall)),
        (String(localized: "竖条"), BrowseChoice(browseMode: .verticalStrip)),
        (String(localized: "横条"), BrowseChoice(browseMode: .horizontalStrip)),
    ]
}

@MainActor
func browseChoice(_ model: SettingsModel) -> Binding<BrowseChoice> {
    Binding(
        get: {
            let book = model.global.defaultBook
            return BrowseChoice(browseMode: book.browseMode, pageMode: book.browseMode == .paged ? book.pageMode : nil)
        },
        set: { choice in
            model.updateGlobal {
                $0.defaultBook.browseMode = choice.browseMode
                if let pageMode = choice.pageMode { $0.defaultBook.pageMode = pageMode }
            }
        }
    )
}

@MainActor
func global<Value>(_ model: SettingsModel, _ path: WritableKeyPath<GlobalSettings, Value>) -> Binding<Value> {
    Binding(
        get: { model.global[keyPath: path] },
        set: { value in model.updateGlobal { $0[keyPath: path] = value } }
    )
}

struct BrowseSettingsPage: View {
    let model: SettingsModel
    let onEditRules: () -> Void
    @State private var historyText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    Text("新打开的书使用这些默认值。书的设置优先于路径规则，路径规则优先于这里。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: Theme.text2))
                    Spacer()
                    Button(action: onEditRules) { Text("编辑路径规则").underline() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: Theme.text))
                }
                SettingsCard {
                    SettingsRow(title: String(localized: "浏览方式")) {
                        SettingsSegments(label: String(localized: "浏览方式"), options: BrowseChoice.options, selection: browseChoice(model))
                    }
                }
                SettingsSection(title: String(localized: "页面排序")) {
                    SettingsRow(title: String(localized: "排序依据"), detail: String(localized: "数字按大小，中文按拼音")) {
                        SettingsPopup(label: String(localized: "排序依据"), options: OverrideField.sortKeys, selection: book(model, \.sort.key))
                    }
                    SettingsDivider()
                    SettingsRow(title: String(localized: "顺序")) {
                        SettingsSegments(label: String(localized: "顺序"), options: [(String(localized: "升序"), true), (String(localized: "降序"), false)], selection: book(model, \.sort.ascending))
                    }
                    SettingsDivider()
                    SettingsRow(title: String(localized: "文件夹"), detail: String(localized: "递归展开时，子文件夹的内容排在前面或与文件混排")) {
                        SettingsSegments(label: String(localized: "文件夹"), options: [(String(localized: "文件夹在前"), true), (String(localized: "与文件混排"), false)], selection: book(model, \.sort.foldersFirst))
                    }
                }
                SettingsSection(title: String(localized: "子文件夹")) {
                    SettingsRow(title: String(localized: "递归展开"), detail: String(localized: "关闭时，每个子文件夹作为下一本书")) {
                        SettingsSwitch(label: String(localized: "递归展开"), isOn: book(model, \.recursion.enabled))
                    }
                    SettingsDivider()
                    SettingsRow(title: String(localized: "展开深度")) {
                        SettingsStepper(format: { String(localized: "\($0) 层") }, range: 1...16, value: book(model, \.recursion.maxDepth))
                            .disabled(!model.global.defaultBook.recursion.enabled)
                    }
                }
                Text("只含一个子文件夹、没有图片的目录会自动进入下一层。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.text2))
                    .padding(.horizontal, 12)
                SettingsSection(title: String(localized: "历史")) {
                    SettingsRow(title: String(localized: "保留最近"), detail: String(localized: "超过的旧记录立即删除，不影响书的阅读进度")) {
                        HStack(spacing: 6) {
                            TextField(String(localized: "历史保留本数"), text: $historyText)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 64)
                                .onSubmit(commitHistory)
                            Text("本")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(nsColor: Theme.text2))
                        }
                    }
                }
                SettingsSection(title: String(localized: "视频")) {
                    SettingsRow(
                        title: String(localized: "悬停预览视频画面"),
                        detail: String(localized: "在画廊里的视频上左右移动鼠标、或停在播放进度条上时显示对应位置的画面。第一次预览会读取视频的多个位置，预览帧存在缩略图缓存里。")
                    ) {
                        SettingsSwitch(label: String(localized: "悬停预览视频画面"), isOn: global(model, \.videoHoverPreview))
                            .accessibilityIdentifier("settings.browse.videoHoverPreview")
                    }
                }
            }
            .padding(16)
        }
        .onAppear { historyText = String(model.global.historyLimit) }
        .onChange(of: model.global.historyLimit) { _, value in historyText = String(value) }
        .onDisappear(perform: commitHistory)
    }

    private func commitHistory() {
        if let value = Int(historyText.trimmingCharacters(in: .whitespaces)) {
            model.setHistoryLimit(value)
        }
        historyText = String(model.global.historyLimit)
    }
}

struct DisplaySettingsPage: View {
    let model: SettingsModel
    @State private var decodeText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("这里同样是默认值；在主窗口“显示”里的改动只作用于当前书。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: Theme.text2))
                SettingsSection(title: String(localized: "双页")) {
                    SettingsRow(title: String(localized: "阅读方向"), detail: String(localized: "右开：从右往左翻页")) {
                        SettingsSegments(label: String(localized: "阅读方向"), options: OverrideField.directions, selection: book(model, \.direction))
                    }
                    SettingsDivider()
                    SettingsRow(title: String(localized: "首页单页"), detail: String(localized: "封面单独占一帧")) {
                        SettingsSwitch(label: String(localized: "首页单页"), isOn: book(model, \.firstPageSingle))
                    }
                    SettingsDivider()
                    SettingsRow(title: String(localized: "宽页"), detail: String(localized: "宽大于高的页面：照常配对、单独成帧或拆成两页")) {
                        SettingsSegments(label: String(localized: "宽页"), options: OverrideField.widePages, selection: book(model, \.widePage))
                    }
                }
                SettingsSection(title: String(localized: "缩放")) {
                    SettingsRow(title: String(localized: "缩放方式")) {
                        SettingsPopup(label: String(localized: "缩放方式"), options: OverrideField.scaleModes, selection: book(model, \.scaleMode))
                    }
                    SettingsDivider()
                    SettingsRow(title: String(localized: "仅缩小，不放大"), detail: String(localized: "适合类模式下，小图保持原始尺寸")) {
                        SettingsSwitch(label: String(localized: "仅缩小，不放大"), isOn: Binding(
                            get: { !model.global.defaultBook.allowUpscale },
                            set: { value in model.updateGlobal { $0.defaultBook.allowUpscale = !value } }
                        ))
                    }
                    SettingsDivider()
                    SettingsRow(title: String(localized: "翻页时保持缩放与位置"), detail: String(localized: "换页后沿用当前的缩放比例和滚动位置")) {
                        SettingsSwitch(label: String(localized: "翻页时保持缩放与位置"), isOn: book(model, \.keepZoomOnPageTurn))
                    }
                }
                SettingsSection(title: String(localized: "重采样")) {
                    SettingsRow(title: String(localized: "算法")) {
                        SettingsSegments(label: String(localized: "算法"), options: OverrideField.resamples, selection: book(model, \.resample))
                    }
                    SettingsDivider()
                    SettingsRow(title: String(localized: "锐化强度")) {
                        HStack(spacing: 10) {
                            Slider(value: book(model, \.sharpen), in: 0...1, step: 0.05)
                                .labelsHidden()
                                .controlSize(.small)
                                .frame(width: 140)
                            Text(String(format: "%.2f", model.global.defaultBook.sharpen))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Color(nsColor: Theme.text2))
                        }
                    }
                }
                SettingsSection(title: String(localized: "背景")) {
                    SettingsRow(title: String(localized: "默认背景")) {
                        SettingsPopup(
                            label: String(localized: "默认背景"),
                            options: Self.backgroundOptions(current: model.global.defaultBook.background),
                            selection: book(model, \.background)
                        )
                    }
                }
                SettingsSection(title: String(localized: "大图")) {
                    SettingsRow(title: String(localized: "解码尺寸上限"), detail: String(localized: "按屏幕所需尺寸解码，长边不超过此值；放大超过时改用原图，超大图分块显示")) {
                        HStack(spacing: 6) {
                            TextField(String(localized: "解码尺寸上限"), text: $decodeText)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 64)
                                .onSubmit(commitDecode)
                            Text(verbatim: "px")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(nsColor: Theme.text2))
                        }
                    }
                }
            }
            .padding(16)
        }
        .onAppear { decodeText = String(model.global.maxDecodeLongSide) }
        .onChange(of: model.global.maxDecodeLongSide) { _, value in decodeText = String(value) }
        .onDisappear(perform: commitDecode)
    }

    private static func backgroundOptions(current: ViewerBackground) -> [(String, ViewerBackground)] {
        if case .custom = current {
            return OverrideField.backgrounds + [(String(localized: "自定义"), current)]
        }
        return OverrideField.backgrounds
    }

    private func commitDecode() {
        if let value = Int(decodeText.trimmingCharacters(in: .whitespaces)) {
            model.setMaxDecodeLongSide(value)
        }
        decodeText = String(model.global.maxDecodeLongSide)
    }
}

struct CacheSettingsPage: View {
    let model: SettingsModel

    private static let gb: Int64 = 1 << 30
    private static let mb: Int64 = 1 << 20

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(title: String(localized: "缓存位置")) {
                    SettingsRow(title: model.cacheDirectory.path(percentEncoded: false)) {
                        Button("在访达中显示") { revealInFinder(model.cacheDirectory) }.controlSize(.small)
                    }
                }
                SettingsSection(title: String(localized: "磁盘缓存")) {
                    SettingsRow(title: String(localized: "缩略图"), detail: String(localized: "书架、页面列表和瀑布流使用")) {
                        SettingsPopup(
                            label: String(localized: "缩略图缓存上限"),
                            options: budgetOptions([1, 2, 5, 10, 20, 50, 100].map { $0 * Self.gb }, current: model.global.cache.thumbnailBytes),
                            selection: global(model, \.cache.thumbnailBytes)
                        )
                    }
                    SettingsDivider()
                    SettingsRow(title: String(localized: "浏览图"), detail: browseDetail) {
                        HStack(spacing: 10) {
                            SettingsSwitch(label: String(localized: "浏览图缓存"), isOn: global(model, \.cache.browseCacheEnabled))
                            SettingsPopup(
                                label: String(localized: "浏览图缓存上限"),
                                options: budgetOptions([5, 10, 20, 50, 100, 200].map { $0 * Self.gb }, current: model.global.cache.browseBytes),
                                selection: global(model, \.cache.browseBytes)
                            )
                            .disabled(!model.global.cache.browseCacheEnabled)
                        }
                    }
                }
                Text("超过上限时，先淘汰最久未用的。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.text2))
                    .padding(.horizontal, 12)
                SettingsSection(title: String(localized: "内存")) {
                    SettingsRow(title: String(localized: "原始数据"), detail: String(localized: "最近读取的文件内容，换尺寸重新解码时不必再读 NAS")) {
                        SettingsPopup(
                            label: String(localized: "原始数据内存上限"),
                            options: budgetOptions([128, 256, 512, 1024, 2048].map { $0 * Self.mb }, current: model.global.cache.rawBytes),
                            selection: global(model, \.cache.rawBytes)
                        )
                    }
                    SettingsDivider()
                    SettingsRow(title: String(localized: "解码结果"), detail: String(localized: "可见页的显示尺寸图和原图；默认取 1 GB 与内存的 5% 中较小者")) {
                        SettingsPopup(
                            label: String(localized: "解码结果内存上限"),
                            options: budgetOptions([512, 1024, 2048, 4096, 8192].map { $0 * Self.mb }, current: model.global.cache.decodedBytes),
                            selection: global(model, \.cache.decodedBytes)
                        )
                    }
                    SettingsDivider()
                    SettingsRow(title: String(localized: "缩略图内存缓存"), detail: String(localized: "书架、页面列表和瀑布流使用")) {
                        SettingsPopup(
                            label: String(localized: "缩略图内存上限"),
                            options: budgetOptions([128, 256, 512, 1024, 2048].map { $0 * Self.mb }, current: model.global.cache.thumbnailMemoryBytes),
                            selection: global(model, \.cache.thumbnailMemoryBytes)
                        )
                    }
                    SettingsDivider()
                    SettingsRow(title: String(localized: "浏览图预载"), detail: String(localized: "查看器前后页帧的预解码结果")) {
                        SettingsPopup(
                            label: String(localized: "浏览图预载内存上限"),
                            options: budgetOptions([128, 256, 512, 1024, 2048].map { $0 * Self.mb }, current: model.global.cache.preloadBytes),
                            selection: global(model, \.cache.preloadBytes)
                        )
                    }
                }
                Text("系统内存紧张时，四项缓存会暂时收缩到上限的 50% 或 25%。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.text2))
                    .padding(.horizontal, 12)
                SettingsSection(title: String(localized: "预取与预生成")) {
                    SettingsRow(title: String(localized: "预解码"), detail: String(localized: "查看器当前页帧的前后")) {
                        SettingsStepper(prefix: String(localized: "前后各"), format: { String(localized: "\($0) 帧") }, range: 0...8, value: global(model, \.prefetch.viewerDecodeFrames))
                    }
                    SettingsDivider()
                    SettingsRow(title: String(localized: "预读原始数据"), detail: String(localized: "预解码范围之外，沿阅读方向继续读取文件")) {
                        SettingsStepper(prefix: String(localized: "再读"), format: { String(localized: "\($0) 页") }, range: 0...32, value: global(model, \.prefetch.viewerReadAheadPages))
                    }
                    SettingsDivider()
                    SettingsRow(title: String(localized: "当前书的全部页面（可见区域优先）"), detail: String(localized: "在后台生成，存入磁盘缓存")) {
                        SettingsSwitch(label: String(localized: "预生成当前书的缩略图"), isOn: global(model, \.prefetch.currentBookPages))
                    }
                    SettingsDivider()
                    SettingsRow(title: String(localized: "预生成书架上后面的书")) {
                        SettingsStepper(prefix: String(localized: "书架上后"), format: { String(localized: "\($0) 本书") }, range: 0...8, value: global(model, \.prefetch.neighborBooks))
                    }
                    SettingsDivider()
                    SettingsRow(title: String(localized: "当前目录各书的封面")) {
                        SettingsSwitch(label: String(localized: "预生成封面"), isOn: global(model, \.prefetch.shelfCovers))
                    }
                }
            }
            .padding(16)
        }
    }

    private var browseDetail: String {
        let base = String(localized: "屏幕尺寸的图，再次打开时不必重读 NAS")
        guard let launch = model.launchBrowseCacheEnabled, launch != model.global.cache.browseCacheEnabled else {
            return base + String(localized: "。开关在下次启动时生效")
        }
        return base + String(localized: "。已改动，下次启动时生效")
    }
}

struct FileSettingsPage: View {
    let model: SettingsModel

    private static let conflictOptions: [(String, ConflictPolicy)] = [
        (String(localized: "加序号"), .appendNumber),
        (String(localized: "跳过"), .skip),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(title: String(localized: "复制和移动")) {
                    SettingsRow(title: String(localized: "目标中已有同名项时"), detail: conflictDetail) {
                        SettingsSegments(
                            label: String(localized: "目标中已有同名项时"),
                            options: Self.conflictOptions,
                            selection: global(model, \.fileOperations.nameConflict)
                        )
                    }
                }
                Text("两种方式都不覆盖目标里的文件。跳过的项会在结果里注明。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.text2))
                    .padding(.horizontal, 12)
            }
            .padding(16)
        }
    }

    private var conflictDetail: String {
        switch model.global.fileOperations.nameConflict {
        case .appendNumber: String(localized: "在名字后加序号，例如 IMG_0012 (2).jpg")
        case .skip: String(localized: "保留目标里的文件，不放入这一项")
        }
    }
}
