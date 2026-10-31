import ArgumentParser

/// mvbench 的入口。新的子命令登记在 `subcommands` 里。
@main
struct MVBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mvbench",
        abstract: "MacView 的基准测试与夹具生成工具。",
        subcommands: [EnvCommand.self]
    )
}
