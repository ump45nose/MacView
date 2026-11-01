import Foundation
import Testing
@testable import MVFoundation

struct NameOrderTests {
    @Test("自然数字、中文拼音、全角数字及中英文混排保持全序")
    func numericAndPinyin() {
        #expect(NameOrder.compare("2.jpg", "10.jpg") == .orderedAscending)
        #expect(NameOrder.compare("阿2.jpg", "波1.jpg") == .orderedAscending)
        #expect(NameOrder.compare("２.jpg", "１２.jpg") == .orderedAscending)
        let names = ["阿10.jpg", "2.jpg", "波1.jpg", "阿2.jpg", "A1.jpg", "a２.jpg", "Ａ12.jpg", "10.jpg", "あ.jpg", "_1.jpg"]
        let ordered = names.sorted { NameOrder.compare($0, $1) == .orderedAscending }
        for a in ordered.indices {
            #expect(NameOrder.compare(ordered[a], ordered[a]) == .orderedSame)
            for b in ordered.indices where a < b {
                #expect(NameOrder.compare(ordered[a], ordered[b]) == .orderedAscending)
                #expect(NameOrder.compare(ordered[b], ordered[a]) == .orderedDescending)
                for c in ordered.indices where b < c { #expect(NameOrder.compare(ordered[a], ordered[c]) == .orderedAscending) }
            }
        }
    }

    @Test("真实 Finder 按名称排序对照（中文拼音部分除外）")
    func finderOrder() async throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = workspace.appending(path: "build/stage3-work/finder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = ["10.jpg", "2.jpg", "1.jpg", "02.jpg", "002.jpg", "a10.jpg", "a2.jpg", "A3.jpg", "b.jpg", "20.jpg", "100.jpg", "x_10.jpg", "x_2.jpg", "x-2.jpg", "x 2.jpg", "é2.jpg", "e10.jpg", "１２.jpg", "3.png"]
        for name in names { try Data().write(to: folder.appending(path: name)) }
        let finder = try await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/osascript")
            let escaped = folder.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            process.arguments = ["-e", """
                tell application "Finder"
                    set orderedItems to sort (every file of folder (POSIX file "\(escaped)")) by name
                    set orderedNames to {}
                    repeat with itemRef in orderedItems
                        set end of orderedNames to name of itemRef
                    end repeat
                    set AppleScript's text item delimiters to linefeed
                    return orderedNames as text
                end tell
                """]
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let error = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "Finder 系统对照失败：\(String(decoding: error, as: UTF8.self))")
            return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        }.value
        #expect(finder == names.sorted { NameOrder.compare($0, $1) == .orderedAscending })
    }
}
