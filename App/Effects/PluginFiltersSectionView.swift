import AppKit
import MVFoundation
import MVPlugins
import MVSettings

/// 效果面板「插件滤镜」一节中单个滤镜行的展示快照。
@MainActor
struct PluginFilterDisplayItem: Equatable {
    let pluginID: String
    let filterID: String
    let title: String
    let subtitle: String
    let isAvailable: Bool
    let isOn: Bool
    let parameters: [PluginFilterParameter]
    let values: [String: JSONValue]
    let activity: PluginFilterActivity.State

    var key: String {
        PluginFilterActivity.key(plugin: pluginID, filter: filterID)
    }
}

/// 效果面板「插件滤镜」一节：列出已启用插件的滤镜与效果链中不可用的条目。
@MainActor
final class PluginFiltersSectionView: NSView {
    var onToggleFilter: ((String, String, Bool) -> Void)?
    var onChangeParameter: ((String, String, String, JSONValue) -> Void)?

    private let rootStack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: String(localized: "插件滤镜"))
    private let rowsStack = NSStackView()
    private let hintLabel = NSTextField(wrappingLabelWithString: String(localized: "先显示原图，处理完自动换成结果；关闭立即恢复原图。"))

    private var orderedKeys: [String] = []
    private var rowViews: [String: PluginFilterRowView] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        setAccessibilityIdentifier("effects.pluginFilters")
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyFonts() {
        titleLabel.font = Theme.font(.panels, size: 12, weight: .semibold)
        hintLabel.font = Theme.font(.panels, size: 11)
        rowViews.values.forEach { $0.applyFonts() }
        needsLayout = true
    }

    func apply(items: [PluginFilterDisplayItem], hasBook: Bool, effectsEnabled: Bool) {
        let nextKeys = items.map(\.key)
        let structureChanged = nextKeys != orderedKeys || items.contains { item in
            rowViews[item.key]?.parameterSignature != item.parameters
        }

        if structureChanged {
            for view in rowsStack.arrangedSubviews {
                rowsStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            rowViews.removeAll()
            orderedKeys = nextKeys

            for (index, item) in items.enumerated() {
                if index > 0 {
                    let divider = SectionDivider()
                    rowsStack.addArrangedSubview(divider)
                    divider.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
                }
                let row = PluginFilterRowView(item: item)
                row.onToggle = { [weak self] isOn in
                    self?.onToggleFilter?(item.pluginID, item.filterID, isOn)
                }
                row.onParameterChange = { [weak self] paramKey, value in
                    self?.onChangeParameter?(item.pluginID, item.filterID, paramKey, value)
                }
                rowViews[item.key] = row
                rowsStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            }
        }

        for item in items {
            rowViews[item.key]?.update(item: item, hasBook: hasBook, effectsEnabled: effectsEnabled)
        }
    }

    // MARK: - 供自检查询控件与状态

    func switchControl(plugin: String, filter: String) -> NSSwitch? {
        rowViews[PluginFilterActivity.key(plugin: plugin, filter: filter)]?.toggleSwitch
    }

    func statusText(plugin: String, filter: String) -> String {
        rowViews[PluginFilterActivity.key(plugin: plugin, filter: filter)]?.currentStatusText ?? ""
    }

    func subtitleText(plugin: String, filter: String) -> String {
        rowViews[PluginFilterActivity.key(plugin: plugin, filter: filter)]?.subtitleLabel.stringValue ?? ""
    }

    func isRowDimmed(plugin: String, filter: String) -> Bool {
        guard let row = rowViews[PluginFilterActivity.key(plugin: plugin, filter: filter)] else { return false }
        return row.alphaValue < 0.9
    }

    func parameterControl(plugin: String, filter: String, key: String) -> NSView? {
        rowViews[PluginFilterActivity.key(plugin: plugin, filter: filter)]?.parameterControl(for: key)
    }

    private func buildUI() {
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 8
        rootStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)

        titleLabel.font = Theme.font(.panels, size: 12, weight: .semibold)
        titleLabel.textColor = Theme.text
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [titleLabel, titleSpacer])
        header.orientation = .horizontal
        header.alignment = .centerY

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        rowsStack.setContentHuggingPriority(.init(1), for: .horizontal)

        hintLabel.font = Theme.font(.panels, size: 11)
        hintLabel.textColor = Theme.text2
        hintLabel.maximumNumberOfLines = 3
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        rootStack.addArrangedSubview(header)
        rootStack.addArrangedSubview(rowsStack)
        rootStack.addArrangedSubview(hintLabel)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -24),
            rowsStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -24),
            hintLabel.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -24),
        ])
    }
}

// MARK: - 单个插件滤镜行

@MainActor
private final class PluginFilterRowView: NSView {
    let parameterSignature: [PluginFilterParameter]
    var onToggle: ((Bool) -> Void)?
    var onParameterChange: ((String, JSONValue) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusStack = NSStackView()
    let toggleSwitch = NSSwitch()
    private let paramsStack = NSStackView()
    private var paramRows: [String: any PluginFilterParamRow] = [:]

    var currentStatusText: String {
        statusStack.isHidden ? "" : statusLabel.stringValue
    }

    init(item: PluginFilterDisplayItem) {
        self.parameterSignature = item.parameters
        super.init(frame: .zero)
        setAccessibilityIdentifier("effects.pluginFilter.\(item.key)")
        buildUI(for: item)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyFonts() {
        titleLabel.font = Theme.font(.panels, size: 12.5)
        subtitleLabel.font = Theme.font(.panels, size: 10.5)
        statusLabel.font = Theme.font(.panels, size: 11)
        paramRows.values.forEach { $0.applyFonts() }
    }

    func parameterControl(for key: String) -> NSView? {
        paramRows[key]?.primaryControl
    }

    func update(item: PluginFilterDisplayItem, hasBook: Bool, effectsEnabled: Bool) {
        titleLabel.stringValue = item.title
        subtitleLabel.stringValue = item.subtitle
        alphaValue = item.isAvailable ? 1.0 : 0.55

        toggleSwitch.state = item.isOn ? .on : .off
        if item.isAvailable {
            toggleSwitch.isEnabled = hasBook && effectsEnabled
        } else {
            // 不可用条目只能关掉（移除条目），不能打开。
            toggleSwitch.isEnabled = hasBook && item.isOn
        }

        if item.isAvailable && item.isOn {
            switch item.activity {
            case .idle:
                spinner.stopAnimation(nil)
                spinner.isHidden = true
                statusLabel.stringValue = ""
                statusLabel.toolTip = nil
                statusStack.isHidden = true
            case .running:
                spinner.isHidden = false
                spinner.startAnimation(nil)
                statusLabel.stringValue = String(localized: "处理中")
                statusLabel.textColor = Theme.text2
                statusLabel.toolTip = nil
                statusStack.isHidden = false
            case let .failed(message):
                spinner.stopAnimation(nil)
                spinner.isHidden = true
                statusLabel.stringValue = String(localized: "失败")
                statusLabel.textColor = Theme.danger
                statusLabel.toolTip = message
                statusStack.isHidden = false
            }
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            statusLabel.stringValue = ""
            statusLabel.toolTip = nil
            statusStack.isHidden = true
        }

        let showParams = item.isAvailable && item.isOn && !item.parameters.isEmpty
        paramsStack.isHidden = !showParams
        if showParams {
            let controlsEnabled = hasBook && effectsEnabled
            for param in item.parameters {
                paramRows[param.key]?.update(value: item.values[param.key] ?? param.defaultValue, isEnabled: controlsEnabled)
            }
        }
    }

    private func buildUI(for item: PluginFilterDisplayItem) {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        titleLabel.font = Theme.font(.panels, size: 12.5)
        titleLabel.textColor = Theme.text
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.font = Theme.font(.panels, size: 10.5)
        subtitleLabel.textColor = Theme.text2
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.setAccessibilityIdentifier("effects.pluginFilter.\(item.key).subtitle")

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        headerSpacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 11),
            spinner.heightAnchor.constraint(equalToConstant: 11),
        ])

        statusLabel.font = Theme.font(.panels, size: 11)
        statusLabel.textColor = Theme.text2
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.setAccessibilityIdentifier("effects.pluginFilter.\(item.key).status")

        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 4
        statusStack.addArrangedSubview(spinner)
        statusStack.addArrangedSubview(statusLabel)
        statusStack.isHidden = true

        toggleSwitch.controlSize = .mini
        toggleSwitch.target = self
        toggleSwitch.action = #selector(switchChanged(_:))
        toggleSwitch.setAccessibilityIdentifier("effects.pluginFilter.\(item.key).switch")

        let header = NSStackView(views: [textStack, headerSpacer, statusStack, toggleSwitch])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        root.addArrangedSubview(header)

        paramsStack.orientation = .vertical
        paramsStack.alignment = .leading
        paramsStack.spacing = 4
        paramsStack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 2, right: 0)
        for param in item.parameters {
            let row: any PluginFilterParamRow
            switch param.type {
            case .number:
                row = PluginNumberParamRow(param: param, identifier: "effects.pluginFilter.\(item.key).param.\(param.key)") { [weak self] value in
                    self?.onParameterChange?(param.key, .number(value))
                }
            case .bool:
                row = PluginBoolParamRow(param: param, identifier: "effects.pluginFilter.\(item.key).param.\(param.key)") { [weak self] value in
                    self?.onParameterChange?(param.key, .bool(value))
                }
            case .choice:
                row = PluginChoiceParamRow(param: param, identifier: "effects.pluginFilter.\(item.key).param.\(param.key)") { [weak self] value in
                    self?.onParameterChange?(param.key, .string(value))
                }
            }
            paramRows[param.key] = row
            paramsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: paramsStack.widthAnchor, constant: -12).isActive = true
        }
        paramsStack.isHidden = true
        root.addArrangedSubview(paramsStack)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            paramsStack.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
    }

    @objc private func switchChanged(_ sender: NSSwitch) {
        onToggle?(sender.state == .on)
    }
}

// MARK: - 参数控件（number / bool / choice）

@MainActor
private protocol PluginFilterParamRow: NSView {
    var primaryControl: NSView { get }
    func applyFonts()
    func update(value: JSONValue?, isEnabled: Bool)
}

@MainActor
private final class PluginNumberParamRow: NSView, PluginFilterParamRow {
    private let param: PluginFilterParameter
    private let onChange: (Double) -> Void
    private let label: NSTextField
    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")

    var primaryControl: NSView { slider }

    private var minVal: Double { param.min ?? 0 }
    private var maxVal: Double {
        let hi = param.max ?? 1
        return hi > minVal ? hi : minVal + 1
    }

    init(param: PluginFilterParameter, identifier: String, onChange: @escaping (Double) -> Void) {
        self.param = param
        self.onChange = onChange
        self.label = NSTextField(labelWithString: param.label)
        super.init(frame: .zero)

        label.font = Theme.font(.panels, size: 11.5)
        label.textColor = Theme.text2
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        slider.minValue = minVal
        slider.maxValue = maxVal
        slider.controlSize = .small
        slider.isContinuous = false
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.setAccessibilityIdentifier(identifier)

        valueLabel.font = Theme.font(.panels, size: 11, weight: .regular, monospacedDigits: true)
        valueLabel.textColor = Theme.text
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(slider)
        addSubview(valueLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 68),
            slider.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 6),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 40),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyFonts() {
        label.font = Theme.font(.panels, size: 11.5)
        valueLabel.font = Theme.font(.panels, size: 11, weight: .regular, monospacedDigits: true)
    }

    func update(value: JSONValue?, isEnabled: Bool) {
        let numeric: Double = if case let .number(d) = value { d } else { minVal }
        let clamped = min(max(numeric, minVal), maxVal)
        slider.doubleValue = clamped
        slider.isEnabled = isEnabled
        valueLabel.stringValue = formatValue(clamped)
        label.textColor = isEnabled ? Theme.text2 : Theme.text2.withAlphaComponent(0.45)
        valueLabel.textColor = isEnabled ? Theme.text : Theme.text2.withAlphaComponent(0.45)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        var value = min(max(sender.doubleValue, minVal), maxVal)
        if let step = param.step, step > 0 {
            value = minVal + ((value - minVal) / step).rounded() * step
            value = min(max(value, minVal), maxVal)
            sender.doubleValue = value
        }
        valueLabel.stringValue = formatValue(value)
        onChange(value)
    }

    private func formatValue(_ value: Double) -> String {
        if let step = param.step, step >= 1, abs(value - value.rounded()) < 0.001 {
            return String(Int(value.rounded()))
        }
        if abs(value - value.rounded()) < 0.001 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.2f", value)
    }
}

@MainActor
private final class PluginBoolParamRow: NSView, PluginFilterParamRow {
    private let onChange: (Bool) -> Void
    private let label: NSTextField
    private let toggle = NSSwitch()

    var primaryControl: NSView { toggle }

    init(param: PluginFilterParameter, identifier: String, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        self.label = NSTextField(labelWithString: param.label)
        super.init(frame: .zero)

        label.font = Theme.font(.panels, size: 11.5)
        label.textColor = Theme.text2
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        toggle.controlSize = .mini
        toggle.target = self
        toggle.action = #selector(toggled(_:))
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.setAccessibilityIdentifier(identifier)

        addSubview(label)
        addSubview(toggle)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -8),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyFonts() {
        label.font = Theme.font(.panels, size: 11.5)
    }

    func update(value: JSONValue?, isEnabled: Bool) {
        let on: Bool = if case let .bool(b) = value { b } else { false }
        toggle.state = on ? .on : .off
        toggle.isEnabled = isEnabled
        label.textColor = isEnabled ? Theme.text2 : Theme.text2.withAlphaComponent(0.45)
    }

    @objc private func toggled(_ sender: NSSwitch) {
        onChange(sender.state == .on)
    }
}

@MainActor
private final class PluginChoiceParamRow: NSView, PluginFilterParamRow {
    private let options: [String]
    private let onChange: (String) -> Void
    private let label: NSTextField
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    var primaryControl: NSView { popup }

    init(param: PluginFilterParameter, identifier: String, onChange: @escaping (String) -> Void) {
        self.options = param.options ?? []
        self.onChange = onChange
        self.label = NSTextField(labelWithString: param.label)
        super.init(frame: .zero)

        label.font = Theme.font(.panels, size: 11.5)
        label.textColor = Theme.text2
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        popup.controlSize = .small
        popup.font = Theme.font(.panels, size: 11.5)
        popup.addItems(withTitles: options)
        popup.target = self
        popup.action = #selector(selectionChanged(_:))
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.setAccessibilityIdentifier(identifier)

        addSubview(label)
        addSubview(popup)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: popup.leadingAnchor, constant: -8),
            popup.trailingAnchor.constraint(equalTo: trailingAnchor),
            popup.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyFonts() {
        label.font = Theme.font(.panels, size: 11.5)
        popup.font = Theme.font(.panels, size: 11.5)
    }

    func update(value: JSONValue?, isEnabled: Bool) {
        let selected: String = if case let .string(s) = value { s } else { options.first ?? "" }
        if let idx = options.firstIndex(of: selected) {
            popup.selectItem(at: idx)
        } else if !options.isEmpty {
            popup.selectItem(at: 0)
        }
        popup.isEnabled = isEnabled
        label.textColor = isEnabled ? Theme.text2 : Theme.text2.withAlphaComponent(0.45)
    }

    @objc private func selectionChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem else { return }
        onChange(title)
    }
}
