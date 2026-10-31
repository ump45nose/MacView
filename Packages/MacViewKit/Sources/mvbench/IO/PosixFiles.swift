import Darwin

/// 系统调用失败。结果里按 `调用: 错误描述` 计数。
struct SystemCallError: Error, CustomStringConvertible {
    var call: String
    var code: Int32

    var description: String {
        "\(call): \(String(cString: strerror(code)))"
    }

    static func last(_ call: String) -> SystemCallError {
        SystemCallError(call: call, code: errno)
    }
}

/// 小读各阶段的耗时，单位毫秒。
struct ProbeTiming: Sendable {
    var open: Double
    var read: Double
    var close: Double

    var total: Double {
        open + read + close
    }
}

/// 经由系统挂载路径的文件操作。这些调用会阻塞，只在专用线程上调用。
enum PosixFiles {
    /// 读完整个文件，每次读 buffer.count 字节，返回读到的字节数。
    /// noCache 时设置 F_NOCACHE，数据不进本机的统一缓冲区缓存，重复读取也要走网络。
    static func readWhole(_ path: String, into buffer: UnsafeMutableRawBufferPointer, noCache: Bool) throws(SystemCallError) -> Int64 {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw .last("open") }
        defer { close(fd) }
        if noCache, fcntl(fd, F_NOCACHE, 1) != 0 { throw .last("fcntl") }
        var offset: off_t = 0
        while true {
            let count = pread(fd, buffer.baseAddress, buffer.count, offset)
            if count < 0 {
                if errno == EINTR { continue }
                throw .last("pread")
            }
            if count == 0 { return Int64(offset) }
            offset += off_t(count)
        }
    }

    /// 小读：打开、读开头 buffer.count 字节、关闭，分别计时。
    static func probe(_ path: String, into buffer: UnsafeMutableRawBufferPointer, noCache: Bool) throws(SystemCallError) -> ProbeTiming {
        let clock = ContinuousClock()
        let start = clock.now
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw .last("open") }
        let opened = clock.now
        if noCache { _ = fcntl(fd, F_NOCACHE, 1) }
        var count: Int
        repeat {
            count = pread(fd, buffer.baseAddress, buffer.count, 0)
        } while count < 0 && errno == EINTR
        let readError = count < 0 ? SystemCallError.last("pread") : nil
        let read = clock.now
        close(fd)
        let closed = clock.now
        if let readError { throw readError }
        return ProbeTiming(open: (opened - start).milliseconds, read: (read - opened).milliseconds, close: (closed - read).milliseconds)
    }

    /// 用 readdir 列出名称，再逐项 lstat，返回项数。
    static func listWithReaddir(_ directory: String) throws(SystemCallError) -> Int {
        guard let dir = opendir(directory) else { throw .last("opendir") }
        defer { closedir(dir) }
        let fd = dirfd(dir)
        let nameOffset = MemoryLayout<dirent>.offset(of: \.d_name)!
        var count = 0
        while true {
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 { throw .last("readdir") }
                return count
            }
            let name = UnsafeRawPointer(entry).advanced(by: nameOffset).assumingMemoryBound(to: CChar.self)
            if name[0] == 0x2E, name[1] == 0 || (name[1] == 0x2E && name[2] == 0) { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw .last("fstatat") }
            count += 1
        }
    }

    /// 用 getattrlistbulk 分批取名称、类型、修改时间和大小，返回项数。
    static func listWithBulk(_ directory: String) throws(SystemCallError) -> Int {
        let fd = open(directory, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw .last("open") }
        defer { close(fd) }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
        request.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 << 10, alignment: 16)
        defer { buffer.deallocate() }
        var count = 0
        while true {
            let batch = getattrlistbulk(fd, &request, buffer.baseAddress, buffer.count, 0)
            if batch < 0 {
                if errno == EINTR { continue }
                throw .last("getattrlistbulk")
            }
            if batch == 0 { return count }
            var entry = UnsafeRawPointer(buffer.baseAddress!)
            for _ in 0..<batch {
                let length = entry.loadUnaligned(as: UInt32.self)
                let returned = entry.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    let code = entry.loadUnaligned(fromByteOffset: 4 + MemoryLayout<attribute_set_t>.size, as: UInt32.self)
                    throw SystemCallError(call: "getattrlistbulk 条目", code: Int32(bitPattern: code))
                }
                count += 1
                entry += Int(length)
            }
        }
    }
}
