import Testing
@testable import MVMedia

@Test func renditionsGetMorePreciseInDeclarationOrder() {
    let qualities: [RenditionQuality] = [.original, .placeholder, .exact, .browse]
    #expect(qualities.sorted() == [.placeholder, .browse, .exact, .original])
}
