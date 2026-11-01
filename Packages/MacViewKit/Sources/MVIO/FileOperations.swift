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
}

/// 阻塞的文件操作。只在专用线程或辅助进程中调用，不能在协作线程池上调用。
enum FileOperations {
    static func stat(_ path: String) throws(FileOperationError) -> FileAttributes {
        var info = Darwin.stat()
        guard fstatat(AT_FDCWD, path, &info, 0) == 0 else { throw .system(call: "stat", code: errno) }
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
        if let file = cache.withLock({ $0.files[request.path] }) { return (file, true) }
        let fd = open(request.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw .system(call: "open", code: errno) }
        if request.noCache { _ = fcntl(fd, F_NOCACHE, 1) }
        let file = OpenFile(fd: fd)
        cache.withLock { cache in
            if cache.files.updateValue(file, forKey: request.path) == nil { cache.order.append(request.path) }
            while cache.order.count > capacity {
                cache.files[cache.order.removeFirst()] = nil
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
