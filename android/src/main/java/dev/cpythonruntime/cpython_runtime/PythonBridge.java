package dev.cpythonruntime.cpython_runtime;

import java.util.Map;
import java.util.concurrent.CopyOnWriteArraySet;

final class PythonBridge {
    interface Listener {
        boolean isInterrupted(long jobId);
        void onOutput(long jobId, int stream, byte[] utf8);
        void onEvent(long jobId, long sessionId, String name, byte[] jsonUtf8);
        void onMethodCall(long callId, long jobId, long sessionId, String method, byte[] jsonUtf8);
    }

    private static final CopyOnWriteArraySet<Listener> listeners = new CopyOnWriteArraySet<>();

    static {
        System.loadLibrary("cpython_runtime");
    }

    private PythonBridge() {}

    static void addListener(Listener value) { listeners.add(value); }
    static void removeListener(Listener value) { listeners.remove(value); }

    @SuppressWarnings("unused")
    private static boolean isInterrupted(long jobId) {
        for (Listener listener : listeners) {
            if (listener.isInterrupted(jobId)) return true;
        }
        return false;
    }

    @SuppressWarnings("unused")
    private static void dispatchOutput(long jobId, int stream, byte[] utf8) {
        for (Listener listener : listeners) listener.onOutput(jobId, stream, utf8);
    }

    @SuppressWarnings("unused")
    private static void dispatchEvent(
        long jobId, long sessionId, String name, byte[] jsonUtf8
    ) {
        for (Listener listener : listeners) {
            listener.onEvent(jobId, sessionId, name, jsonUtf8);
        }
    }

    @SuppressWarnings("unused")
    private static void dispatchMethodCall(
        long callId, long jobId, long sessionId, String method, byte[] jsonUtf8
    ) {
        for (Listener listener : listeners) {
            listener.onMethodCall(callId, jobId, sessionId, method, jsonUtf8);
        }
    }

    static native Map<String, Object> execute(
        byte[] pythonHomeUtf8,
        long jobId,
        long sessionId,
        boolean evaluate,
        byte[] sourceUtf8,
        byte[] filenameUtf8,
        byte[] argumentsJsonUtf8,
        byte[] workingDirectoryUtf8,
        byte[] projectPathUtf8
    );

    static native void interrupt(long jobId);
    static native void destroyContext(long sessionId);
    static native void completeHostCall(long callId, byte[] resultJsonUtf8, byte[] errorUtf8);
    static native Map<String, Object> getRuntimeInfo(byte[] pythonHomeUtf8);
}
