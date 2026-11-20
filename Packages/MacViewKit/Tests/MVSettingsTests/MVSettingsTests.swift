import Foundation
import MVFoundation
import Testing
@testable import MVSettings

@Test func layersOverrideFieldByField() {
    let rule = BookSettings(pageMode: .double, direction: .rightToLeft, sort: SortSpec(key: .modified, ascending: false))
    let memory = BookSettings(direction: .leftToRight, scaleMode: .fitWidth, sharpen: 0.5)
    let resolved = ResolvedBookSettings.default.applying(rule).applying(memory)
    #expect(resolved.pageMode == .double)
    #expect(resolved.direction == .leftToRight)
    #expect(resolved.sort == SortSpec(key: .modified, ascending: false))
    #expect(resolved.scaleMode == .fitWidth)
    #expect(resolved.sharpen == 0.5)
    #expect(resolved.browseMode == ResolvedBookSettings.default.browseMode)
    #expect(ResolvedBookSettings.default.applying(BookSettings()) == .default)
}

@Test func layerJSONHoldsOnlyOverriddenFields() throws {
    #expect(String(decoding: try JSONEncoder().encode(BookSettings(pageMode: .double)), as: UTF8.self) == #"{"pageMode":"double"}"#)
    #expect(try JSONDecoder().decode(BookSettings.self, from: Data("{}".utf8)) == BookSettings())
}

@Test func globalDefaultsRoundTripAndFollowTheBudgets() throws {
    let global = GlobalSettings.default
    #expect(try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(global)) == global)
    #expect(global.cache.rawBytes == 512 << 20)
    #expect(global.cache.decodedBytes == min(1 << 30, Int64(ProcessInfo.processInfo.physicalMemory / 20)))
    #expect(global.cache.thumbnailMemoryBytes == 512 << 20)
    #expect(global.cache.preloadBytes == 512 << 20)
    #expect(global.prefetch.neighborBooks == 2)
}

@Test func fileOperationSettingsRoundTripTargets() throws {
    let location = Location(root: .network(scheme: "nfs", host: "server", share: "images"), layers: [["分类"]])
    var global = GlobalSettings.default
    global.fileOperations = FileOperationSettings(nameConflict: .skip, classifyMode: .copy, classifyTargets: [ClassifyTarget(location: location, listsSubfolders: true)])
    #expect(try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(global)) == global)
    #expect(try JSONDecoder().decode(FileOperationSettings.self, from: Data("{}".utf8)) == .default)
}

@Test("C1.1 BookSettings.merge 与 ResolvedBookSettings.applying 按非空字段合并效果和背景")
func effectsAndBackgroundMergeByField() {
    let warm = EffectChain(effects: [.colorAdjust(ColorAdjust(brightness: 0.2, temperature: 0.3))])
    let cool = EffectChain(effects: [.colorAdjust(ColorAdjust(contrast: 0.4, temperature: -0.5))])
    let custom = ViewerBackground.custom(red: 0.1, green: 0.2, blue: 0.3)

    var base = BookSettings(pageMode: .double, effects: warm, background: .black)
    base.merge(BookSettings(direction: .rightToLeft, background: custom))
    #expect(base.pageMode == .double)
    #expect(base.direction == .rightToLeft)
    #expect(base.effects == warm)
    #expect(base.background == custom)
    #expect(base.scaleMode == nil)

    base.merge(BookSettings(effects: cool))
    #expect(base.effects == cool)
    #expect(base.background == custom)

    let resolved = ResolvedBookSettings.default
        .applying(BookSettings(effects: warm, background: .gray))
        .applying(BookSettings(background: .checkerboard))
    #expect(resolved.effects == warm)
    #expect(resolved.background == .checkerboard)
}

@Test("C1.3 越界数值解码时夹到合法范围，EffectChain 恒等判断与扁平 JSON 契约")
func effectsAndBackgroundClampingIdentityAndJSONShape() throws {
    let rawColor = Data(#"{"brightness":5,"contrast":-9,"saturation":2.5,"gamma":0.01,"temperature":-3,"tint":4}"#.utf8)
    let clampedColor = try JSONDecoder().decode(ColorAdjust.self, from: rawColor)
    #expect(clampedColor == ColorAdjust(brightness: 1, contrast: -1, saturation: 1, gamma: 0.25, temperature: -1, tint: 1))

    let highGamma = try JSONDecoder().decode(ColorAdjust.self, from: Data(#"{"gamma":99}"#.utf8))
    #expect(highGamma == ColorAdjust(gamma: 4))

    let rawBackground = Data(#"{"type":"custom","red":-0.5,"green":0.5,"blue":2.0}"#.utf8)
    #expect(try JSONDecoder().decode(ViewerBackground.self, from: rawBackground) == .custom(red: 0, green: 0.5, blue: 1))

    for preset: ViewerBackground in [.auto, .black, .gray, .white, .checkerboard, .custom(red: 0.2, green: 0.4, blue: 0.6)] {
        #expect(try JSONDecoder().decode(ViewerBackground.self, from: JSONEncoder().encode(preset)) == preset)
    }

    var chain = EffectChain.empty
    #expect(chain.isIdentity)
    #expect(chain.colorAdjust == .identity)
    #expect(EffectChain(effects: [.colorAdjust(.identity)]).isIdentity)

    let adjusted = ColorAdjust(brightness: 0.25, gamma: 1.5)
    chain.colorAdjust = adjusted
    #expect(!chain.isIdentity)
    #expect(chain.colorAdjust == adjusted)
    #expect(chain.effects == [.colorAdjust(adjusted)])

    chain.colorAdjust = .identity
    #expect(chain.effects.isEmpty)
    #expect(chain.isIdentity)

    let encodedEffect = try JSONEncoder().encode(Effect.colorAdjust(adjusted))
    let object = try #require(JSONSerialization.jsonObject(with: encodedEffect) as? [String: Any])
    #expect(object["type"] as? String == "colorAdjust")
    #expect(object["brightness"] as? Double == 0.25)
    #expect(object["gamma"] as? Double == 1.5)
    #expect(object["contrast"] as? Double == 0)
    #expect(try JSONDecoder().decode(Effect.self, from: encodedEffect) == .colorAdjust(adjusted))
}

@Test("C1.4 DisplayProfile 按选定组提取字段，merge 到书层时只改变这两组字段")
func displayProfileCapturesSelectedGroupsAndMergesOnlyThoseFields() throws {
    let customEffects = EffectChain(effects: [.colorAdjust(ColorAdjust(brightness: 0.3, saturation: -0.2))])
    let customBackground = ViewerBackground.custom(red: 0.1, green: 0.2, blue: 0.3)
    let resolved = ResolvedBookSettings(
        browseMode: .waterfall,
        pageMode: .double,
        direction: .rightToLeft,
        firstPageSingle: false,
        widePage: .split,
        sort: SortSpec(key: .modified, ascending: false, foldersFirst: false, randomSeed: 99),
        recursion: RecursionSpec(enabled: true, maxDepth: 4),
        scaleMode: .fixed,
        allowUpscale: true,
        fixedScale: 1.5,
        keepZoomOnPageTurn: true,
        resample: .nearest,
        sharpen: 0.6,
        effects: customEffects,
        background: customBackground
    )

    // 只勾选 layout 与 background 两组
    let profile = DisplayProfile(name: "双页夜景", capturing: resolved, groups: [.layout, .background])
    #expect(profile.groups == [.layout, .background])
    #expect(profile.settings.browseMode == .waterfall)
    #expect(profile.settings.pageMode == .double)
    #expect(profile.settings.direction == .rightToLeft)
    #expect(profile.settings.firstPageSingle == false)
    #expect(profile.settings.widePage == .split)
    #expect(profile.settings.background == customBackground)
    // 未勾选组及排序/递归均为 nil
    #expect(profile.settings.scaleMode == nil)
    #expect(profile.settings.allowUpscale == nil)
    #expect(profile.settings.fixedScale == nil)
    #expect(profile.settings.keepZoomOnPageTurn == nil)
    #expect(profile.settings.resample == nil)
    #expect(profile.settings.sharpen == nil)
    #expect(profile.settings.effects == nil)
    #expect(profile.settings.sort == nil)
    #expect(profile.settings.recursion == nil)

    // Codable 往返保留全部信息及 groups 推导
    let roundTripped = try JSONDecoder().decode(DisplayProfile.self, from: JSONEncoder().encode(profile))
    #expect(roundTripped == profile)
    #expect(roundTripped.groups == [.layout, .background])

    // 另一组组合（scale + effects）也完整覆盖
    let scaleAndEffects = DisplayProfile(name: "锐化调色", capturing: resolved, groups: [.scale, .effects])
    #expect(scaleAndEffects.groups == [.scale, .effects])
    #expect(scaleAndEffects.settings.scaleMode == .fixed)
    #expect(scaleAndEffects.settings.allowUpscale == true)
    #expect(scaleAndEffects.settings.fixedScale == 1.5)
    #expect(scaleAndEffects.settings.keepZoomOnPageTurn == true)
    #expect(scaleAndEffects.settings.resample == .nearest)
    #expect(scaleAndEffects.settings.sharpen == 0.6)
    #expect(scaleAndEffects.settings.effects == customEffects)
    #expect(scaleAndEffects.settings.browseMode == nil)
    #expect(scaleAndEffects.settings.background == nil)
    #expect(scaleAndEffects.settings.sort == nil)
    #expect(scaleAndEffects.settings.recursion == nil)

    // merge 进一本书的 BookSettings 书层：只有勾选的两组字段变化，其余保持原值
    let originalEffects = EffectChain(effects: [.colorAdjust(ColorAdjust(contrast: 0.4))])
    let originalSort = SortSpec(key: .size, ascending: true)
    let originalRecursion = RecursionSpec(enabled: false, maxDepth: 2)
    var bookLayer = BookSettings(
        browseMode: .paged,
        pageMode: .single,
        direction: .leftToRight,
        firstPageSingle: true,
        widePage: .asIs,
        sort: originalSort,
        recursion: originalRecursion,
        scaleMode: .fitWidth,
        allowUpscale: false,
        fixedScale: 0.8,
        keepZoomOnPageTurn: false,
        resample: .lanczos,
        sharpen: 0.1,
        effects: originalEffects,
        background: .white
    )
    bookLayer.merge(profile.settings)
    // layout 与 background 两组更新
    #expect(bookLayer.browseMode == .waterfall)
    #expect(bookLayer.pageMode == .double)
    #expect(bookLayer.direction == .rightToLeft)
    #expect(bookLayer.firstPageSingle == false)
    #expect(bookLayer.widePage == .split)
    #expect(bookLayer.background == customBackground)
    // scale、effects、sort、recursion 保持原值
    #expect(bookLayer.scaleMode == .fitWidth)
    #expect(bookLayer.allowUpscale == false)
    #expect(bookLayer.fixedScale == 0.8)
    #expect(bookLayer.keepZoomOnPageTurn == false)
    #expect(bookLayer.resample == .lanczos)
    #expect(bookLayer.sharpen == 0.1)
    #expect(bookLayer.effects == originalEffects)
    #expect(bookLayer.sort == originalSort)
    #expect(bookLayer.recursion == originalRecursion)
}
