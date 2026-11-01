#if DEBUG
import AppKit
import MVFoundation
import MVIO
import MVLayout
import MVSettings
import MVTestSupport
import os
import QuartzCore

/// 画布引擎的回归测试窗口：1 万项，缩略图来自 MockImagePipeline，四种布局可切换。
///
/// “运行场景”按显示链接逐帧驱动快速拖动、惯性滚动、停走和改变窗口尺寸，并统计帧间隔与主线程用时。
/// 启动参数：
/// - `-MVCanvasTest YES` 直接打开本窗口，`-MVCanvasTestAutorun YES` 打开后运行场景并退出；
/// - `-MVCanvasTestLayout masonry|grid|verticalStrip|horizontalStrip` 选择布局，默认砌体；
/// - `-MVCanvasTestReport <路径>` 把结果写成 JSON。
final class CanvasTestWindowController: NSWindowController, NSWindowDelegate {
    static let launchKey = "MVCanvasTest"
    static let autorunKey = "MVCanvasTestAutorun"
    static let reportKey = "MVCanvasTestReport"
    static let layoutKey = "MVCanvasTestLayout"
    static let pageCount = 10_000
    /// 每 1000 项注入一个读取失败，用来检查错误标记。
    static let failureEvery = 1000

    private static var current: CanvasTestWindowController?

    static func show(autorun: Bool) {
        let controller = current ?? CanvasTestWindowController()
        current = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.startDisplayLink()
        if autorun {
            NSApp.activate()
            // 等首屏缩略图到齐再开始。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { controller.runScenario(terminateWhenDone: true) }
        }
    }

    private enum Timing: Int, CaseIterable {
        case fast
        case nas

        var title: String {
            switch self {
            case .fast: "快速：400 张/秒，延迟 20 ms"
            case .nas: "NAS 首访：2.5 张/秒"
            }
        }

        var mock: MockTiming {
            var timing = MockTiming()
            if self == .fast {
                timing.readsPerSecond = 400
            }
            return timing
        }
    }

    private static let kindTitles: [(CollectionLayoutKind, String)] = [
        (.masonry, "砌体"), (.grid, "网格"), (.verticalStrip, "纵向条"), (.horizontalStrip, "横向条"),
    ]
    private static let sourceTitles: [(CanvasImageSource, String)] = [(.thumbnail, "缩略图"), (.display, "显示图（渐进）")]

    private let tree: MockTree
    private let failures: [Location: IOError]
    private var items: [CanvasItem]
    private let canvas: CanvasView
    private let hud = NSTextField(labelWithString: "")
    private let kindPopup = NSPopUpButton()
    private let directionPopup = NSPopUpButton()
    private let sourcePopup = NSPopUpButton()
    private let timingPopup = NSPopUpButton()
    private let extentSlider = NSSlider()
    private let runButton = NSButton()
    private var timing = Timing.fast
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var scenario: ScenarioRun?
    private var arrival: Timer?
    /// 宽高比重新到达时，还没到达的项（乱序）和各项是否已知。
    private var arrivalOrder: [Int] = []
    private var known: [Bool] = []
    private var hudTimer: Timer?
    private var lastRange = CanvasVisibleRange(visible: 0..<0, margin: 0..<0)
    private let logger = Logger(category: "canvas-test")

    private init() {
        let (tree, items) = Self.makeLibrary()
        self.tree = tree
        self.items = items
        failures = Dictionary(uniqueKeysWithValues: stride(from: Self.failureEvery - 1, to: items.count, by: Self.failureEvery).map {
            (items[$0].identity.location, IOError.notFound(items[$0].identity.location))
        })
        let kind = UserDefaults.standard.string(forKey: Self.layoutKey).flatMap(CollectionLayoutKind.init(rawValue:)) ?? .masonry
        canvas = CanvasView(pipeline: MockImagePipeline(environment: MockEnvironment(MockOptions(tree: tree, timing: Timing.fast.mock, failures: failures))), kind: kind, imageSource: .thumbnail)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        updateTitle()
        // 验收要在 ProMotion 屏幕上进行：放到刷新率最高的屏幕中央。
        if let screen = NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }) {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
        } else {
            window.center()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 数据

    /// 1 万张图，尺寸按序号确定性地取自几种常见比例，含横图、方图和长条。
    private static func makeLibrary() -> (MockTree, [CanvasItem]) {
        let shapes = [
            PixelSize(width: 3600, height: 5400), PixelSize(width: 5400, height: 3600), PixelSize(width: 4000, height: 4000),
            PixelSize(width: 3000, height: 4000), PixelSize(width: 4000, height: 3000), PixelSize(width: 1080, height: 1920),
            PixelSize(width: 2400, height: 3600), PixelSize(width: 6000, height: 2000), PixelSize(width: 1200, height: 4800),
        ]
        let pages = (1...pageCount).map { number -> (String, PixelSize) in
            var mixed = UInt64(number) &* 0x9E37_79B9_7F4A_7C15
            mixed = (mixed ^ (mixed >> 31)) &* 0xBF58_476D_1CE4_E5B9
            return (String(format: "%05d.jpg", number), shapes[Int((mixed ^ (mixed >> 29)) % UInt64(shapes.count))])
        }
        let nodes = pages.map { MockNode.image($0.0, $0.1) }
        let tree = MockTree(nodes: [.directory("瀑布流", nodes)])
        let items = zip(pages, nodes).map { page, node in
            let identity = ContentIdentity(location: tree.location("瀑布流/\(node.name)"), size: node.size, modificationNanos: node.modificationNanos)
            return CanvasItem(identity: identity, aspectRatio: Double(page.1.width) / Double(page.1.height))
        }
        return (tree, items)
    }

    private func makePipeline() -> MockImagePipeline {
        MockImagePipeline(environment: MockEnvironment(MockOptions(tree: tree, timing: timing.mock, failures: failures)))
    }

    // MARK: - 界面

    private func buildContent(in window: NSWindow) {
        let content = NSView()
        window.contentView = content

        for (kind, title) in Self.kindTitles {
            kindPopup.addItem(withTitle: title)
            if kind == canvas.kind { kindPopup.selectItem(at: kindPopup.numberOfItems - 1) }
        }
        directionPopup.addItems(withTitles: ["左开", "右开"])
        for (_, title) in Self.sourceTitles {
            sourcePopup.addItem(withTitle: title)
        }
        for timing in Timing.allCases {
            timingPopup.addItem(withTitle: timing.title)
        }
        extentSlider.minValue = canvas.itemExtentRange.lowerBound
        extentSlider.maxValue = canvas.itemExtentRange.upperBound
        extentSlider.doubleValue = canvas.itemExtent
        extentSlider.isContinuous = true
        extentSlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        runButton.title = "运行场景"
        runButton.bezelStyle = .push
        let reverseButton = NSButton(title: "倒序", target: self, action: #selector(reverseItems(_:)))
        let arrivalButton = NSButton(title: "宽高比重新到达", target: self, action: #selector(replayArrival(_:)))
        for (control, action) in [
            (kindPopup, #selector(kindChanged(_:))), (directionPopup, #selector(directionChanged(_:))), (sourcePopup, #selector(sourceChanged(_:))),
            (timingPopup, #selector(timingChanged(_:))), (extentSlider, #selector(extentChanged(_:))), (runButton, #selector(runScenarioAction(_:))),
        ] as [(NSControl, Selector)] {
            control.target = self
            control.action = action
        }
        let bar = NSStackView(views: [kindPopup, directionPopup, extentSlider, sourcePopup, timingPopup, reverseButton, arrivalButton, runButton])
        bar.orientation = .horizontal
        bar.spacing = 8

        hud.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        hud.textColor = .white
        hud.drawsBackground = true
        hud.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        hud.maximumNumberOfLines = 0

        for view in [bar, canvas, hud] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            canvas.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            hud.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 8),
            hud.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -24),
        ])

        canvas.onMeasure = { [weak self] measure in
            self?.scenario?.record(measure)
        }
        canvas.onVisibleRangeChange = { [weak self] range in
            self?.lastRange = range
        }
        canvas.onItemExtentChange = { [weak self] extent in
            self?.extentSlider.doubleValue = extent
        }
        canvas.setItems(items)

        hudTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHUD() }
        }
        updateHUD()
    }

    private func updateTitle() {
        let kind = Self.kindTitles.first { $0.0 == canvas.kind }?.1 ?? ""
        window?.title = "画布测试（\(Self.pageCount) 项，\(kind)）"
    }

    /// 显示链接跟随创建时窗口所在的屏幕，窗口换屏后要重新创建。
    private func startDisplayLink() {
        link?.invalidate()
        let link = canvas.displayLink(target: self, selector: #selector(step(_:)))
        let fastest = Float(window?.screen?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fastest, maximum: fastest, preferred: fastest)
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTimestamp = nil
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if link != nil {
            startDisplayLink()
        }
    }

    private func updateHUD() {
        let counters = canvas.counters
        var lines = [
            "项 \(items.count) · 图层 \(counters.activeLayers)（峰值 \(counters.peakLayers)，共创建 \(counters.createdLayers)）",
            "已加载 \(counters.loadedImages) · 请求中 \(counters.inFlight) · 选中 \(canvas.selection.count)",
            "回报：可见 \(lastRange.visible.lowerBound)..<\(lastRange.visible.upperBound) · 余量 \(lastRange.margin.lowerBound)..<\(lastRange.margin.upperBound)",
            "锚点：\(counters.anchoredRelayouts) 次重排，离开视口 \(counters.anchorMisses) 次",
        ]
        if let scenario {
            lines.append("场景：\(scenario.currentPhase.name)")
        }
        hud.stringValue = lines.joined(separator: "\n")
    }

    @objc private func kindChanged(_ sender: NSPopUpButton) {
        canvas.kind = Self.kindTitles[sender.indexOfSelectedItem].0
        updateTitle()
    }

    @objc private func directionChanged(_ sender: NSPopUpButton) {
        canvas.direction = sender.indexOfSelectedItem == 0 ? .leftToRight : .rightToLeft
    }

    @objc private func sourceChanged(_ sender: NSPopUpButton) {
        canvas.imageSource = Self.sourceTitles[sender.indexOfSelectedItem].0
    }

    @objc private func extentChanged(_ sender: NSSlider) {
        canvas.itemExtent = sender.doubleValue.rounded()
    }

    @objc private func timingChanged(_ sender: NSPopUpButton) {
        guard let timing = Timing(rawValue: sender.indexOfSelectedItem), timing != self.timing else { return }
        self.timing = timing
        canvas.replacePipeline(makePipeline())
    }

    /// 整体重排：选中项（没有时为中心项）保持在视口中的位置。
    @objc private func reverseItems(_ sender: Any?) {
        items.reverse()
        canvas.setItems(items)
    }

    /// 宽高比全部清空后按乱序分批到达：只排已知的最长前缀，已排的项不动。
    @objc private func replayArrival(_ sender: Any?) {
        arrival?.invalidate()
        arrivalOrder = items.indices.shuffled()
        known = Array(repeating: false, count: items.count)
        canvas.setItems(items.map { CanvasItem(identity: $0.identity, aspectRatio: nil) })
        arrival = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.arriveBatch() }
        }
    }

    private func arriveBatch() {
        for index in arrivalOrder.suffix(500) {
            known[index] = true
        }
        arrivalOrder.removeLast(min(500, arrivalOrder.count))
        canvas.setItems(items.indices.map { CanvasItem(identity: items[$0].identity, aspectRatio: known[$0] ? items[$0].aspectRatio : nil) })
        if arrivalOrder.isEmpty {
            arrival?.invalidate()
        }
    }

    @objc private func runScenarioAction(_ sender: Any?) {
        runScenario(terminateWhenDone: false)
    }

    func windowWillClose(_ notification: Notification) {
        link?.invalidate()
        hudTimer?.invalidate()
        arrival?.invalidate()
        Self.current = nil
    }

    // MARK: - 场景

    private var horizontal: Bool {
        canvas.kind.isHorizontal
    }

    private func runScenario(terminateWhenDone: Bool) {
        guard scenario == nil, let window else { return }
        scroll(to: (contentLength - viewportLength) / 2)
        scenario = ScenarioRun(
            phases: ScenarioRun.phases(horizontal: horizontal), originalFrame: window.frame, terminateWhenDone: terminateWhenDone,
            refreshInterval: 1000 / Double(max(window.screen?.maximumFramesPerSecond ?? 60, 1))
        )
        runButton.isEnabled = false
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastTimestamp = now }
        guard let last = lastTimestamp, var run = scenario else { return }
        let interval = now - last
        if run.start == nil {
            run.start = now
        }
        let elapsed = now - (run.start ?? now)
        guard let (index, phaseTime) = run.phase(at: elapsed) else {
            scenario = nil
            run.enter(run.phases.count, at: now, counters: canvas.counters)
            finish(run)
            return
        }
        run.enter(index, at: now, counters: canvas.counters)
        run.currentIndex = index
        run.recordInterval(interval)
        // 先写回：下面的滚动会同步触发图层更新，用时记进 `scenario`。
        scenario = run
        let dt = min(interval, 0.05)
        switch run.phases[index].motion {
        case .pause:
            break
        case let .drag(speed, flipEvery):
            scroll(by: speed * (Int(phaseTime / flipEvery).isMultiple(of: 2) ? 1 : -1) * dt)
        case let .flick(initial, count):
            let each = run.phases[index].duration / Double(count)
            let flick = Int(phaseTime / each)
            let velocity = initial * (flick.isMultiple(of: 2) ? 1 : -1) * pow(0.998, (phaseTime - Double(flick) * each) * 1000)
            scroll(by: velocity * dt)
        case let .stopAndGo(speed, move, rest):
            let cycle = Int(phaseTime / (move + rest))
            if phaseTime - Double(cycle) * (move + rest) < move {
                scroll(by: speed * (cycle.isMultiple(of: 2) ? 1 : -1) * dt)
            }
        case let .resize(minimum, maximum, period):
            let length = (minimum + maximum) / 2 + (maximum - minimum) / 2 * sin(2 * .pi * phaseTime / period)
            resizeWindow(crossLength: length, from: run.originalFrame)
        }
    }

    private var contentLength: CGFloat {
        horizontal ? canvas.documentView?.frame.width ?? 0 : canvas.documentView?.frame.height ?? 0
    }

    private var viewportLength: CGFloat {
        horizontal ? canvas.contentView.bounds.width : canvas.contentView.bounds.height
    }

    private func scroll(by delta: CGFloat) {
        let origin = canvas.contentView.bounds.origin
        scroll(to: (horizontal ? origin.x : origin.y) + delta)
    }

    private func scroll(to position: CGFloat) {
        let clip = canvas.contentView
        let clamped = min(max(position, 0), max(0, contentLength - viewportLength))
        clip.scroll(to: horizontal ? NSPoint(x: clamped, y: 0) : NSPoint(x: 0, y: clamped))
        canvas.reflectScrolledClipView(clip)
    }

    /// 改变横截方向的窗口尺寸（横向条改高度，其余改宽度），保持窗口中心不动。
    private func resizeWindow(crossLength: CGFloat, from original: NSRect) {
        guard let window else { return }
        var frame = window.frame
        if horizontal {
            frame.size.height = crossLength.rounded()
            frame.origin.y = original.midY - frame.height / 2
        } else {
            frame.size.width = crossLength.rounded()
            frame.origin.x = original.midX - frame.width / 2
        }
        window.setFrame(frame, display: true)
    }

    private func finish(_ run: ScenarioRun) {
        window?.setFrame(run.originalFrame, display: true)
        runButton.isEnabled = true
        let counters = canvas.counters
        let summary = CanvasTestSummary(
            screen: window?.screen?.localizedName ?? "",
            maximumFramesPerSecond: window?.screen?.maximumFramesPerSecond ?? 0,
            timing: timing.title,
            layout: canvas.kind.rawValue,
            direction: canvas.direction.rawValue,
            imageSource: canvas.imageSource.rawValue,
            itemExtent: canvas.itemExtent,
            items: items.count,
            peakLayers: counters.peakLayers,
            createdLayers: counters.createdLayers,
            activeLayersAtEnd: counters.activeLayers,
            loadedImages: counters.loadedImages,
            phases: run.results(endCounters: counters)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(summary)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        logger.info("画布测试结果：\(json, privacy: .public)")
        if let path = UserDefaults.standard.string(forKey: Self.reportKey) {
            do {
                try Data((json + "\n").utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                logger.error("写结果失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        updateHUD()
        if run.terminateWhenDone {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        }
    }
}

/// 一次场景运行：各阶段的帧间隔、主线程用时、滚动停止后请求的发出时间和锚点检查。
private struct ScenarioRun {
    enum Motion {
        case pause
        /// 匀速拖动，每隔 `flipEvery` 秒换方向。
        case drag(speed: CGFloat, flipEvery: Double)
        /// 松手后的惯性：初速 `initial`，每毫秒衰减为 0.998 倍，与系统的默认减速度相当；方向交替。
        case flick(initial: CGFloat, count: Int)
        /// 匀速移动 `move` 秒后停 `rest` 秒，方向交替；用来测滚动停止后可见项的请求。
        case stopAndGo(speed: CGFloat, move: Double, rest: Double)
        /// 窗口横截方向的尺寸按正弦在两个值之间变化。
        case resize(minimum: CGFloat, maximum: CGFloat, period: Double)
    }

    struct Phase {
        var name: String
        var duration: Double
        var motion: Motion
        var measured = true
    }

    /// 与 S0-F1 相同的三个阶段，加上停走。横向条改窗口高度，其余改宽度。
    static func phases(horizontal: Bool) -> [Phase] {
        [
            Phase(name: "准备", duration: 1, motion: .pause, measured: false),
            Phase(name: "快速拖动", duration: 6, motion: .drag(speed: 6000, flipEvery: 1.5)),
            Phase(name: "惯性滚动", duration: 10.5, motion: .flick(initial: 15000, count: 3)),
            Phase(name: "停走", duration: 6, motion: .stopAndGo(speed: 3000, move: 0.35, rest: 0.4)),
            Phase(name: "改变窗口尺寸", duration: 6, motion: horizontal ? .resize(minimum: 500, maximum: 900, period: 2) : .resize(minimum: 800, maximum: 1400, period: 2)),
        ]
    }

    let phases: [Phase]
    let originalFrame: NSRect
    let terminateWhenDone: Bool
    /// 屏幕的最短刷新周期，毫秒。
    let refreshInterval: Double
    var start: CFTimeInterval?
    /// 各阶段开始时的显示链接时间戳，最后一项是结束时间；与 mach_absolute_time 同一时基，用来对齐 Instruments 的录制。
    private var phaseStarts: [CFTimeInterval?]
    /// 各阶段开始时画布的计数，用来算每个阶段的锚点检查。
    private var countersAtPhaseStart: [CanvasCounters?]
    var currentIndex = 0
    private var intervals: [[Double]]
    private var scrollUpdates: [[Double]]
    private var relayouts: [[Double]]
    private var settles: [[Double]]

    init(phases: [Phase], originalFrame: NSRect, terminateWhenDone: Bool, refreshInterval: Double) {
        self.phases = phases
        self.originalFrame = originalFrame
        self.terminateWhenDone = terminateWhenDone
        self.refreshInterval = refreshInterval
        // 多一项记结束时刻。
        phaseStarts = Array(repeating: nil, count: phases.count + 1)
        countersAtPhaseStart = Array(repeating: nil, count: phases.count + 1)
        intervals = Array(repeating: [], count: phases.count)
        scrollUpdates = Array(repeating: [], count: phases.count)
        relayouts = Array(repeating: [], count: phases.count)
        settles = Array(repeating: [], count: phases.count)
    }

    var currentPhase: Phase {
        phases[currentIndex]
    }

    func phase(at elapsed: Double) -> (Int, Double)? {
        var remaining = elapsed
        for (index, phase) in phases.enumerated() {
            if remaining < phase.duration { return (index, remaining) }
            remaining -= phase.duration
        }
        return nil
    }

    /// 进入第 `index` 个阶段（`phases.count` 表示结束）。显示链接停顿跨过整个阶段时，被跳过的阶段与它同时开始，记为空阶段。
    mutating func enter(_ index: Int, at time: CFTimeInterval, counters: CanvasCounters) {
        for phase in 0...index where phaseStarts[phase] == nil {
            phaseStarts[phase] = time
            countersAtPhaseStart[phase] = counters
        }
    }

    mutating func recordInterval(_ interval: Double) {
        intervals[currentIndex].append(interval * 1000)
    }

    mutating func record(_ measure: CanvasMeasure) {
        switch measure {
        case let .scroll(duration): scrollUpdates[currentIndex].append(Self.milliseconds(duration))
        case let .relayout(duration): relayouts[currentIndex].append(Self.milliseconds(duration))
        case let .settled(latency, visible) where visible > 0: settles[currentIndex].append(Self.milliseconds(latency))
        case .settled: break
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.attoseconds) * 1e-15 + Double(duration.components.seconds) * 1000
    }

    func results(endCounters: CanvasCounters) -> [CanvasTestSummary.Phase] {
        phases.indices.filter { phases[$0].measured }.map { index in
            let frames = intervals[index]
            let before = countersAtPhaseStart[index] ?? endCounters
            let after = countersAtPhaseStart[index + 1] ?? endCounters
            return CanvasTestSummary.Phase(
                name: phases[index].name,
                start: phaseStarts[index] ?? 0,
                end: phaseStarts[index + 1] ?? 0,
                frames: frames.count,
                intervalP50: percentile(frames, 0.5),
                intervalP99: percentile(frames, 0.99),
                intervalMax: frames.max() ?? 0,
                // 超过 1.5 个刷新周期视为显示链接错过了一帧。
                longIntervals: frames.filter { $0 > refreshInterval * 1.5 }.count,
                scrollUpdates: scrollUpdates[index].count,
                scrollUpdateP99: percentile(scrollUpdates[index], 0.99),
                scrollUpdateMax: scrollUpdates[index].max() ?? 0,
                relayouts: relayouts[index].count,
                relayoutP99: percentile(relayouts[index], 0.99),
                relayoutMax: relayouts[index].max() ?? 0,
                settles: settles[index].count,
                settleLatencyMax: settles[index].max() ?? 0,
                anchoredRelayouts: after.anchoredRelayouts - before.anchoredRelayouts,
                anchorMisses: after.anchorMisses - before.anchorMisses
            )
        }
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * fraction).rounded(.up)) - 1)]
    }
}

/// 场景结果，时间单位为毫秒。
struct CanvasTestSummary: Codable {
    struct Phase: Codable {
        var name: String
        /// 显示链接时间戳，秒。
        var start: Double
        var end: Double
        var frames: Int
        var intervalP50: Double
        var intervalP99: Double
        var intervalMax: Double
        var longIntervals: Int
        var scrollUpdates: Int
        var scrollUpdateP99: Double
        var scrollUpdateMax: Double
        var relayouts: Int
        var relayoutP99: Double
        var relayoutMax: Double
        /// 有可见项的滚动停止次数，以及停止后可见项的请求全部发出的最长用时。
        var settles: Int
        var settleLatencyMax: Double
        var anchoredRelayouts: Int
        var anchorMisses: Int
    }

    var screen: String
    var maximumFramesPerSecond: Int
    var timing: String
    var layout: String
    var direction: String
    var imageSource: String
    var itemExtent: Double
    var items: Int
    var peakLayers: Int
    var createdLayers: Int
    var activeLayersAtEnd: Int
    var loadedImages: Int
    var phases: [Phase]
}

extension AppDelegate {
    @objc func showCanvasTest(_ sender: Any?) {
        CanvasTestWindowController.show(autorun: false)
    }
}
#endif
