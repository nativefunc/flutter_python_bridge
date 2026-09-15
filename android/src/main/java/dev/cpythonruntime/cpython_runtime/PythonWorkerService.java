package dev.cpythonruntime.cpython_runtime;

import android.app.Service;
import android.content.Intent;
import android.os.Bundle;
import android.os.IBinder;
import android.os.ParcelFileDescriptor;
import android.os.Parcel;
import android.os.Process;
import android.os.RemoteException;
import android.system.Os;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

public abstract class PythonWorkerService extends Service implements PythonBridge.Listener {
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final ScheduledExecutorService timer = Executors.newSingleThreadScheduledExecutor();
    private final Object jobStateLock = new Object();
    private final ConcurrentHashMap<Long, IPythonWorkerCallback> callbacks = new ConcurrentHashMap<>();
    private final Set<Long> knownJobs = ConcurrentHashMap.newKeySet();
    private final Set<Long> timedOutJobs = ConcurrentHashMap.newKeySet();
    private final Set<Long> cancelledJobs = ConcurrentHashMap.newKeySet();
    private final ConcurrentHashMap<Long, ProjectSource> projects = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Long, Long> hostCalls = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Long, Long> hostCallJobs = new ConcurrentHashMap<>();
    private volatile String pythonHome;
    private volatile String defaultWorkingDirectory;
    private long activeJobId;

    private final IPythonWorker.Stub binder = new IPythonWorker.Stub() {
        @Override
        public int getPid() {
            return Process.myPid();
        }

        @Override
        public void initializeRuntime(String requestedPythonHome, String workingDirectory) {
            String initializedHome = pythonHome;
            if (initializedHome != null) {
                require(initializedHome.equals(requestedPythonHome),
                        "Python Worker is already initialized with another Python Home");
                require(new File(workingDirectory).isDirectory(),
                        "Invalid Python working directory: " + workingDirectory);
                defaultWorkingDirectory = workingDirectory;
                return;
            }
            require(new File(requestedPythonHome, "lib/python3.14/os.py").isFile(),
                    "Invalid Python Home: " + requestedPythonHome);
            require(new File(workingDirectory).isDirectory(),
                    "Invalid Python working directory: " + workingDirectory);
            try {
                Os.setenv("TMPDIR", getCacheDir().getAbsolutePath(), true);
            } catch (android.system.ErrnoException error) {
                throw new IllegalStateException(error);
            }
            PythonBridge.getRuntimeInfo(requestedPythonHome.getBytes(StandardCharsets.UTF_8));
            pythonHome = requestedPythonHome;
            defaultWorkingDirectory = workingDirectory;
        }

        @Override
        public void loadProject(long projectId, String directory, ParcelFileDescriptor archive) {
            try {
                require((directory == null) != (archive == null), "Exactly one project source is required");
                if (directory != null) {
                    File root = new File(directory);
                    require(root.isAbsolute() && root.isDirectory() && root.canRead(),
                            "Invalid Python project directory: " + directory);
                }
                ProjectSource previous = projects.put(projectId, new ProjectSource(directory, archive));
                if (previous != null) close(previous.archive);
            } catch (RuntimeException error) {
                close(archive);
                throw error;
            }
        }

        @Override
        public void execute(Bundle request, IPythonWorkerCallback callback) throws RemoteException {
            long jobId = request.getLong("jobId");
            callbacks.put(jobId, callback);
            synchronized (jobStateLock) {
                knownJobs.add(jobId);
            }
            executor.execute(() -> runJob(request, callback));
        }

        @Override
        public void interrupt(long jobId) {
            boolean active;
            synchronized (jobStateLock) {
                require(knownJobs.contains(jobId), "Python job " + jobId + " is not active");
                cancelledJobs.add(jobId);
                active = activeJobId == jobId;
            }
            if (active) {
                try {
                    PythonBridge.interrupt(jobId);
                } catch (RuntimeException ignored) {
                }
            }
        }

        @Override
        public void destroySession(long sessionId) {
            try {
                executor.submit(() -> PythonBridge.destroyContext(sessionId)).get();
            } catch (Exception error) {
                throw new IllegalStateException("Unable to close Python session", error);
            }
        }

        @Override
        public void completeHostCall(long callId, String resultJson, String error) {
            Long localCallId = hostCalls.remove(callId);
            hostCallJobs.remove(callId);
            if (localCallId == null) {
                return;
            }
            PythonBridge.completeHostCall(
                    localCallId,
                    resultJson == null ? null : resultJson.getBytes(StandardCharsets.UTF_8),
                    error == null ? null : error.getBytes(StandardCharsets.UTF_8)
            );
        }

        @Override
        public Bundle getRuntimeInfo() {
            Map<String, Object> nativeResult = PythonBridge.getRuntimeInfo(
                    requirePythonHome().getBytes(StandardCharsets.UTF_8)
            );
            Bundle bundle = nativeResultBundle(nativeResult);
            bundle.putInt("pid", Process.myPid());
            return bundle;
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        PythonBridge.addListener(this);
    }

    @Override
    public IBinder onBind(Intent intent) {
        return binder;
    }

    private void runJob(Bundle request, IPythonWorkerCallback callback) {
        long jobId = request.getLong("jobId");
        ScheduledFuture<?> timeoutTask = null;
        try {
            boolean cancelledBeforeStart;
            synchronized (jobStateLock) {
                cancelledBeforeStart = cancelledJobs.remove(jobId);
                if (!cancelledBeforeStart) {
                    activeJobId = jobId;
                }
            }
            if (cancelledBeforeStart) {
                sendState(callback, jobId, "cancelled");
                callback.onResult(controlResult(
                        "cancelled",
                        130,
                        "PythonCancelledError",
                        "Python 任务已取消"
                ));
                return;
            }
            sendState(callback, jobId, "running");
            long timeoutMs = request.getLong("timeoutMs", 30_000L);
            if (timeoutMs > 0) {
                timeoutTask = timer.schedule(() -> {
                    boolean active;
                    synchronized (jobStateLock) {
                        active = activeJobId == jobId;
                        if (active) {
                            timedOutJobs.add(jobId);
                        }
                    }
                    if (active) {
                        try {
                            PythonBridge.interrupt(jobId);
                        } catch (Throwable ignored) {
                        }
                    }
                }, timeoutMs, TimeUnit.MILLISECONDS);
            }
            PreparedSource prepared = prepareSource(request);
            ArrayList<String> arguments = request.getStringArrayList("arguments");
            Map<String, Object> nativeResult = PythonBridge.execute(
                    requirePythonHome().getBytes(StandardCharsets.UTF_8),
                    jobId,
                    request.getLong("sessionId", 0L),
                    prepared.evaluate,
                    prepared.source.getBytes(StandardCharsets.UTF_8),
                    prepared.filename.getBytes(StandardCharsets.UTF_8),
                    new JSONArray(arguments == null ? Collections.emptyList() : arguments)
                            .toString().getBytes(StandardCharsets.UTF_8),
                    request.getString("workingDirectory", requireWorkingDirectory())
                            .getBytes(StandardCharsets.UTF_8),
                    prepared.projectPath == null ? null : prepared.projectPath.getBytes(StandardCharsets.UTF_8)
            );
            int exitCode = ((Number) nativeResult.get("exitCode")).intValue();
            String state;
            synchronized (jobStateLock) {
                if (activeJobId == jobId) {
                    activeJobId = 0L;
                }
                if (timedOutJobs.remove(jobId)) {
                    state = "timedOut";
                } else if (cancelledJobs.remove(jobId)) {
                    state = "cancelled";
                } else if (exitCode == 0) {
                    state = "completed";
                } else {
                    state = "failed";
                }
            }
            Bundle result = nativeResultBundle(nativeResult);
            result.putString("state", state);
            if ("timedOut".equals(state) || "cancelled".equals(state)) {
                boolean timedOut = "timedOut".equals(state);
                result.putInt("exitCode", timedOut ? 124 : 130);
                result.putString("exceptionType", timedOut ? "PythonTimeoutError" : "PythonCancelledError");
                result.putString("exceptionMessage", timedOut ? "Python 任务超时" : "Python 任务已取消");
                result.putString("traceback", "");
            }
            Parcel parcel = Parcel.obtain();
            try {
                result.writeToParcel(parcel, 0);
                require(parcel.dataSize() <= 256 * 1024, "Python result exceeds the transport limit");
            } finally {
                parcel.recycle();
            }
            sendState(callback, jobId, state);
            callback.onResult(result);
        } catch (Throwable error) {
            sendState(callback, jobId, "failed");
            try {
                callback.onError(
                        "python_worker_error",
                        error.getMessage() == null ? error.getClass().getSimpleName() : error.getMessage(),
                        stackTrace(error)
                );
            } catch (RemoteException ignored) {
            }
        } finally {
            if (timeoutTask != null) {
                timeoutTask.cancel(false);
            }
            synchronized (jobStateLock) {
                if (activeJobId == jobId) {
                    activeJobId = 0L;
                }
                knownJobs.remove(jobId);
                timedOutJobs.remove(jobId);
                cancelledJobs.remove(jobId);
            }
            callbacks.remove(jobId);
            for (Map.Entry<Long, Long> entry : hostCallJobs.entrySet()) {
                if (entry.getValue() == jobId) {
                    hostCalls.remove(entry.getKey());
                    hostCallJobs.remove(entry.getKey());
                }
            }
        }
    }

    private Bundle controlResult(String state, int exitCode, String type, String message) {
        Bundle result = new Bundle();
        result.putInt("exitCode", exitCode);
        result.putByteArray("stdout", new byte[0]);
        result.putByteArray("stderr", new byte[0]);
        result.putString("state", state);
        result.putString("exceptionType", type);
        result.putString("exceptionMessage", message);
        result.putString("traceback", "");
        return result;
    }

    private void sendState(IPythonWorkerCallback callback, long jobId, String state) {
        Bundle event = new Bundle();
        event.putString("kind", "state");
        event.putLong("jobId", jobId);
        event.putString("state", state);
        sendEvent(callback, event);
    }

    private PreparedSource prepareSource(Bundle request) {
        String mode = request.getString("mode", "exec");
        long projectId = request.getLong("projectId", 0L);
        String projectPath = null;
        if (projectId != 0L) {
            ProjectSource project = projects.get(projectId);
            if (project == null) {
                throw new IllegalStateException("Python project " + projectId + " is not loaded in this worker");
            }
            projectPath = project.directory != null ? project.directory : descriptorPath(project.archive);
        }
        if ("call".equals(mode)) {
            String entrypoint = request.getString("entrypoint");
            if (entrypoint == null) {
                throw new IllegalArgumentException("entrypoint is required for call mode");
            }
            int separator = entrypoint.lastIndexOf(':');
            require(separator > 0 && separator < entrypoint.length() - 1,
                    "entrypoint must use module.path:function format");
            String module = entrypoint.substring(0, separator);
            String function = entrypoint.substring(separator + 1);
            require(module.matches("[A-Za-z_][A-Za-z0-9_.]*"), "Invalid module name");
            require(function.matches("[A-Za-z_][A-Za-z0-9_]*"), "Invalid function name");
            String argumentsJson = request.getString("argumentsJson", "[]");
            String namedArgumentsJson = request.getString("namedArgumentsJson", "{}");
            require(projectPath != null, "call mode requires a Python project");
            String source = "getattr(__import__('importlib').import_module(" + JSONObject.quote(module) + "), "
                    + JSONObject.quote(function) + ")(*__import__('json').loads("
                    + JSONObject.quote(argumentsJson) + "), **__import__('json').loads("
                    + JSONObject.quote(namedArgumentsJson) + "))";
            return new PreparedSource(source, true, "<" + entrypoint + ">", projectPath);
        }
        String original = request.getString("source", "");
        String defaultFilename = "eval".equals(mode) ? "<python-eval>" : "<python>";
        return new PreparedSource(
                original,
                "eval".equals(mode),
                request.getString("filename", defaultFilename),
                projectPath
        );
    }

    private String requirePythonHome() {
        if (pythonHome == null) {
            throw new IllegalStateException("Python worker runtime has not been initialized");
        }
        return pythonHome;
    }

    private String requireWorkingDirectory() {
        if (defaultWorkingDirectory == null) {
            throw new IllegalStateException("Python worker runtime has not been initialized");
        }
        return defaultWorkingDirectory;
    }

    private String descriptorPath(ParcelFileDescriptor descriptor) {
        return "/proc/self/fd/" + descriptor.getFd();
    }

    private Bundle nativeResultBundle(Map<String, Object> nativeResult) {
        Bundle bundle = new Bundle();
        for (Map.Entry<String, Object> entry : nativeResult.entrySet()) {
            String key = entry.getKey();
            Object value = entry.getValue();
            if (value instanceof byte[]) {
                bundle.putByteArray(key, (byte[]) value);
            } else if (value instanceof Integer) {
                bundle.putInt(key, (Integer) value);
            } else if (value instanceof Long) {
                bundle.putLong(key, (Long) value);
            } else if (value instanceof Boolean) {
                bundle.putBoolean(key, (Boolean) value);
            } else if (value instanceof String) {
                bundle.putString(key, (String) value);
            }
        }
        return bundle;
    }

    @Override
    public void onOutput(long jobId, int stream, byte[] utf8) {
        IPythonWorkerCallback callback = callbacks.get(jobId);
        if (callback == null) {
            return;
        }
        Bundle event = new Bundle();
        event.putString("kind", "output");
        event.putLong("jobId", jobId);
        event.putString("stream", stream == 2 ? "stderr" : "stdout");
        event.putByteArray("utf8", utf8);
        sendEvent(callback, event);
    }

    @Override
    public boolean isInterrupted(long jobId) {
        synchronized (jobStateLock) {
            return cancelledJobs.contains(jobId) || timedOutJobs.contains(jobId);
        }
    }

    @Override
    public void onEvent(long jobId, long sessionId, String name, byte[] jsonUtf8) {
        IPythonWorkerCallback callback = callbacks.get(jobId);
        if (callback == null) {
            return;
        }
        Bundle event = new Bundle();
        event.putString("kind", "event");
        event.putLong("jobId", jobId);
        event.putLong("sessionId", sessionId);
        event.putString("name", name);
        event.putByteArray("jsonUtf8", jsonUtf8);
        sendEvent(callback, event);
    }

    @Override
    public void onMethodCall(long callId, long jobId, long sessionId, String method, byte[] jsonUtf8) {
        long externalCallId = ((long) Process.myPid() << 32) | (callId & 0xffffffffL);
        hostCalls.put(externalCallId, callId);
        hostCallJobs.put(externalCallId, jobId);
        IPythonWorkerCallback callback = callbacks.get(jobId);
        if (callback == null) {
            hostCalls.remove(externalCallId);
            hostCallJobs.remove(externalCallId);
            timer.execute(() -> PythonBridge.completeHostCall(callId, null,
                    "Python job has ended".getBytes(StandardCharsets.UTF_8)));
            return;
        }
        Bundle event = new Bundle();
        event.putString("kind", "methodCall");
        event.putLong("callId", externalCallId);
        event.putLong("jobId", jobId);
        event.putLong("sessionId", sessionId);
        event.putString("method", method);
        event.putByteArray("jsonUtf8", jsonUtf8);
        try {
            Parcel parcel = Parcel.obtain();
            try {
                event.writeToParcel(parcel, 0);
                require(parcel.dataSize() <= 128 * 1024, "Flutter method call exceeds the transport limit");
            } finally {
                parcel.recycle();
            }
            callback.onEvent(event);
        } catch (Exception error) {
            hostCalls.remove(externalCallId);
            hostCallJobs.remove(externalCallId);
            timer.execute(() -> PythonBridge.completeHostCall(callId, null,
                    "Unable to deliver Flutter method call".getBytes(StandardCharsets.UTF_8)));
        }
    }

    private void sendEvent(IPythonWorkerCallback callback, Bundle event) {
        try {
            callback.onEvent(event);
        } catch (RemoteException ignored) {
        }
    }

    @Override
    public void onDestroy() {
        PythonBridge.removeListener(this);
        executor.shutdownNow();
        timer.shutdownNow();
        for (ProjectSource project : projects.values()) {
            close(project.archive);
        }
        projects.clear();
        hostCalls.clear();
        super.onDestroy();
        Process.killProcess(Process.myPid());
    }

    private static void close(ParcelFileDescriptor descriptor) {
        if (descriptor == null) {
            return;
        }
        try {
            descriptor.close();
        } catch (Exception ignored) {
        }
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new IllegalArgumentException(message);
        }
    }

    private static String stackTrace(Throwable error) {
        java.io.StringWriter writer = new java.io.StringWriter();
        error.printStackTrace(new java.io.PrintWriter(writer));
        return writer.toString();
    }

    private static final class ProjectSource {
        final String directory;
        final ParcelFileDescriptor archive;

        ProjectSource(String directory, ParcelFileDescriptor archive) {
            this.directory = directory;
            this.archive = archive;
        }
    }

    private static final class PreparedSource {
        final String source;
        final boolean evaluate;
        final String filename;
        final String projectPath;

        PreparedSource(String source, boolean evaluate, String filename, String projectPath) {
            this.source = source;
            this.evaluate = evaluate;
            this.filename = filename;
            this.projectPath = projectPath;
        }
    }
}
