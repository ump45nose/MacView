// MVServices：组合根，创建并连接各服务，负责启动、退出和内存压力处理。职责与契约见 docs/architecture.md §2、§4。
import MVCommands
import MVIO
import MVPipeline
import MVReading
import MVSettings

/// 前端使用的全部服务。真实服务的组装（`make(configuration:)`）在 S1-T8 加入；目前由 MVTestSupport 的 `makeMock` 创建。
@MainActor public final class CoreServices {
    public let sources: any SourceRegistry
    public let pipeline: any ImagePipeline
    public let settings: any SettingsStore
    public let commands: CommandRegistry
    public let bookshelf: any Bookshelf
    private let loader: any BookLoader

    public init(
        sources: any SourceRegistry, pipeline: any ImagePipeline, settings: any SettingsStore,
        commands: CommandRegistry, bookshelf: any Bookshelf, loader: any BookLoader
    ) {
        self.sources = sources
        self.pipeline = pipeline
        self.settings = settings
        self.commands = commands
        self.bookshelf = bookshelf
        self.loader = loader
    }

    public func makeSession() -> ReaderSession {
        ReaderSession(loader: loader, settings: settings, bookshelf: bookshelf, pipeline: pipeline)
    }

    /// 退出前调用。接入真实服务后在这里落盘设置并取消 I/O，有时限地等待，不等被卡住的 I/O 线程；Mock 没有要收尾的工作。
    public func shutdown() async {}
}
