import AppKit
import MVSettings

/// 效果面板视图：自上而下为“调色”“背景”“显示配置”三段。
@MainActor
final class EffectsPanelView: NSView {
    enum AdjustField: CaseIterable {
        case brightness, contrast, saturation, gamma, temperature, tint

        var title: String {
            switch self {
            case .brightness: String(localized: "亮度")
            case .contrast: String(localized: "对比度")
            case .saturation: String(localized: "饱和度")
            case .gamma: String(localized: "伽马")
            case .temperature: String(localized: "色温")
            case .tint: String(localized: "色调")
            }
        }

        func value(in adjust: ColorAdjust) -> Double {
            switch self {
            case .brightness: adjust.brightness
            case .contrast: adjust.contrast
            case .saturation: adjust.saturation
            case .gamma: adjust.gamma
            case .temperature: adjust.temperature
            case .tint: adjust.tint
            }
        }

        func set(_ value: Double, in adjust: inout ColorAdjust) {
            switch self {
            case .brightness: adjust.brightness = min(max(value, -1), 1)
            case .contrast: adjust.contrast = min(max(value, -1), 1)
            case .saturation: adjust.saturation = min(max(value, -1), 1)
            case .gamma: adjust.gamma = min(max(value, 0.25), 4)
            case .temperature: adjust.temperature = min(max(value, -1), 1)
            case .tint: adjust.tint = min(max(value, -1), 1)
            }
        }

        var defaultValue: Double { self == .gamma ? 1 : 0 }
        var sliderMin: Double { self == .gamma ? -2 : -100 }
        var sliderMax: Double { self == .gamma ? 2 : 100 }

        func toSlider(_ value: Double) -> Double {
            self == .gamma ? log2(min(max(value, 0.25), 4)) : (value * 100).rounded()
        }

        func fromSlider(_ slider: Double) -> Double {
            if self == .gamma {
                return (pow(2, slider) * 100).rounded() / 100
            }
            return (slider.rounded()) / 100
        }

        func format(_ value: Double) -> String {
            if self == .gamma { return String(format: "%.2f", value) }
            let intVal = Int((value * 100).rounded())
            return intVal > 0 ? "+\(intVal)" : "\(intVal)"
        }

        func parse(_ text: String) -> Double? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let num = Double(trimmed), num.isFinite else { return nil }
            if self == .gamma { return min(max((num * 100).rounded() / 100, 0.25), 4) }
            return min(max(num.rounded(), -100), 100) / 100
        }
    }

    enum BackgroundOption: CaseIterable {
        case auto, black, gray, white, custom, checkerboard

        var title: String {
            switch self {
            case .auto: String(localized: "默认")
            case .black: String(localized: "黑")
            case .gray: String(localized: "灰")
            case .white: String(localized: "白")
            case .custom: String(localized: "自定义")
            case .checkerboard: String(localized: "棋盘格")
            }
        }

        func matches(_ background: ViewerBackground) -> Bool {
            switch (self, background) {
            case (.auto, .auto), (.black, .black), (.gray, .gray), (.white, .white), (.checkerboard, .checkerboard), (.custom, .custom):
                true
            default:
                false
            }
        }
    }

    var onToggleEffects: ((Bool) -> Void)?
    var onChangeAdjust: (((inout ColorAdjust) -> Void) -> Void)?
    var onResetAll: (() -> Void)?
    var onSelectBackground: ((ViewerBackground) -> Void)?
    var onPickCustomColor: (() -> Void)?

    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()

    // 调色段
    let effectsSwitch = NSSwitch()
    private let effectsStateLabel = NSTextField(labelWithString: "")
    private let shortcutBadge = KeyBadgeView(text: "E")
    private var sliderRows: [AdjustField: AdjustSliderRow] = [:]
    let resetButton = FlatButton(
        font: .systemFont(ofSize: 12), fill: .clear, foreground: Theme.text2, border: nil, radius: 6, height: 24, padding: 6
    )

    // 背景段
    private var swatches: [BackgroundOption: BackgroundSwatchView] = [:]

    // 显示配置段
    let profilesSection = NSStackView()
    let profileListView = ProfileListSectionView()

    private var customColor = NSColor(srgbRed: 0x3B / 255, green: 0x4A / 255, blue: 0x5C / 255, alpha: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.ground.cgColor
    }

    func slider(for field: AdjustField) -> NSSlider? {
        sliderRows[field]?.slider
    }

    func swatchView(for option: BackgroundOption) -> NSView? {
        swatches[option]
    }

    func apply(
        hasBook: Bool,
        isVirtualBook: Bool,
        effectsEnabled: Bool,
        adjust: ColorAdjust,
        background: ViewerBackground,
        customColor: NSColor
    ) {
        self.customColor = customColor
        effectsSwitch.state = effectsEnabled ? .on : .off
        effectsSwitch.isEnabled = hasBook
        effectsStateLabel.stringValue = effectsEnabled ? String(localized: "开") : String(localized: "关（显示原图）")
        effectsStateLabel.textColor = hasBook ? Theme.text2 : Theme.text2.withAlphaComponent(0.5)

        let slidersActive = hasBook && effectsEnabled
        for field in AdjustField.allCases {
            sliderRows[field]?.update(value: field.value(in: adjust), isEnabled: slidersActive)
        }
        resetButton.isEnabled = slidersActive && !adjust.isIdentity

        for option in BackgroundOption.allCases {
            swatches[option]?.update(
                selected: hasBook && option.matches(background),
                isEnabled: hasBook,
                customColor: customColor
            )
        }
        _ = isVirtualBook
    }

    private func buildUI() {
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        let doc = FlippedDocumentView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = doc

        contentStack.orientation = .vertical
        contentStack.alignment = .width
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: doc.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])

        contentStack.addArrangedSubview(buildColorSection())
        contentStack.addArrangedSubview(SectionDivider())
        contentStack.addArrangedSubview(buildBackgroundSection())
        contentStack.addArrangedSubview(SectionDivider())
        contentStack.addArrangedSubview(buildProfilesContainer())
    }

    private func buildColorSection() -> NSView {
        let section = makeSectionStack()

        let title = makeSectionTitle(String(localized: "调色"))
        effectsStateLabel.font = .systemFont(ofSize: 11)
        effectsStateLabel.textColor = Theme.text2
        effectsStateLabel.setContentHuggingPriority(.required, for: .horizontal)

        effectsSwitch.controlSize = .mini
        effectsSwitch.target = self
        effectsSwitch.action = #selector(switchChanged(_:))
        effectsSwitch.toolTip = String(localized: "临时关闭/打开效果，滑块值保留")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [title, spacer, effectsStateLabel, effectsSwitch, shortcutBadge])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        section.addArrangedSubview(header)
        section.setCustomSpacing(8, after: header)

        for field in AdjustField.allCases {
            let row = AdjustSliderRow(field: field)
            row.onValueChange = { [weak self] value in
                self?.onChangeAdjust? { field.set(value, in: &$0) }
            }
            sliderRows[field] = row
            section.addArrangedSubview(row)
        }

        resetButton.setText(String(localized: "全部复位"))
        resetButton.target = self
        resetButton.action = #selector(resetClicked(_:))
        let hint = NSTextField(labelWithString: String(localized: "双击滑块复位单项"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = Theme.text2
        hint.lineBreakMode = .byTruncatingTail
        let footSpacer = NSView()
        footSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [resetButton, footSpacer, hint])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        section.setCustomSpacing(8, after: sliderRows[.tint]!)
        section.addArrangedSubview(footer)

        return section
    }

    private func buildBackgroundSection() -> NSView {
        let section = makeSectionStack()
        let title = makeSectionTitle(String(localized: "背景"))
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [title, headerSpacer])
        header.orientation = .horizontal
        header.alignment = .centerY
        section.addArrangedSubview(header)
        section.setCustomSpacing(8, after: header)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 4
        for option in BackgroundOption.allCases {
            let swatch = BackgroundSwatchView(option: option)
            swatch.onClick = { [weak self] in
                guard let self else { return }
                switch option {
                case .auto: onSelectBackground?(.auto)
                case .black: onSelectBackground?(.black)
                case .gray: onSelectBackground?(.gray)
                case .white: onSelectBackground?(.white)
                case .checkerboard: onSelectBackground?(.checkerboard)
                case .custom:
                    if let srgb = customColor.usingColorSpace(.sRGB) {
                        onSelectBackground?(.custom(
                            red: Double(srgb.redComponent),
                            green: Double(srgb.greenComponent),
                            blue: Double(srgb.blueComponent)
                        ))
                    }
                    onPickCustomColor?()
                }
            }
            swatches[option] = swatch
            row.addArrangedSubview(swatch)
        }
        section.addArrangedSubview(row)
        return section
    }

    private func buildProfilesContainer() -> NSView {
        profilesSection.orientation = .vertical
        profilesSection.alignment = .width
        profilesSection.spacing = 8
        profilesSection.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        profilesSection.addArrangedSubview(profileListView)
        return profilesSection
    }

    private func makeSectionStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        return stack
    }

    private func makeSectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = Theme.text
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    @objc private func switchChanged(_ sender: NSSwitch) {
        onToggleEffects?(sender.state == .on)
    }

    @objc private func resetClicked(_ sender: Any?) {
        onResetAll?()
    }
}

// MARK: 辅助子视图

@MainActor
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class SectionDivider: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.line.cgColor
    }
}

@MainActor
final class KeyBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 0.5
        label.stringValue = text
        label.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        label.textColor = Theme.text2
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setText(_ text: String) {
        label.stringValue = text
        isHidden = text.isEmpty
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.borderColor = Theme.line.cgColor
    }
}

@MainActor
private final class DoubleClickSlider: NSSlider {
    var onDoubleClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }
}

@MainActor
private final class AdjustSliderRow: NSView, NSTextFieldDelegate {
    let field: EffectsPanelView.AdjustField
    var onValueChange: ((Double) -> Void)?

    private let label: NSTextField
    let slider = DoubleClickSlider()
    private let valueField = NSTextField()
    private var currentValue: Double = 0

    init(field: EffectsPanelView.AdjustField) {
        self.field = field
        self.currentValue = field.defaultValue
        self.label = NSTextField(labelWithString: field.title)
        super.init(frame: .zero)

        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.text2
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        slider.minValue = field.sliderMin
        slider.maxValue = field.sliderMax
        slider.doubleValue = field.toSlider(field.defaultValue)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        slider.onDoubleClick = { [weak self] in
            guard let self else { return }
            self.onValueChange?(self.field.defaultValue)
        }
        slider.translatesAutoresizingMaskIntoConstraints = false

        valueField.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        valueField.textColor = Theme.text
        valueField.alignment = .right
        valueField.isBordered = false
        valueField.drawsBackground = false
        valueField.focusRingType = .exterior
        valueField.delegate = self
        valueField.toolTip = String(localized: "点击输入数值")
        valueField.stringValue = field.format(field.defaultValue)
        valueField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(slider)
        addSubview(valueField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 74),
            slider.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueField.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 6),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueField.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueField.widthAnchor.constraint(equalToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(value: Double, isEnabled: Bool) {
        currentValue = value
        slider.isEnabled = isEnabled
        slider.doubleValue = field.toSlider(value)
        valueField.isEnabled = isEnabled
        valueField.isEditable = isEnabled
        label.textColor = isEnabled ? Theme.text2 : Theme.text2.withAlphaComponent(0.45)
        valueField.textColor = isEnabled ? Theme.text : Theme.text2.withAlphaComponent(0.45)
        if valueField.currentEditor() == nil {
            valueField.stringValue = field.format(value)
        }
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        let value = field.fromSlider(sender.doubleValue)
        currentValue = value
        valueField.stringValue = field.format(value)
        onValueChange?(value)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitText()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitText()
            window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            valueField.stringValue = field.format(currentValue)
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    private func commitText() {
        if let parsed = field.parse(valueField.stringValue) {
            currentValue = parsed
            valueField.stringValue = field.format(parsed)
            slider.doubleValue = field.toSlider(parsed)
            onValueChange?(parsed)
        } else {
            valueField.stringValue = field.format(currentValue)
        }
    }
}

@MainActor
private final class BackgroundSwatchView: NSView {
    let option: EffectsPanelView.BackgroundOption
    var onClick: (() -> Void)?

    private let tile = SwatchTileView()
    private let label = NSTextField(labelWithString: "")
    private var isEnabled = true

    init(option: EffectsPanelView.BackgroundOption) {
        self.option = option
        super.init(frame: .zero)
        tile.option = option
        tile.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = option.title
        label.font = .systemFont(ofSize: 10)
        label.textColor = Theme.text2
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tile)
        addSubview(label)
        NSLayoutConstraint.activate([
            tile.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            tile.centerXAnchor.constraint(equalTo: centerXAnchor),
            tile.widthAnchor.constraint(equalToConstant: 32),
            tile.heightAnchor.constraint(equalToConstant: 32),
            label.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(option.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(selected: Bool, isEnabled: Bool, customColor: NSColor) {
        self.isEnabled = isEnabled
        alphaValue = isEnabled ? 1 : 0.45
        tile.isSelected = selected
        tile.customColor = customColor
        tile.needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onClick?()
    }
}

@MainActor
private final class SwatchTileView: NSView {
    var option: EffectsPanelView.BackgroundOption = .auto
    var isSelected = false
    var customColor = NSColor(srgbRed: 0x3B / 255, green: 0x4A / 255, blue: 0x5C / 255, alpha: 1)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let inner = bounds.insetBy(dx: 2.5, dy: 2.5)
        let path = NSBezierPath(roundedRect: inner, xRadius: 6, yRadius: 6)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        switch option {
        case .auto:
            NSColor(srgbRed: 0xF0 / 255, green: 0xEE / 255, blue: 0xE6 / 255, alpha: 1).setFill()
            inner.fill()
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: inner.maxX, y: inner.maxY))
            tri.line(to: NSPoint(x: inner.maxX, y: inner.minY))
            tri.line(to: NSPoint(x: inner.minX, y: inner.minY))
            tri.close()
            NSColor(srgbRed: 0x1A / 255, green: 0x19 / 255, blue: 0x18 / 255, alpha: 1).setFill()
            tri.fill()
        case .black:
            NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1).setFill()
            inner.fill()
        case .gray:
            NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1).setFill()
            inner.fill()
        case .white:
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1).setFill()
            inner.fill()
        case .custom:
            customColor.setFill()
            inner.fill()
        case .checkerboard:
            NSColor.white.setFill()
            inner.fill()
            NSColor(srgbRed: 0xCF / 255, green: 0xCD / 255, blue: 0xC4 / 255, alpha: 1).setFill()
            let step: CGFloat = 6
            var y = inner.minY
            var row = 0
            while y < inner.maxY {
                var x = inner.minX
                var col = 0
                while x < inner.maxX {
                    if (row + col).isMultiple(of: 2) {
                        NSRect(x: x, y: y, width: step, height: step).fill()
                    }
                    x += step
                    col += 1
                }
                y += step
                row += 1
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        Theme.lineStrong.setStroke()
        path.lineWidth = 1
        path.stroke()

        if isSelected {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7.5, yRadius: 7.5)
            Theme.accent.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}
