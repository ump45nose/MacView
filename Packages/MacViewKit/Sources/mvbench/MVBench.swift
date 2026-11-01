import ArgumentParser
import MVIO

/// mvbench 的入口。作为 MVIO 的辅助进程启动时不解析参数，直接进入请求循环。
@main
enum MVBenchMain {
    static func main() async {
        IOHelper.runIfRequested()
        await MVBench.main()
    }
}

/// 新的子命令登记在 `subcommands` 里。
struct MVBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mvbench",
        abstract: "MacView 的基准测试与夹具生成工具。",
        subcommands: [EnvCommand.self, IOCommand.self, FixturesCommand.self, MediaCommand.self]
    )
}
