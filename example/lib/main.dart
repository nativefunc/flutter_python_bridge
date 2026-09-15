import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_python_bridge/flutter_python_bridge.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final source =
      TextEditingController(text: '''from flutter_python_bridge import flutter
import math
import time

for value in range(1, 4):
    print(f"step={value}, sqrt={math.sqrt(value):.3f}", flush=True)
    flutter.emit("progress", {"value": value / 3})
    time.sleep(0.4)
''');
  final output = StringBuffer();
  PythonRuntime? runtime;
  PythonJob? job;
  StreamSubscription<PythonOutput>? outputSubscription;
  StreamSubscription<PythonEvent>? eventSubscription;

  @override
  void initState() {
    super.initState();
    initialize();
  }

  Future<void> initialize() async {
    try {
      final current = await PythonRuntime.initialize();
      if (!mounted) {
        await current.dispose();
        return;
      }
      setState(() {
        runtime = current;
      });
    } catch (error) {
      print('初始化失败：$error');
    }
  }

  Future<void> runCode() async {
    final current = runtime;
    if (current == null || job != null) return;
    await outputSubscription?.cancel();
    await eventSubscription?.cancel();
    if (!mounted) return;
    final currentJob = current.start(source.text);
    outputSubscription = currentJob.output.listen((event) {
      if (mounted) setState(() => output.write(event.text));
    });
    eventSubscription = currentJob.events.listen((event) {
      if (mounted) {
        setState(() => output.writeln('[${event.name}] ${event.data}'));
      }
    });
    setState(() {
      output.clear();
      job = currentJob;
    });
    try {
      await currentJob.completed;
    } finally {
      if (mounted && identical(job, currentJob)) {
        setState(() {
          job = null;
        });
      }
    }
  }

  @override
  void dispose() {
    outputSubscription?.cancel();
    eventSubscription?.cancel();
    runtime?.dispose();
    source.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final running = job != null;
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: TextField(
                  controller: source,
                  expands: true,
                  maxLines: null,
                  minLines: null,
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                FilledButton(
                  onPressed: runtime != null && !running ? runCode : null,
                  child: const Text('运行'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: running ? job!.cancel : null,
                  child: const Text('取消'),
                ),
              ]),
              const SizedBox(height: 8),
              Expanded(
                child: ColoredBox(
                  color: const Color(0xff101418),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      output.toString(),
                      style: const TextStyle(
                          color: Colors.white),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
