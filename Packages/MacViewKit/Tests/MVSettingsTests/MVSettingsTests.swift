import Foundation
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
    #expect(global.cache.decodedBytes == min(2 << 30, Int64(ProcessInfo.processInfo.physicalMemory / 10)))
    #expect(global.prefetch.neighborBooks == 2)
}
