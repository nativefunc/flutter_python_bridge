package dev.cpythonruntime.cpython_runtime;

import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import dev.cpythonruntime.cpython_runtime.IPythonWorkerCallback;

interface IPythonWorker {
    int getPid();
    void initializeRuntime(String pythonHome, String workingDirectory);
    void loadProject(long projectId, String directory, in ParcelFileDescriptor archive);
    void execute(in Bundle request, IPythonWorkerCallback callback);
    void interrupt(long jobId);
    void destroySession(long sessionId);
    void completeHostCall(long callId, String resultJson, String error);
    Bundle getRuntimeInfo();
}
