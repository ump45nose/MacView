import Darwin
import Foundation
import Synchronization

/// 文件系统返回的一项的属性。
struct FileAttributes: Sendable, Equatable {
    enum FileType: UInt8, Sendable {
        case regular, directory, symbolicLink, other
    }

    var name: String
    var type: FileType
    var size: Int64
    var modificationNanos: Int64
    var creationNanos: Int64?
}

/// 文件操作的失败。在进程内和辅助进程之间原样传递，由调用方换成 `IOError`。
enum FileOperationError: Error, Sendable, Equatable {
    /// 系统调用失败，附 errno。
    case system(call: String, code: Int32)
    /// 文件的大小或修改时间与打开时的身份不一致。
    case changed
    /// 辅助进程退出或被弃用，请求没有结果。
    case helperLost

    var isNotFound: Bool {
        if case let .system(_, code) = self { return code == ENOENT || code == ENOTDIR }
        return false
    }
}

/// 一次按范围读取的参数。
struct ReadRequest: Sendable, Equatable {
    var path: String
    var offset: Int64
    var length: Int
    /// 打开时期望的大小与修改时间；不一致时报 `changed`。
    var expectedSize: Int64?
    var expectedModificationNanos: Int64?
    /// 设置 F_NOCACHE，数据不进统一缓冲区缓存。原始字节由 L0 缓存，不必在系统里再存一份。
    var noCache: Bool
    /// 读失败时关掉文件重新打开再读一次。网络卷断开较久后恢复时，故障中的那次读会返回错误。
    var retryByReopening: Bool
    var freshDescriptor: Bool = false
}

/// 阻塞的文件操作。只在专用线程或辅助进程中调用，不能在协作线程池上调用。
enum FileOperations {
    /// 所有写入都在一个后端请求中完成，不对失败的写调用重试。
    static func execute(_ request: HelperRequest, configureNoCache: (Int32) -> Int32 = { fd in
        fcntl(fd, F_NOCACHE, 1) == -1 ? errno : 0
    }) throws(FileOperationError) -> String? {
        switch request {
        case let .create(path):
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o644))
            guard fd >= 0 else { throw .system(call: "open", code: errno) }
            defer { close(fd) }
            try requireNoCache(fd, configure: configureNoCache)
        case let .write(path, offset, data):
            let fd = open(path, O_WRONLY | O_CLOEXEC)
            guard fd >= 0 else { throw .system(call: "open", code: errno) }
            defer { close(fd) }
            try requireNoCache(fd, configure: configureNoCache)
            try data.withUnsafeBytes { (buffer) throws(FileOperationError) in
                var written = 0
                while written < buffer.count {
                    let count = pwrite(fd, buffer.baseAddress! + written, buffer.count - written, off_t(offset) + off_t(written))
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw .system(call: "pwrite", code: errno)
                    }
                    guard count > 0 else { throw .system(call: "pwrite", code: EIO) }
                    written += count
                }
            }
        case let .finish(path, modification):
            let fd = open(path, O_WRONLY | O_CLOEXEC)
            guard fd >= 0 else { throw .system(call: "open", code: errno) }
            defer { close(fd) }
            try requireNoCache(fd, configure: configureNoCache)
            guard fsync(fd) == 0 else { throw .system(call: "fsync", code: errno) }
            if let modification {
                let seconds = modification / 1_000_000_000
                let remainder = modification % 1_000_000_000
                var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: Int(seconds - (remainder < 0 ? 1 : 0)), tv_nsec: Int(remainder < 0 ? remainder + 1_000_000_000 : remainder))]
                guard futimens(fd, &times) == 0 else { throw .system(call: "futimens", code: errno) }
            }
        case let .rename(source, target, exclusive):
            let status = renamex_np(source, target, exclusive ? UInt32(RENAME_EXCL) : 0)
            if status != 0 {
                let code = errno
                // NFS 不支持排他改名时，内核已先检查目标不存在；普通改名与检查之间的竞态可接受。
                if exclusive && (code == ENOTSUP || code == EINVAL) {
                    guard Darwin.rename(source, target) == 0 else { throw .system(call: "rename", code: errno) }
                } else { throw .system(call: "rename", code: code) }
            }
        case let .makeDirectory(path):
            guard mkdir(path, mode_t(0o755)) == 0 else { throw .system(call: "mkdir", code: errno) }
        case let .remove(path):
            var info = Darwin.stat()
            guard lstat(path, &info) == 0 else { throw .system(call: "lstat", code: errno) }
            let isDirectory = info.st_mode & S_IFMT == S_IFDIR
            guard (isDirectory ? rmdir(path) : unlink(path)) == 0 else { throw .system(call: isDirectory ? "rmdir" : "unlink", code: errno) }
        case let .trash(path):
            var result: NSURL?
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
            } catch {
                let nsError = error as NSError
                let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
                let posix = nsError.domain == NSPOSIXErrorDomain ? nsError : underlying
                if let posix, posix.domain == NSPOSIXErrorDomain { throw .system(call: "trash", code: Int32(posix.code)) }
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError { throw .system(call: "trash", code: ENOENT) }
                throw .system(call: "trash", code: EIO)
            }
            guard let result else { throw .system(call: "trash", code: EIO) }
            return result.path
        default:
            throw .system(call: "invalid write request", code: EINVAL)
        }
        return nil
    }

    private static func requireNoCache(_ fd: Int32, configure: (Int32) -> Int32) throws(FileOperationError) {
        let error = configure(fd)
        guard error == 0 else { throw .system(call: "fcntl(F_NOCACHE)", code: error) }
    }

    static func stat(_ path: String, followLinks: Bool = true) throws(FileOperationError) -> FileAttributes {
        var info = Darwin.stat()
        guard fstatat(AT_FDCWD, path, &info, followLinks ? 0 : AT_SYMLINK_NOFOLLOW) == 0 else { throw .system(call: "stat", code: errno) }
        let name = path.split(separator: "/").last.map(String.init) ?? ""
        return attributes(name: name, info)
    }

    /// 卷的健康探测：在挂载点下查找一个随机的、不存在的名字，返回 ENOENT 即卷可用。
    /// 新名字不在任何缓存里，查找必须问服务器。stat 挂载点由属性缓存回答；statfs 在 NFS 上约 10 秒后
    /// 返回缓存的值并报成功。两者在服务器不可达时都会成功，不能用来探测（S1-T1 实测）。
    static func probe(_ mountPoint: String) throws(FileOperationError) {
        var info = Darwin.stat()
        let name = mountPoint + "/.macview-probe-" + UUID().uuidString
        if fstatat(AT_FDCWD, name, &info, AT_SYMLINK_NOFOLLOW) != 0, errno != ENOENT {
            throw .system(call: "stat", code: errno)
        }
    }

    /// 用 getattrlistbulk 分批列出目录的直接子项（不含 `.` 和 `..`）。`batch` 返回 false 时停止。
    static func list(_ path: String, batch: ([FileAttributes]) -> Bool) throws(FileOperationError) {
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw .system(call: "open", code: errno) }
        defer { close(fd) }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_CRTIME) | attrgroup_t(ATTR_CMN_MODTIME)
        request.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 << 10, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = getattrlistbulk(fd, &request, buffer.baseAddress, buffer.count, 0)
            if count < 0 {
                if errno == EINTR { continue }
                throw .system(call: "getattrlistbulk", code: errno)
            }
            if count == 0 { return }
            var entries: [FileAttributes] = []
            entries.reserveCapacity(Int(count))
            var record = UnsafeRawPointer(buffer.baseAddress!)
            for _ in 0..<count {
                if let entry = try parse(record) { entries.append(entry) }
                record += Int(record.loadUnaligned(as: UInt32.self))
            }
            guard batch(entries) else { return }
        }
    }

    /// 解析 getattrlistbulk 的一条记录。字段按属性位的顺序排列，只有 returned 中置位的才出现。
    private static func parse(_ record: UnsafeRawPointer) throws(FileOperationError) -> FileAttributes? {
        let returned = record.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
        var field = record + 4 + MemoryLayout<attribute_set_t>.size
        if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            let code = field.loadUnaligned(as: UInt32.self)
            if code != 0 { throw .system(call: "getattrlistbulk", code: Int32(bitPattern: code)) }
            field += 4
        }
        guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { return nil }
        let reference = field.loadUnaligned(as: attrreference_t.self)
        let name = String(cString: (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
        field += MemoryLayout<attrreference_t>.size
        var type = FileAttributes.FileType.other
        if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            switch Int(field.loadUnaligned(as: fsobj_type_t.self)) {
            case Int(VREG.rawValue): type = .regular
            case Int(VDIR.rawValue): type = .directory
            case Int(VLNK.rawValue): type = .symbolicLink
            default: type = .other
            }
            field += MemoryLayout<fsobj_type_t>.size
        }
        var creation: Int64?
        if returned.commonattr & attrgroup_t(ATTR_CMN_CRTIME) != 0 {
            creation = nanoseconds(field.loadUnaligned(as: timespec.self))
            field += MemoryLayout<timespec>.size
        }
        var modification: Int64 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            modification = nanoseconds(field.loadUnaligned(as: timespec.self))
            field += MemoryLayout<timespec>.size
        }
        var size: Int64 = 0
        if returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
            size = Int64(field.loadUnaligned(as: off_t.self))
        }
        return FileAttributes(name: name, type: type, size: size, modificationNanos: modification, creationNanos: creation)
    }

    static func attributes(name: String, _ info: Darwin.stat) -> FileAttributes {
        let type: FileAttributes.FileType = switch info.st_mode & S_IFMT {
        case S_IFREG: .regular
        case S_IFDIR: .directory
        case S_IFLNK: .symbolicLink
        default: .other
        }
        return FileAttributes(
            name: name,
            type: type,
            size: Int64(info.st_size),
            modificationNanos: nanoseconds(info.st_mtimespec),
            creationNanos: nanoseconds(info.st_birthtimespec)
        )
    }

    static func nanoseconds(_ time: timespec) -> Int64 {
        Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
    }
}

/// 按范围读文件，打开的文件描述符按路径缓存复用，避免每读一块都在网络卷上重新打开。
final class FileReader: Sendable {
    /// 打开的文件。最后一个引用释放时关闭，所以正在读的文件不会被淘汰关掉。
    private final class OpenFile: Sendable {
        let fd: Int32

        init(fd: Int32) {
            self.fd = fd
        }

        deinit {
            close(fd)
        }
    }

    private struct Cache {
        var files: [String: OpenFile] = [:]
        var order: [String] = []
        var generation: UInt64 = 0
        var mutations: [String: Int] = [:]
    }

    private let capacity: Int
    private let cache = Mutex(Cache())

    init(capacity: Int = 32) {
        self.capacity = capacity
    }

    func read(_ request: ReadRequest) throws(FileOperationError) -> Data {
        do {
            return try readOnce(request)
        } catch .system where request.retryByReopening {
            forget(request.path)
            return try readOnce(request)
        }
    }

    /// 改名或删除前释放源路径及其后代的缓存引用，修改完成前不重新缓存；读取本身照常进行。
    func withInvalidatedCache<T>(for request: HelperRequest, operation: () throws(FileOperationError) -> T) throws(FileOperationError) -> T {
        let path: String
        switch request {
        case let .rename(source, _, _): path = source
        case let .remove(source), let .trash(source): path = source
        default: return try operation()
        }
        cache.withLock { cache in
            cache.generation &+= 1
            cache.mutations[path, default: 0] += 1
            let paths = cache.order.filter { Self.includes($0, under: path) }
            for path in paths { cache.files[path] = nil }
            cache.order.removeAll { Self.includes($0, under: path) }
        }
        defer {
            cache.withLock { cache in
                cache.generation &+= 1
                if cache.mutations[path] == 1 { cache.mutations[path] = nil }
                else { cache.mutations[path, default: 0] -= 1 }
            }
        }
        return try operation()
    }

    private static func includes(_ path: String, under ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }

    private func readOnce(_ request: ReadRequest) throws(FileOperationError) -> Data {
        var (file, cached) = try openFile(request)
        // 缓存中的描述符可能指向已被替换的旧文件，校验不过时重新打开一次。
        if cached, (try? validate(file, request)) == nil {
            forget(request.path)
            (file, cached) = try openFile(request)
        }
        try validate(file, request)
        var data = Data(count: request.length)
        let read = try data.withUnsafeMutableBytes { (buffer) throws(FileOperationError) -> Int in
            var done = 0
            while done < buffer.count {
                let count = pread(file.fd, buffer.baseAddress! + done, buffer.count - done, off_t(request.offset) + off_t(done))
                if count < 0 {
                    if errno == EINTR { continue }
                    throw .system(call: "pread", code: errno)
                }
                if count == 0 { break }
                done += count
            }
            return done
        }
        if read < data.count { data.removeSubrange(read...) }
        return data
    }

    private func validate(_ file: OpenFile, _ request: ReadRequest) throws(FileOperationError) {
        guard request.expectedSize != nil || request.expectedModificationNanos != nil else { return }
        var info = Darwin.stat()
        guard fstat(file.fd, &info) == 0 else { throw .system(call: "fstat", code: errno) }
        if let size = request.expectedSize, Int64(info.st_size) != size { throw .changed }
        if let modification = request.expectedModificationNanos, FileOperations.nanoseconds(info.st_mtimespec) != modification { throw .changed }
    }

    private func openFile(_ request: ReadRequest) throws(FileOperationError) -> (OpenFile, cached: Bool) {
        let (cached, generation) = cache.withLock { (request.freshDescriptor ? nil : $0.files[request.path], $0.generation) }
        if let cached { return (cached, true) }
        let fd = open(request.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw .system(call: "open", code: errno) }
        if request.noCache && fcntl(fd, F_NOCACHE, 1) == -1 && request.freshDescriptor {
            let code = errno
            close(fd)
            throw .system(call: "fcntl(F_NOCACHE)", code: code)
        }
        let file = OpenFile(fd: fd)
        if !request.freshDescriptor { cache.withLock { cache in
            // 修改窗口内的读取，以及打开期间跨过修改边界的读取，结束后直接关闭描述符。
            guard cache.generation == generation,
                  !cache.mutations.keys.contains(where: { Self.includes(request.path, under: $0) }) else { return }
            if cache.files.updateValue(file, forKey: request.path) == nil { cache.order.append(request.path) }
            while cache.order.count > capacity {
                cache.files[cache.order.removeFirst()] = nil
            }
        }
        }
        return (file, false)
    }

    private func forget(_ path: String) {
        cache.withLock { cache in
            if cache.files.removeValue(forKey: path) != nil { cache.order.removeAll { $0 == path } }
        }
    }
}
