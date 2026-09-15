# Flutter Python Bridge

English | [简体中文](README.zh-CN.md)

`flutter_python_bridge` embeds CPython 3.14 in Flutter applications. It can execute Python code, call functions from Python projects, and exchange data between Dart and Python.

## Features

- Execute Python code, evaluate expressions, or call functions from Python projects in Dart
- Call Dart methods or send messages to Dart from Python
- Receive Python output and errors in real time
- Set execution timeouts or cancel running jobs

## Platform support

| Platform | Minimum version | Architectures |
| --- | --- | --- |
| Android | API 24 | `arm64-v8a`, `x86_64` |
| iOS | iOS 13 | arm64 devices, arm64/x86_64 simulators |

## Installation

```yaml
dependencies:
  flutter_python_bridge:
    path: ../flutter_python_bridge
```

Then run:

```bash
flutter pub get
flutter pub add path_provider
```

The plugin does not include CPython. Before using it, prepare the required Android or iOS files as described below.

## Android setup

Download and extract both archives from [Python releases for Android](https://www.python.org/downloads/android/):

```text
python-3.14.7-aarch64-linux-android.tar.gz
python-3.14.7-x86_64-linux-android.tar.gz
```

### arm64-v8a

Use `python-3.14.7-aarch64-linux-android.tar.gz`:

| File in archive | Copy to plugin |
| --- | --- |
| `prefix/include/` | `android/runtime/arm64-v8a/prefix/include/` |
| `prefix/lib/libpython3.14.so` | `android/runtime/arm64-v8a/prefix/lib/libpython3.14.so` |
| `prefix/lib/libpython3.14.so` | `android/src/main/jniLibs/arm64-v8a/libpython3.14.so` |
| `prefix/lib/libpython3.so` | `android/src/main/jniLibs/arm64-v8a/libpython3.so` |
| `prefix/lib/libcrypto_python.so` | `android/src/main/jniLibs/arm64-v8a/libcrypto_python.so` |
| `prefix/lib/libsqlite3_python.so` | `android/src/main/jniLibs/arm64-v8a/libsqlite3_python.so` |
| `prefix/lib/libssl_python.so` | `android/src/main/jniLibs/arm64-v8a/libssl_python.so` |

### x86_64

Use `python-3.14.7-x86_64-linux-android.tar.gz`:

| File in archive | Copy to plugin |
| --- | --- |
| `prefix/include/` | `android/runtime/x86_64/prefix/include/` |
| `prefix/lib/libpython3.14.so` | `android/runtime/x86_64/prefix/lib/libpython3.14.so` |
| `prefix/lib/libpython3.14.so` | `android/src/main/jniLibs/x86_64/libpython3.14.so` |
| `prefix/lib/libpython3.so` | `android/src/main/jniLibs/x86_64/libpython3.so` |
| `prefix/lib/libcrypto_python.so` | `android/src/main/jniLibs/x86_64/libcrypto_python.so` |
| `prefix/lib/libsqlite3_python.so` | `android/src/main/jniLibs/x86_64/libsqlite3_python.so` |
| `prefix/lib/libssl_python.so` | `android/src/main/jniLibs/x86_64/libssl_python.so` |

### Package the Python standard library

Package the standard libraries from the two extracted Python packages into separate ZIP files as follows:

#### arm64-v8a

1. Create the `python-home-arm64-v8a/lib/` directory.
2. From the directory extracted from `python-3.14.7-aarch64-linux-android.tar.gz`, copy `prefix/lib/python3.14/` to `python-home-arm64-v8a/lib/python3.14/`.
3. Compress the `lib/` directory under `python-home-arm64-v8a` into a ZIP file and name it `python-home-arm64-v8a.zip`.
4. Place the ZIP file at `android/src/main/assets/python/python-home-arm64-v8a.zip`.

#### x86_64

1. Create the `python-home-x86_64/lib/` directory.
2. From the directory extracted from `python-3.14.7-x86_64-linux-android.tar.gz`, copy `prefix/lib/python3.14/` to `python-home-x86_64/lib/python3.14/`.
3. Compress the `lib/` directory under `python-home-x86_64` into a ZIP file and name it `python-home-x86_64.zip`.
4. Place the ZIP file at `android/src/main/assets/python/python-home-x86_64.zip`.

## iOS setup

On a Mac with Xcode installed, open the CPython 3.14.7 source directory and run:

```bash
python3 Apple build iOS
```

Extract the generated archive:

```text
cross-build/dist/python-3.14.7-iOS-XCframework.tar.gz
```

Copy the complete `Python.xcframework` directory to:

```text
ios/Frameworks/Python.xcframework
```

In the host project's Xcode `Runner` target, add a Run Script Build Phase after `Copy Bundle Resources` and before `Embed Frameworks`:

```bash
set -e
cd "$PROJECT_DIR"
PYTHON_XCFRAMEWORK_PATH=".symlinks/plugins/flutter_python_bridge/ios/Frameworks/Python.xcframework"
source "$PROJECT_DIR/$PYTHON_XCFRAMEWORK_PATH/build/utils.sh"
install_python "$PYTHON_XCFRAMEWORK_PATH"
```

## Basic usage

```dart
import 'dart:io';

import 'package:flutter_python_bridge/flutter_python_bridge.dart';
import 'package:path_provider/path_provider.dart';

final appDirectory = await getApplicationSupportDirectory();
final workingDirectory = Directory('${appDirectory.path}/python');
await workingDirectory.create(recursive: true);

final python = await PythonRuntime.initialize(
  options: PythonRuntimeOptions(
    defaultExecutionTimeout: Duration(seconds: 30),
    workingDirectory: workingDirectory.path,
  ),
);

final result = await python.run('''
import math
print(math.sqrt(81))
''');

print(result.stdout);
print(result.stderr);
print(result.exitCode);
```

## Executing code

Specify a filename, command-line arguments, working directory, and timeout for an execution:

```dart
final result = await python.run(
  source,
  filename: 'main.py',
  arguments: ['first', 'second'],
  workingDirectory: workingDirectory.path,
  timeout: const Duration(seconds: 10),
);
```

`arguments` maps to `sys.argv[1:]`. Use `Duration.zero` to disable the timeout.

Evaluate an expression and read its value:

```dart
final result = await python.evaluate(
  '{"total": sum(range(101)), "items": [1, 2, 3]}',
);

print(result.value);
print(result.binaryValue);
print(result.valueRepresentation);
```

`value` can contain `null`, `bool`, `int`, `double`, `String`, `List`, or a `Map` with string keys. Python `bytes` are returned through `binaryValue`. For other objects, use `valueRepresentation`.

## Streaming output and cancellation

```dart
final job = python.start(source);

job.stdout.listen(print);
job.stderr.listen(print);
job.states.listen(print);

final result = await job.completed;
```

Cancel the current job:

```dart
await job.cancel();
```

## Calling a Python project

Projects can be loaded from a local directory, ZIP archive, or Flutter asset.

```text
demo_project/
└── demo/
    ├── __init__.py
    └── api.py
```

`demo/api.py`:

```python
def add(a, b, scale=1):
    return (a + b) * scale
```

Load the project:

```dart
final project = await python.loadProject(
  PythonProjectSource.archive(
    '${workingDirectory.path}/demo_project.zip',
  ),
);

final directoryProject = await python.loadProject(
  PythonProjectSource.directory(
    '${workingDirectory.path}/demo_project',
  ),
);

final assetProject = await python.loadProject(
  const PythonProjectSource.asset('assets/python/demo_project.zip'),
);
```

Declare asset ZIP files in the host application:

```yaml
flutter:
  assets:
    - assets/python/demo_project.zip
```

Call a function:

```dart
final result = await project.call(
  'demo.api:add',
  arguments: [20, 22],
  namedArguments: {'scale': 2},
);

print(result.value);
```

Use `startCall` when streaming output is required:

```dart
final job = project.startCall(
  'demo.api:add',
  arguments: [20, 22],
);

job.stdout.listen(print);
final result = await job.completed;
```

## Running code continuously

Create a session when several pieces of code need to share previously defined variables:

```dart
final session = await project.openSession();

await session.execute('counter = 40');
final value = await session.evaluate('counter + 2');
final called = await session.call(
  'demo.api:add',
  arguments: [20, 22],
);

await session.close();
```

`PythonSession` also provides `start` and `startCall` for reading output while code is running.

## Dart and Python communication

Register a Dart method that can be called from Python:

```dart
python.setMethodCallHandler((call) async {
  if (call.method == 'readSetting') {
    return {'theme': 'dark'};
  }
  throw UnsupportedError(call.method);
});
```

Call the Dart method and send a message back to Dart:

```python
from flutter_python_bridge import flutter

setting = flutter.invoke("readSetting", {"key": "theme"})
flutter.emit("settingLoaded", setting)
```

Receive the message in Dart:

```dart
final job = python.start(source);

job.events.listen((event) {
  print(event.name);
  print(event.data);
});

final result = await job.completed;
```

## Releasing resources

```dart
await session.close();
await python.dispose();
```

`python.dispose()` releases all projects and sessions. To reopen a project or switch projects, dispose of the runtime and initialize it again:

```dart
await python.dispose();

final nextPython = await PythonRuntime.initialize();
final nextProject = await nextPython.loadProject(
  const PythonProjectSource.asset('assets/python/demo_project.zip'),
);
```
