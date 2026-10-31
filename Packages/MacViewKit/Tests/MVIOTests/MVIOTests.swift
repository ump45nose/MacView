import Testing
@testable import MVIO

@Test func visibleIsTheHighestPriority() {
    let priorities: [IOPriority] = [.background, .visible, .book, .adjacent, .near]
    #expect(priorities.sorted(by: >) == [.visible, .near, .book, .adjacent, .background])
}
