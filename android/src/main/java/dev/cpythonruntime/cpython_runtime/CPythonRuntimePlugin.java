package dev.cpythonruntime.cpython_runtime;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.os.Parcel;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.DigestInputStream;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.zip.ZipFile;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import java.util.zip.CRC32;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

public final class CPythonRuntimePlugin implements
        FlutterPlugin,
        MethodChannel.MethodCallHandler,
        EventChannel.StreamHandler {
    private static final AtomicLong NEXT_ENGINE_ID = new AtomicLong(1);
    private static final Object RUNTIME_INSTALL_LOCK = new Object();
    private final long engineId = NEXT_ENGINE_ID.getAndIncrement();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final ExecutorService ioExecutor = Executors.newSingleThreadExecutor();
    private final ScheduledExecutorService timeoutExecutor = Executors.newSingleThreadScheduledExecutor();
    private volatile WorkerHandle worker;
    private static CPythonRuntimePlugin activeRuntime;
    private volatile long generation;
    private boolean initializing;
    private boolean disposing;
    private int recoveryAttempts;
    private boolean recovering;
    private MethodChannel.Result initializeResult;
    private final ConcurrentHashMap<Long, ProjectRecord> projects = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Long, WorkerHandle> sessionWorkers = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Long, WorkerHandle> jobWorkers = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Long, MethodChannel.Result> jobResults = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Long, Long> jobTimeouts = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Long, ScheduledFuture<?>> hardTimeouts = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Long, WorkerHandle> hostCallWorkers = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Long, Long> hostCallJobs = new ConcurrentHashMap<>();
    private final ArrayDeque<Map<String, Object>> pendingEvents = new ArrayDeque<>();
    private final AtomicLong nextProjectId = new AtomicLong(1);
    private final AtomicLong nextSessionId = new AtomicLong(1);
    private Context context;
    private FlutterPlugin.FlutterAssets flutterAssets;
    private MethodChannel methods;
    private EventChannel events;
    private EventChannel.EventSink eventSink;
    private volatile boolean initialized;
    private File pythonHome;
    private File workingDirectory;

    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        flutterAssets = binding.getFlutterAssets();
        methods = new MethodChannel(binding.getBinaryMessenger(), "cpython_runtime/methods");
        events = new EventChannel(binding.getBinaryMessenger(), "cpython_runtime/events");
        methods.setMethodCallHandler(this);
        events.setStreamHandler(this);
    }

    @Override
    public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        try {
            switch (call.method) {
                case "initialize":
                    initialize(call, result);
                    break;
                case "loadProject":
                    loadProject(call, result);
                    break;
                case "openSession":
                    openSession(call, result);
                    break;
                case "closeSession":
                    closeSession(call, result);
                    break;
                case "startJob":
                    startJob(call, result);
                    break;
                case "cancelJob":
                    controlJob(call, result);
                    break;
                case "completeHostCall":
                    completeHostCall(call, result);
                    break;
                case "getRuntimeInfo":
                    runtimeInfo(result);
                    break;
                case "dispose":
                    disposeRuntime(result);
                    break;
                default:
                    result.notImplemented();
                    break;
            }
        } catch (Throwable error) {
            result.error("cpython_runtime_error", error.getMessage(), stackTrace(error));
        }
    }

    private void initialize(MethodCall call, MethodChannel.Result result) {
        require(!initialized && !initializing && !disposing, "PythonRuntime is already initialized, initializing or disposing");
        require(activeRuntime == null || activeRuntime == this, "Another FlutterEngine is using PythonRuntime");
        activeRuntime = this;
        initializing = true;
        initializeResult = result;
        recoveryAttempts = 0;
        recovering = false;
        long currentGeneration = ++generation;
        ioExecutor.execute(() -> {
            try {
                File home = preparePythonHome();
                String configured = call.argument("workingDirectory");
                File cwd = configured == null || configured.trim().isEmpty()
                        ? new File(context.getFilesDir(), "cpython_runtime/workspace")
                        : new File(configured);
                require(cwd.isAbsolute(), "workingDirectory must be an absolute path");
                require(cwd.mkdirs() || cwd.isDirectory(), "Cannot create Python working directory: " + cwd);
                mainHandler.post(() -> {
                    if (generation != currentGeneration) return;
                    workingDirectory = cwd;
                    bindWorker(home, cwd);
                });
            } catch (Throwable error) {
                mainHandler.post(() -> {
                    if (generation != currentGeneration) return;
                    failInitialization(error);
                });
            }
        });
    }

    private void failInitialization(Throwable error) {
        initializing = false;
        initialized = false;
        if (activeRuntime == this) activeRuntime = null;
        MethodChannel.Result pending = initializeResult;
        initializeResult = null;
        if (pending != null) pending.error("runtime_initialize_failed", error.getMessage(), stackTrace(error));
    }

    private void unbindWorker(WorkerHandle handle) {
        if (handle == null || handle.connection == null) return;
        try {
            context.unbindService(handle.connection);
        } catch (IllegalArgumentException ignored) {
        }
        handle.connection = null;
        handle.connected = false;
    }

    private void recoverWorker(WorkerHandle handle) {
        if (worker != handle || generation != handle.generation) return;
        unbindWorker(handle);
        if (++recoveryAttempts > 3) {
            initialized = false;
            recovering = false;
            Map<String, Object> event = new HashMap<>();
            event.put("kind", "event");
            event.put("name", "workerRecoveryFailed");
            event.put("dataJson", "\"Python Worker recovery failed; dispose and initialize the runtime again\"");
            emit(event);
            if (initializing) failInitialization(new IllegalStateException("Python Worker recovery failed"));
            return;
        }
        mainHandler.postDelayed(() -> {
            if (worker == handle && generation == handle.generation) {
                bindWorker(pythonHome, workingDirectory);
            }
        }, 250L * recoveryAttempts);
    }

    private void bindWorker(File home, File cwd) {
        WorkerHandle handle = new WorkerHandle();
        handle.generation = generation;
        worker = handle;
        ServiceConnection connection = new ServiceConnection() {
            @Override
            public void onServiceConnected(ComponentName name, IBinder binder) {
                if (worker != handle || generation != handle.generation) return;
                IPythonWorker remote = IPythonWorker.Stub.asInterface(binder);
                handle.remote = remote;
                try {
                    handle.pid = remote.getPid();
                } catch (Exception error) {
                    recoverWorker(handle);
                    return;
                }
                ioExecutor.execute(() -> {
                    try {
                        remote.initializeRuntime(home.getAbsolutePath(), cwd.getAbsolutePath());
                        int pid = remote.getPid();
                        for (Map.Entry<Long, ProjectRecord> entry : projects.entrySet()) {
                            entry.getValue().load(remote, nativeId(entry.getKey()));
                        }
                        mainHandler.post(() -> {
                            if (worker != handle || generation != handle.generation || handle.remote != remote) return;
                            handle.pid = pid;
                            handle.connected = true;
                            initialized = true;
                            initializing = false;
                            recoveryAttempts = 0;
                            MethodChannel.Result pending = initializeResult;
                            initializeResult = null;
                            if (pending != null) pending.success(null);
                            if (recovering) {
                                recovering = false;
                                Map<String, Object> event = new HashMap<>();
                                event.put("kind", "event");
                                event.put("name", "workerRecovered");
                                emit(event);
                            }
                        });
                    } catch (Throwable error) {
                        mainHandler.post(() -> {
                            if (worker != handle || generation != handle.generation || handle.remote != remote) return;
                            if (initializing) {
                                unbindWorker(handle);
                                failInitialization(error);
                            } else {
                                recoverWorker(handle);
                            }
                        });
                    }
                });
            }

            @Override
            public void onServiceDisconnected(ComponentName name) {
                if (worker != handle || generation != handle.generation) return;
                handle.connected = false;
                handle.remote = null;
                failJobsForWorker(handle, "Python Worker 进程已断开。");
                mainHandler.postDelayed(() -> {
                    if (!handle.connected && handle.remote == null) recoverWorker(handle);
                }, 2_000L);
            }

            @Override
            public void onBindingDied(ComponentName name) {
                if (worker != handle || generation != handle.generation) return;
                handle.connected = false;
                failJobsForWorker(handle, "Python Worker 绑定已失效。");
                recoverWorker(handle);
            }

            @Override
            public void onNullBinding(ComponentName name) {
                if (worker != handle || generation != handle.generation) return;
                unbindWorker(handle);
                if (initializing) failInitialization(new IllegalStateException("Python Worker returned a null Binder"));
                else recoverWorker(handle);
            }
        };
        handle.connection = connection;
        if (!context.bindService(new Intent(context, PythonWorker.class), connection, Context.BIND_AUTO_CREATE)) {
            handle.connection = null;
            if (initializing) failInitialization(new IllegalStateException("Unable to bind Python Worker"));
            else recoverWorker(handle);
        }
    }

    private void loadProject(MethodCall call, MethodChannel.Result result) {
        requireInitialized();
        WorkerHandle handle = connectedWorker();
        String kind = requiredString(call, "kind");
        String location = requiredString(call, "location");
        IPythonWorker remote = handle.remote;
        long currentGeneration = generation;
        ioExecutor.execute(() -> {
            ProjectRecord project = null;
            try {
                if ("directory".equals(kind)) {
                    File directory = new File(location);
                    require(directory.isAbsolute() && directory.isDirectory() && directory.canRead(),
                            "Invalid Python project directory: " + location);
                    project = new ProjectRecord(directory.getCanonicalFile(), false);
                } else {
                    project = new ProjectRecord(prepareProjectArchive(kind, location), true);
                }
                require(generation == currentGeneration && worker == handle && handle.connected && handle.remote == remote,
                        "PythonRuntime changed during project loading");
                long projectId = nextProjectId.getAndIncrement();
                project.load(remote, nativeId(projectId));
                ProjectRecord loadedProject = project;
                mainHandler.post(() -> {
                    if (generation != currentGeneration || worker != handle || !handle.connected || handle.remote != remote) {
                        loadedProject.release();
                        result.error("runtime_changed", "PythonRuntime changed during project loading", null);
                        return;
                    }
                    projects.put(projectId, loadedProject);
                    result.success(projectId);
                });
            } catch (Throwable error) {
                if (project != null) project.release();
                postError(result, "project_load_failed", error);
            }
        });
    }

    private void openSession(MethodCall call, MethodChannel.Result result) {
        requireInitialized();
        long projectId = requiredNumber(call, "projectId").longValue();
        require(projects.containsKey(projectId), "Python project " + projectId + " does not exist");
        long sessionId = nextSessionId.getAndIncrement();
        sessionWorkers.put(sessionId, connectedWorker());
        result.success(sessionId);
    }

    private void closeSession(MethodCall call, MethodChannel.Result result) {
        long sessionId = requiredNumber(call, "sessionId").longValue();
        WorkerHandle worker = sessionWorkers.remove(sessionId);
        if (worker == null) {
            result.success(null);
            return;
        }
        ioExecutor.execute(() -> {
            try {
                worker.remote.destroySession(nativeId(sessionId));
                mainHandler.post(() -> result.success(null));
            } catch (Throwable error) {
                postError(result, "session_close_failed", error);
            }
        });
    }

    private void startJob(MethodCall call, MethodChannel.Result result) throws Exception {
        requireInitialized();
        Bundle request = argumentsBundle(call);
        Parcel parcel = Parcel.obtain();
        try {
            request.writeToParcel(parcel, 0);
            require(parcel.dataSize() <= 128 * 1024, "Python job exceeds the transport limit");
        } finally {
            parcel.recycle();
        }
        String requestedDirectory = call.argument("workingDirectory");
        if (requestedDirectory != null) {
            File directory = new File(requestedDirectory);
            require(directory.isAbsolute() && directory.isDirectory(),
                    "workingDirectory must be an existing absolute directory: " + requestedDirectory);
        }
        long jobId = requiredNumber(call, "jobId").longValue();
        Number sessionValue = call.argument("sessionId");
        long sessionId = sessionValue == null ? 0L : sessionValue.longValue();
        WorkerHandle worker;
        if (sessionId == 0L) {
            worker = connectedWorker();
        } else {
            worker = sessionWorkers.get(sessionId);
            if (worker == null) {
                throw new IllegalStateException("Python session " + sessionId + " does not exist");
            }
        }
        require(!jobResults.containsKey(jobId), "Python job already exists");
        long currentGeneration = generation;
        jobWorkers.put(jobId, worker);
        jobResults.put(jobId, result);
        Map<String, Object> queued = new HashMap<>();
        queued.put("kind", "state");
        queued.put("jobId", jobId);
        queued.put("state", "queued");
        emit(queued);
        if (!request.containsKey("workingDirectory")) {
            request.putString("workingDirectory", Objects.requireNonNull(workingDirectory).getAbsolutePath());
        }
        request.putLong("jobId", nativeId(jobId));
        if (sessionId != 0L) {
            request.putLong("sessionId", nativeId(sessionId));
        }
        Number projectId = call.argument("projectId");
        if (projectId != null) {
            request.putLong("projectId", nativeId(projectId.longValue()));
        }
        long timeoutMs = request.getLong("timeoutMs", 30_000L);
        if (timeoutMs > 0) {
            jobTimeouts.put(jobId, timeoutMs);
        }
        IPythonWorkerCallback callback = new IPythonWorkerCallback.Stub() {
            @Override
            public void onEvent(Bundle event) {
                mainHandler.post(() -> {
                    if (generation != currentGeneration || !jobResults.containsKey(jobId)) return;
                    forwardWorkerEvent(worker, event, jobId);
                });
            }

            @Override
            public void onResult(Bundle nativeResult) {
                mainHandler.post(() -> {
                    if (generation != currentGeneration) return;
                    clearHostCalls(jobId);
                    jobWorkers.remove(jobId);
                    jobTimeouts.remove(jobId);
                    ScheduledFuture<?> timeout = hardTimeouts.remove(jobId);
                    if (timeout != null) {
                        timeout.cancel(false);
                    }
                    MethodChannel.Result pending = jobResults.remove(jobId);
                    if (pending != null) {
                        pending.success(decodeResult(nativeResult));
                    }
                });
            }

            @Override
            public void onError(String code, String message, String details) {
                mainHandler.post(() -> {
                    if (generation != currentGeneration) return;
                    clearHostCalls(jobId);
                    jobWorkers.remove(jobId);
                    jobTimeouts.remove(jobId);
                    ScheduledFuture<?> timeout = hardTimeouts.remove(jobId);
                    if (timeout != null) {
                        timeout.cancel(false);
                    }
                    MethodChannel.Result pending = jobResults.remove(jobId);
                    if (pending != null) {
                        pending.error(code, message, details);
                    }
                });
            }
        };
        try {
            worker.remote.execute(request, callback);
        } catch (Exception error) {
            jobWorkers.remove(jobId);
            jobResults.remove(jobId);
            jobTimeouts.remove(jobId);
            ScheduledFuture<?> timeout = hardTimeouts.remove(jobId);
            if (timeout != null) {
                timeout.cancel(false);
            }
            throw error;
        }
    }

    private void controlJob(MethodCall call, MethodChannel.Result result) {
        long jobId = requiredNumber(call, "jobId").longValue();
        WorkerHandle worker = jobWorkers.get(jobId);
        if (worker == null) {
            throw new IllegalStateException("Python job " + jobId + " is not active");
        }
        ioExecutor.execute(() -> {
            try {
                worker.remote.interrupt(nativeId(jobId));
                mainHandler.post(() -> result.success(null));
            } catch (Throwable error) {
                postError(result, "job_control_failed", error);
            }
        });
    }

    private void completeHostCall(MethodCall call, MethodChannel.Result result) throws Exception {
        long callId = requiredNumber(call, "callId").longValue();
        WorkerHandle worker = hostCallWorkers.remove(callId);
        hostCallJobs.remove(callId);
        if (worker == null) {
            result.success(null);
            return;
        }
        String json = call.argument("resultJson");
        String error = call.argument("error");
        if ((json != null && json.getBytes(StandardCharsets.UTF_8).length > 64 * 1024)
                || (error != null && error.getBytes(StandardCharsets.UTF_8).length > 16 * 1024)) {
            json = null;
            error = "Dart callback exceeds the transport limit";
        }
        worker.remote.completeHostCall(callId, json, error);
        result.success(null);
    }

    private void runtimeInfo(MethodChannel.Result result) {
        requireInitialized();
        ioExecutor.execute(() -> {
            try {
                Bundle nativeResult = connectedWorker().remote.getRuntimeInfo();
                Map<String, Object> response = decodeResult(nativeResult);
                response.put("workingDirectory", workingDirectory == null ? "" : workingDirectory.getAbsolutePath());
                mainHandler.post(() -> result.success(response));
            } catch (Throwable error) {
                postError(result, "runtime_info_failed", error);
            }
        });
    }

    private void disposeRuntime(MethodChannel.Result result) {
        require(!disposing, "PythonRuntime is being disposed");
        disposing = true;
        generation++;
        initializing = false;
        if (initializeResult != null) {
            initializeResult.error("runtime_disposed", "PythonRuntime has been released", null);
            initializeResult = null;
        }
        WorkerHandle previousWorker = worker;
        worker = null;
        pendingEvents.clear();
        for (ProjectRecord project : projects.values()) {
            project.release();
        }
        projects.clear();
        sessionWorkers.clear();
        jobWorkers.clear();
        for (Long jobId : jobResults.keySet()) {
            MethodChannel.Result pending = jobResults.remove(jobId);
            if (pending != null) {
                pending.error("runtime_disposed", "PythonRuntime 已经释放。", null);
            }
        }
        jobTimeouts.clear();
        for (ScheduledFuture<?> timeout : hardTimeouts.values()) {
            timeout.cancel(false);
        }
        hardTimeouts.clear();
        hostCallWorkers.clear();
        hostCallJobs.clear();
        initialized = false;
        IPythonWorker previousRemote = previousWorker == null ? null : previousWorker.remote;
        IBinder binder = previousRemote == null ? null : previousRemote.asBinder();
        AtomicBoolean finished = new AtomicBoolean();
        Runnable complete = () -> mainHandler.post(() -> {
            if (!finished.compareAndSet(false, true)) return;
            disposing = false;
            if (activeRuntime == this) activeRuntime = null;
            result.success(null);
        });
        if (binder != null && binder.isBinderAlive()) {
            try {
                binder.linkToDeath(complete::run, 0);
            } catch (android.os.RemoteException ignored) {
                complete.run();
            }
        }
        unbindWorker(previousWorker);
        if (previousWorker != null && previousWorker.pid > 0 && binder != null && binder.isBinderAlive()) {
            android.os.Process.killProcess(previousWorker.pid);
        }
        if (binder == null || !binder.isBinderAlive()) complete.run();
    }

    private void forwardWorkerEvent(WorkerHandle worker, Bundle event, long localJobId) {
        String kind = event.getString("kind");
        Map<String, Object> mapped = new HashMap<>();
        mapped.put("kind", kind);
        if ("output".equals(kind)) {
            mapped.put("jobId", localJobId);
            mapped.put("stream", event.getString("stream"));
            byte[] utf8 = event.getByteArray("utf8");
            mapped.put("text", utf8 == null ? "" : new String(utf8, StandardCharsets.UTF_8));
        } else if ("event".equals(kind)) {
            mapped.put("jobId", localJobId);
            long sessionId = event.getLong("sessionId");
            mapped.put("sessionId", sessionId == 0L ? null : localId(sessionId));
            mapped.put("name", event.getString("name"));
            byte[] json = event.getByteArray("jsonUtf8");
            mapped.put("dataJson", json == null ? null : new String(json, StandardCharsets.UTF_8));
        } else if ("state".equals(kind)) {
            mapped.put("jobId", localJobId);
            String state = event.getString("state");
            mapped.put("state", state);
            if ("running".equals(state)) {
                startHardTimeout(localJobId, worker);
            }
        } else if ("methodCall".equals(kind)) {
            long callId = event.getLong("callId");
            hostCallWorkers.put(callId, worker);
            hostCallJobs.put(callId, localJobId);
            mapped.put("callId", callId);
            mapped.put("jobId", localJobId);
            long sessionId = event.getLong("sessionId");
            mapped.put("sessionId", sessionId == 0L ? null : localId(sessionId));
            mapped.put("method", event.getString("method"));
            byte[] json = event.getByteArray("jsonUtf8");
            mapped.put("argumentsJson", json == null ? null : new String(json, StandardCharsets.UTF_8));
        }
        emit(mapped);
    }

    private void startHardTimeout(long jobId, WorkerHandle worker) {
        Long timeoutMs = jobTimeouts.remove(jobId);
        if (timeoutMs == null) {
            return;
        }
        ScheduledFuture<?> timeout = timeoutExecutor.schedule(() -> {
            if (generation != worker.generation) return;
            hardTimeouts.remove(jobId);
            MethodChannel.Result pending = jobResults.remove(jobId);
            if (pending != null) {
                worker.connected = false;
                clearHostCalls(jobId);
                jobWorkers.remove(jobId);
                mainHandler.post(() -> {
                    Map<String, Object> timeoutResult = new HashMap<>();
                    timeoutResult.put("exitCode", 124);
                    timeoutResult.put("stdout", "");
                    timeoutResult.put("stderr", "");
                    timeoutResult.put("state", "timedOut");
                    timeoutResult.put("exceptionType", "PythonTimeoutError");
                    timeoutResult.put("exceptionMessage", "Python 任务超时，Worker 已被终止。");
                    timeoutResult.put("traceback", "");
                    Map<String, Object> state = new HashMap<>();
                    state.put("kind", "state");
                    state.put("jobId", jobId);
                    state.put("state", "timedOut");
                    if (generation == worker.generation) {
                        failJobsForWorker(worker, "Python Worker 已因任务超时而终止。");
                        emit(state);
                        pending.success(timeoutResult);
                    } else {
                        pending.error("runtime_disposed", "PythonRuntime has been released", null);
                    }
                });
                try {
                    if (generation == worker.generation) android.os.Process.killProcess(worker.pid);
                } catch (Throwable ignored) {
                }
            }
        }, timeoutMs + 2_000L, TimeUnit.MILLISECONDS);
        ScheduledFuture<?> previous = hardTimeouts.put(jobId, timeout);
        if (previous != null) {
            previous.cancel(false);
        }
        if (!jobResults.containsKey(jobId) && hardTimeouts.remove(jobId, timeout)) {
            timeout.cancel(false);
        }
    }

    private Map<String, Object> decodeResult(Bundle bundle) {
        Map<String, Object> result = new HashMap<>();
        for (String key : bundle.keySet()) {
            Object value = bundle.get(key);
            if (value instanceof byte[] && !"binaryValue".equals(key)) {
                value = new String((byte[]) value, StandardCharsets.UTF_8);
            }
            result.put(key, value);
        }
        Object pathsValue = result.get("moduleSearchPaths");
        if (pathsValue instanceof String) {
            List<String> paths = new ArrayList<>();
            for (String path : ((String) pathsValue).split("\\n")) {
                if (!path.isEmpty()) {
                    paths.add(path);
                }
            }
            result.put("moduleSearchPaths", paths);
        }
        return result;
    }

    private File preparePythonHome() throws Exception {
        synchronized (RUNTIME_INSTALL_LOCK) {
            String abi = null;
            for (String candidate : Build.SUPPORTED_ABIS) {
                if ("arm64-v8a".equals(candidate) || "x86_64".equals(candidate)) {
                    abi = candidate;
                    break;
                }
            }
            if (abi == null) {
                throw new IllegalStateException("Unsupported Android ABI: " + Arrays.toString(Build.SUPPORTED_ABIS));
            }
            String assetName = "python/python-home-" + abi + ".zip";
            File target = new File(context.getFilesDir(), "cpython_runtime/python-3.14.7-" + abi);
            File marker = new File(target, ".installed");
            File staging = new File(target.getParentFile(), target.getName() + ".installing");
            File archive = File.createTempFile("cpython_home_", ".zip", context.getCacheDir());
            try {
                MessageDigest digest = MessageDigest.getInstance("SHA-256");
                try (InputStream input = new DigestInputStream(context.getAssets().open(assetName), digest);
                     FileOutputStream output = new FileOutputStream(archive)) {
                    copy(input, output);
                }
                String signature = "zipfile-v2:3.14.7:" + abi + ":"
                        + android.util.Base64.encodeToString(digest.digest(), android.util.Base64.NO_WRAP);
                if (marker.isFile() && signature.equals(readText(marker)) && hasPythonHomeFiles(target)) {
                    pythonHome = target;
                    return target;
                }
                if (staging.exists()) deleteRecursively(staging);
                require(staging.mkdirs(), "Cannot create Python Home: " + staging);
                String root = staging.getCanonicalPath() + File.separator;
                try (ZipFile zip = new ZipFile(archive)) {
                    Enumeration<? extends ZipEntry> entries = zip.entries();
                    byte[] buffer = new byte[8192];
                    while (entries.hasMoreElements()) {
                        ZipEntry entry = entries.nextElement();
                        File output = new File(staging, entry.getName()).getCanonicalFile();
                        require(output.getPath().startsWith(root), "Unsafe path in Python Home archive: " + entry.getName());
                        if (entry.isDirectory()) {
                            require(output.mkdirs() || output.isDirectory(), "Cannot create " + output);
                        } else {
                            File parent = Objects.requireNonNull(output.getParentFile());
                            require(parent.mkdirs() || parent.isDirectory(), "Cannot create " + parent);
                            CRC32 crc = new CRC32();
                            long size = 0;
                            try (InputStream input = zip.getInputStream(entry);
                                 FileOutputStream stream = new FileOutputStream(output)) {
                                int count;
                                while ((count = input.read(buffer)) != -1) {
                                    stream.write(buffer, 0, count);
                                    crc.update(buffer, 0, count);
                                    size += count;
                                }
                            }
                            require(size == entry.getSize() && crc.getValue() == entry.getCrc(),
                                    "Python Home archive entry is damaged: " + entry.getName());
                        }
                    }
                }
                require(hasPythonHomeFiles(staging), "Python Home archive is incomplete");
                writeText(new File(staging, ".installed"), signature);
                if (target.exists()) deleteRecursively(target);
                require(staging.renameTo(target), "Cannot install Python Home: " + target);
                pythonHome = target;
                return target;
            } finally {
                archive.delete();
                if (staging.exists()) deleteRecursively(staging);
            }
        }
    }

    private static boolean hasPythonHomeFiles(File home) {
        for (String path : Arrays.asList(
                "os.py", "encodings/__init__.py", "encodings/utf_8.py",
                "json/__init__.py", "json/encoder.py", "json/decoder.py", "json/scanner.py")) {
            File file = new File(home, "lib/python3.14/" + path);
            if (!file.isFile() || file.length() == 0) return false;
        }
        return true;
    }

    private File prepareProjectArchive(String kind, String location) throws Exception {
        File target = File.createTempFile("cpython_project_", ".zip", context.getCacheDir());
        try {
            switch (kind) {
                case "archive":
                    copyToFile(new FileInputStream(new File(location)), target);
                    break;
                case "asset":
                    String assetPath = flutterAssets.getAssetFilePathByName(location);
                    copyToFile(context.getAssets().open(assetPath), target);
                    break;
                default:
                    throw new IllegalArgumentException("Unsupported Python project source: " + kind);
            }
            validateArchive(target);
            return target;
        } catch (Exception error) {
            target.delete();
            throw error;
        }
    }

    private void copyToFile(InputStream input, File target) throws Exception {
        try (InputStream source = input; FileOutputStream output = new FileOutputStream(target)) {
            byte[] buffer = new byte[8192];
            int count;
            while ((count = source.read(buffer)) >= 0) {
                output.write(buffer, 0, count);
            }
        }
    }

    private void validateArchive(File archive) throws Exception {
        try (ZipFile zip = new ZipFile(archive)) {
            require(zip.size() > 0, "Python project archive is empty");
        }
        try (ZipInputStream zip = new ZipInputStream(new FileInputStream(archive))) {
            ZipEntry entry;
            while ((entry = zip.getNextEntry()) != null) {
                String name = entry.getName().replace('\\', '/');
                require(!name.startsWith("/") && !Arrays.asList(name.split("/")).contains(".."),
                        "Unsafe path in Python project archive: " + entry.getName());
                zip.closeEntry();
            }
        }
    }

    @SuppressWarnings("unchecked")
    private Bundle argumentsBundle(MethodCall call) {
        Bundle bundle = new Bundle();
        if (!(call.arguments instanceof Map)) {
            return bundle;
        }
        for (Map.Entry<?, ?> entry : ((Map<?, ?>) call.arguments).entrySet()) {
            if (!(entry.getKey() instanceof String)) {
                continue;
            }
            String key = (String) entry.getKey();
            Object value = entry.getValue();
            if (value instanceof String) {
                bundle.putString(key, (String) value);
            } else if (value instanceof Boolean) {
                bundle.putBoolean(key, (Boolean) value);
            } else if (value instanceof Number) {
                bundle.putLong(key, ((Number) value).longValue());
            } else if (value instanceof List) {
                ArrayList<String> strings = new ArrayList<>();
                for (Object item : (List<Object>) value) {
                    if (item instanceof String) {
                        strings.add((String) item);
                    }
                }
                bundle.putStringArrayList(key, strings);
            }
        }
        return bundle;
    }

    private WorkerHandle connectedWorker() {
        require(worker != null && worker.connected, "PythonRuntime has no connected worker");
        return worker;
    }

    private void failJobsForWorker(WorkerHandle worker, String message) {
        if (!recovering) {
            recovering = true;
            Map<String, Object> event = new HashMap<>();
            event.put("kind", "event");
            event.put("name", "sessionsInvalidated");
            emit(event);
        }
        List<Long> failedJobs = new ArrayList<>();
        for (Map.Entry<Long, WorkerHandle> entry : jobWorkers.entrySet()) {
            if (entry.getValue() == worker) {
                failedJobs.add(entry.getKey());
            }
        }
        for (Long jobId : failedJobs) {
            clearHostCalls(jobId);
            jobWorkers.remove(jobId);
            jobTimeouts.remove(jobId);
            ScheduledFuture<?> timeout = hardTimeouts.remove(jobId);
            if (timeout != null) {
                timeout.cancel(false);
            }
            MethodChannel.Result pending = jobResults.remove(jobId);
            if (pending != null) {
                mainHandler.post(() -> pending.error("python_worker_crashed", message, null));
            }
            Map<String, Object> event = new HashMap<>();
            event.put("kind", "state");
            event.put("jobId", jobId);
            event.put("state", "workerCrashed");
            emit(event);
        }
        for (Map.Entry<Long, WorkerHandle> entry : sessionWorkers.entrySet()) {
            if (entry.getValue() == worker) {
                sessionWorkers.remove(entry.getKey(), worker);
            }
        }
    }

    private void emit(Map<String, Object> event) {
        EventChannel.EventSink sink = eventSink;
        if (sink == null) {
            pendingEvents.addLast(event);
        } else {
            sink.success(event);
        }
    }

    private void clearHostCalls(long jobId) {
        for (Map.Entry<Long, Long> entry : hostCallJobs.entrySet()) {
            if (entry.getValue() == jobId) {
                hostCallWorkers.remove(entry.getKey());
                hostCallJobs.remove(entry.getKey());
            }
        }
    }

    @Override
    public void onListen(Object arguments, EventChannel.EventSink sink) {
        eventSink = sink;
        while (!pendingEvents.isEmpty()) {
            sink.success(pendingEvents.removeFirst());
        }
    }

    @Override
    public void onCancel(Object arguments) {
        eventSink = null;
    }

    private String requiredString(MethodCall call, String name) {
        String value = call.argument(name);
        if (value == null) {
            throw new IllegalArgumentException(name + " must be a String");
        }
        return value;
    }

    private Number requiredNumber(MethodCall call, String name) {
        Number value = call.argument(name);
        if (value == null) {
            throw new IllegalArgumentException(name + " must be a number");
        }
        return value;
    }

    private void requireInitialized() {
        if (!initialized) {
            throw new IllegalStateException("PythonRuntime has not been initialized");
        }
    }

    private void postError(MethodChannel.Result result, String code, Throwable error) {
        mainHandler.post(() -> result.error(code, error.getMessage(), stackTrace(error)));
    }

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        methods.setMethodCallHandler(null);
        events.setStreamHandler(null);
        if (!disposing) {
            disposeRuntime(new MethodChannel.Result() {
                @Override
                public void success(Object value) {}

                @Override
                public void error(String code, String message, Object details) {}

                @Override
                public void notImplemented() {}
            });
        }
        ioExecutor.shutdownNow();
        timeoutExecutor.shutdownNow();
    }

    private long nativeId(long localId) {
        return (engineId << 32) | (localId & 0xffffffffL);
    }

    private long localId(long nativeId) {
        return nativeId & 0xffffffffL;
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new IllegalArgumentException(message);
        }
    }

    private static void copy(InputStream input, java.io.OutputStream output) throws Exception {
        byte[] buffer = new byte[8192];
        int count;
        while ((count = input.read(buffer)) >= 0) {
            output.write(buffer, 0, count);
        }
    }

    private static String readText(File file) throws Exception {
        try (FileInputStream input = new FileInputStream(file)) {
            byte[] bytes = new byte[(int) file.length()];
            int offset = 0;
            while (offset < bytes.length) {
                int count = input.read(bytes, offset, bytes.length - offset);
                if (count < 0) {
                    break;
                }
                offset += count;
            }
            return new String(bytes, 0, offset, StandardCharsets.UTF_8);
        }
    }

    private static void writeText(File file, String value) throws Exception {
        try (FileOutputStream output = new FileOutputStream(file)) {
            output.write(value.getBytes(StandardCharsets.UTF_8));
        }
    }

    private static void deleteRecursively(File file) {
        if (file.isDirectory()) {
            File[] children = file.listFiles();
            if (children != null) {
                for (File child : children) {
                    deleteRecursively(child);
                }
            }
        }
        if (!file.delete() && file.exists()) {
            throw new IllegalStateException("Cannot delete " + file);
        }
    }

    private static String stackTrace(Throwable error) {
        java.io.StringWriter writer = new java.io.StringWriter();
        error.printStackTrace(new java.io.PrintWriter(writer));
        return writer.toString();
    }

    private static final class WorkerHandle {
        volatile IPythonWorker remote;
        ServiceConnection connection;
        volatile boolean connected;
        long generation;
        int pid;
    }

    private static final class ProjectRecord {
        final File path;
        final boolean archive;

        ProjectRecord(File path, boolean archive) {
            this.path = path;
            this.archive = archive;
        }

        void load(IPythonWorker remote, long projectId) throws Exception {
            if (archive) {
                try (ParcelFileDescriptor descriptor = ParcelFileDescriptor.open(path, ParcelFileDescriptor.MODE_READ_ONLY)) {
                    remote.loadProject(projectId, null, descriptor);
                }
            } else {
                remote.loadProject(projectId, path.getAbsolutePath(), null);
            }
        }

        void release() {
            if (archive) path.delete();
        }
    }
}
