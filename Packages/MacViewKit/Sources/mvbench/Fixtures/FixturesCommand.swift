import ArgumentParser
import Foundation
import MVTestSupport

/// `mvbench fixtures`：生成全部测试夹具与清单，再逐个核对。
struct FixturesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fixtures",
        abstract: "生成测试夹具与清单，并逐个核对。"
    )

    @Option(help: "夹具目录；省略时为仓库的 Fixtures/。")
    var root: String?

    @Flag(help: "不生成 local/generated 下的大夹具。")
    var skipLocal = false

    @Flag(help: "不生成，只核对现有的夹具。")
    var verifyOnly = false

    func run() async throws {
        let root = root.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Fixtures.root
        let clock = ContinuousClock()
        var start = clock.now
        let manifest: FixtureManifest
        if verifyOnly {
            manifest = try Fixtures.manifest(in: root)
        } else {
            manifest = try await FixtureGenerator.generate(into: root, includeLocal: !skipLocal)
            print("生成用时 \(seconds(clock.now - start))")
        }

        let hasLocal = Fixtures.hasLocal(in: root)
        let committed = manifest.fixtures.filter { !$0.isLocal }
        let local = manifest.fixtures.filter(\.isLocal)
        print("入库 \(committed.count) 个，\(mebibytes(try committed.reduce(0) { $0 + (try $1.byteCount(in: root)) }))")
        if hasLocal {
            print("本地 \(local.count) 个，\(mebibytes(try local.reduce(0) { $0 + (try $1.byteCount(in: root)) }))（\(Fixtures.localDirectory)）")
        } else {
            print("本地 \(local.count) 个未生成，跳过核对")
        }

        start = clock.now
        var failures = 0
        for fixture in hasLocal ? manifest.fixtures : committed {
            let issues = await FixtureVerifier.issues(of: fixture, in: root)
            if !issues.isEmpty {
                failures += 1
                print("✗ \(fixture.path)\n" + issues.map { "    \($0)" }.joined(separator: "\n"))
            }
        }
        print("核对用时 \(seconds(clock.now - start))，\(failures == 0 ? "全部与清单一致" : "\(failures) 个与清单不一致")")
        if failures > 0 {
            throw ExitCode.failure
        }
    }

    private func seconds(_ duration: Duration) -> String {
        String(format: "%.1f 秒", Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18)
    }

    private func mebibytes(_ bytes: Int64) -> String {
        String(format: "%.1f MiB", Double(bytes) / 1_048_576)
    }
}

extension Fixture {
    /// 夹具的字节数；目录树为其中全部文件之和。
    func byteCount(in root: URL) throws -> Int64 {
        let url = Fixtures.url(path, in: root)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard directory != nil else { return Int64(try url.resourceValues(forKeys: keys).fileSize ?? 0) }
        var total: Int64 = 0
        for path in try FileManager.default.subpathsOfDirectory(atPath: url.path) {
            let values = try url.appending(path: path).resourceValues(forKeys: keys)
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
