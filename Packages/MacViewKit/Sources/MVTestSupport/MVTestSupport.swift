// MVTestSupport：Mock 与夹具加载。职责与契约见 docs/architecture.md §2、§4。
import MVCommands
import MVServices

extension CoreServices {
    /// 用内存目录树和合成图搭建的一套服务，供界面开发与测试使用。各 Mock 共用同一个 MockEnvironment。
    public static func makeMock(_ options: MockOptions = MockOptions()) -> CoreServices {
        let environment = MockEnvironment(options)
        return CoreServices(
            sources: MockSourceRegistry(environment: environment),
            pipeline: MockImagePipeline(environment: environment),
            settings: MockSettingsStore(global: options.settings),
            commands: CommandRegistry(),
            bookshelf: MockBookshelf(environment: environment),
            loader: MockBookLoader(environment: environment)
        )
    }
}
