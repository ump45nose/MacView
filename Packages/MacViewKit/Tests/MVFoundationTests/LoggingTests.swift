import Testing
@testable import MVFoundation

@Test func subsystemMatchesBundleIdentifier() {
    #expect(MVLog.subsystem == "io.github.ump45nose.MacView")
}

@Test func signpostCategoriesFollowPipelineStages() {
    #expect(SignpostCategory.allCases.map(\.rawValue) == ["io", "decode", "cache", "layout", "render"])
}
