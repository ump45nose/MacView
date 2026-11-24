import Darwin
import Foundation
import JavaScriptCore
import MVFoundation
import Synchronization

/// 在 JS 线程上管理同步宿主调用等待、停止信号与执行时限。
public final class JSExecutionControl: Sendable {
    public enum TerminationReason: Sendable, Equatable {
        case stopped
        case timedOut
    }

    private final class HostWait: Sendable {
        struct State {
            var result: Result<JSONValue, any Error>?
            var task: Task<Void, Never>?
        }
        let state = Mutex(State())
        let semaphore = DispatchSemaphore(value: 0)

        func complete(_ result: Result<JSONValue, any Error>) {
            let shouldSignal = state.withLock { state in
                guard state.result == nil else { return false }
                state.result = result
                return true
            }
            if shouldSignal { semaphore.signal() }
        }

        func cancel() {
            let task = state.withLock { $0.task }
            task?.cancel()
            complete(.failure(CancellationError()))
        }
    }

    private struct State {
        var stopped = false
        var deadline: ContinuousClock.Instant?
        var terminationReason: TerminationReason?
        var pollInterval: TimeInterval = 0.1
        var wait: HostWait?
    }

    private let state = Mutex(State())

    public init() {}

    public var isStopped: Bool { state.withLock { $0.stopped } }
    public var terminationReason: TerminationReason? { state.withLock { $0.terminationReason } }
    var pollInterval: TimeInterval { state.withLock { $0.pollInterval } }

    public func begin(timeout: Duration? = nil) {
        let deadline = timeout.map { ContinuousClock.now + $0 }
        state.withLock { state in
            state.stopped = false
            state.deadline = deadline
            state.terminationReason = nil
        }
    }

    public func end() {
        state.withLock { state in
            state.deadline = nil
        }
    }

    public func setPollInterval(_ interval: TimeInterval) {
        state.withLock { $0.pollInterval = max(0.01, interval) }
    }

    public func stop() {
        let wait = state.withLock { state -> HostWait? in
            state.stopped = true
            if state.terminationReason == nil { state.terminationReason = .stopped }
            return state.wait
        }
        wait?.cancel()
    }

    func checkShouldTerminate() -> Bool {
        state.withLock { state in
            if state.stopped { return true }
            if let deadline = state.deadline, ContinuousClock.now >= deadline {
                state.stopped = true
                if state.terminationReason == nil { state.terminationReason = .timedOut }
                return true
            }
            return false
        }
    }

    public func syncCall(_ operation: @escaping @Sendable () async throws -> JSONValue) throws -> JSONValue {
        let wait = HostWait()
        let deadline: ContinuousClock.Instant? = try state.withLock { state in
            if state.stopped { throw CancellationError() }
            if let deadline = state.deadline, ContinuousClock.now >= deadline {
                state.stopped = true
                if state.terminationReason == nil { state.terminationReason = .timedOut }
                throw CancellationError()
            }
            state.wait = wait
            return state.deadline
        }
        let task = Task {
            do { wait.complete(.success(try await operation())) }
            catch { wait.complete(.failure(error)) }
        }
        let alreadyCompleted = wait.state.withLock { state in
            state.task = task
            return state.result != nil
        }
        if alreadyCompleted { task.cancel() }

        if let deadline {
            let remaining = deadline - ContinuousClock.now
            let nanos = remaining.components.seconds * 1_000_000_000 + remaining.components.attoseconds / 1_000_000_000
            let dispatchTimeout: DispatchTime = nanos > 0 ? .now() + .nanoseconds(Int(min(nanos, Int64(Int.max)))) : .now()
            if wait.semaphore.wait(timeout: dispatchTimeout) == .timedOut {
                state.withLock { state in
                    state.stopped = true
                    if state.terminationReason == nil { state.terminationReason = .timedOut }
                }
                wait.cancel()
            }
        } else {
            wait.semaphore.wait()
        }

        state.withLock { $0.wait = nil }
        if checkShouldTerminate() { throw CancellationError() }
        return try wait.state.withLock { try $0.result!.get() }
    }
}

/// 供 ScriptRuntime 与 MVPlugins 共用的 JavaScriptCore 桥接工具。
public enum JSBridge {
    private enum BridgeError: LocalizedError {
        case invalidMethod(String)
        var errorDescription: String? {
            switch self {
            case .invalidMethod(let name): "未知宿主方法：\(name)"
            }
        }
    }

    private typealias TerminationCallback = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetTimeLimit = @convention(c) (JSContextGroupRef?, Double, TerminationCallback?, UnsafeMutableRawPointer?) -> Void
    private typealias ClearTimeLimit = @convention(c) (JSContextGroupRef?) -> Void

    private static let setLimit: SetTimeLimit? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit").map {
        unsafeBitCast($0, to: SetTimeLimit.self)
    }
    private static let clearLimit: ClearTimeLimit? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupClearExecutionTimeLimit").map {
        unsafeBitCast($0, to: ClearTimeLimit.self)
    }

    private static let shouldTerminate: TerminationCallback = { context, pointer in
        guard let pointer else { return false }
        let control = Unmanaged<JSExecutionControl>.fromOpaque(pointer).takeUnretainedValue()
        if control.checkShouldTerminate() { return true }
        // 某些 JavaScriptCore 版本在回调返回 false 后不会再次触发，显式重设。
        if let context, let setLimit {
            setLimit(JSContextGetGroup(context), control.pollInterval, shouldTerminate, pointer)
        }
        return false
    }

    public static var supportsExecutionTimeLimit: Bool {
        setLimit != nil && clearLimit != nil
    }

    /// 在上下文所在的 JSContextGroup 上安装执行时限探测。调用方须保证 control 在清除时限前一直存活。
    @discardableResult
    public static func setExecutionTimeLimit(
        on context: JSContext,
        interval: TimeInterval = 0.1,
        control: JSExecutionControl
    ) -> Bool {
        guard let setLimit, clearLimit != nil else { return false }
        control.setPollInterval(interval)
        setLimit(JSContextGetGroup(context.jsGlobalContextRef), control.pollInterval, shouldTerminate, Unmanaged.passUnretained(control).toOpaque())
        return true
    }

    public static func clearExecutionTimeLimit(on context: JSContext) {
        guard let clearLimit else { return }
        clearLimit(JSContextGetGroup(context.jsGlobalContextRef))
    }

    /// 终止后清除异常并重设执行时限，使常驻上下文可继续复用。
    @discardableResult
    public static func resetAfterTermination(
        on context: JSContext,
        interval: TimeInterval = 0.1,
        control: JSExecutionControl
    ) -> Bool {
        context.exception = nil
        clearExecutionTimeLimit(on: context)
        control.begin(timeout: nil)
        return setExecutionTimeLimit(on: context, interval: interval, control: control)
    }

    /// 创建并安装 `mv.*` 同步垫片、`console.*` 以及额外的 `mv.<name>` 方法。
    public static func makeContext(
        call: @escaping @Sendable (ScriptAPI.Method, [JSONValue]) throws -> JSONValue,
        log: @escaping @Sendable (ScriptLogEntry.Level, String) -> Void,
        extraMethods: [String: @Sendable ([JSONValue]) throws -> JSONValue] = [:]
    ) -> JSContext? {
        guard let context = JSContext() else { return nil }
        let bridge: @convention(block) (String, JSValue) -> JSValue = { [weak context] methodName, value in
            guard let context else { return JSValue() }
            do {
                guard let method = ScriptAPI.Method(rawValue: methodName) else {
                    throw BridgeError.invalidMethod(methodName)
                }
                let args: [JSONValue]
                if case let .array(items) = jsonValue(value) { args = items } else { args = [] }
                let result = try call(method, args)
                return jsValue(result, in: context)
            } catch {
                context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: context)
                return JSValue(nullIn: context)
            }
        }
        let logBlock: @convention(block) (String, JSValue) -> Void = { levelName, values in
            let level: ScriptLogEntry.Level = levelName == "warn" ? .warning : (levelName == "error" ? .error : .info)
            let parts = (values.toArray() ?? []).map { String(describing: $0) }
            log(level, parts.joined(separator: " "))
        }
        context.setObject(bridge, forKeyedSubscript: "__mvCall" as NSString)
        context.setObject(logBlock, forKeyedSubscript: "__mvLog" as NSString)
        context.evaluateScript(ScriptAPI.syncShimSource)
        context.evaluateScript("globalThis.console = {}; for (const level of ['log','info','warn','error']) console[level] = (...args) => __mvLog(level, args);")

        if !extraMethods.isEmpty {
            let extraBridge: @convention(block) (String, JSValue) -> JSValue = { [weak context] name, value in
                guard let context else { return JSValue() }
                do {
                    guard let handler = extraMethods[name] else {
                        throw BridgeError.invalidMethod(name)
                    }
                    let args: [JSONValue]
                    if case let .array(items) = jsonValue(value) { args = items } else { args = [] }
                    let result = try handler(args)
                    return jsValue(result, in: context)
                } catch {
                    context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: context)
                    return JSValue(nullIn: context)
                }
            }
            context.setObject(extraBridge, forKeyedSubscript: "__mvExtra" as NSString)
            for name in extraMethods.keys.sorted() {
                if let escaped = try? String(decoding: JSONEncoder().encode(name), as: UTF8.self) {
                    context.evaluateScript("mv[\(escaped)] = (...args) => __mvExtra(\(escaped), args);")
                }
            }
        }
        return context
    }

    public static func jsValue(_ value: JSONValue, in context: JSContext) -> JSValue {
        switch value {
        case .null:
            return JSValue(nullIn: context)
        case .bool(let flag):
            return JSValue(bool: flag, in: context)
        case .number(let number):
            return JSValue(double: number, in: context)
        case .string(let string):
            return JSValue(object: string, in: context)
        case .array(let items):
            let array = JSValue(newArrayIn: context)!
            for (index, item) in items.enumerated() {
                array.setValue(jsValue(item, in: context), at: index)
            }
            return array
        case .object(let dictionary):
            let object = JSValue(newObjectIn: context)!
            for (key, item) in dictionary {
                object.setObject(jsValue(item, in: context), forKeyedSubscript: key as NSString)
            }
            return object
        }
    }

    public static func jsonValue(_ value: JSValue) -> JSONValue {
        convertJSONValue(value, depth: 0)
    }

    private static func convertJSONValue(_ value: JSValue, depth: Int) -> JSONValue {
        guard depth < 64 else { return .null }
        if value.isUndefined || value.isNull { return .null }
        if value.isBoolean { return .bool(value.toBool()) }
        if value.isNumber {
            let number = value.toDouble()
            return number.isFinite ? .number(number) : .null
        }
        if value.isString { return .string(value.toString() ?? "") }
        if value.isArray {
            let count = Int(max(0, value.forProperty("length")?.toInt32() ?? 0))
            var result: [JSONValue] = []
            result.reserveCapacity(count)
            for index in 0..<count {
                if let element = value.atIndex(index) {
                    result.append(convertJSONValue(element, depth: depth + 1))
                } else {
                    result.append(.null)
                }
            }
            return .array(result)
        }
        if value.isObject, let context = value.context, let ctxRef = context.jsGlobalContextRef,
           let objRef = JSValueToObject(ctxRef, value.jsValueRef, nil) {
            let names = JSObjectCopyPropertyNames(ctxRef, objRef)
            defer { JSPropertyNameArrayRelease(names) }
            let count = JSPropertyNameArrayGetCount(names)
            var result: [String: JSONValue] = [:]
            result.reserveCapacity(count)
            for index in 0..<count {
                let nameRef = JSPropertyNameArrayGetNameAtIndex(names, index)
                var buffer = [CChar](repeating: 0, count: JSStringGetMaximumUTF8CStringSize(nameRef))
                let length = JSStringGetUTF8CString(nameRef, &buffer, buffer.count)
                let key = String(decoding: buffer.prefix(max(0, length - 1)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if let property = value.forProperty(key), !property.isUndefined {
                    result[key] = convertJSONValue(property, depth: depth + 1)
                }
            }
            return .object(result)
        }
        return .null
    }

    public static func exceptionProblem(from context: JSContext) -> ScriptProblem? {
        guard let exception = context.exception else { return nil }
        let lineValue = exception.forProperty("line")
        let line = (lineValue?.isNumber == true && lineValue!.toInt32() > 0) ? Int(lineValue!.toInt32()) : nil
        return ScriptProblem(line: line, message: exception.toString() ?? "JavaScript 运行错误")
    }
}
