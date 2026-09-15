library flutter_python_bridge;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

enum PythonProjectSourceKind { directory, archive, asset }
enum PythonExecutionMode { exec, eval, call }
enum PythonStream { stdout, stderr }
enum PythonJobState { queued, running, completed, failed, cancelled, timedOut, killed, workerCrashed }

class PythonRuntimeOptions {
  const PythonRuntimeOptions({
    this.workingDirectory,
    this.defaultExecutionTimeout = const Duration(seconds: 30),
  });

  final String? workingDirectory;
  final Duration defaultExecutionTimeout;

  Map<String, Object> toMap() => <String, Object>{
        if (workingDirectory != null) 'workingDirectory': workingDirectory!,
        'defaultExecutionTimeoutMs': _timeoutMilliseconds(defaultExecutionTimeout),
      };
}

class PythonProjectSource {
  const PythonProjectSource._(this.kind, this.location);
  const PythonProjectSource.directory(String path) : this._(PythonProjectSourceKind.directory, path);
  const PythonProjectSource.archive(String path) : this._(PythonProjectSourceKind.archive, path);
  const PythonProjectSource.asset(String assetKey) : this._(PythonProjectSourceKind.asset, assetKey);

  final PythonProjectSourceKind kind;
  final String location;
  Map<String, Object> toMap() => <String, Object>{'kind': kind.name, 'location': location};
}

class PythonException implements Exception {
  const PythonException({required this.type, required this.message, required this.traceback});
  final String type;
  final String message;
  final String traceback;
  @override
  String toString() => '$type: $message';
}

class PythonExecutionResult {
  const PythonExecutionResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.state,
    this.value,
    this.binaryValue,
    this.valueRepresentation,
    this.exception,
    this.outputTruncated = false,
  });

  factory PythonExecutionResult.fromMap(Map<Object?, Object?> map) {
    final valueJson = map['valueJson'] as String?;
    final exceptionType = map['exceptionType'] as String?;
    return PythonExecutionResult(
      exitCode: (map['exitCode'] as num?)?.toInt() ?? 1,
      stdout: map['stdout'] as String? ?? '',
      stderr: map['stderr'] as String? ?? '',
      state: _jobState(map['state'] as String?),
      outputTruncated: map['outputTruncated'] == true,
      value: valueJson == null ? null : jsonDecode(valueJson),
      binaryValue: map['binaryValue'] as Uint8List?,
      valueRepresentation: map['valueRepr'] as String?,
      exception: exceptionType == null
          ? null
          : PythonException(
              type: exceptionType,
              message: map['exceptionMessage'] as String? ?? '',
              traceback: map['traceback'] as String? ?? '',
            ),
    );
  }

  final int exitCode;
  final String stdout;
  final String stderr;
  final PythonJobState state;
  final bool outputTruncated;
  final Object? value;
  final Uint8List? binaryValue;
  final String? valueRepresentation;
  final PythonException? exception;
  bool get succeeded => state == PythonJobState.completed && exitCode == 0;
}

class PythonRuntimeInfo {
  const PythonRuntimeInfo({
    required this.version,
    required this.platform,
    required this.executable,
    required this.prefix,
    required this.moduleSearchPaths,
    required this.workingDirectory,
  });

  factory PythonRuntimeInfo.fromMap(Map<Object?, Object?> map) => PythonRuntimeInfo(
        version: map['version'] as String? ?? '',
        platform: map['platform'] as String? ?? '',
        executable: map['executable'] as String? ?? '',
        prefix: map['prefix'] as String? ?? '',
        moduleSearchPaths: (map['moduleSearchPaths'] as List<Object?>? ?? const <Object?>[]).cast<String>(),
        workingDirectory: map['workingDirectory'] as String? ?? '',
      );

  final String version;
  final String platform;
  final String executable;
  final String prefix;
  final List<String> moduleSearchPaths;
  final String workingDirectory;
}

class PythonOutput {
  const PythonOutput({required this.jobId, required this.stream, required this.text});
  final int jobId;
  final PythonStream stream;
  final String text;
}

class PythonEvent {
  const PythonEvent({required this.name, this.data, this.sessionId, this.jobId});
  final String name;
  final Object? data;
  final int? sessionId;
  final int? jobId;
}

class PythonMethodCall {
  const PythonMethodCall({required this.method, required this.arguments, required this.sessionId});
  final String method;
  final Object? arguments;
  final int? sessionId;
}

typedef PythonMethodCallHandler = FutureOr<Object?> Function(PythonMethodCall call);

class PythonJob {
  PythonJob._({required PythonRuntime runtime, required this.id, required this.completed}) : _runtime = runtime;
  final PythonRuntime _runtime;
  final int id;
  final Future<PythonExecutionResult> completed;

  Stream<PythonOutput> get output => _runtime._outputs.stream.where((event) => event.jobId == id);
  Stream<String> get stdout => output.where((event) => event.stream == PythonStream.stdout).map((event) => event.text);
  Stream<String> get stderr => output.where((event) => event.stream == PythonStream.stderr).map((event) => event.text);
  Stream<PythonEvent> get events => _runtime.events.where((event) => event.jobId == id);
  Stream<PythonJobState> get states => _runtime._states.stream.where((event) => event.$1 == id).map((event) => event.$2);

  Future<void> cancel() => _runtime._invokeVoid('cancelJob', <String, Object>{'jobId': id});
}

class PythonProject {
  PythonProject._(this._runtime, this.id, this.source);
  final PythonRuntime _runtime;
  final int id;
  final PythonProjectSource source;

  PythonJob startCall(String entrypoint, {
    List<Object?> arguments = const <Object?>[],
    Map<String, Object?> namedArguments = const <String, Object?>{},
    String? workingDirectory,
    Duration? timeout,
  }) {
    _checkActive();
    return _runtime._startJob(<String, Object?>{
      'mode': PythonExecutionMode.call.name,
      'projectId': id,
      'entrypoint': entrypoint,
      'argumentsJson': jsonEncode(arguments),
      'namedArgumentsJson': jsonEncode(namedArguments),
      'workingDirectory': workingDirectory,
      'timeoutMs': _timeoutMilliseconds(timeout ?? _runtime.options.defaultExecutionTimeout),
    });
  }

  Future<PythonExecutionResult> call(String entrypoint, {
    List<Object?> arguments = const <Object?>[],
    Map<String, Object?> namedArguments = const <String, Object?>{},
    String? workingDirectory,
    Duration? timeout,
  }) => startCall(entrypoint, arguments: arguments, namedArguments: namedArguments, workingDirectory: workingDirectory, timeout: timeout).completed;

  Future<PythonSession> openSession() async {
    _runtime._checkCanSchedule();
    final generation = _runtime._sessionGeneration;
    final sessionId = await _runtime._channel.invokeMethod<int>('openSession', <String, Object>{'projectId': id});
    _checkActive();
    if (generation != _runtime._sessionGeneration) throw StateError('Python Worker 已断开，Session 创建失败。');
    if (sessionId == null) throw PlatformException(code: 'empty_result', message: '原生端没有返回 Python Session ID。');
    return PythonSession._(_runtime, sessionId, this, generation);
  }

  void _checkActive() {
    _runtime._checkActive();
  }
}

class PythonSession {
  PythonSession._(this._runtime, this.id, this.project, this._generation);
  final PythonRuntime _runtime;
  final int id;
  final PythonProject project;
  final int _generation;
  bool _closed = false;
  Future<void>? _closing;

  bool get isValid => !_closed && !_runtime._disposed && _generation == _runtime._sessionGeneration;

  Stream<PythonEvent> get events => _runtime.events.where((event) => event.sessionId == id);

  void setMethodCallHandler(PythonMethodCallHandler? handler) {
    _checkOpen();
    if (handler == null) {
      _runtime._sessionHandlers.remove(id);
    } else {
      _runtime._sessionHandlers[id] = handler;
    }
  }

  PythonJob start(String source, {
    PythonExecutionMode mode = PythonExecutionMode.exec,
    String filename = '<session>',
    List<String> arguments = const <String>[],
    String? workingDirectory,
    Duration? timeout,
  }) {
    _checkOpen();
    return _runtime._startJob(<String, Object?>{
      'mode': mode.name,
      'projectId': project.id,
      'sessionId': id,
      'source': source,
      'filename': filename,
      'arguments': arguments,
      'workingDirectory': workingDirectory,
      'timeoutMs': _timeoutMilliseconds(timeout ?? _runtime.options.defaultExecutionTimeout),
    });
  }

  Future<PythonExecutionResult> execute(String source, {String filename = '<session>', String? workingDirectory, Duration? timeout}) =>
      start(source, filename: filename, workingDirectory: workingDirectory, timeout: timeout).completed;

  Future<PythonExecutionResult> evaluate(String expression, {String filename = '<session-eval>', String? workingDirectory, Duration? timeout}) =>
      start(expression, mode: PythonExecutionMode.eval, filename: filename, workingDirectory: workingDirectory, timeout: timeout).completed;

  PythonJob startCall(String entrypoint, {
    List<Object?> arguments = const <Object?>[],
    Map<String, Object?> namedArguments = const <String, Object?>{},
    String? workingDirectory,
    Duration? timeout,
  }) {
    _checkOpen();
    return _runtime._startJob(<String, Object?>{
      'mode': PythonExecutionMode.call.name,
      'projectId': project.id,
      'sessionId': id,
      'entrypoint': entrypoint,
      'argumentsJson': jsonEncode(arguments),
      'namedArgumentsJson': jsonEncode(namedArguments),
      'workingDirectory': workingDirectory,
      'timeoutMs': _timeoutMilliseconds(timeout ?? _runtime.options.defaultExecutionTimeout),
    });
  }

  Future<PythonExecutionResult> call(String entrypoint, {
    List<Object?> arguments = const <Object?>[],
    Map<String, Object?> namedArguments = const <String, Object?>{},
    String? workingDirectory,
    Duration? timeout,
  }) => startCall(
        entrypoint,
        arguments: arguments,
        namedArguments: namedArguments,
        workingDirectory: workingDirectory,
        timeout: timeout,
      ).completed;

  Future<void> close() {
    if (_closing != null) return _closing!;
    if (_closed) return Future<void>.value();
    _checkOpen();
    _runtime._checkCanSchedule();
    _closed = true;
    return _closing = _close();
  }

  Future<void> _close() async {
    try {
      await _runtime._invokeVoid('closeSession', <String, Object>{'sessionId': id});
      _runtime._sessionHandlers.remove(id);
    } catch (_) {
      _closed = false;
      rethrow;
    } finally {
      _closing = null;
    }
  }

  void _checkOpen() {
    if (_closed) throw StateError('PythonSession $id 已经关闭。');
    if (_generation != _runtime._sessionGeneration) throw StateError('PythonSession $id 已因 Worker 断开而失效，请重新创建 Session。');
    project._checkActive();
  }
}

class PythonRuntime {
  PythonRuntime._(this.options);
  static const MethodChannel _methodChannel = MethodChannel('cpython_runtime/methods');
  static const EventChannel _eventChannel = EventChannel('cpython_runtime/events');
  static bool _initializingOrActive = false;
  static final Object _hostCallZone = Object();
  static int _nextJobId = 1;

  final PythonRuntimeOptions options;
  final MethodChannel _channel = _methodChannel;
  final StreamController<PythonOutput> _outputs = StreamController<PythonOutput>.broadcast();
  final StreamController<PythonEvent> _events = StreamController<PythonEvent>.broadcast();
  final StreamController<(int, PythonJobState)> _states = StreamController<(int, PythonJobState)>.broadcast();
  final Map<int, PythonMethodCallHandler> _sessionHandlers = <int, PythonMethodCallHandler>{};
  StreamSubscription<Object?>? _nativeEvents;
  final Set<int> _jobs = <int>{};
  bool _disposed = false;
  int _sessionGeneration = 0;
  bool _recovering = false;
  Future<void>? _disposal;

  Stream<PythonEvent> get events => _events.stream;
  bool get isRecovering => _recovering;

  static Future<PythonRuntime> initialize({PythonRuntimeOptions options = const PythonRuntimeOptions()}) async {
    if (_initializingOrActive) throw StateError('PythonRuntime 已经初始化或正在初始化。');
    _initializingOrActive = true;
    final runtime = PythonRuntime._(options);
    runtime._connectEvents();
    try {
      await _methodChannel.invokeMethod<void>('initialize', options.toMap());
      return runtime;
    } catch (_) {
      runtime._disposed = true;
      try {
        await runtime._nativeEvents?.cancel();
        await runtime._outputs.close();
        await runtime._events.close();
        await runtime._states.close();
      } finally {
        _initializingOrActive = false;
      }
      rethrow;
    }
  }

  Future<PythonProject> loadProject(PythonProjectSource source) async {
    _checkCanSchedule();
    final projectId = await _channel.invokeMethod<int>('loadProject', source.toMap());
    _checkActive();
    if (projectId == null) throw PlatformException(code: 'empty_result', message: '原生端没有返回 Python Project ID。');
    return PythonProject._(this, projectId, source);
  }

  PythonJob start(String source, {
    PythonExecutionMode mode = PythonExecutionMode.exec,
    String filename = '<python>',
    List<String> arguments = const <String>[],
    String? workingDirectory,
    Duration? timeout,
  }) {
    _checkActive();
    return _startJob(<String, Object?>{
      'mode': mode.name,
      'source': source,
      'filename': filename,
      'arguments': arguments,
      'workingDirectory': workingDirectory,
      'timeoutMs': _timeoutMilliseconds(timeout ?? options.defaultExecutionTimeout),
    });
  }

  Future<PythonExecutionResult> run(String source, {
    String filename = '<python>',
    List<String> arguments = const <String>[],
    String? workingDirectory,
    Duration? timeout,
  }) => start(source, filename: filename, arguments: arguments, workingDirectory: workingDirectory, timeout: timeout).completed;

  Future<PythonExecutionResult> evaluate(String expression, {String filename = '<python-eval>', String? workingDirectory, Duration? timeout}) =>
      start(expression, mode: PythonExecutionMode.eval, filename: filename, workingDirectory: workingDirectory, timeout: timeout).completed;

  void setMethodCallHandler(PythonMethodCallHandler? handler) {
    _checkActive();
    if (handler == null) {
      _sessionHandlers.remove(0);
    } else {
      _sessionHandlers[0] = handler;
    }
  }

  Future<PythonRuntimeInfo> getRuntimeInfo() async {
    _checkCanSchedule();
    final map = await _channel.invokeMapMethod<Object?, Object?>('getRuntimeInfo');
    if (map == null) throw PlatformException(code: 'empty_result', message: '原生端没有返回 Python Runtime 信息。');
    return PythonRuntimeInfo.fromMap(map);
  }

  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    _checkCanSchedule();
    _disposed = true;
    _recovering = false;
    return _disposal = _dispose();
  }

  Future<void> _dispose() async {
    try {
      await _channel.invokeMethod<void>('dispose');
    } finally {
      try {
        await _nativeEvents?.cancel();
        unawaited(_outputs.close());
        unawaited(_events.close());
        unawaited(_states.close());
      } finally {
        _sessionHandlers.clear();
        _jobs.clear();
        _initializingOrActive = false;
      }
    }
  }

  PythonJob _startJob(Map<String, Object?> request) {
    _checkCanSchedule();
    if (request['mode'] == PythonExecutionMode.call.name && request['entrypoint'] == null) {
      throw ArgumentError('call 模式请使用 startCall 或 call。');
    }
    final jobId = _nextJobId++;
    _jobs.add(jobId);
    final completed = _channel.invokeMapMethod<Object?, Object?>('startJob', <String, Object?>{
      ...request,
      'jobId': jobId,
    }).then((map) {
      if (map == null) throw PlatformException(code: 'empty_result', message: 'Python Worker 没有返回执行结果。');
      return PythonExecutionResult.fromMap(map);
    }).whenComplete(() => _jobs.remove(jobId));
    return PythonJob._(runtime: this, id: jobId, completed: completed);
  }

  Future<void> _invokeVoid(String method, Map<String, Object> arguments) {
    _checkActive();
    return _channel.invokeMethod<void>(method, arguments);
  }

  void _connectEvents() {
    _nativeEvents = _eventChannel.receiveBroadcastStream().listen((Object? raw) {
      if (_disposed) return;
      final map = raw as Map<Object?, Object?>;
      switch (map['kind'] as String?) {
        case 'output':
          _outputs.add(PythonOutput(
            jobId: (map['jobId'] as num).toInt(),
            stream: map['stream'] == 'stderr' ? PythonStream.stderr : PythonStream.stdout,
            text: map['text'] as String? ?? '',
          ));
          break;
        case 'event':
          final name = map['name'] as String? ?? '';
          if (map['jobId'] == null) {
            switch (name) {
              case 'sessionsInvalidated':
                _sessionGeneration++;
                _recovering = true;
                _sessionHandlers.removeWhere((id, _) => id != 0);
                _jobs.clear();
                break;
              case 'workerRecovered':
              case 'workerRecoveryFailed':
                _recovering = false;
                break;
            }
          }
          final dataJson = map['dataJson'] as String?;
          _events.add(PythonEvent(
            name: name,
            data: dataJson == null ? null : jsonDecode(dataJson),
            jobId: (map['jobId'] as num?)?.toInt(),
            sessionId: (map['sessionId'] as num?)?.toInt(),
          ));
          break;
        case 'state':
          _states.add(((map['jobId'] as num).toInt(), _jobState(map['state'] as String?)));
          break;
        case 'methodCall':
          unawaited(_handlePythonMethodCall(map));
          break;
      }
    }, onError: (Object error, StackTrace stackTrace) {
      if (_disposed) return;
      _outputs.addError(error, stackTrace);
      _events.addError(error, stackTrace);
    });
  }

  Future<void> _handlePythonMethodCall(Map<Object?, Object?> map) async {
    if (_disposed || !_jobs.contains((map['jobId'] as num?)?.toInt())) return;
    final callId = (map['callId'] as num).toInt();
    final sessionId = (map['sessionId'] as num?)?.toInt();
    final argumentsJson = map['argumentsJson'] as String?;
    final handler = _sessionHandlers[sessionId ?? 0] ?? _sessionHandlers[0];
    final response = <String, Object?>{'callId': callId};
    try {
      if (handler == null) throw StateError('Flutter 没有注册该 Python 方法处理器。');
      final value = await runZoned(() => handler(PythonMethodCall(
            method: map['method'] as String? ?? '',
            arguments: argumentsJson == null ? null : jsonDecode(argumentsJson),
            sessionId: sessionId,
          )), zoneValues: <Object, Object>{_hostCallZone: this});
      final encoded = jsonEncode(value);
      if (utf8.encode(encoded).length > 64 * 1024) throw StateError('Dart 回调结果超过 64 KiB。');
      response['resultJson'] = encoded;
    } catch (error) {
      final message = error.toString();
      response['error'] = message.length > 4096 ? message.substring(0, 4096) : message;
    }
    if (_disposed || !_jobs.contains((map['jobId'] as num?)?.toInt())) return;
    try {
      await _channel.invokeMethod<void>('completeHostCall', response);
    } catch (_) {
      return;
    }
  }

  void _checkCanSchedule() {
    _checkActive();
    if (identical(Zone.current[_hostCallZone], this)) throw StateError('Python 调用 Dart 的处理器中不能等待同一 Runtime 的执行或释放操作。');
  }

  void _checkActive() {
    if (_disposed) throw StateError('PythonRuntime 已经释放。');
  }
}

PythonJobState _jobState(String? value) {
  for (final state in PythonJobState.values) {
    if (state.name == value) return state;
  }
  return value == null ? PythonJobState.completed : PythonJobState.failed;
}

int _timeoutMilliseconds(Duration value) {
  if (value.isNegative) {
    throw ArgumentError.value(value, 'timeout', '超时时间不能是负数。');
  }
  return value > Duration.zero && value.inMilliseconds == 0 ? 1 : value.inMilliseconds;
}
