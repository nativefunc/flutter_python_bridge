import Flutter
import Foundation

public final class CPythonRuntimePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private let engine = CPRPythonEngine()
    private let pythonQueue = PythonExecutor()
    private let stateLock = NSLock()
    private var registrar: FlutterPluginRegistrar?
    private var eventSink: FlutterEventSink?
    private var pendingEvents: [[String: Any]] = []
    private var initialized = false
    private var initializing = false
    private var disposing = false
    private var workingDirectory = ""
    private var projects: [Int64: String] = [:]
    private var sessions: [Int64: Int64] = [:]
    private var activeJobs: Set<Int64> = []
    private var knownJobs: Set<Int64> = []
    private var cancelledJobs: Set<Int64> = []
    private var timedOutJobs: Set<Int64> = []
    private var timers: [Int64: DispatchWorkItem] = [:]
    private var nextProjectId: Int64 = 1
    private var nextSessionId: Int64 = 1

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = CPythonRuntimePlugin()
        instance.registrar = registrar
        let methods = FlutterMethodChannel(name: "cpython_runtime/methods", binaryMessenger: registrar.messenger())
        let events = FlutterEventChannel(name: "cpython_runtime/events", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methods)
        registrar.publish(instance)
        events.setStreamHandler(instance)
    }

    public override init() {
        super.init()
        engine.eventHandler = { [weak self] event in
            self?.emit(event)
        }
        engine.interruptionHandler = { [weak self] jobId in
            guard let self else { return true }
            self.stateLock.lock()
            defer { self.stateLock.unlock() }
            return self.cancelledJobs.contains(jobId) || self.timedOutJobs.contains(jobId)
        }
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        if !disposing { dispose { _ in } }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        do {
            switch call.method {
            case "initialize":
                try initialize(call, result: result)
            case "loadProject":
                try loadProject(call, result: result)
            case "openSession":
                try openSession(call, result: result)
            case "closeSession":
                try closeSession(call, result: result)
            case "startJob":
                try startJob(call, result: result)
            case "cancelJob":
                try cancelJob(call, result: result)
            case "completeHostCall":
                try completeHostCall(call, result: result)
            case "getRuntimeInfo":
                try runtimeInfo(result)
            case "dispose":
                dispose(result)
            default:
                result(FlutterMethodNotImplemented)
            }
        } catch {
            result(FlutterError(code: "cpython_runtime_error", message: error.localizedDescription, details: String(describing: error)))
        }
    }

    private func initialize(_ call: FlutterMethodCall, result: @escaping FlutterResult) throws {
        if initialized || initializing || disposing {
            throw RuntimeError("PythonRuntime 已经初始化")
        }
        let arguments = dictionary(call.arguments)
        let configuredDirectory = arguments["workingDirectory"] as? String
        let directory: String
        if let configuredDirectory, !configuredDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !configuredDirectory.hasPrefix("/") {
                throw RuntimeError("workingDirectory 必须是绝对路径")
            }
            directory = configuredDirectory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            directory = base.appendingPathComponent("cpython_runtime/workspace", isDirectory: true).path
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
        guard let home = pythonHome(), FileManager.default.fileExists(atPath: home + "/lib/python3.14/os.py") else {
            throw RuntimeError("App 中缺少 Python 标准库，请检查 Python.xcframework 和 Runner 的 install_python 构建阶段")
        }
        workingDirectory = directory
        initializing = true
        pythonQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.engine.initialize(withPythonHome: home)
                DispatchQueue.main.async {
                    self.initializing = false
                    self.initialized = true
                    result(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self.initializing = false
                    result(FlutterError(code: "runtime_initialize_failed", message: error.localizedDescription, details: String(describing: error)))
                }
            }
        }
    }

    private func loadProject(_ call: FlutterMethodCall, result: @escaping FlutterResult) throws {
        try requireInitialized()
        let arguments = dictionary(call.arguments)
        let kind = try requiredString(arguments, "kind")
        let location = try requiredString(arguments, "location")
        let path: String
        switch kind {
        case "directory", "archive":
            path = location
        case "asset":
            guard let registrar else { throw RuntimeError("Flutter registrar 不可用") }
            let assetKey = registrar.lookupKey(forAsset: location)
            let directPath = Bundle.main.bundlePath + "/" + assetKey
            guard let resolved = FileManager.default.fileExists(atPath: directPath) ? directPath : Bundle.main.path(forResource: assetKey, ofType: nil) else {
                throw RuntimeError("找不到 Flutter asset：\(location)")
            }
            path = resolved
        default:
            throw RuntimeError("不支持的 Python 项目来源：\(kind)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw RuntimeError("Python 项目不存在：\(path)")
        }
        if kind == "directory" && !isDirectory.boolValue {
            throw RuntimeError("Python 项目路径不是目录：\(path)")
        }
        if kind != "directory" && isDirectory.boolValue {
            throw RuntimeError("Python 项目归档必须是文件：\(path)")
        }
        let identifier = nextProjectId
        nextProjectId += 1
        projects[identifier] = path
        result(identifier)
    }

    private func openSession(_ call: FlutterMethodCall, result: @escaping FlutterResult) throws {
        try requireInitialized()
        let projectId = try requiredInt64(dictionary(call.arguments), "projectId")
        guard projects[projectId] != nil else { throw RuntimeError("Python project \(projectId) 不存在") }
        let identifier = nextSessionId
        nextSessionId += 1
        sessions[identifier] = projectId
        result(identifier)
    }

    private func closeSession(_ call: FlutterMethodCall, result: @escaping FlutterResult) throws {
        let identifier = try requiredInt64(dictionary(call.arguments), "sessionId")
        sessions.removeValue(forKey: identifier)
        pythonQueue.async { [weak self] in
            self?.engine.destroySession(identifier)
            DispatchQueue.main.async { result(nil) }
        }
    }

    private func startJob(_ call: FlutterMethodCall, result: @escaping FlutterResult) throws {
        try requireInitialized()
        let request = dictionary(call.arguments)
        let jobId = try requiredInt64(request, "jobId")
        let sessionId = int64(request["sessionId"]) ?? 0
        if sessionId != 0 && sessions[sessionId] == nil {
            throw RuntimeError("Python session \(sessionId) 不存在")
        }
        let projectId = int64(request["projectId"])
        let projectPath = projectId.flatMap { projects[$0] }
        if projectId != nil && projectPath == nil {
            throw RuntimeError("Python project \(projectId!) 不存在")
        }
        let directory = (request["workingDirectory"] as? String) ?? workingDirectory
        var isDirectory: ObjCBool = false
        guard directory.hasPrefix("/"), FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RuntimeError("workingDirectory 必须是已存在的绝对目录：\(directory)")
        }
        let prepared = try prepareSource(request, projectPath: projectPath)
        let arguments = (request["arguments"] as? [String]) ?? []
        let timeout = int64(request["timeoutMs"]) ?? 30_000
        stateLock.lock()
        if knownJobs.contains(jobId) {
            stateLock.unlock()
            throw RuntimeError("Python job \(jobId) 已存在")
        }
        knownJobs.insert(jobId)
        stateLock.unlock()
        emit(["kind": "state", "jobId": jobId, "state": "queued"])
        pythonQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let cancelledBeforeStart = self.cancelledJobs.contains(jobId)
            if !cancelledBeforeStart { self.activeJobs.insert(jobId) }
            self.stateLock.unlock()
            if cancelledBeforeStart {
                self.stateLock.lock()
                self.cancelledJobs.remove(jobId)
                self.knownJobs.remove(jobId)
                self.stateLock.unlock()
                self.emit(["kind": "state", "jobId": jobId, "state": "cancelled"])
                self.finish(jobId, response: self.controlResult(state: "cancelled", type: "PythonCancelledError", message: "Python 任务已取消"), flutterResult: result)
                return
            }
            self.emit(["kind": "state", "jobId": jobId, "state": "running"])
            if timeout > 0 {
                let timer = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.stateLock.lock()
                    let active = self.activeJobs.contains(jobId)
                    if active { self.timedOutJobs.insert(jobId) }
                    self.stateLock.unlock()
                    if active { self.engine.interruptJob(jobId) }
                }
                self.stateLock.lock()
                self.timers[jobId] = timer
                self.stateLock.unlock()
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(Int(timeout)), execute: timer)
            }
            var response = self.engine.executeJob(
                jobId,
                sessionId: sessionId,
                evaluate: prepared.evaluate,
                source: prepared.source,
                filename: prepared.filename,
                arguments: arguments,
                workingDirectory: directory,
                projectPath: projectPath
            )
            self.stateLock.lock()
            let timedOut = self.timedOutJobs.remove(jobId) != nil
            let cancelled = self.cancelledJobs.remove(jobId) != nil
            self.activeJobs.remove(jobId)
            self.knownJobs.remove(jobId)
            let timer = self.timers.removeValue(forKey: jobId)
            self.stateLock.unlock()
            timer?.cancel()
            let state: String
            if timedOut {
                response["exitCode"] = 124
                response["state"] = "timedOut"
                response["exceptionType"] = "PythonTimeoutError"
                response["exceptionMessage"] = "Python 任务超时"
                response["traceback"] = ""
                state = "timedOut"
            } else if cancelled {
                response["exitCode"] = 130
                response["state"] = "cancelled"
                response["exceptionType"] = "PythonCancelledError"
                response["exceptionMessage"] = "Python 任务已取消"
                response["traceback"] = ""
                state = "cancelled"
            } else if (response["exitCode"] as? NSNumber)?.intValue == 0 {
                state = "completed"
                response["state"] = state
            } else {
                state = "failed"
                response["state"] = state
            }
            self.emit(["kind": "state", "jobId": jobId, "state": state])
            self.finish(jobId, response: response, flutterResult: result)
        }
    }

    private func cancelJob(_ call: FlutterMethodCall, result: @escaping FlutterResult) throws {
        let jobId = try requiredInt64(dictionary(call.arguments), "jobId")
        stateLock.lock()
        guard knownJobs.contains(jobId) else {
            stateLock.unlock()
            throw RuntimeError("Python job \(jobId) 不存在或已经结束")
        }
        cancelledJobs.insert(jobId)
        let active = activeJobs.contains(jobId)
        stateLock.unlock()
        if active {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.engine.interruptJob(jobId) }
        }
        result(nil)
    }

    private func completeHostCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) throws {
        let arguments = dictionary(call.arguments)
        let callId = try requiredInt64(arguments, "callId")
        engine.completeHostCall(callId, resultJson: arguments["resultJson"] as? String, error: arguments["error"] as? String)
        result(nil)
    }

    private func runtimeInfo(_ result: @escaping FlutterResult) throws {
        try requireInitialized()
        pythonQueue.async { [weak self] in
            guard let self else { return }
            var info = self.engine.runtimeInfo()
            info["workingDirectory"] = self.workingDirectory
            DispatchQueue.main.async { result(info) }
        }
    }

    private func dispose(_ result: @escaping FlutterResult) {
        if disposing {
            result(FlutterError(code: "runtime_disposing", message: "PythonRuntime 正在释放", details: nil))
            return
        }
        disposing = true
        stateLock.lock()
        let jobs = activeJobs
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        cancelledJobs.formUnion(knownJobs)
        stateLock.unlock()
        for job in jobs {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.engine.interruptJob(job) }
        }
        projects.removeAll()
        sessions.removeAll()
        initialized = false
        pythonQueue.async {
            self.engine.dispose()
            DispatchQueue.main.async {
                self.initialized = false
                self.initializing = false
                self.disposing = false
                self.pendingEvents.removeAll()
                result(nil)
            }
        }
    }

    private func prepareSource(_ request: [String: Any], projectPath: String?) throws -> PreparedSource {
        let mode = (request["mode"] as? String) ?? "exec"
        if mode == "call" {
            guard let entrypoint = request["entrypoint"] as? String else { throw RuntimeError("call 模式必须提供 entrypoint") }
            guard let separator = entrypoint.lastIndex(of: ":"), separator != entrypoint.startIndex, separator < entrypoint.index(before: entrypoint.endIndex) else {
                throw RuntimeError("entrypoint 必须使用 module.path:function 格式")
            }
            guard projectPath != nil else { throw RuntimeError("call 模式必须指定 Python project") }
            let module = String(entrypoint[..<separator])
            let function = String(entrypoint[entrypoint.index(after: separator)...])
            let modulePattern = try NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_.]*$")
            let functionPattern = try NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_]*$")
            guard modulePattern.firstMatch(in: module, range: NSRange(module.startIndex..., in: module)) != nil else { throw RuntimeError("模块名无效") }
            guard functionPattern.firstMatch(in: function, range: NSRange(function.startIndex..., in: function)) != nil else { throw RuntimeError("函数名无效") }
            let positional = (request["argumentsJson"] as? String) ?? "[]"
            let named = (request["namedArgumentsJson"] as? String) ?? "{}"
            let source = "getattr(__import__('importlib').import_module(\(try quote(module))), \(try quote(function)))(*__import__('json').loads(\(try quote(positional))), **__import__('json').loads(\(try quote(named))))"
            return PreparedSource(source: source, evaluate: true, filename: "<\(entrypoint)>")
        }
        let original = (request["source"] as? String) ?? ""
        let filename = (request["filename"] as? String) ?? (mode == "eval" ? "<python-eval>" : "<python>")
        return PreparedSource(source: original, evaluate: mode == "eval", filename: filename)
    }

    private func quote(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value])
        let encoded = String(decoding: data, as: UTF8.self)
        return String(encoded.dropFirst().dropLast())
    }

    private func pythonHome() -> String? {
        let bundles = [Bundle.main, Bundle(for: CPythonRuntimePlugin.self)]
        for bundle in bundles {
            if let path = bundle.path(forResource: "python", ofType: nil) { return path }
            if let resourcePath = bundle.resourcePath {
                let path = resourcePath + "/python"
                if FileManager.default.fileExists(atPath: path) { return path }
            }
        }
        return nil
    }

    private func controlResult(state: String, type: String, message: String) -> [String: Any] {
        ["exitCode": state == "timedOut" ? 124 : 130, "stdout": "", "stderr": "", "state": state, "exceptionType": type, "exceptionMessage": message, "traceback": ""]
    }

    private func finish(_ jobId: Int64, response: [String: Any], flutterResult: @escaping FlutterResult) {
        var result = response
        if let data = result["binaryValue"] as? Data {
            result["binaryValue"] = FlutterStandardTypedData(bytes: data)
        }
        DispatchQueue.main.async { flutterResult(result) }
    }

    private func emit(_ event: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.initialized, !self.disposing else { return }
            if let eventSink {
                eventSink(event)
            } else {
                pendingEvents.append(event)
            }
        }
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        for event in pendingEvents { events(event) }
        pendingEvents.removeAll()
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    private func dictionary(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private func requiredString(_ values: [String: Any], _ key: String) throws -> String {
        guard let value = values[key] as? String else { throw RuntimeError("\(key) 必须是 String") }
        return value
    }

    private func requiredInt64(_ values: [String: Any], _ key: String) throws -> Int64 {
        guard let value = int64(values[key]) else { throw RuntimeError("\(key) 必须是数字") }
        return value
    }

    private func int64(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    private func requireInitialized() throws {
        if !initialized || disposing { throw RuntimeError("PythonRuntime 尚未初始化") }
    }
}

private struct PreparedSource {
    let source: String
    let evaluate: Bool
    let filename: String
}

private struct RuntimeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class PythonExecutor {
    private final class State {
        let condition = NSCondition()
        var tasks: [() -> Void] = []
        var stopped = false
    }

    private let state: State
    private let thread: Thread

    init() {
        let state = State()
        self.state = state
        thread = Thread {
            while true {
                state.condition.lock()
                while state.tasks.isEmpty && !state.stopped { state.condition.wait() }
                if state.tasks.isEmpty && state.stopped {
                    state.condition.unlock()
                    return
                }
                let task = state.tasks.removeFirst()
                state.condition.unlock()
                autoreleasepool { task() }
            }
        }
        thread.name = "dev.cpythonruntime.python"
        thread.start()
    }

    func async(_ task: @escaping () -> Void) {
        state.condition.lock()
        precondition(!state.stopped)
        state.tasks.append(task)
        state.condition.signal()
        state.condition.unlock()
    }

    deinit {
        state.condition.lock()
        state.stopped = true
        state.condition.signal()
        state.condition.unlock()
    }
}
