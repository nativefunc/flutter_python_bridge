#include <jni.h>
#include <Python.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    char *data;
    size_t length;
    size_t capacity;
    int truncated;
} Buffer;

typedef struct {
    long long id;
    long long session_id;
    int interrupted;
    unsigned long thread_id;
    PyObject *owner;
    Buffer stdout_buffer;
    Buffer stderr_buffer;
} Operation;

typedef struct Context {
    long long id;
    PyObject *globals;
    struct Context *next;
} Context;

static JavaVM *java_vm = NULL;
static jclass bridge_class = NULL;
static jmethodID dispatch_output_method = NULL;
static jmethodID dispatch_event_method = NULL;
static jmethodID dispatch_method_call_method = NULL;
static pthread_mutex_t initialization_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t operation_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t host_call_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t host_call_condition = PTHREAD_COND_INITIALIZER;
static int python_initialized = 0;
static Operation *active_operation = NULL;
static Context *contexts = NULL;
static long long next_host_call_id = 1;

typedef struct {
    long long id;
    long long operation_id;
    int completed;
    char *result_json;
    char *error;
} HostCall;

static HostCall pending_host_call = {0};
static PyObject *json_result(PyObject *value);

static int buffer_append(Buffer *buffer, const char *data, size_t length) {
    size_t available = buffer->truncated ? 0 : 32 * 1024 - buffer->length;
    if (length > available) {
        buffer->truncated = 1;
        while (available > 0 && ((unsigned char)data[available] & 0xc0) == 0x80) available--;
        length = available;
    }
    if (length == 0) return 1;
    if (length > SIZE_MAX - buffer->length - 1) return 0;
    size_t required = buffer->length + length + 1;
    if (required > buffer->capacity) {
        size_t capacity = buffer->capacity ? buffer->capacity : 256;
        while (capacity < required) {
            if (capacity > SIZE_MAX / 2) {
                capacity = required;
                break;
            }
            capacity *= 2;
        }
        char *resized = (char *)realloc(buffer->data, capacity);
        if (resized == NULL) return 0;
        buffer->data = resized;
        buffer->capacity = capacity;
    }
    memcpy(buffer->data + buffer->length, data, length);
    buffer->length += length;
    buffer->data[buffer->length] = '\0';
    return 1;
}

static void buffer_clear(Buffer *buffer) {
    free(buffer->data);
    memset(buffer, 0, sizeof(*buffer));
}

static char *copy_java_bytes(JNIEnv *env, jbyteArray input, jsize *size_out) {
    if (input == NULL) {
        *size_out = 0;
        return NULL;
    }
    jsize size = (*env)->GetArrayLength(env, input);
    char *result = (char *)malloc((size_t)size + 1);
    if (result == NULL) return NULL;
    (*env)->GetByteArrayRegion(env, input, 0, size, (jbyte *)result);
    result[size] = '\0';
    *size_out = size;
    return result;
}

static void throw_runtime_exception(JNIEnv *env, const char *message) {
    jclass cls = (*env)->FindClass(env, "java/lang/RuntimeException");
    (*env)->ThrowNew(env, cls, message ? message : "Unknown CPython error");
}

static JNIEnv *get_jni_env(int *attached) {
    JNIEnv *env = NULL;
    *attached = 0;
    if ((*java_vm)->GetEnv(java_vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        if ((*java_vm)->AttachCurrentThread(java_vm, &env, NULL) != JNI_OK) return NULL;
        *attached = 1;
    }
    return env;
}

static void dispatch_output(long long operation_id, int stream, const char *data, size_t length) {
    if (bridge_class == NULL || dispatch_output_method == NULL || length == 0) return;
    int attached;
    JNIEnv *env = get_jni_env(&attached);
    if (env == NULL) return;
    size_t offset = 0;
    while (offset < length) {
        size_t remaining = length - offset;
        size_t chunk = remaining > 64 * 1024 ? 64 * 1024 : remaining;
        if (chunk < remaining) {
            while (chunk > 0 && ((unsigned char)data[offset + chunk] & 0xc0) == 0x80) chunk--;
        }
        jbyteArray bytes = (*env)->NewByteArray(env, (jsize)chunk);
        if (bytes == NULL) break;
        (*env)->SetByteArrayRegion(
            env, bytes, 0, (jsize)chunk, (const jbyte *)(data + offset));
        (*env)->CallStaticVoidMethod(
            env, bridge_class, dispatch_output_method,
            (jlong)operation_id, (jint)stream, bytes);
        (*env)->DeleteLocalRef(env, bytes);
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            break;
        }
        offset += chunk;
    }
    if (attached) (*java_vm)->DetachCurrentThread(java_vm);
}

static void dispatch_event(
    long long operation_id, long long session_id,
    const char *name, const char *json, size_t json_length
) {
    if (bridge_class == NULL || dispatch_event_method == NULL) return;
    int attached;
    JNIEnv *env = get_jni_env(&attached);
    if (env == NULL) return;
    jstring java_name = (*env)->NewStringUTF(env, name);
    jbyteArray bytes = (*env)->NewByteArray(env, (jsize)json_length);
    if (java_name != NULL && bytes != NULL) {
        (*env)->SetByteArrayRegion(env, bytes, 0, (jsize)json_length, (const jbyte *)json);
        (*env)->CallStaticVoidMethod(
            env, bridge_class, dispatch_event_method,
            (jlong)operation_id, (jlong)session_id, java_name, bytes);
    }
    (*env)->DeleteLocalRef(env, java_name);
    (*env)->DeleteLocalRef(env, bytes);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    if (attached) (*java_vm)->DetachCurrentThread(java_vm);
}

static void dispatch_method_call(
    long long call_id, long long operation_id, long long session_id,
    const char *method, const char *json, size_t json_length
) {
    if (bridge_class == NULL || dispatch_method_call_method == NULL) return;
    int attached;
    JNIEnv *env = get_jni_env(&attached);
    if (env == NULL) return;
    jstring java_method = (*env)->NewStringUTF(env, method);
    jbyteArray bytes = (*env)->NewByteArray(env, (jsize)json_length);
    if (java_method != NULL && bytes != NULL) {
        (*env)->SetByteArrayRegion(env, bytes, 0, (jsize)json_length, (const jbyte *)json);
        (*env)->CallStaticVoidMethod(
            env, bridge_class, dispatch_method_call_method,
            (jlong)call_id, (jlong)operation_id, (jlong)session_id, java_method, bytes);
    }
    (*env)->DeleteLocalRef(env, java_method);
    (*env)->DeleteLocalRef(env, bytes);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    if (attached) (*java_vm)->DetachCurrentThread(java_vm);
}

typedef struct {
    PyObject *context;
} BridgeState;

static PyObject *bridge_owner(PyObject *module) {
    if (module == NULL || !PyModule_Check(module)) {
        PyErr_SetString(PyExc_RuntimeError, "Python bridge module is unavailable");
        return NULL;
    }
    BridgeState *state = PyModule_GetState(module);
    PyObject *owner = NULL;
    if (state == NULL || state->context == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "Python bridge context is unavailable");
        return NULL;
    }
    if (PyContextVar_Get(state->context, Py_None, &owner) < 0) return NULL;
    return owner;
}

static PyObject *bridge_write(PyObject *self, PyObject *args) {
    int stream;
    PyObject *text;
    if (!PyArg_ParseTuple(args, "iU", &stream, &text)) return NULL;

    Py_ssize_t length;
    const char *utf8 = PyUnicode_AsUTF8AndSize(text, &length);
    if (utf8 == NULL) return NULL;

    PyObject *owner = bridge_owner(self);
    if (owner == NULL) return NULL;
    long long operation_id = 0;
    int found = 0;
    int appended = 0;
    size_t streamed_length = 0;
    pthread_mutex_lock(&operation_mutex);
    if (active_operation != NULL && active_operation->owner == owner) {
        found = 1;
        operation_id = active_operation->id;
        Buffer *target = stream == 2
            ? &active_operation->stderr_buffer
            : &active_operation->stdout_buffer;
        streamed_length = (size_t)length;
        appended = buffer_append(target, utf8, (size_t)length);
    }
    pthread_mutex_unlock(&operation_mutex);
    Py_DECREF(owner);

    if (found && !appended) {
        PyErr_NoMemory();
        return NULL;
    }
    if (!found) return PyLong_FromSsize_t(PyUnicode_GET_LENGTH(text));
    dispatch_output(operation_id, stream, utf8, streamed_length);
    return PyLong_FromSsize_t(PyUnicode_GET_LENGTH(text));
}

static PyObject *bridge_emit(PyObject *self, PyObject *args) {
    const char *name;
    PyObject *value = Py_None;
    if (!PyArg_ParseTuple(args, "s|O", &name, &value)) return NULL;
    if (strlen(name) > 4096) {
        PyErr_SetString(PyExc_ValueError, "Flutter event or method name exceeds 4096 bytes");
        return NULL;
    }
    PyObject *encoded = json_result(value);
    if (encoded == NULL) return NULL;
    Py_ssize_t length;
    const char *json = PyUnicode_AsUTF8AndSize(encoded, &length);
    if (json == NULL) {
        Py_DECREF(encoded);
        return NULL;
    }
    if (length > 64 * 1024) {
        Py_DECREF(encoded);
        PyErr_SetString(PyExc_ValueError, "flutter.emit payload exceeds 64 KiB");
        return NULL;
    }
    PyObject *owner = bridge_owner(self);
    if (owner == NULL) {
        Py_DECREF(encoded);
        return NULL;
    }
    long long operation_id = 0, session_id = 0;
    pthread_mutex_lock(&operation_mutex);
    if (active_operation != NULL && active_operation->owner == owner) {
        operation_id = active_operation->id;
        session_id = active_operation->session_id;
    }
    pthread_mutex_unlock(&operation_mutex);
    Py_DECREF(owner);
    if (operation_id == 0) {
        Py_DECREF(encoded);
        PyErr_SetString(PyExc_RuntimeError, "Flutter event requires a current Python job context");
        return NULL;
    }
    dispatch_event(operation_id, session_id, name, json, (size_t)length);
    Py_DECREF(encoded);
    Py_RETURN_NONE;
}

static PyObject *bridge_invoke(PyObject *self, PyObject *args) {
    const char *method;
    PyObject *value = Py_None;
    if (!PyArg_ParseTuple(args, "s|O", &method, &value)) return NULL;
    if (strlen(method) > 4096) {
        PyErr_SetString(PyExc_ValueError, "Flutter event or method name exceeds 4096 bytes");
        return NULL;
    }
    PyObject *encoded = json_result(value);
    if (encoded == NULL) return NULL;
    Py_ssize_t length;
    const char *json = PyUnicode_AsUTF8AndSize(encoded, &length);
    if (json == NULL) {
        Py_DECREF(encoded);
        return NULL;
    }
    if (length > 64 * 1024) {
        Py_DECREF(encoded);
        PyErr_SetString(PyExc_ValueError, "flutter.invoke payload exceeds 64 KiB");
        return NULL;
    }

    PyObject *owner = bridge_owner(self);
    if (owner == NULL) {
        Py_DECREF(encoded);
        return NULL;
    }
    pthread_mutex_lock(&host_call_mutex);
    if (pending_host_call.id != 0) {
        pthread_mutex_unlock(&host_call_mutex);
        Py_DECREF(owner);
        Py_DECREF(encoded);
        PyErr_SetString(PyExc_RuntimeError, "another Flutter method call is already pending");
        return NULL;
    }
    long long operation_id = 0, session_id = 0;
    pthread_mutex_lock(&operation_mutex);
    if (active_operation != NULL && active_operation->owner == owner) {
        operation_id = active_operation->id;
        session_id = active_operation->session_id;
    }
    pthread_mutex_unlock(&operation_mutex);
    Py_DECREF(owner);
    if (operation_id == 0) {
        pthread_mutex_unlock(&host_call_mutex);
        Py_DECREF(encoded);
        PyErr_SetString(PyExc_RuntimeError, "Flutter method call requires a current Python job context");
        return NULL;
    }
    pending_host_call.id = next_host_call_id++;
    pending_host_call.operation_id = operation_id;
    long long call_id = pending_host_call.id;
    dispatch_method_call(call_id, operation_id, session_id, method, json, (size_t)length);
    Py_DECREF(encoded);

    PyThreadState *saved_thread = PyEval_SaveThread();
    while (!pending_host_call.completed) {
        pthread_cond_wait(&host_call_condition, &host_call_mutex);
    }
    char *result_json = pending_host_call.result_json;
    char *error = pending_host_call.error;
    memset(&pending_host_call, 0, sizeof(pending_host_call));
    pthread_mutex_unlock(&host_call_mutex);
    PyEval_RestoreThread(saved_thread);

    if (error != NULL) {
        PyErr_SetString(PyExc_RuntimeError, error);
        free(error);
        free(result_json);
        return NULL;
    }
    PyObject *json_module = PyImport_ImportModule("json");
    PyObject *loads = json_module ? PyObject_GetAttrString(json_module, "loads") : NULL;
    PyObject *text = result_json ? PyUnicode_FromString(result_json) : PyUnicode_FromString("null");
    PyObject *result = loads && text ? PyObject_CallFunctionObjArgs(loads, text, NULL) : NULL;
    Py_XDECREF(text);
    Py_XDECREF(loads);
    Py_XDECREF(json_module);
    free(result_json);
    return result;
}

static PyMethodDef bridge_methods[] = {
    {"write", bridge_write, METH_VARARGS, NULL},
    {"emit", bridge_emit, METH_VARARGS, NULL},
    {"invoke", bridge_invoke, METH_VARARGS, NULL},
    {NULL, NULL, 0, NULL}
};

static int bridge_traverse(PyObject *module, visitproc visit, void *arg) {
    BridgeState *state = PyModule_GetState(module);
    if (state != NULL) Py_VISIT(state->context);
    return 0;
}

static int bridge_clear(PyObject *module) {
    BridgeState *state = PyModule_GetState(module);
    if (state != NULL) Py_CLEAR(state->context);
    return 0;
}

static void bridge_free(void *module) {
    bridge_clear((PyObject *)module);
}

static struct PyModuleDef bridge_module = {
    PyModuleDef_HEAD_INIT,
    "_cpython_runtime_bridge",
    NULL,
    sizeof(BridgeState),
    bridge_methods,
    NULL,
    bridge_traverse,
    bridge_clear,
    bridge_free
};

PyMODINIT_FUNC PyInit__cpython_runtime_bridge(void) {
    PyObject *module = PyModule_Create(&bridge_module);
    if (module == NULL) return NULL;
    BridgeState *state = PyModule_GetState(module);
    state->context = PyContextVar_New("flutter_python_bridge.job", Py_None);
    if (state->context == NULL) {
        Py_DECREF(module);
        return NULL;
    }
    return module;
}

static int initialize_python(JNIEnv *env, const char *python_home) {
    pthread_mutex_lock(&initialization_mutex);
    if (python_initialized) {
        pthread_mutex_unlock(&initialization_mutex);
        return 1;
    }

    if (PyImport_AppendInittab("_cpython_runtime_bridge", &PyInit__cpython_runtime_bridge) != 0) {
        pthread_mutex_unlock(&initialization_mutex);
        throw_runtime_exception(env, "Unable to register the Flutter Python bridge");
        return 0;
    }

    PyConfig config;
    PyConfig_InitPythonConfig(&config);
    config.install_signal_handlers = 0;

    const char *argv[] = {"cpython_runtime", NULL};
    PyStatus status = PyConfig_SetBytesArgv(&config, 1, (char *const *)argv);
    if (!PyStatus_Exception(status)) {
        status = PyConfig_SetBytesString(&config, &config.home, python_home);
    }
    if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);

    if (PyStatus_Exception(status)) {
        const char *message = status.err_msg ? status.err_msg : "CPython initialization failed";
        throw_runtime_exception(env, message);
        PyConfig_Clear(&config);
        pthread_mutex_unlock(&initialization_mutex);
        return 0;
    }

    PyConfig_Clear(&config);
    python_initialized = 1;
    PyEval_SaveThread();
    pthread_mutex_unlock(&initialization_mutex);
    return 1;
}

static Context *get_context(long long id, int create) {
    for (Context *item = contexts; item != NULL; item = item->next) {
        if (item->id == id) return item;
    }
    if (!create) return NULL;

    Context *item = (Context *)calloc(1, sizeof(Context));
    if (item == NULL) return NULL;
    item->id = id;
    item->globals = PyDict_New();
    if (item->globals == NULL) {
        free(item);
        return NULL;
    }
    PyDict_SetItemString(item->globals, "__builtins__", PyEval_GetBuiltins());
    PyObject *name = PyUnicode_FromString("__main__");
    if (name != NULL) {
        PyDict_SetItemString(item->globals, "__name__", name);
        Py_DECREF(name);
    }
    item->next = contexts;
    contexts = item;
    return item;
}

static int install_streams(PyObject **old_stdin, PyObject **old_stdout, PyObject **old_stderr) {
    static const char *bootstrap =
        "import sys, _cpython_runtime_bridge as _b\n"
        "class _FlutterOut:\n"
        "  def __init__(self, stream): self.stream = stream\n"
        "  encoding = 'utf-8'\n"
        "  errors = 'strict'\n"
        "  def write(self, text): return _b.write(self.stream, str(text))\n"
        "  def flush(self): pass\n"
        "  def isatty(self): return False\n"
        "  def writable(self): return True\n"
        "class _NoInput:\n"
        "  encoding = 'utf-8'\n"
        "  errors = 'strict'\n"
        "  def read(self, size=-1): return ''\n"
        "  def readline(self, size=-1): return ''\n"
        "  def isatty(self): return False\n"
        "  def readable(self): return True\n"
        "import types, asyncio\n"
        "_flutter = types.ModuleType('flutter_python_bridge.flutter')\n"
        "_flutter.emit = _b.emit\n"
        "_flutter.invoke = _b.invoke\n"
        "async def _ainvoke(method, arguments=None):\n"
        "  return await asyncio.to_thread(_b.invoke, method, arguments)\n"
        "_flutter.ainvoke = _ainvoke\n"
        "_package = sys.modules.get('flutter_python_bridge') or types.ModuleType('flutter_python_bridge')\n"
        "_package.flutter = _flutter\n"
        "sys.modules['flutter_python_bridge'] = _package\n"
        "sys.modules['flutter_python_bridge.flutter'] = _flutter\n"
        "sys.stdin = _NoInput()\n"
        "sys.stdout = _FlutterOut(1)\n"
        "sys.stderr = _FlutterOut(2)\n";

    *old_stdin = PySys_GetObject("stdin");
    *old_stdout = PySys_GetObject("stdout");
    *old_stderr = PySys_GetObject("stderr");
    Py_XINCREF(*old_stdin);
    Py_XINCREF(*old_stdout);
    Py_XINCREF(*old_stderr);
    return PyRun_SimpleString(bootstrap) == 0;
}

static void restore_streams(PyObject *old_stdin, PyObject *old_stdout, PyObject *old_stderr) {
    PySys_SetObject("stdin", old_stdin);
    PySys_SetObject("stdout", old_stdout);
    PySys_SetObject("stderr", old_stderr);
    Py_XDECREF(old_stdin);
    Py_XDECREF(old_stdout);
    Py_XDECREF(old_stderr);
}

static void set_argv(const char *filename, const char *arguments_json) {
    PyObject *json = PyImport_ImportModule("json");
    PyObject *loads = json ? PyObject_GetAttrString(json, "loads") : NULL;
    PyObject *json_text = loads ? PyUnicode_FromString(arguments_json) : NULL;
    PyObject *arguments = json_text
        ? PyObject_CallFunctionObjArgs(loads, json_text, NULL)
        : NULL;
    if (arguments != NULL && PyList_Check(arguments)) {
        PyObject *name = PyUnicode_FromString(filename);
        if (name != NULL) {
            PyList_Insert(arguments, 0, name);
            Py_DECREF(name);
            PySys_SetObject("argv", arguments);
        }
    } else {
        PyErr_Clear();
    }
    Py_XDECREF(arguments);
    Py_XDECREF(json_text);
    Py_XDECREF(loads);
    Py_XDECREF(json);
}

typedef struct {
    PyObject *type;
    PyObject *value;
    PyObject *traceback;
    PyObject *type_text;
    PyObject *message_text;
    PyObject *traceback_text;
} ExceptionInfo;

static ExceptionInfo fetch_exception(void) {
    ExceptionInfo info = {0};
    PyErr_Fetch(&info.type, &info.value, &info.traceback);
    PyErr_NormalizeException(&info.type, &info.value, &info.traceback);

    info.type_text = info.type ? PyObject_GetAttrString(info.type, "__name__") : NULL;
    info.message_text = info.value ? PyObject_Str(info.value) : PyUnicode_FromString("");

    PyObject *module = PyImport_ImportModule("traceback");
    PyObject *formatter = module ? PyObject_GetAttrString(module, "format_exception") : NULL;
    PyObject *lines = formatter ? PyObject_CallFunctionObjArgs(
        formatter,
        info.type ? info.type : Py_None,
        info.value ? info.value : Py_None,
        info.traceback ? info.traceback : Py_None,
        NULL) : NULL;
    PyObject *separator = lines ? PyUnicode_FromString("") : NULL;
    info.traceback_text = separator ? PyUnicode_Join(separator, lines) : NULL;
    if (info.traceback_text == NULL) {
        PyErr_Clear();
        info.traceback_text = info.message_text
            ? Py_NewRef(info.message_text)
            : PyUnicode_FromString("Python error");
    }

    Py_XDECREF(separator);
    Py_XDECREF(lines);
    Py_XDECREF(formatter);
    Py_XDECREF(module);
    return info;
}

static void clear_exception_info(ExceptionInfo *info) {
    Py_XDECREF(info->type);
    Py_XDECREF(info->value);
    Py_XDECREF(info->traceback);
    Py_XDECREF(info->type_text);
    Py_XDECREF(info->message_text);
    Py_XDECREF(info->traceback_text);
}

static PyObject *json_result(PyObject *value) {
    PyObject *module = PyImport_ImportModule("json");
    PyObject *dumps = module ? PyObject_GetAttrString(module, "dumps") : NULL;
    PyObject *args = dumps ? PyTuple_Pack(1, value) : NULL;
    PyObject *kwargs = args ? PyDict_New() : NULL;
    PyObject *result = NULL;
    if (kwargs != NULL &&
        PyDict_SetItemString(kwargs, "ensure_ascii", Py_False) == 0 &&
        PyDict_SetItemString(kwargs, "allow_nan", Py_False) == 0) {
        result = PyObject_Call(dumps, args, kwargs);
    }
    Py_XDECREF(kwargs);
    Py_XDECREF(args);
    Py_XDECREF(dumps);
    Py_XDECREF(module);
    return result;
}

static jbyteArray unicode_to_java_bytes(JNIEnv *env, PyObject *value) {
    if (value == NULL) return NULL;
    PyObject *bytes = PyUnicode_AsEncodedString(value, "utf-8", "replace");
    if (bytes == NULL) return NULL;
    Py_ssize_t size = PyBytes_GET_SIZE(bytes);
    jbyteArray output = (*env)->NewByteArray(env, (jsize)size);
    if (output != NULL) {
        (*env)->SetByteArrayRegion(
            env, output, 0, (jsize)size, (const jbyte *)PyBytes_AS_STRING(bytes));
    }
    Py_DECREF(bytes);
    return output;
}

static jbyteArray unicode_to_java_bytes_limited(
    JNIEnv *env, PyObject *value, Py_ssize_t limit
) {
    if (value == NULL) return NULL;
    PyObject *bytes = PyUnicode_AsEncodedString(value, "utf-8", "replace");
    if (bytes == NULL) return NULL;
    Py_ssize_t size = PyBytes_GET_SIZE(bytes);
    if (size > limit) {
        size = limit;
        while (size > 0 && ((unsigned char)PyBytes_AS_STRING(bytes)[size] & 0xc0) == 0x80) size--;
    }
    jbyteArray output = (*env)->NewByteArray(env, (jsize)size);
    if (output != NULL && size > 0) {
        (*env)->SetByteArrayRegion(
            env, output, 0, (jsize)size, (const jbyte *)PyBytes_AS_STRING(bytes));
    }
    Py_DECREF(bytes);
    return output;
}

static jbyteArray buffer_to_java_bytes(JNIEnv *env, Buffer *buffer) {
    jbyteArray output = (*env)->NewByteArray(env, (jsize)buffer->length);
    if (output != NULL && buffer->length > 0) {
        (*env)->SetByteArrayRegion(
            env, output, 0, (jsize)buffer->length, (const jbyte *)buffer->data);
    }
    return output;
}

static jbyteArray python_bytes_to_java(JNIEnv *env, PyObject *value) {
    if (value == NULL || !PyBytes_Check(value)) return NULL;
    Py_ssize_t size = PyBytes_GET_SIZE(value);
    if (size > 64 * 1024) return NULL;
    jbyteArray output = (*env)->NewByteArray(env, (jsize)size);
    if (output != NULL && size > 0) {
        (*env)->SetByteArrayRegion(
            env, output, 0, (jsize)size, (const jbyte *)PyBytes_AS_STRING(value));
    }
    return output;
}

static void map_put(JNIEnv *env, jobject map, const char *key, jobject value) {
    jclass map_class = (*env)->GetObjectClass(env, map);
    jmethodID put = (*env)->GetMethodID(
        env, map_class, "put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");
    jstring java_key = (*env)->NewStringUTF(env, key);
    (*env)->CallObjectMethod(env, map, put, java_key, value);
    (*env)->DeleteLocalRef(env, java_key);
    (*env)->DeleteLocalRef(env, map_class);
}

static jobject new_result_map(JNIEnv *env, int exit_code, Operation *operation) {
    jclass map_class = (*env)->FindClass(env, "java/util/HashMap");
    jmethodID constructor = (*env)->GetMethodID(env, map_class, "<init>", "()V");
    jobject map = (*env)->NewObject(env, map_class, constructor);

    jclass integer_class = (*env)->FindClass(env, "java/lang/Integer");
    jmethodID value_of = (*env)->GetStaticMethodID(
        env, integer_class, "valueOf", "(I)Ljava/lang/Integer;");
    jobject code = (*env)->CallStaticObjectMethod(env, integer_class, value_of, (jint)exit_code);
    map_put(env, map, "exitCode", code);
    map_put(env, map, "stdout", buffer_to_java_bytes(env, &operation->stdout_buffer));
    map_put(env, map, "stderr", buffer_to_java_bytes(env, &operation->stderr_buffer));
    jclass boolean_class = (*env)->FindClass(env, "java/lang/Boolean");
    jmethodID boolean_value = (*env)->GetStaticMethodID(env, boolean_class, "valueOf", "(Z)Ljava/lang/Boolean;");
    map_put(env, map, "outputTruncated", (*env)->CallStaticObjectMethod(
        env, boolean_class, boolean_value,
        (jboolean)(operation->stdout_buffer.truncated || operation->stderr_buffer.truncated)));
    return map;
}

JNIEXPORT jobject JNICALL
Java_dev_cpythonruntime_cpython_1runtime_PythonBridge_execute(
    JNIEnv *env, jclass cls, jbyteArray python_home_bytes, jlong operation_id,
    jlong context_id, jboolean evaluate, jbyteArray source_bytes,
    jbyteArray filename_bytes,
    jbyteArray arguments_json_bytes, jbyteArray working_directory_bytes,
    jbyteArray project_path_bytes
) {
    if (bridge_class == NULL) {
        bridge_class = (*env)->NewGlobalRef(env, cls);
        dispatch_output_method = (*env)->GetStaticMethodID(
            env, cls, "dispatchOutput", "(JI[B)V");
        dispatch_event_method = (*env)->GetStaticMethodID(
            env, cls, "dispatchEvent", "(JJLjava/lang/String;[B)V");
        dispatch_method_call_method = (*env)->GetStaticMethodID(
            env, cls, "dispatchMethodCall", "(JJJLjava/lang/String;[B)V");
    }

    jsize python_home_size, source_size, filename_size, args_size, cwd_size;
    char *python_home = copy_java_bytes(env, python_home_bytes, &python_home_size);
    char *source = copy_java_bytes(env, source_bytes, &source_size);
    char *filename = copy_java_bytes(env, filename_bytes, &filename_size);
    char *arguments_json = copy_java_bytes(env, arguments_json_bytes, &args_size);
    char *working_directory = copy_java_bytes(env, working_directory_bytes, &cwd_size);
    if (python_home == NULL || source == NULL || filename == NULL || arguments_json == NULL) {
        free(python_home); free(source); free(filename);
        free(arguments_json); free(working_directory);
        throw_runtime_exception(env, "Out of memory preparing Python execution");
        return NULL;
    }
    if (memchr(source, '\0', (size_t)source_size) != NULL) {
        free(python_home); free(source); free(filename);
        free(arguments_json); free(working_directory);
        throw_runtime_exception(env, "Python source cannot contain NUL bytes");
        return NULL;
    }
    if (!initialize_python(env, python_home)) {
        free(python_home); free(source); free(filename);
        free(arguments_json); free(working_directory);
        return NULL;
    }

    Operation operation = {0};
    operation.id = (long long)operation_id;
    operation.session_id = (long long)context_id;
    pthread_mutex_lock(&operation_mutex);
    if (active_operation != NULL) {
        pthread_mutex_unlock(&operation_mutex);
        throw_runtime_exception(env, "Only one Python execution may run at a time");
        goto cleanup_strings;
    }
    active_operation = &operation;
    pthread_mutex_unlock(&operation_mutex);

    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *old_stdin = NULL, *old_stdout = NULL, *old_stderr = NULL;
    PyObject *old_path = NULL;
    PyObject *bridge = NULL, *context_token = NULL;
    PyObject *result = NULL, *value_json = NULL, *value_repr = NULL, *value_binary = NULL;
    ExceptionInfo exception = {0};
    int exit_code = 1;

    pthread_mutex_lock(&operation_mutex);
    operation.thread_id = PyThread_get_thread_ident();
    int interrupted = operation.interrupted;
    pthread_mutex_unlock(&operation_mutex);
    jmethodID is_interrupted = (*env)->GetStaticMethodID(env, cls, "isInterrupted", "(J)Z");
    if (is_interrupted != NULL) {
        interrupted |= (*env)->CallStaticBooleanMethod(env, cls, is_interrupted, operation_id);
    }
    if (interrupted) {
        PyErr_SetNone(PyExc_KeyboardInterrupt);
        exception = fetch_exception();
        goto execution_done;
    }

    bridge = PyImport_ImportModule("_cpython_runtime_bridge");
    operation.owner = PyDict_New();
    if (bridge != NULL && operation.owner != NULL) {
        if (PyModule_Check(bridge) && PyModule_GetDef(bridge) == &bridge_module) {
            BridgeState *state = PyModule_GetState(bridge);
            context_token = PyContextVar_Set(state->context, operation.owner);
        } else {
            PyErr_SetString(PyExc_RuntimeError, "Python bridge module has been replaced");
        }
    }
    if (context_token == NULL || !install_streams(&old_stdin, &old_stdout, &old_stderr)) {
        exception = fetch_exception();
        goto execution_done;
    }

    if (project_path_bytes != NULL) {
        jsize path_size;
        char *path = copy_java_bytes(env, project_path_bytes, &path_size);
        PyObject *path_text = path ? PyUnicode_DecodeUTF8(path, path_size, "strict") : NULL;
        free(path);
        PyObject *search_path = PySys_GetObject("path");
        old_path = search_path ? PySequence_List(search_path) : NULL;
        if (path_text == NULL || old_path == NULL || PyList_Insert(search_path, 0, path_text) < 0) {
            Py_XDECREF(path_text);
            if (!PyErr_Occurred()) PyErr_SetString(PyExc_RuntimeError, "Unable to set Python project path");
            exception = fetch_exception();
            goto execution_done;
        }
        Py_DECREF(path_text);
    }

    set_argv(filename, arguments_json);
    char previous_directory[4096] = {0};
    int changed_directory = 0;
    if (working_directory != NULL && cwd_size > 0) {
        if (getcwd(previous_directory, sizeof(previous_directory)) != NULL &&
            chdir(working_directory) == 0) {
            changed_directory = 1;
        } else {
            PyErr_SetFromErrnoWithFilename(PyExc_OSError, working_directory);
            exception = fetch_exception();
            goto execution_done;
        }
    }

    PyObject *globals = NULL;
    int temporary_globals = context_id == 0;
    if (temporary_globals) {
        globals = PyDict_New();
        if (globals != NULL) {
            PyDict_SetItemString(globals, "__builtins__", PyEval_GetBuiltins());
            PyObject *name = PyUnicode_FromString("__main__");
            if (name != NULL) {
                PyDict_SetItemString(globals, "__name__", name);
                Py_DECREF(name);
            }
        }
    } else {
        Context *context = get_context((long long)context_id, 1);
        globals = context ? context->globals : NULL;
    }

    if (globals == NULL) {
        PyErr_NoMemory();
    } else {
        PyObject *filename_object = PyUnicode_DecodeUTF8(filename, filename_size, "strict");
        if (filename_object != NULL) {
            PyDict_SetItemString(globals, "__file__", filename_object);
        }
        PyObject *compiled = filename_object
            ? Py_CompileStringObject(
                source, filename_object,
                evaluate ? Py_eval_input : Py_file_input,
                NULL, -1)
            : NULL;
        result = compiled ? PyEval_EvalCode(compiled, globals, globals) : NULL;
        Py_XDECREF(compiled);
        Py_XDECREF(filename_object);
    }

    if (result == NULL) {
        exception = fetch_exception();
        if (exception.type != NULL &&
            PyErr_GivenExceptionMatches(exception.type, PyExc_SystemExit)) {
            PyObject *code = exception.value
                ? PyObject_GetAttrString(exception.value, "code")
                : NULL;
            if (code == NULL || code == Py_None) {
                PyErr_Clear();
                exit_code = 0;
            } else if (PyLong_Check(code)) {
                long parsed = PyLong_AsLong(code);
                exit_code = parsed < 0 ? 1 : (parsed > 255 ? 255 : (int)parsed);
            } else {
                exit_code = 1;
            }
            Py_XDECREF(code);
            PyErr_Clear();
            if (exit_code == 0) {
                clear_exception_info(&exception);
                memset(&exception, 0, sizeof(exception));
            }
        }
        Py_ssize_t traceback_length;
        const char *traceback_utf8 = exception.traceback_text
            ? PyUnicode_AsUTF8AndSize(exception.traceback_text, &traceback_length)
            : NULL;
        if (traceback_utf8 != NULL) {
            PyObject *write_args = Py_BuildValue("(iO)", 2, exception.traceback_text);
            PyObject *ignored = write_args ? bridge_write(bridge, write_args) : NULL;
            if (ignored == NULL) PyErr_Clear();
            Py_XDECREF(ignored);
            Py_XDECREF(write_args);
        } else {
            PyErr_Clear();
        }
    } else {
        exit_code = 0;
        if (evaluate) {
            if (PyBytes_Check(result)) value_binary = Py_NewRef(result);
            else {
                value_json = json_result(result);
                if (value_json == NULL) PyErr_Clear();
                if (value_json != NULL) {
                    Py_ssize_t json_size = 0;
                    if (PyUnicode_AsUTF8AndSize(value_json, &json_size) == NULL ||
                        json_size > 64 * 1024) {
                        PyErr_Clear();
                        Py_CLEAR(value_json);
                        exit_code = 1;
                        PyErr_SetString(PyExc_ValueError, "Python result exceeds 64 KiB");
                        exception = fetch_exception();
                    }
                }
            }
            value_repr = PyObject_Repr(result);
            if (value_repr == NULL) PyErr_Clear();
        }
    }

    if (value_binary != NULL && PyBytes_GET_SIZE(value_binary) > 64 * 1024) {
        Py_CLEAR(value_binary);
        exit_code = 1;
        PyErr_SetString(PyExc_ValueError, "Python result exceeds 64 KiB");
        exception = fetch_exception();
    }
    Py_XDECREF(result);
    if (temporary_globals) Py_XDECREF(globals);
    if (changed_directory) chdir(previous_directory);

execution_done:
    if (old_path != NULL) {
        if (PySys_SetObject("path", old_path) < 0) PyErr_Clear();
        Py_DECREF(old_path);
    }
    if (old_stdin != NULL || old_stdout != NULL || old_stderr != NULL) {
        restore_streams(old_stdin, old_stdout, old_stderr);
    }

    jobject result_map = new_result_map(env, exit_code, &operation);
    if (value_json != NULL) map_put(env, result_map, "valueJson", unicode_to_java_bytes(env, value_json));
    if (value_binary != NULL) map_put(env, result_map, "binaryValue", python_bytes_to_java(env, value_binary));
    if (value_repr != NULL) map_put(env, result_map, "valueRepr", unicode_to_java_bytes_limited(env, value_repr, 64 * 1024));
    if (exception.type_text != NULL) {
        map_put(env, result_map, "exceptionType", unicode_to_java_bytes_limited(env, exception.type_text, 4096));
        map_put(env, result_map, "exceptionMessage", unicode_to_java_bytes_limited(env, exception.message_text, 64 * 1024));
        map_put(env, result_map, "traceback", unicode_to_java_bytes_limited(env, exception.traceback_text, 64 * 1024));
    }

    Py_XDECREF(value_json);
    Py_XDECREF(value_binary);
    Py_XDECREF(value_repr);
    clear_exception_info(&exception);
    pthread_mutex_lock(&operation_mutex);
    active_operation = NULL;
    pthread_mutex_unlock(&operation_mutex);
    if (context_token != NULL) {
        BridgeState *state = PyModule_GetState(bridge);
        if (PyContextVar_Reset(state->context, context_token) < 0) PyErr_Clear();
    }
    Py_XDECREF(context_token);
    Py_XDECREF(operation.owner);
    Py_XDECREF(bridge);
    PyGILState_Release(gil);

    buffer_clear(&operation.stdout_buffer);
    buffer_clear(&operation.stderr_buffer);
    free(python_home); free(source); free(filename);
    free(arguments_json); free(working_directory);
    return result_map;

cleanup_strings:
    buffer_clear(&operation.stdout_buffer);
    buffer_clear(&operation.stderr_buffer);
    free(python_home); free(source); free(filename);
    free(arguments_json); free(working_directory);
    return NULL;
}

JNIEXPORT void JNICALL
Java_dev_cpythonruntime_cpython_1runtime_PythonBridge_interrupt(
    JNIEnv *env, jclass cls, jlong operation_id
) {
    (void)cls;
    pthread_mutex_lock(&operation_mutex);
    if (active_operation == NULL || active_operation->id != operation_id) {
        pthread_mutex_unlock(&operation_mutex);
        throw_runtime_exception(env, "Python operation is not active");
        return;
    }
    active_operation->interrupted = 1;
    pthread_mutex_unlock(&operation_mutex);

    PyGILState_STATE gil = PyGILState_Ensure();
    pthread_mutex_lock(&operation_mutex);
    if (active_operation != NULL && active_operation->id == operation_id &&
        active_operation->thread_id != 0) {
        unsigned long thread_id = active_operation->thread_id;
        int affected = PyThreadState_SetAsyncExc(thread_id, PyExc_KeyboardInterrupt);
        if (affected > 1) PyThreadState_SetAsyncExc(thread_id, NULL);
    }
    pthread_mutex_unlock(&operation_mutex);
    PyGILState_Release(gil);

    pthread_mutex_lock(&host_call_mutex);
    if (pending_host_call.id != 0 && pending_host_call.operation_id == operation_id &&
        !pending_host_call.completed) {
        pending_host_call.error = strdup("Python job was cancelled");
        pending_host_call.completed = 1;
        pthread_cond_broadcast(&host_call_condition);
    }
    pthread_mutex_unlock(&host_call_mutex);
}

JNIEXPORT void JNICALL
Java_dev_cpythonruntime_cpython_1runtime_PythonBridge_completeHostCall(
    JNIEnv *env, jclass cls, jlong call_id,
    jbyteArray result_json_bytes, jbyteArray error_bytes
) {
    (void)cls;
    jsize result_size = 0, error_size = 0;
    char *result_json = copy_java_bytes(env, result_json_bytes, &result_size);
    char *error = copy_java_bytes(env, error_bytes, &error_size);
    pthread_mutex_lock(&host_call_mutex);
    if (pending_host_call.id != (long long)call_id || pending_host_call.completed) {
        pthread_mutex_unlock(&host_call_mutex);
        free(result_json);
        free(error);
        throw_runtime_exception(env, "Python host call is not active");
        return;
    }
    pending_host_call.result_json = result_json;
    pending_host_call.error = error;
    pending_host_call.completed = 1;
    pthread_cond_broadcast(&host_call_condition);
    pthread_mutex_unlock(&host_call_mutex);
}

JNIEXPORT void JNICALL
Java_dev_cpythonruntime_cpython_1runtime_PythonBridge_destroyContext(
    JNIEnv *env, jclass cls, jlong context_id
) {
    (void)env; (void)cls;
    if (!python_initialized) return;
    PyGILState_STATE gil = PyGILState_Ensure();
    Context **cursor = &contexts;
    while (*cursor != NULL) {
        if ((*cursor)->id == context_id) {
            Context *removed = *cursor;
            *cursor = removed->next;
            Py_DECREF(removed->globals);
            free(removed);
            break;
        }
        cursor = &(*cursor)->next;
    }
    PyGILState_Release(gil);
}

static PyObject *sys_attribute(const char *name) {
    PyObject *sys = PyImport_ImportModule("sys");
    PyObject *value = sys ? PyObject_GetAttrString(sys, name) : NULL;
    Py_XDECREF(sys);
    return value;
}

JNIEXPORT jobject JNICALL
Java_dev_cpythonruntime_cpython_1runtime_PythonBridge_getRuntimeInfo(
    JNIEnv *env, jclass cls, jbyteArray python_home_bytes
) {
    jsize python_home_size;
    char *python_home = copy_java_bytes(env, python_home_bytes, &python_home_size);
    if (python_home == NULL) {
        throw_runtime_exception(env, "Out of memory reading Python Home");
        return NULL;
    }
    if (!initialize_python(env, python_home)) {
        free(python_home);
        return NULL;
    }
    free(python_home);

    if (bridge_class == NULL) {
        bridge_class = (*env)->NewGlobalRef(env, cls);
        dispatch_output_method = (*env)->GetStaticMethodID(
            env, cls, "dispatchOutput", "(JI[B)V");
        dispatch_event_method = (*env)->GetStaticMethodID(
            env, cls, "dispatchEvent", "(JJLjava/lang/String;[B)V");
        dispatch_method_call_method = (*env)->GetStaticMethodID(
            env, cls, "dispatchMethodCall", "(JJJLjava/lang/String;[B)V");
    }

    PyGILState_STATE gil = PyGILState_Ensure();
    jclass map_class = (*env)->FindClass(env, "java/util/HashMap");
    jmethodID constructor = (*env)->GetMethodID(env, map_class, "<init>", "()V");
    jobject map = (*env)->NewObject(env, map_class, constructor);

    PyObject *version = sys_attribute("version");
    PyObject *platform = sys_attribute("platform");
    PyObject *executable = sys_attribute("executable");
    PyObject *prefix = sys_attribute("prefix");
    PyObject *path = sys_attribute("path");
    PyObject *separator = PyUnicode_FromString("\n");
    PyObject *paths = path && separator ? PyUnicode_Join(separator, path) : NULL;

    map_put(env, map, "version", unicode_to_java_bytes(env, version));
    map_put(env, map, "platform", unicode_to_java_bytes(env, platform));
    map_put(env, map, "executable", unicode_to_java_bytes(env, executable));
    map_put(env, map, "prefix", unicode_to_java_bytes(env, prefix));
    map_put(env, map, "moduleSearchPaths", unicode_to_java_bytes(env, paths));

    Py_XDECREF(paths);
    Py_XDECREF(separator);
    Py_XDECREF(path);
    Py_XDECREF(prefix);
    Py_XDECREF(executable);
    Py_XDECREF(platform);
    Py_XDECREF(version);
    PyGILState_Release(gil);
    return map;
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    java_vm = vm;
    return JNI_VERSION_1_6;
}
