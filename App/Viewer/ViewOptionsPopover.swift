import AppKit
import MVMedia
import MVReading
import MVSettings
import SwiftUI

/// 工具栏“显示”按钮的弹层：双页、缩放和重采样的设置，都写进书层。
@MainActor
enum ViewOptionsPopover {
    static func make(session: ReaderSession, viewer: ViewerContainerView) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ViewOptionsView(session: session, viewer: viewer))
        return popover
    }
}

private struct ViewOptionsView: View {
    let session: ReaderSession
    let viewer: ViewerContainerView

    private static let modes: [ScaleMode] = [.fitWindow, .fitWidth, .fitHeight, .fill, .original, .fixed, .devicePixel]

    var body: some View {
        let settings = session.settings
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("双页")
            row("阅读方向") {
                Picker("", selection: binding(settings.direction) { $0.direction = $1 }) {
                    Text("从左到右").tag(ReadingDirection.leftToRight)
                    Text("从右到左").tag(ReadingDirection.rightToLeft)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            }
            row("首页单页") {
                Toggle("", isOn: binding(settings.firstPageSingle) { $0.firstPageSingle = $1 })
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
            row("宽页") {
                Picker("", selection: binding(settings.widePage) { $0.widePage = $1 }) {
                    Text("原样").tag(WidePagePolicy.asIs)
                    Text("单独").tag(WidePagePolicy.single)
                    Text("拆分").tag(WidePagePolicy.split)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            }
            Divider()
            sectionTitle("缩放")
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Self.modes, id: \.self) { mode in
                    Button {
                        session.update { $0.scaleMode = mode }
                        viewer.paged.resetTransform()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark").opacity(settings.scaleMode == mode ? 1 : 0).frame(width: 14)
                            Text(ViewerHUD.title(of: mode)).fontWeight(settings.scaleMode == mode ? .semibold : .regular)
                            Spacer()
                            if let percent = viewer.paged.percent(for: mode, fixedScale: settings.fixedScale) {
                                Text(verbatim: "\(percent)%").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            row("仅缩小不放大") {
                Toggle("", isOn: binding(!settings.allowUpscale) { $0.allowUpscale = !$1 })
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
            row("翻页保持缩放") {
                Toggle("", isOn: binding(settings.keepZoomOnPageTurn) { $0.keepZoomOnPageTurn = $1 })
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
            Divider()
            row("重采样") {
                Picker("", selection: Binding(
                    get: { settings.resample == .nearest ? 1 : settings.sharpen > 0 ? 2 : 0 },
                    set: { value in
                        session.update {
                            $0.resample = value == 1 ? .nearest : .lanczos
                            $0.sharpen = Float(value == 2 ? 0.5 : 0)
                        }
                    }
                )) {
                    Text(verbatim: "Lanczos").tag(0)
                    Text("最近邻").tag(1)
                    Text("缩小后锐化").tag(2)
                }
                .labelsHidden().controlSize(.small).fixedSize()
            }
        }
        .font(.system(size: 13))
        .padding(14)
        .frame(width: 296)
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func row(_ title: LocalizedStringKey, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(title)
            Spacer()
            control()
        }
    }

    /// 改动写进书层，读的是解析后的值。
    private func binding<Value>(_ value: Value, _ write: @escaping (inout BookSettings, Value) -> Void) -> Binding<Value> {
        Binding(get: { value }, set: { new in session.update { write(&$0, new) } })
    }
}
