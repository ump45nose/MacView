import ArgumentParser
import Darwin
import Foundation
import MVFoundation
import MVIO
import Synchronization

/// `mvbench io scheduler-fault`：经 MVIO 的调度器访问测试挂载，让代理卡住或断线，
/// 记录超时、degraded 与恢复的时间，以及辅助进程卡住时宿主能否按时退出、重开后能否立即工作。
struct SchedulerFaultCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scheduler-fault",
        abstract: "经 MVIO 调度器访问测试挂载，施加故障，记录超时、degraded、恢复和退出。",
        discussion: """
            每个场景：两个任务循环读文件开头 2 MB（大块读取通道，F_NOCACHE）；3 秒后施加故障，持续 --duration 秒后恢复，
            等卷回到 healthy 并有一次成功的读取（最多 --recovery-timeout 秒）。
            退出测试：子进程 `io scheduler-hold` 循环读测试挂载，施加故障 --exit-delay 秒后让它退出，记录多久后进程消失；
            随后立即启动第二个子进程，先读本机文件，再在恢复转发后读测试挂载。最后检查卡住的辅助进程是否在恢复后消失。
            """
    )

    @OptionGroup var report: ReportOptions

    @Option(help: "proxy 打印的控制端口。")
    var control: UInt16

    @Option(name: .customLong("dir"), help: "测试挂载下的图集目录。")
    var directory: String

    @Option(help: "退出测试中重开后读取的本机文件。")
    var localFile: String

    @Option(parsing: .upToNextOption, help: "故障方式：pause、drop。")
    var mode: [FaultProxy.Mode] = [.pause]

    @Option(parsing: .upToNextOption, help: "故障持续的秒数，可给多个值。")
    var duration: [Double] = [5, 30, 60]

    @Option(help: "故障结束后最多等待恢复的秒数。")
    var recoveryTimeout: Double = 90

    @Option(help: "退出测试中施加故障到请求退出的秒数；要长于期限，让调用卡在辅助进程里。")
    var exitDelay: Double = 12

    @Flag(help: "只做退出测试。")
    var exitTestOnly = false

    func run() async throws {
        let files = try Samples.files(in: directory, limit: 40).map(\.path)
        guard !files.isEmpty else { throw ValidationFailure("\(directory) 下没有文件") }
        try ProxyControl.send("forward", port: control)
        var scenarios: [SchedulerFaultScenario] = []
        for mode in exitTestOnly ? [] : mode {
            for seconds in duration {
                let scenario = try await runScenario(mode: mode, seconds: seconds, files: files)
                progress("\(report.label) \(mode.rawValue) \(Int(seconds)) 秒：首次超时 \(scenario.firstTimeoutAfterStart.map { String(format: "%.1f", $0) } ?? "-") 秒，"
                    + "degraded \(scenario.degradedAfterStart.map { String(format: "%.1f", $0) } ?? "-") 秒，"
                    + "恢复 \(scenario.healthyAfterEnd.map { String(format: "%.1f", $0) } ?? "-") 秒")
                progress(scenario.transitions.map { String(format: "  %.1f %@ stuck %d", $0.time, $0.state, $0.stuck) }.joined(separator: "\n"))
                scenarios.append(scenario)
            }
        }
        var exit: SchedulerExitTest
        do {
            exit = try runExitTest(files: files)
        } catch {
            _ = try? ProxyControl.send("forward", port: control)
            exit = SchedulerExitTest(delaySeconds: exitDelay, error: "\(error)")
        }
        progress("\(report.label) 退出测试：退出 \(exit.exitMilliseconds.map { "\(Int($0)) ms" } ?? "超时")，"
            + "重开读本机 \(exit.relaunchLocalMilliseconds.map { "\(Int($0)) ms" } ?? "-")，恢复后读 NAS \(exit.relaunchNetworkAfterResumeMilliseconds.map { "\(Int($0)) ms" } ?? "-")，"
            + "残留辅助进程 \(exit.helpersLeftAfterRecovery)")
        let result = SchedulerFaultResult(scenarios: scenarios, exitTest: exit)
        try IOReport.write(result, label: report.label, transport: .scheduler, paths: [directory], output: report.output)
    }

    private func runScenario(mode: FaultProxy.Mode, seconds: Double, files: [String]) async throws -> SchedulerFaultScenario {
        let registry = SchedulerBackend.registry(concurrency: 4, chunk: 4 << 20)
        defer { registry.scheduler.shutdown() }
        let clock = ContinuousClock()
        let origin = clock.now
        let operations = ResultSink<SchedulerOperation>()
        let transitions = ResultSink<HealthTransition>()
        let healthTask = Task {
            var last: String?
            for await health in registry.volumeHealth() {
                guard let volume = health.first(where: { if case .network = $0.root { true } else { false } }) else { continue }
                let state = "\(volume.state)"
                if state != last {
                    transitions.append(HealthTransition(time: (clock.now - origin).seconds, state: state, stuck: volume.stuck))
                    last = state
                }
            }
        }
        let stop = Atomic(false)
        let readers = (0..<2).map { index in
            Task {
                var next = index
                while !stop.load(ordering: .relaxed) {
                    let begin = clock.now
                    var failure: String?
                    do {
                        let location = try await registry.location(for: URL(filePath: files[next % files.count], directoryHint: .notDirectory))
                        let source = try await registry.provider(for: location).open(location)
                        _ = try await source.read(0..<(2 << 20), priority: .visible, group: nil)
                    } catch {
                        failure = "\(error)"
                    }
                    operations.append(SchedulerOperation(start: (begin - origin).seconds, milliseconds: (clock.now - begin).milliseconds, error: failure))
                    next += 2
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
        try await Task.sleep(for: .seconds(3))
        let faultStart = (clock.now - origin).seconds
        try ProxyControl.send(mode.rawValue, port: control)
        try await Task.sleep(for: .seconds(seconds))
        try ProxyControl.send("forward", port: control)
        let faultEnd = (clock.now - origin).seconds
        let deadline = clock.now + .seconds(recoveryTimeout)
        while clock.now < deadline {
            let healthy = transitions.values.last.map { $0.state == "healthy" && $0.time > faultEnd } ?? false
            let succeeded = operations.values.contains { $0.error == nil && $0.start > faultEnd }
            if healthy || (succeeded && transitions.values.last?.state == "healthy") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        stop.store(true, ordering: .relaxed)
        for reader in readers { _ = await reader.value }
        healthTask.cancel()
        let all = operations.values
        let during = all.filter { $0.start + $0.milliseconds / 1000 >= faultStart && $0.start <= faultEnd }
        return SchedulerFaultScenario(
            mode: mode,
            durationSeconds: seconds,
            faultStart: faultStart,
            faultEnd: faultEnd,
            baseline: Summary(all.filter { $0.start + $0.milliseconds / 1000 < faultStart && $0.error == nil }.map(\.milliseconds)),
            firstTimeoutAfterStart: all.filter { $0.error == "timeout" }.map { $0.start + $0.milliseconds / 1000 - faultStart }.min(),
            degradedAfterStart: transitions.values.first { $0.state.hasPrefix("degraded") && $0.time > faultStart }.map { $0.time - faultStart },
            healthyAfterEnd: transitions.values.first { $0.state == "healthy" && $0.time > faultEnd }.map { $0.time - faultEnd },
            firstSuccessAfterEnd: all.filter { $0.error == nil && $0.start > faultEnd }.map { $0.start + $0.milliseconds / 1000 - faultEnd }.min(),
            longestDuringFaultMilliseconds: during.map(\.milliseconds).max(),
            errorsDuringFault: errorCounts(during.map(\.error)),
            errorsAfterFault: errorCounts(all.filter { $0.start > faultEnd }.map(\.error)),
            transitions: transitions.values
        )
    }

    private func runExitTest(files: [String]) throws -> SchedulerExitTest {
        guard let executable = Bundle.main.executablePath else { throw ValidationFailure("找不到 mvbench 的可执行文件路径") }
        var test = SchedulerExitTest(delaySeconds: exitDelay)
        let first = try ChildProcess(executable, ["io", "scheduler-hold"] + files.flatMap { ["--file", $0] })
        guard first.readLine(timeout: 30) == "ready" else {
            first.kill()
            throw ValidationFailure("scheduler-hold 子进程 30 秒内没有完成第一次读取")
        }
        try ProxyControl.send("pause", port: control)
        Thread.sleep(forTimeInterval: exitDelay)
        let clock = ContinuousClock()
        let asked = clock.now
        first.send("exit")
        if first.waitForExit(timeout: 30) {
            test.exitMilliseconds = (clock.now - asked).milliseconds
        } else {
            first.kill()
        }
        // 重开：本机卷立即可用；恢复转发后网络卷也可用。
        let relaunched = clock.now
        let second = try ChildProcess(executable, ["io", "scheduler-hold", "--relaunch", "--local-file", localFile] + files.flatMap { ["--file", $0] })
        if let line = second.readLine(timeout: 10), line.hasPrefix("local") {
            test.relaunchLocalMilliseconds = (clock.now - relaunched).milliseconds
        }
        let resumed = clock.now
        try ProxyControl.send("forward", port: control)
        if second.readLine(timeout: recoveryTimeout) == "network" {
            test.relaunchNetworkAfterResumeMilliseconds = (clock.now - resumed).milliseconds
        }
        second.send("exit")
        _ = second.waitForExit(timeout: 10)
        // 卡住的辅助进程在网络恢复后自行退出。辅助进程的命令行只有可执行文件路径。
        Thread.sleep(forTimeInterval: 5)
        test.helpersLeftAfterRecovery = (try? runTool("/usr/bin/pgrep", ["-fx", executable]))?.split(separator: "\n").count ?? 0
        return test
    }
}

/// 退出测试用的子进程：经调度器循环读文件；读到 `exit` 后调用 exit(0)。
/// `--relaunch` 时先读本机文件并打印 `local`，再循环读网络文件直到成功，打印 `network`。
struct SchedulerHoldCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "scheduler-hold", shouldDisplay: false)

    @Option(name: .customLong("file"))
    var files: [String]

    @Option
    var localFile: String?

    @Flag
    var relaunch = false

    func run() async throws {
        let registry = SchedulerBackend.registry(concurrency: 4, chunk: 4 << 20)
        let files = files
        Thread.detachNewThread {
            while let line = Swift.readLine() {
                if line == "exit" { Darwin.exit(0) }
            }
            Darwin.exit(0)
        }
        func read(_ path: String) async throws {
            let location = try await registry.location(for: URL(filePath: path, directoryHint: .notDirectory))
            let source = try await registry.provider(for: location).open(location)
            _ = try await source.read(0..<(2 << 20), priority: .visible, group: nil)
        }
        if relaunch, let localFile {
            try await read(localFile)
            FileHandle.standardOutput.write(Data("local\n".utf8))
            var index = 0
            while (try? await read(files[index % files.count])) == nil {
                index += 1
                try await Task.sleep(for: .milliseconds(200))
            }
            FileHandle.standardOutput.write(Data("network\n".utf8))
        } else {
            let announced = Atomic(false)
            await withTaskGroup(of: Void.self) { group in
                for start in 0..<2 {
                    group.addTask {
                        var index = start
                        while true {
                            if (try? await read(files[index % files.count])) != nil, !announced.exchange(true, ordering: .relaxed) {
                                FileHandle.standardOutput.write(Data("ready\n".utf8))
                            }
                            index += 2
                        }
                    }
                }
            }
        }
        try await Task.sleep(for: .seconds(3600))
    }
}

struct SchedulerFaultResult: Encodable {
    var scenarios: [SchedulerFaultScenario]
    var exitTest: SchedulerExitTest
}

/// 一次读取。start 为相对场景开始的秒数，耗时单位为毫秒。
struct SchedulerOperation: Codable, Sendable {
    var start: Double
    var milliseconds: Double
    var error: String?
}

/// 卷健康状态的一次变化。
struct HealthTransition: Codable, Sendable {
    var time: Double
    var state: String
    var stuck: Int
}

/// 时间单位：秒；耗时：毫秒。
struct SchedulerFaultScenario: Codable {
    var mode: FaultProxy.Mode
    var durationSeconds: Double
    var faultStart: Double
    var faultEnd: Double
    /// 故障前成功读取的耗时。
    var baseline: Summary?
    /// 故障开始到调用方第一次收到 timeout。
    var firstTimeoutAfterStart: Double?
    /// 故障开始到卷变为 degraded。
    var degradedAfterStart: Double?
    /// 故障结束到卷回到 healthy。
    var healthyAfterEnd: Double?
    /// 故障结束到第一次成功读取完成（该读取在故障结束后开始）。
    var firstSuccessAfterEnd: Double?
    /// 与故障时段重叠的读取中最长的耗时。
    var longestDuringFaultMilliseconds: Double?
    var errorsDuringFault: [String: Int]
    var errorsAfterFault: [String: Int]
    var transitions: [HealthTransition]
}

struct SchedulerExitTest: Codable {
    var delaySeconds: Double
    /// 请求退出到进程消失；nil 表示 30 秒内没有消失。
    var exitMilliseconds: Double?
    /// 重开的子进程从启动到读完本机文件。
    var relaunchLocalMilliseconds: Double?
    /// 恢复转发到重开的子进程读完网络文件。
    var relaunchNetworkAfterResumeMilliseconds: Double?
    /// 恢复 5 秒后仍在的辅助进程数。
    var helpersLeftAfterRecovery = 0
    var error: String?
}
