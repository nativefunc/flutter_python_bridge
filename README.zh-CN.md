# Flutter Python Bridge

[English](README.md) | 简体中文

`flutter_python_bridge` 在 Flutter 应用中嵌入 CPython 3.14，可执行 Python 代码、调用 Python 项目函数，并在 Dart 与 Python 之间传递数据。

## 功能

- 在 Dart 中执行 Python 代码、计算表达式或调用 Python 项目中的函数
- 在 Python 中调用 Dart 方法或向 Dart 发送消息
- 实时获取 Python 的输出和错误
- 设置执行超时时间或取消任务

## 平台支持

| 平台 | 最低版本 | 架构 |
| --- | --- | --- |
| Android | API 24 | `arm64-v8a`、`x86_64` |
| iOS | iOS 13 | arm64 真机、arm64/x86_64 模拟器 |

## 安装

```yaml
dependencies:
  flutter_python_bridge:
    path: ../flutter_python_bridge
```

然后运行：

```bash
flutter pub get
flutter pub add path_provider
```

插件不包含CPython。使用前需要按下文准备 Android 或 iOS 所需文件。

## Android 配置

从 [Python Android 发布页](https://www.python.org/downloads/android/) 下载并解压：

```text
python-3.14.7-aarch64-linux-android.tar.gz
python-3.14.7-x86_64-linux-android.tar.gz
```

### arm64-v8a

使用 `python-3.14.7-aarch64-linux-android.tar.gz`：

| 压缩包中的文件 | 复制到插件目录 |
| --- | --- |
| `prefix/include/` | `android/runtime/arm64-v8a/prefix/include/` |
| `prefix/lib/libpython3.14.so` | `android/runtime/arm64-v8a/prefix/lib/libpython3.14.so` |
| `prefix/lib/libpython3.14.so` | `android/src/main/jniLibs/arm64-v8a/libpython3.14.so` |
| `prefix/lib/libpython3.so` | `android/src/main/jniLibs/arm64-v8a/libpython3.so` |
| `prefix/lib/libcrypto_python.so` | `android/src/main/jniLibs/arm64-v8a/libcrypto_python.so` |
| `prefix/lib/libsqlite3_python.so` | `android/src/main/jniLibs/arm64-v8a/libsqlite3_python.so` |
| `prefix/lib/libssl_python.so` | `android/src/main/jniLibs/arm64-v8a/libssl_python.so` |

### x86_64

使用 `python-3.14.7-x86_64-linux-android.tar.gz`：

| 压缩包中的文件 | 复制到插件目录 |
| --- | --- |
| `prefix/include/` | `android/runtime/x86_64/prefix/include/` |
| `prefix/lib/libpython3.14.so` | `android/runtime/x86_64/prefix/lib/libpython3.14.so` |
| `prefix/lib/libpython3.14.so` | `android/src/main/jniLibs/x86_64/libpython3.14.so` |
| `prefix/lib/libpython3.so` | `android/src/main/jniLibs/x86_64/libpython3.so` |
| `prefix/lib/libcrypto_python.so` | `android/src/main/jniLibs/x86_64/libcrypto_python.so` |
| `prefix/lib/libsqlite3_python.so` | `android/src/main/jniLibs/x86_64/libsqlite3_python.so` |
| `prefix/lib/libssl_python.so` | `android/src/main/jniLibs/x86_64/libssl_python.so` |

### 打包 Python 标准库

将前面解压的两个 Python 包中的标准库分别打包成 ZIP 文件，具体步骤如下：

#### arm64-v8a

1. 新建目录 `python-home-arm64-v8a/lib/`。
2. 从 `python-3.14.7-aarch64-linux-android.tar.gz` 的解压目录中，将 `prefix/lib/python3.14/` 复制到 `python-home-arm64-v8a/lib/python3.14/`。
3. 将 `python-home-arm64-v8a` 下的 `lib/` 目录压缩为 ZIP，并将压缩包命名为 `python-home-arm64-v8a.zip`。
4. 将 ZIP 放到 `android/src/main/assets/python/python-home-arm64-v8a.zip`。

#### x86_64

1. 新建目录 `python-home-x86_64/lib/`。
2. 从 `python-3.14.7-x86_64-linux-android.tar.gz` 的解压目录中，将 `prefix/lib/python3.14/` 复制到 `python-home-x86_64/lib/python3.14/`。
3. 将 `python-home-x86_64` 下的 `lib/` 目录压缩为 ZIP，并将压缩包命名为 `python-home-x86_64.zip`。
4. 将 ZIP 放到 `android/src/main/assets/python/python-home-x86_64.zip`。

## iOS 配置

在安装了 Xcode 的 macOS 上进入 CPython 3.14.7 源码目录，运行：

```bash
python3 Apple build iOS
```

解压生成的文件：

```text
cross-build/dist/python-3.14.7-iOS-XCframework.tar.gz
```

将完整的 `Python.xcframework` 复制到：

```text
ios/Frameworks/Python.xcframework
```

在宿主项目的 Xcode `Runner` Target 中添加 Run Script Build Phase，放在 `Copy Bundle Resources` 后、`Embed Frameworks` 前：

```bash
set -e
cd "$PROJECT_DIR"
PYTHON_XCFRAMEWORK_PATH=".symlinks/plugins/flutter_python_bridge/ios/Frameworks/Python.xcframework"
source "$PROJECT_DIR/$PYTHON_XCFRAMEWORK_PATH/build/utils.sh"
install_python "$PYTHON_XCFRAMEWORK_PATH"
```

## 基本用法

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

## 执行代码

传入文件名、命令行参数、工作目录和本次执行的超时时间：

```dart
final result = await python.run(
  source,
  filename: 'main.py',
  arguments: ['first', 'second'],
  workingDirectory: workingDirectory.path,
  timeout: const Duration(seconds: 10),
);
```

`arguments` 对应 `sys.argv[1:]`。`Duration.zero` 表示不设置超时。

计算表达式并取得返回值：

```dart
final result = await python.evaluate(
  '{"total": sum(range(101)), "items": [1, 2, 3]}',
);

print(result.value);
print(result.binaryValue);
print(result.valueRepresentation);
```

`value` 可返回 `null`、`bool`、`int`、`double`、`String`、`List` 和字符串键 `Map`。Python `bytes` 通过 `binaryValue` 返回，其他对象可读取 `valueRepresentation`。

## 实时输出和取消

```dart
final job = python.start(source);

job.stdout.listen(print);
job.stderr.listen(print);
job.states.listen(print);

final result = await job.completed;
```

取消当前任务：

```dart
await job.cancel();
```

## 调用 Python 项目

项目可以来自本地目录、ZIP 文件或 Flutter Asset。

```text
demo_project/
└── demo/
    ├── __init__.py
    └── api.py
```

`demo/api.py`：

```python
def add(a, b, scale=1):
    return (a + b) * scale
```

加载项目：

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

Asset ZIP 需要在宿主项目中声明：

```yaml
flutter:
  assets:
    - assets/python/demo_project.zip
```

调用函数：

```dart
final result = await project.call(
  'demo.api:add',
  arguments: [20, 22],
  namedArguments: {'scale': 2},
);

print(result.value);
```

需要实时输出时使用 `startCall`：

```dart
final job = project.startCall(
  'demo.api:add',
  arguments: [20, 22],
);

job.stdout.listen(print);
final result = await job.completed;
```

## 连续执行

需要连续运行多段代码，并使用前面定义的变量时，可以创建 Session：

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

`PythonSession` 也提供 `start` 和 `startCall`，可以在代码运行时读取打印内容。

## Dart 与 Python 通信

Dart 可以注册一个方法，供 Python 调用：

```dart
python.setMethodCallHandler((call) async {
  if (call.method == 'readSetting') {
    return {'theme': 'dark'};
  }
  throw UnsupportedError(call.method);
});
```

Python 调用这个 Dart 方法，并向 Dart 发送一条消息：

```python
from flutter_python_bridge import flutter

setting = flutter.invoke("readSetting", {"key": "theme"})
flutter.emit("settingLoaded", setting)
```

Dart 接收 Python 发来的消息：

```dart
final job = python.start(source);

job.events.listen((event) {
  print(event.name);
  print(event.data);
});

final result = await job.completed;
```

## 释放资源

```dart
await session.close();
await python.dispose();
```

`python.dispose()` 会释放所有项目和 Session。需要重新打开项目或切换项目时，先销毁 Runtime，再重新初始化：

```dart
await python.dispose();

final nextPython = await PythonRuntime.initialize();
final nextProject = await nextPython.loadProject(
  const PythonProjectSource.asset('assets/python/demo_project.zip'),
);
```
