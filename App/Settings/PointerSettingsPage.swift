import AppKit
import MVCommands
import MVSettings
import Observation
import SwiftUI

/// 鼠标与触控板设置页的数据模型。
@MainActor
@Observable
final class PointerModel {
    struct PendingGestureConflict: Equatable {
        var directions: [PointerDirection]
        var existingCommand: CommandID
        var replacementCommand: CommandID?
    }

    struct TrackpadPair: Hashable {
        var first: CommandID?
        var second: CommandID?
    }

    enum WheelMode: Hashable {
        case standard, zoom, commands, none
    }

    static let defaultBindings = InputBindings.effective(defaults: .standard, user: KeyBindingsFile())

    static let wheelModifiers: [(label: String, value: KeyModifiers)] = [
        (String(localized: "无修饰键"), []),
        ("⌘", .command),
        ("⌥", .option),
        ("⇧", .shift),
        ("⌃", .control),
    ]

    static let trackpadPairPresets: [(title: String, pair: TrackpadPair)] = [
        (String(localized: "无"), TrackpadPair(first: nil, second: nil)),
        (String(localized: "翻页（按阅读方向）"), TrackpadPair(first: .frameLeft, second: .frameRight)),
        (String(localized: "上一帧 / 下一帧"), TrackpadPair(first: .framePrevious, second: .frameNext)),
        (String(localized: "上一页 / 下一页"), TrackpadPair(first: .pagePrevious, second: .pageNext)),
        (String(localized: "上一本书 / 下一本书"), TrackpadPair(first: .bookPrevious, second: .bookNext)),
        (String(localized: "缩小 / 放大"), TrackpadPair(first: .zoomOut, second: .zoomIn)),
    ]

    struct GestureEntry: Equatable {
        var directions: [PointerDirection]
        var command: CommandID
    }

    static let maxGestureDirections = 4

    var wheelDevice: WheelDevice = .mouse
    private(set) var file: KeyBindingsFile
    private(set) var recordedDirections: [PointerDirection] = []
    private(set) var pendingGestureConflict: PendingGestureConflict?
    private(set) var errorMessage: String?

    @ObservationIgnored private var bridge: DocumentStoreBridge<KeyBindingsFile>?

    init(store: JSONDocumentStore<KeyBindingsFile>?) {
        self.file = store?.value() ?? KeyBindingsFile()
        self.bridge = DocumentStoreBridge(
            store: store,
            onSync: { [weak self] in self?.file = $0 },
            onError: { [weak self] in self?.errorMessage = $0 }
        )
    }

    func reload() {
        bridge?.reload()
    }

    var effective: InputBindings {
        InputBindings.effective(defaults: .standard, user: file)
    }

    var hasCustomBindings: Bool {
        !(file.clickZones ?? []).isEmpty
            || !(file.wheel ?? []).isEmpty
            || !(file.trackpad ?? []).isEmpty
            || !(file.mouseGestures ?? []).isEmpty
    }

    var commandOptions: [(String, CommandID)] {
        SettingsCommandCatalog.all.map { (SettingsCommandCatalog.title(of: $0.id), $0.id) }
    }

    var optionalCommandOptions: [(String, CommandID?)] {
        [(String(localized: "无"), nil)] + SettingsCommandCatalog.all.map { (SettingsCommandCatalog.title(of: $0.id), Optional($0.id)) }
    }

    // MARK: 点击区域

    func clickZoneCommand(for zone: ClickZone) -> CommandID? {
        effective.command(for: zone)?.0
    }

    func setClickZone(_ command: CommandID?, for zone: ClickZone) {
        var next = (file.clickZones ?? []).filter { $0.zone != zone }
        if command != Self.defaultBindings.command(for: zone)?.0 {
            next.append(ClickZoneBinding(zone: zone, command: command))
        }
        let persisted: [ClickZoneBinding]? = next.isEmpty ? nil : next
        persist { $0.clickZones = persisted }
    }

    // MARK: 滚轮

    func wheelAction(device: WheelDevice, modifiers: KeyModifiers) -> WheelAction {
        effective.wheelAction(device: device, modifiers: modifiers)
    }

    private func defaultWheelAction(device: WheelDevice, modifiers: KeyModifiers) -> WheelAction? {
        InputBindingDefaults.standard.wheel.first { $0.device == device && $0.modifiers == modifiers }?.action
    }

    private func explicitUserWheelAction(device: WheelDevice, modifiers: KeyModifiers) -> WheelAction? {
        (file.wheel ?? []).first { $0.device == device && $0.modifiers == modifiers }?.action
    }

    func isWheelModified(device: WheelDevice, modifiers: KeyModifiers) -> Bool {
        guard let userAction = explicitUserWheelAction(device: device, modifiers: modifiers) else { return false }
        return userAction != defaultWheelAction(device: device, modifiers: modifiers)
    }

    func setWheelAction(_ action: WheelAction, device: WheelDevice, modifiers: KeyModifiers) {
        var next = (file.wheel ?? []).filter { !($0.device == device && $0.modifiers == modifiers) }
        if action != defaultWheelAction(device: device, modifiers: modifiers) {
            next.append(WheelBinding(device: device, modifiers: modifiers, action: action))
        }
        let persisted: [WheelBinding]? = next.isEmpty ? nil : next
        persist { $0.wheel = persisted }
    }

    func resetWheel(device: WheelDevice, modifiers: KeyModifiers) {
        let next = (file.wheel ?? []).filter { !($0.device == device && $0.modifiers == modifiers) }
        let persisted: [WheelBinding]? = next.isEmpty ? nil : next
        persist { $0.wheel = persisted }
    }

    // MARK: 触控板

    func trackpadSwipePair() -> TrackpadPair {
        TrackpadPair(first: effective.command(for: .swipeLeft)?.0, second: effective.command(for: .swipeRight)?.0)
    }

    func setTrackpadSwipe(_ pair: TrackpadPair) {
        setTrackpadInputs([(.swipeLeft, pair.first), (.swipeRight, pair.second)])
    }

    func trackpadDoubleTap() -> CommandID? {
        effective.command(for: .doubleTap)?.0
    }

    func setTrackpadDoubleTap(_ command: CommandID?) {
        setTrackpadInputs([(.doubleTap, command)])
    }

    func trackpadRotatePair() -> TrackpadPair {
        TrackpadPair(first: effective.command(for: .rotateLeft)?.0, second: effective.command(for: .rotateRight)?.0)
    }

    func setTrackpadRotate(_ pair: TrackpadPair) {
        setTrackpadInputs([(.rotateLeft, pair.first), (.rotateRight, pair.second)])
    }

    func trackpadPairOptions(current: TrackpadPair) -> [(String, TrackpadPair)] {
        if Self.trackpadPairPresets.contains(where: { $0.pair == current }) {
            return Self.trackpadPairPresets
        }
        let leftTitle = current.first.map(SettingsCommandCatalog.title(of:)) ?? String(localized: "无")
        let rightTitle = current.second.map(SettingsCommandCatalog.title(of:)) ?? String(localized: "无")
        return Self.trackpadPairPresets + [("\(leftTitle) / \(rightTitle)", current)]
    }

    private func setTrackpadInputs(_ updates: [(TrackpadInput, CommandID?)]) {
        let updatedInputs = Set(updates.map(\.0))
        var next = (file.trackpad ?? []).filter { !updatedInputs.contains($0.input) }
        for (input, command) in updates where command != Self.defaultBindings.command(for: input)?.0 {
            next.append(TrackpadBinding(input: input, command: command))
        }
        let persisted: [TrackpadBinding]? = next.isEmpty ? nil : next
        persist { $0.trackpad = persisted }
    }

    // MARK: 鼠标手势

    var effectiveGestures: [GestureEntry] {
        var list = InputBindingDefaults.standard.mouseGestures.compactMap { binding -> GestureEntry? in
            guard !binding.directions.isEmpty, let command = binding.command else { return nil }
            return GestureEntry(directions: binding.directions, command: command)
        }
        var seen: Set<[PointerDirection]> = []
        for binding in file.mouseGestures ?? [] where !binding.directions.isEmpty {
            guard seen.insert(binding.directions).inserted else { continue }
            if let index = list.firstIndex(where: { $0.directions == binding.directions }) {
                if let command = binding.command {
                    list[index] = GestureEntry(directions: binding.directions, command: command)
                } else {
                    list.remove(at: index)
                }
            } else if let command = binding.command {
                list.append(GestureEntry(directions: binding.directions, command: command))
            }
        }
        return list
    }

    func handleRecordedGesture(_ rawDirections: [PointerDirection]) {
        guard !rawDirections.isEmpty else { return }
        guard rawDirections.count <= Self.maxGestureDirections else {
            recordedDirections = []
            pendingGestureConflict = nil
            errorMessage = String(localized: "手势最多支持 \(Self.maxGestureDirections) 个方向")
            return
        }

        errorMessage = nil
        recordedDirections = rawDirections
        if let existing = effectiveGestures.first(where: { $0.directions == rawDirections }) {
            pendingGestureConflict = PendingGestureConflict(
                directions: rawDirections,
                existingCommand: existing.command,
                replacementCommand: nil
            )
        } else {
            pendingGestureConflict = nil
        }
    }

    func assignRecordedGesture(command: CommandID) {
        guard !recordedDirections.isEmpty else { return }
        if pendingGestureConflict != nil {
            pendingGestureConflict?.replacementCommand = command
            return
        }
        let directions = recordedDirections
        recordedDirections = []
        upsertGesture(directions: directions, command: command)
    }

    func resolveGestureConflictByReplacing() {
        guard let conflict = pendingGestureConflict, let command = conflict.replacementCommand else { return }
        pendingGestureConflict = nil
        recordedDirections = []
        upsertGesture(directions: conflict.directions, command: command)
    }

    func cancelRecordedGesture() {
        recordedDirections = []
        pendingGestureConflict = nil
    }

    func updateGesture(_ directions: [PointerDirection], command: CommandID) {
        upsertGesture(directions: directions, command: command)
    }

    func removeGesture(_ directions: [PointerDirection]) {
        if recordedDirections == directions {
            cancelRecordedGesture()
        }
        var next = (file.mouseGestures ?? []).filter { $0.directions != directions }
        if Self.defaultBindings.command(forGesture: directions) != nil {
            next.append(MouseGestureBinding(directions: directions, command: nil))
        }
        let persisted: [MouseGestureBinding]? = next.isEmpty ? nil : next
        persist { $0.mouseGestures = persisted }
    }

    func resetAll() {
        cancelRecordedGesture()
        persist {
            $0.clickZones = nil
            $0.wheel = nil
            $0.trackpad = nil
            $0.mouseGestures = nil
        }
    }

    func conflictDescription(for conflict: PendingGestureConflict) -> String {
        let arrows = GestureTrailView.format(conflict.directions)
        let title = SettingsCommandCatalog.title(of: conflict.existingCommand)
        return String(localized: "“\(arrows)”已用于“\(title)”")
    }

    private func upsertGesture(directions: [PointerDirection], command: CommandID) {
        var next = (file.mouseGestures ?? []).filter { $0.directions != directions }
        if Self.defaultBindings.command(forGesture: directions)?.0 != command {
            next.append(MouseGestureBinding(directions: directions, command: command))
        }
        let persisted: [MouseGestureBinding]? = next.isEmpty ? nil : next
        persist { $0.mouseGestures = persisted }
    }

    private func persist(_ mutate: @escaping @Sendable (inout KeyBindingsFile) -> Void) {
        mutate(&file)
        bridge?.persist(mutate)
    }
}

// MARK: - 鼠标与触控板设置页视图

struct PointerSettingsPage: View {
    @Bindable var model: PointerModel

    private static let wheelDevices: [(String, WheelDevice)] = [
        (String(localized: "鼠标滚轮"), .mouse),
        (String(localized: "触控板滚动"), .trackpad),
    ]

    private static let wheelModes: [(String, PointerModel.WheelMode)] = [
        (String(localized: "默认（滚动；不超出时翻页）"), .standard),
        (String(localized: "缩放"), .zoom),
        (String(localized: "执行命令"), .commands),
        (String(localized: "无"), .none),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    Text("鼠标、触控板与手势改动立即生效并写入 keybindings.json。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: Theme.text2))
                    Spacer()
                    Button(String(localized: "全部恢复默认")) {
                        model.resetAll()
                    }
                    .controlSize(.small)
                    .disabled(!model.hasCustomBindings)
                }

                SettingsErrorBanner(message: model.errorMessage)

                clickZonesSection
                wheelSection
                trackpadSection
                mouseGesturesSection
            }
            .padding(16)
        }
        .onAppear { model.reload() }
        .onDisappear { model.cancelRecordedGesture() }
    }

    // MARK: 点击区域

    private var clickZonesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "点击区域"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: Theme.text2))
                .padding(.horizontal, 12)
            Text("单击查看器的左、中、右区域执行命令。“左翻帧 / 右翻帧”按阅读方向换算。")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Theme.text2))
                .padding(.horizontal, 12)

            HStack(spacing: 0) {
                clickZoneColumn(title: String(localized: "左侧"), zone: .left)
                dashedVerticalDivider
                clickZoneColumn(title: String(localized: "中间"), zone: .center)
                dashedVerticalDivider
                clickZoneColumn(title: String(localized: "右侧"), zone: .right)
            }
            .frame(height: 92)
            .background(Color(nsColor: Theme.well), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: Theme.line), lineWidth: 0.5))
        }
    }

    private func clickZoneColumn(title: String, zone: ClickZone) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: Theme.text2))
            SettingsPopup(
                label: title,
                options: model.optionalCommandOptions,
                selection: Binding(
                    get: { model.clickZoneCommand(for: zone) },
                    set: { model.setClickZone($0, for: zone) }
                )
            )
            .frame(maxWidth: 168)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
    }

    private var dashedVerticalDivider: some View {
        Rectangle()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(Color(nsColor: Theme.lineStrong))
            .frame(width: 1)
            .padding(.vertical, 8)
    }

    // MARK: 滚轮

    private var wheelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(localized: "滚轮"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Theme.text2))
                Spacer()
                SettingsSegments(
                    label: String(localized: "滚轮设备"),
                    options: Self.wheelDevices,
                    selection: $model.wheelDevice
                )
            }
            .padding(.horizontal, 12)

            SettingsCard {
                ForEach(Array(PointerModel.wheelModifiers.enumerated()), id: \.offset) { index, item in
                    if index > 0 { SettingsDivider() }
                    wheelRow(label: item.label, modifiers: item.value)
                }
            }
        }
    }

    private func wheelRow(label: String, modifiers: KeyModifiers) -> some View {
        let device = model.wheelDevice
        let action = model.wheelAction(device: device, modifiers: modifiers)
        let mode: PointerModel.WheelMode = switch action {
        case .standard: .standard
        case .zoom: .zoom
        case .commands: .commands
        case .none: .none
        }
        let isModified = model.isWheelModified(device: device, modifiers: modifiers)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(label)
                    .font(.system(size: 13))
                    .frame(width: 84, alignment: .leading)
                SettingsPopup(
                    label: label,
                    options: Self.wheelModes,
                    selection: Binding(
                        get: { mode },
                        set: { nextMode in
                            switch nextMode {
                            case .standard: model.setWheelAction(.standard, device: device, modifiers: modifiers)
                            case .zoom: model.setWheelAction(.zoom, device: device, modifiers: modifiers)
                            case .commands:
                                if case .commands = action { return }
                                model.setWheelAction(.commands(up: .framePrevious, down: .frameNext), device: device, modifiers: modifiers)
                            case .none: model.setWheelAction(.none, device: device, modifiers: modifiers)
                            }
                        }
                    )
                )
                Spacer(minLength: 8)
                if isModified {
                    SettingsIconButton(systemImage: "arrow.counterclockwise", help: String(localized: "恢复默认")) {
                        model.resetWheel(device: device, modifiers: modifiers)
                    }
                }
            }

            if case let .commands(up, down) = action {
                HStack(spacing: 10) {
                    Text(String(localized: "向上"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: Theme.text2))
                    SettingsPopup(
                        label: String(localized: "向上滚动"),
                        options: model.commandOptions,
                        selection: Binding(
                            get: { up },
                            set: { model.setWheelAction(.commands(up: $0, down: down), device: device, modifiers: modifiers) }
                        )
                    )
                    Text(String(localized: "向下"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: Theme.text2))
                    SettingsPopup(
                        label: String(localized: "向下滚动"),
                        options: model.commandOptions,
                        selection: Binding(
                            get: { down },
                            set: { model.setWheelAction(.commands(up: up, down: $0), device: device, modifiers: modifiers) }
                        )
                    )
                }
                .padding(.leading, 94)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 34)
    }

    // MARK: 触控板

    private var trackpadSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSection(title: String(localized: "触控板")) {
                SettingsRow(title: String(localized: "横扫")) {
                    let current = model.trackpadSwipePair()
                    SettingsPopup(
                        label: String(localized: "横扫"),
                        options: model.trackpadPairOptions(current: current),
                        selection: Binding(get: { current }, set: { model.setTrackpadSwipe($0) })
                    )
                }
                SettingsDivider()
                SettingsRow(title: String(localized: "轻点两下")) {
                    SettingsPopup(
                        label: String(localized: "轻点两下"),
                        options: model.optionalCommandOptions,
                        selection: Binding(
                            get: { model.trackpadDoubleTap() },
                            set: { model.setTrackpadDoubleTap($0) }
                        )
                    )
                }
                SettingsDivider()
                SettingsRow(title: String(localized: "旋转")) {
                    let current = model.trackpadRotatePair()
                    SettingsPopup(
                        label: String(localized: "旋转"),
                        options: model.trackpadPairOptions(current: current),
                        selection: Binding(get: { current }, set: { model.setTrackpadRotate($0) })
                    )
                }
            }
            Text("捏合始终用于缩放。双指横扫依赖“系统设置 › 触控板 › 更多手势”中的“在页面间轻扫”。")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Theme.text2))
                .padding(.horizontal, 12)
        }
    }

    // MARK: 鼠标手势

    private var mouseGesturesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSection(title: String(localized: "鼠标手势")) {
                let gestures = model.effectiveGestures
                if gestures.isEmpty && model.recordedDirections.isEmpty {
                    Text("尚未设置鼠标手势")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: Theme.text2))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                }
                ForEach(Array(gestures.enumerated()), id: \.element.directions) { index, binding in
                    if index > 0 { SettingsDivider() }
                    gestureRow(binding)
                }
                if !model.recordedDirections.isEmpty {
                    if !gestures.isEmpty { SettingsDivider() }
                    recordedGestureRow
                }
            }

            Text("按住右键拖动执行手势；不拖动直接松开仍弹出右键菜单。在下方录制区按住右键画出手势，松开后选择命令。")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Theme.text2))
                .padding(.horizontal, 12)

            GestureRecorderPadView { directions in
                model.handleRecordedGesture(directions)
            }
            .frame(height: 88)
        }
    }

    private func gestureRow(_ entry: PointerModel.GestureEntry) -> some View {
        HStack(spacing: 10) {
            Text(GestureTrailView.format(entry.directions))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .frame(width: 84, alignment: .leading)
            SettingsPopup(
                label: GestureTrailView.format(entry.directions),
                options: model.commandOptions,
                selection: Binding(
                    get: { entry.command },
                    set: { model.updateGesture(entry.directions, command: $0) }
                )
            )
            Spacer(minLength: 8)
            SettingsIconButton(systemImage: "xmark", fontSize: 10, weight: .semibold, help: String(localized: "删除手势")) {
                model.removeGesture(entry.directions)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
    }

    private var recordedGestureRow: some View {
        let placeholderOptions: [(String, CommandID?)] = [(String(localized: "选择命令…"), nil)]
            + model.commandOptions.map { ($0.0, Optional($0.1)) }
        let selectedCommand: CommandID? = model.pendingGestureConflict?.replacementCommand

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(GestureTrailView.format(model.recordedDirections))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .frame(width: 84, alignment: .leading)
                SettingsPopup(
                    label: String(localized: "选择命令…"),
                    options: placeholderOptions,
                    selection: Binding(
                        get: { selectedCommand },
                        set: { command in
                            if let command {
                                model.assignRecordedGesture(command: command)
                            }
                        }
                    )
                )
                Spacer(minLength: 8)
                SettingsIconButton(systemImage: "xmark", fontSize: 10, weight: .semibold, help: String(localized: "取消")) {
                    model.cancelRecordedGesture()
                }
            }

            if let conflict = model.pendingGestureConflict {
                SettingsConflictBanner(
                    message: model.conflictDescription(for: conflict),
                    replaceDisabled: conflict.replacementCommand == nil,
                    onReplace: { model.resolveGestureConflictByReplacing() },
                    onCancel: { model.cancelRecordedGesture() }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: Theme.accentSoft))
    }
}

/// 鼠标手势录制区：接收真实右键拖动事件，经 `MouseGestureTracker` 折算方向并绘制实时轨迹。
private struct GestureRecorderPadView: NSViewRepresentable {
    var onFinish: ([PointerDirection]) -> Void

    func makeNSView(context: Context) -> RecorderPadNSView {
        let view = RecorderPadNSView()
        view.onFinish = onFinish
        return view
    }

    func updateNSView(_ nsView: RecorderPadNSView, context: Context) {
        nsView.onFinish = onFinish
    }

    final class RecorderPadNSView: NSView {
        static let accessibilityID = "pointer.gestureRecorderPad"

        var onFinish: (([PointerDirection]) -> Void)?
        private var tracker: MouseGestureTracker?
        private var trailPoints: [CGPoint] = []

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityIdentifier(Self.accessibilityID)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func rightMouseDown(with event: NSEvent) {
            tracker = MouseGestureTracker(origin: event.locationInWindow)
            trailPoints = [convert(event.locationInWindow, from: nil)]
            needsDisplay = true
        }

        override func rightMouseDragged(with event: NSEvent) {
            guard var tracker else { return }
            tracker.add(event.locationInWindow)
            self.tracker = tracker
            trailPoints.append(convert(event.locationInWindow, from: nil))
            needsDisplay = true
        }

        override func rightMouseUp(with event: NSEvent) {
            guard let tracker else { return }
            self.tracker = nil
            trailPoints = []
            needsDisplay = true
            if tracker.hasMoved {
                onFinish?(tracker.directions)
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
            let outline = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            Theme.well.setFill()
            outline.fill()

            let borderColor = tracker?.hasMoved == true ? Theme.accent : Theme.lineStrong
            borderColor.setStroke()
            outline.lineWidth = tracker?.hasMoved == true ? 1.5 : 1
            outline.setLineDash([5, 3], count: 2, phase: 0)
            outline.stroke()

            if trailPoints.count >= 2 {
                let path = NSBezierPath()
                path.move(to: trailPoints[0])
                for point in trailPoints.dropFirst() {
                    path.line(to: point)
                }
                Theme.accent.setStroke()
                path.lineWidth = 2.5
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }

            let isActive = tracker?.hasMoved == true
            let text = isActive
                ? GestureTrailView.format(tracker?.directions ?? [])
                : String(localized: "在此按住右键拖动画出手势")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: isActive ? NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold) : NSFont.systemFont(ofSize: 12),
                .foregroundColor: isActive ? Theme.text : Theme.text2,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
            (text as NSString).draw(at: origin, withAttributes: attributes)
        }
    }
}
