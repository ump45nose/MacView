import Darwin

/// libsmb2 的错误。
struct SMB2Error: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

/// 运行时用 dlopen 加载的 libsmb2（LGPL-2.1，只能动态链接）。
/// 只含 dlsym 得到的 C 函数指针，加载后不再改变，可以在线程间共享。
struct LibSMB2: @unchecked Sendable {
    typealias Callback = @convention(c) (OpaquePointer?, Int32, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

    let initContext: @convention(c) () -> OpaquePointer?
    let destroyContext: @convention(c) (OpaquePointer?) -> Void
    let setUser: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void
    let setPassword: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void
    let setSecurityMode: @convention(c) (OpaquePointer?, UInt16) -> Void
    let setTimeout: @convention(c) (OpaquePointer?, Int32) -> Void
    let connectShare: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    let disconnectShare: @convention(c) (OpaquePointer?) -> Int32
    let getError: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    let getFD: @convention(c) (OpaquePointer?) -> Int32
    let whichEvents: @convention(c) (OpaquePointer?) -> Int32
    let service: @convention(c) (OpaquePointer?, Int32) -> Int32
    let maxReadSize: @convention(c) (OpaquePointer?) -> UInt32
    let openAsync: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, Callback?, UnsafeMutableRawPointer?) -> Int32
    let closeAsync: @convention(c) (OpaquePointer?, OpaquePointer?, Callback?, UnsafeMutableRawPointer?) -> Int32
    let preadAsync: @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<UInt8>?, UInt32, UInt64, Callback?, UnsafeMutableRawPointer?) -> Int32
    let opendir: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> OpaquePointer?
    let readdir: @convention(c) (OpaquePointer?, OpaquePointer?) -> UnsafeRawPointer?
    let closedir: @convention(c) (OpaquePointer?, OpaquePointer?) -> Void

    init(path: String) throws(SMB2Error) {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw SMB2Error("无法加载 libsmb2（\(path)）：\(String(cString: dlerror()))；先运行 scripts/build-libsmb2.sh")
        }
        initContext = try Self.symbol(handle, "smb2_init_context")
        destroyContext = try Self.symbol(handle, "smb2_destroy_context")
        setUser = try Self.symbol(handle, "smb2_set_user")
        setPassword = try Self.symbol(handle, "smb2_set_password")
        setSecurityMode = try Self.symbol(handle, "smb2_set_security_mode")
        setTimeout = try Self.symbol(handle, "smb2_set_timeout")
        connectShare = try Self.symbol(handle, "smb2_connect_share")
        disconnectShare = try Self.symbol(handle, "smb2_disconnect_share")
        getError = try Self.symbol(handle, "smb2_get_error")
        getFD = try Self.symbol(handle, "smb2_get_fd")
        whichEvents = try Self.symbol(handle, "smb2_which_events")
        service = try Self.symbol(handle, "smb2_service")
        maxReadSize = try Self.symbol(handle, "smb2_get_max_read_size")
        openAsync = try Self.symbol(handle, "smb2_open_async")
        closeAsync = try Self.symbol(handle, "smb2_close_async")
        preadAsync = try Self.symbol(handle, "smb2_pread_async")
        opendir = try Self.symbol(handle, "smb2_opendir")
        readdir = try Self.symbol(handle, "smb2_readdir")
        closedir = try Self.symbol(handle, "smb2_closedir")
    }

    private static func symbol<Function>(_ handle: UnsafeMutableRawPointer, _ name: String) throws(SMB2Error) -> Function {
        guard let address = dlsym(handle, name) else { throw SMB2Error("libsmb2 缺少符号 \(name)") }
        return unsafeBitCast(address, to: Function.self)
    }
}

/// `struct smb2dirent` 的字段：开头是 name 指针，随后是 `struct smb2_stat_64`。
enum SMB2DirectoryEntry {
    static let typeOffset = 8
    static let sizeOffset = 24
    static let fileType: UInt32 = 0

    static func name(_ entry: UnsafeRawPointer) -> String {
        String(cString: entry.load(as: UnsafePointer<CChar>.self))
    }
}

/// 一个 libsmb2 会话。只在创建它的线程上使用；异步命令的回调在 `run(until:)` 里执行。
final class SMB2Session {
    let library: LibSMB2
    let context: OpaquePointer

    private init(library: LibSMB2, context: OpaquePointer) {
        self.library = library
        self.context = context
    }

    deinit {
        _ = library.disconnectShare(context)
        library.destroyContext(context)
    }

    static func connect(_ library: LibSMB2, share: SMBShare, credentials: SMBCredentials, timeout: Int32) throws(SMB2Error) -> SMB2Session {
        guard let context = library.initContext() else { throw SMB2Error("smb2_init_context 失败") }
        // 声明支持签名；服务端要求签名时 libsmb2 会对请求签名。
        library.setSecurityMode(context, 0x0001)
        library.setUser(context, credentials.user)
        library.setPassword(context, credentials.password)
        library.setTimeout(context, timeout)
        guard library.connectShare(context, share.server, share.share, credentials.user) == 0 else {
            let message = library.getError(context).map { String(cString: $0) } ?? "未知错误"
            library.destroyContext(context)
            throw SMB2Error("连接 \(share.server)/\(share.share) 失败：\(message)")
        }
        return SMB2Session(library: library, context: context)
    }

    var lastError: String {
        library.getError(context).map { String(cString: $0) } ?? "未知错误"
    }

    /// 服务器允许的单次读取上限。
    var maxReadSize: Int {
        Int(library.maxReadSize(context))
    }

    static func describe(_ status: Int32) -> String {
        String(cString: strerror(-status))
    }

    /// 处理网络事件，直到 done() 为真。设置了命令超时时，libsmb2 要求至少每秒调用一次 smb2_service。
    func run(until done: () -> Bool) throws(SMB2Error) {
        while !done() {
            var descriptor = pollfd(fd: library.getFD(context), events: Int16(truncatingIfNeeded: library.whichEvents(context)), revents: 0)
            if poll(&descriptor, 1, 1000) < 0, errno != EINTR {
                throw SMB2Error("poll：\(String(cString: strerror(errno)))")
            }
            if library.service(context, Int32(descriptor.revents)) < 0 {
                throw SMB2Error("smb2_service：\(lastError)")
            }
        }
    }

    /// 发出一个异步命令。返回 false 表示命令没有发出，completion 不会被调用，原因见 lastError。
    func submit(
        _ issue: (LibSMB2.Callback, UnsafeMutableRawPointer) -> Int32,
        completion: @escaping (Int32, UnsafeMutableRawPointer?) -> Void
    ) -> Bool {
        let box = Unmanaged.passRetained(Completion(completion)).toOpaque()
        let status = issue({ _, status, data, box in
            guard let box else { return }
            Unmanaged<Completion>.fromOpaque(box).takeRetainedValue().handler(status, data)
        }, box)
        guard status >= 0 else {
            Unmanaged<Completion>.fromOpaque(box).release()
            return false
        }
        return true
    }

    /// 异步命令完成后要执行的代码，作为 cb_data 交给 libsmb2，回调时取回并释放。
    private final class Completion {
        let handler: (Int32, UnsafeMutableRawPointer?) -> Void

        init(_ handler: @escaping (Int32, UnsafeMutableRawPointer?) -> Void) {
            self.handler = handler
        }
    }
}
