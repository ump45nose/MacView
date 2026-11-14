import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import MVFileOps
import MVFoundation
import MVIO
import Synchronization

/// 只在规格指定的两个 NFS 挂载和工作区中创建本次测试目录。
struct FileOpsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fileops", abstract: "验证文件操作在两个 NFS 测试卷上的移动与强杀恢复。")
    @Option(name: .shortAndLong, help: "JSON 输出路径。") var output: String?

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let a = home.appending(path: "MacViewBench/fileops-a")
        let b = home.appending(path: "MacViewBench/fileops-b")
        var report = FileOpsReport(environment: BenchEnvironment.collect(paths: [a.path, b.path], host: nil))
        do {
            try validateMount(a)
            try validateMount(b)
            var sa = statfs(), sb = statfs()
            guard statfs(a.path, &sa) == 0, statfs(b.path, &sb) == 0,
                  cString(of: &sa.f_mntfromname) != cString(of: &sb.f_mntfromname) else {
                throw ValidationFailure("两个测试目录必须是不同的 NFS 挂载")
            }
            let localParent = URL(fileURLWithPath: "Fixtures/local", isDirectory: true).standardizedFileURL
            try FileManager.default.createDirectory(at: localParent, withIntermediateDirectories: true)
            let id = ".mvbench-fileops-" + UUID().uuidString
            let roots = [a.appending(path: id), b.appending(path: id), localParent.appending(path: id)]
            var created: [URL] = []
            do {
                for root in roots {
                    guard mkdir(root.path, 0o700) == 0 else { throw SystemCallError.last("mkdir") }
                    created.append(root)
                }
                let registry = FileSourceRegistry(scheduler: IOScheduler(configuration: IOConfiguration(helperExecutable: Bundle.main.executableURL)))
                defer { registry.scheduler.shutdown() }
                let service = try FileOperationService(fileSystem: registry.fileSystem, journalURL: roots[2].appending(path: "transfers.json"))
                let startFolder = roots[0].appending(path: "same-source", directoryHint: .isDirectory)
                let endFolder = roots[0].appending(path: "same-target", directoryHint: .isDirectory)
                try mkdirOwned(startFolder); try mkdirOwned(endFolder)
                let source = startFolder.appending(path: "large.bin")
                _ = try writePattern(source, bytes: 500_000_000, seed: 7)
                let clock = ContinuousClock()
                let started = clock.now
                let result = await service.perform(.transfer([try await registry.location(for: source)], into: try await registry.location(for: endFolder), mode: .move, conflict: .skip))
                let seconds = started.duration(to: clock.now).milliseconds / 1000
                try checkResult(result, count: 1)
                guard !exists(source), exists(endFolder.appending(path: "large.bin")) else { throw ValidationFailure("同卷移动结果不正确") }
                report.sameVolumeSeconds = seconds
                report.sameVolumePassed = seconds <= 1
                report.transfers.append(try await transferTwenty(from: roots[0], to: roots[2], label: "network-to-local", registry: registry, service: service, journal: roots[2].appending(path: "transfers.json")))
                report.transfers.append(try await transferTwenty(from: roots[0], to: roots[1], label: "network-to-network", registry: registry, service: service, journal: roots[2].appending(path: "transfers.json")))
                report.recovery = try await recoverAfterKill(from: roots[0], to: roots[1], local: roots[2], registry: registry, service: service)
            } catch {
                report.error = String(describing: error)
            }
            var cleanupErrors: [String] = []
            for root in created.reversed() {
                do { try FileManager.default.removeItem(at: root) }
                catch { cleanupErrors.append("\(root.path): \(error.localizedDescription)") }
            }
            report.cleanupErrors = cleanupErrors
            report.cleanupPassed = cleanupErrors.isEmpty && created.allSatisfy { !exists($0) }
        } catch { report.error = String(describing: error) }
        try JSONReport.write(report, to: output)
        guard report.error == nil, report.sameVolumePassed == true, report.transfers.count == 2,
              report.transfers.allSatisfy(\.passed), report.recovery?.passed == true, report.cleanupPassed == true else {
            throw ExitCode.failure
        }
    }
}

private struct FileOpsReport: Encodable {
    var environment: BenchEnvironment
    var sameVolumeSeconds: Double?
    var sameVolumePassed: Bool?
    var transfers: [TransferEvidence] = []
    var recovery: RecoveryEvidence?
    var cleanupPassed: Bool?
    var cleanupErrors: [String] = []
    var error: String?
    let faultTest = "C1.25 留给整体验收"
}
private struct TransferEvidence: Encodable {
    var direction: String
    var seconds: Double
    var count: Int
    var conflictKept: Bool
    var fileTimesPreserved: Bool
    var hashesMatch: Bool
    var sha256ByFile: [String: String]
    var journalEmpty: Bool
    var passed: Bool { count == 20 && conflictKept && fileTimesPreserved && hashesMatch && journalEmpty }
    enum CodingKeys: String, CodingKey { case direction, seconds, count, conflictKept, fileTimesPreserved, hashesMatch, sha256ByFile, journalEmpty, passed }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(direction, forKey: .direction); try c.encode(seconds, forKey: .seconds); try c.encode(count, forKey: .count)
        try c.encode(conflictKept, forKey: .conflictKept); try c.encode(fileTimesPreserved, forKey: .fileTimesPreserved)
        try c.encode(hashesMatch, forKey: .hashesMatch); try c.encode(sha256ByFile, forKey: .sha256ByFile)
        try c.encode(journalEmpty, forKey: .journalEmpty); try c.encode(passed, forKey: .passed)
    }
}
private struct RecoveryEvidence: Encodable {
    var killedAtBytes: Int64
    var expectedSHA256: String
    var actualSHA256: String
    var sourceRemoved: Bool
    var temporaryRemoved: Bool
    var journalEmpty: Bool
    var recovered: Int
    var passed: Bool { killedAtBytes > (1 << 29) && expectedSHA256 == actualSHA256 && sourceRemoved && temporaryRemoved && journalEmpty && recovered == 1 }
    enum CodingKeys: String, CodingKey { case killedAtBytes, expectedSHA256, actualSHA256, sourceRemoved, temporaryRemoved, journalEmpty, recovered, passed }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(killedAtBytes, forKey: .killedAtBytes); try c.encode(expectedSHA256, forKey: .expectedSHA256)
        try c.encode(actualSHA256, forKey: .actualSHA256); try c.encode(sourceRemoved, forKey: .sourceRemoved)
        try c.encode(temporaryRemoved, forKey: .temporaryRemoved); try c.encode(journalEmpty, forKey: .journalEmpty)
        try c.encode(recovered, forKey: .recovered); try c.encode(passed, forKey: .passed)
    }
}

private func validateMount(_ url: URL) throws {
    var info = statfs()
    guard statfs(url.path, &info) == 0, cString(of: &info.f_mntonname) == url.path,
          cString(of: &info.f_fstypename) == "nfs", info.f_flags & UInt32(MNT_RDONLY) == 0 else {
        throw ValidationFailure("\(url.path) 不是已挂载的可写 NFS 测试卷")
    }
}
private func mkdirOwned(_ url: URL) throws {
    guard mkdir(url.path, 0o700) == 0 else { throw SystemCallError.last("mkdir") }
}
private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
private func checkResult(_ result: FileOperationResult, count: Int) throws {
    guard result.failures.isEmpty, result.skipped.isEmpty, result.changes.count == count else {
        throw ValidationFailure("文件操作失败：\(result.failures.map { String(describing: $0.error) })，跳过 \(result.skipped.count)，完成 \(result.changes.count)/\(count)")
    }
}
private func emptyJournal(_ url: URL) throws -> Bool {
    guard exists(url) else { return true }
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    return (json?["transfers"] as? [Any])?.isEmpty == true
}
private func digest(_ data: SHA256.Digest) -> String { data.map { String(format: "%02x", $0) }.joined() }
private func writePattern(_ url: URL, bytes: Int, seed: UInt8) throws -> String {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ValidationFailure("无法创建测试文件 \(url.path)") }
    let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
    let block = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &+ Int(seed)) })
    var hash = SHA256(), remaining = bytes
    while remaining > 0 {
        let chunk = block.prefix(min(remaining, block.count))
        try handle.write(contentsOf: chunk); hash.update(data: chunk); remaining -= chunk.count
    }
    try handle.synchronize()
    return digest(hash.finalize())
}
private func hashFile(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty { hash.update(data: data) }
    return digest(hash.finalize())
}

private func transferTwenty(from: URL, to: URL, label: String, registry: FileSourceRegistry, service: FileOperationService, journal: URL) async throws -> TransferEvidence {
    let sourceFolder = from.appending(path: label + "-source"), targetFolder = to.appending(path: label + "-target")
    try mkdirOwned(sourceFolder); try mkdirOwned(targetFolder)
    var expected: [String: String] = [:], sourceTimes: [String: Int64] = [:], sources: [Location] = []
    let stamp: Int64 = 1_700_000_000_123_456_789
    for index in 0..<20 {
        let name = String(format: "item%02d.bin", index)
        let source = sourceFolder.appending(path: name)
        expected[name] = try writePattern(source, bytes: 1 << 20, seed: UInt8(index))
        let location = try await registry.location(for: source)
        try await registry.fileSystem.finishFile(at: location, modificationNanos: stamp)
        sourceTimes[name] = try await registry.fileSystem.entry(at: location).identity.modificationNanos
        sources.append(location)
    }
    let conflict = targetFolder.appending(path: "item00.bin")
    try Data("existing".utf8).write(to: conflict)
    let started = ContinuousClock.now
    let result = await service.perform(.transfer(sources, into: try await registry.location(for: targetFolder), mode: .move, conflict: .appendNumber))
    let seconds = started.duration(to: .now).milliseconds / 1000
    try checkResult(result, count: 20)
    var hashesMatch = true, timesMatch = true
    for index in 0..<20 {
        let name = String(format: "item%02d.bin", index)
        let output = targetFolder.appending(path: index == 0 ? "item00 (2).bin" : name)
        guard !exists(sourceFolder.appending(path: name)), exists(output) else { throw ValidationFailure("跨卷移动缺少 \(name)") }
        let currentHash = try hashFile(output)
        let outputLocation = try await registry.location(for: output)
        let currentTime = try await registry.fileSystem.entry(at: outputLocation).identity.modificationNanos
        hashesMatch = hashesMatch && currentHash == expected[name]
        timesMatch = timesMatch && currentTime == sourceTimes[name]
    }
    return TransferEvidence(direction: label, seconds: seconds, count: result.changes.count,
                            conflictKept: try Data(contentsOf: conflict) == Data("existing".utf8), fileTimesPreserved: timesMatch,
                            hashesMatch: hashesMatch, sha256ByFile: expected, journalEmpty: try emptyJournal(journal))
}

private func recoverAfterKill(from: URL, to: URL, local: URL, registry: FileSourceRegistry, service: FileOperationService) async throws -> RecoveryEvidence {
    let sourceFolder = from.appending(path: "kill-source"), targetFolder = to.appending(path: "kill-target")
    try mkdirOwned(sourceFolder); try mkdirOwned(targetFolder)
    let source = sourceFolder.appending(path: "recover.bin"), target = targetFolder.appending(path: "recover.bin")
    let journal = local.appending(path: "transfers.json")
    let expected = try writePattern(source, bytes: 1 << 30, seed: 91)
    guard let executable = Bundle.main.executablePath else { throw ValidationFailure("找不到 mvbench 可执行文件") }
    let child = try ChildProcess(executable, ["fileops-worker", "--source", source.path, "--destination", targetFolder.path, "--journal", journal.path])
    guard let line = child.readLine(timeout: 1800), let bytes = Int64(line), bytes > (1 << 29) else {
        child.kill(); _ = child.waitForExit(timeout: 10)
        throw ValidationFailure("子进程未报告超过一半的复制进度")
    }
    child.kill()
    guard child.waitForExit(timeout: 10) else { throw ValidationFailure("子进程未在强杀后退出") }
    let result = await service.resumeInterruptedTransfers()
    guard result.completed == 1, result.pending == 0, result.failed == 0, exists(target) else {
        throw ValidationFailure("恢复未完成：completed=\(result.completed) pending=\(result.pending) failed=\(result.failed)")
    }
    let remaining = try FileManager.default.contentsOfDirectory(atPath: targetFolder.path)
    return RecoveryEvidence(killedAtBytes: bytes, expectedSHA256: expected, actualSHA256: try hashFile(target),
                            sourceRemoved: !exists(source), temporaryRemoved: !remaining.contains { $0.hasPrefix(".recover.bin.macview-part") },
                            journalEmpty: try emptyJournal(journal), recovered: result.completed)
}

/// 子进程到达半程后阻塞在回调中，确保父进程强杀发生在复制完成之前。
struct FileOpsWorker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fileops-worker", shouldDisplay: false)
    @Option var source: String
    @Option var destination: String
    @Option var journal: String
    func run() async throws {
        let registry = FileSourceRegistry(scheduler: IOScheduler(configuration: IOConfiguration(helperExecutable: Bundle.main.executableURL)))
        defer { registry.scheduler.shutdown() }
        let service = try FileOperationService(fileSystem: registry.fileSystem, journalURL: URL(fileURLWithPath: journal))
        let src = try await registry.location(for: URL(fileURLWithPath: source))
        let dest = try await registry.location(for: URL(fileURLWithPath: destination))
        let announced = Atomic(false)
        let result = await service.perform(.transfer([src], into: dest, mode: .move, conflict: .skip)) { progress in
            guard progress.completedBytes > (1 << 29), !announced.exchange(true, ordering: .relaxed) else { return }
            FileHandle.standardOutput.write(Data("\(progress.completedBytes)\n".utf8))
            var byte: UInt8 = 0
            _ = read(STDIN_FILENO, &byte, 1)
        }
        try checkResult(result, count: 1)
    }
}
