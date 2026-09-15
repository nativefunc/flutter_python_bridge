package dev.cpythonruntime.cpython_runtime;

import android.os.Bundle;

oneway interface IPythonWorkerCallback {
    void onEvent(in Bundle event);
    void onResult(in Bundle result);
    void onError(String code, String message, String details);
}
