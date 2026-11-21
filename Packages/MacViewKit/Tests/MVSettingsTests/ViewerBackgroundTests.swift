import Foundation
import MVFoundation
import Testing
@testable import MVSettings

@Test("C1.5 新背景按约定字符串往返编解码", arguments: [
    (ViewerBackground.frostedGlass, "frostedGlass"),
    (.imageColor, "imageColor"),
])
func appearanceBackgroundStringsRoundTrip(_ background: ViewerBackground, _ name: String) throws {
    let encoded = try JSONEncoder().encode(background)
    #expect(String(decoding: encoded, as: UTF8.self) == "\"\(name)\"")
    #expect(try JSONDecoder().decode(ViewerBackground.self, from: encoded) == background)
    #expect(try JSONDecoder().decode(ViewerBackground.self, from: Data("\"\(name)\"".utf8)) == background)
}

@Test("C1.5 显示配置与路径规则文件读回新背景", arguments: [
    ViewerBackground.frostedGlass, .imageColor,
])
func appearanceBackgroundFilesRoundTrip(_ background: ViewerBackground) async throws {
    let directory = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../.build/appearance-background-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .standardizedFileURL
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let prefix = Location(root: .local, layers: [["背景测试"]])
    let profile = DisplayProfile(name: "新背景", settings: BookSettings(background: background))
    let rule = PathRule(name: "新背景", prefix: prefix, settings: BookSettings(background: background))
    let store = try FileSettingsStore(directory: directory)
    try await store.updateProfiles { $0 = [profile] }
    try await store.updatePathRules { $0 = [rule] }

    let reopened = try FileSettingsStore(directory: directory)
    #expect(await reopened.profiles() == [profile])
    #expect(await reopened.pathRules() == [rule])
    #expect(await reopened.resolve(for: prefix.appending("book.zip")).background == background)
    for file in ["profiles.json", "path-rules.json"] {
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: file))) as? [String: Any])
        let values = try #require(envelope["value"] as? [[String: Any]])
        let value = try #require(values.first)
        let settings = try #require(value["settings"] as? [String: Any])
        #expect(settings["background"] as? String == (background == .frostedGlass ? "frostedGlass" : "imageColor"))
    }
}
