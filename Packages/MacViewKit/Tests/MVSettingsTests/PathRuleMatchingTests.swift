import Foundation
import MVFoundation
import MVSettings
import Testing

@Test func pathRuleMatchingOrdersBySpecificityThenOriginalOrder() {
    func location(_ path: String...) -> Location { Location(root: .local, layers: [path]) }
    let deep = PathRule(name: "deep", prefix: location("a", "b"), settings: BookSettings())
    let first = PathRule(name: "first", prefix: location("a"), settings: BookSettings())
    let second = PathRule(name: "second", prefix: location("a"), settings: BookSettings())
    let other = PathRule(name: "other", prefix: location("c"), settings: BookSettings())
    let matching = PathRule.matching([deep, first, other, second], for: location("a", "b", "book"))
    #expect(matching.map(\.name) == ["first", "second", "deep"])
    #expect(PathRule.matching([deep, other], for: location("a")).isEmpty)
}
