#import "CPRPythonEngine.h"
#import <Python/Python.h>
#import <pthread.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <limits.h>
#import <unistd.h>

typedef struct {
    char *data;
    size_t length;
    size_t capacity;
    int truncated;
} CPRBuffer;

typedef struct {
    int64_t identifier;
    int64_t sessionIdentifier;
    unsigned long threadIdentifier;
    PyObject *owner;
    CPRBuffer standardOutput;
    CPRBuffer standardError;
} CPROperation;

typedef struct CPRContext {
    int64_t identifier;
    PyObject *globals;
    struct CPRContext *next;
} CPRContext;

typedef struct {
    int64_t identifier;
    int64_t operationIdentifier;
    int completed;
    char *resultJSON;
    char *error;
} CPRHostCall;

typedef struct {
    PyObject *type;
    PyObject *value;
    PyObject *traceback;
    PyObject *typeText;
    PyObject *messageText;
    PyObject *tracebackText;
} CPRExceptionInfo;

static pthread_mutex_t CPRInitializationMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t CPROperationMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t CPRHostCallMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t CPRHostCallCondition = PTHREAD_COND_INITIALIZER;
static int CPRInitialized = 0;
static int CPRBridgeRegistered = 0;
static PyThreadState *CPRMainThreadState = NULL;
static CPROperation *CPRActiveOperation = NULL;
static CPRContext *CPRContexts = NULL;
static CPRHostCall CPRPendingHostCall = {0};
static int64_t CPRNextHostCallIdentifier = 1;
static __weak CPRPythonEngine *CPRActiveEngine = nil;

@interface CPRPythonEngine ()
- (void)dispatchEvent:(NSDictionary<NSString *, id> *)event;
@end

static int CPRBufferAppend(CPRBuffer *buffer, const char *data, size_t length) {
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
        size_t capacity = buffer->capacity == 0 ? 256 : buffer->capacity;
        while (capacity < required) {
            if (capacity > SIZE_MAX / 2) {
                capacity = required;
                break;
            }
            capacity *= 2;
        }
        char *resized = realloc(buffer->data, capacity);
        if (resized == NULL) return 0;
        buffer->data = resized;
        buffer->capacity = capacity;
    }
    memcpy(buffer->data + buffer->length, data, length);
    buffer->length += length;
    buffer->data[buffer->length] = '\0';
    return 1;
}

static void CPRBufferClear(CPRBuffer *buffer) {
    free(buffer->data);
    memset(buffer, 0, sizeof(*buffer));
}

static NSString *CPRString(const char *data, size_t length) {
    if (data == NULL || length == 0) return @"";
    NSString *value = [[NSString alloc] initWithBytes:data length:length encoding:NSUTF8StringEncoding];
    if (value != nil) return value;
    NSData *bytes = [NSData dataWithBytes:data length:length];
    return [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] ?: @"";
}

static NSString *CPRPythonString(PyObject *value, Py_ssize_t maximumBytes) {
    if (value == NULL) return nil;
    PyObject *bytes = PyUnicode_AsEncodedString(value, "utf-8", "replace");
    if (bytes == NULL) return nil;
    Py_ssize_t length = PyBytes_GET_SIZE(bytes);
    if (maximumBytes >= 0 && length > maximumBytes) {
        length = maximumBytes;
        while (length > 0 && ((unsigned char)PyBytes_AS_STRING(bytes)[length] & 0xc0) == 0x80) length--;
    }
    NSString *result = CPRString(PyBytes_AS_STRING(bytes), (size_t)length);
    Py_DECREF(bytes);
    return result;
}

static void CPRDispatchOutput(int64_t operationIdentifier, int stream, const char *data, size_t length) {
    if (length == 0) return;
    CPRPythonEngine *engine = CPRActiveEngine;
    if (engine == nil) return;
    size_t offset = 0;
    while (offset < length) {
        size_t count = MIN(length - offset, 64 * 1024);
        while (offset + count < length && count > 0 && (((unsigned char)data[offset + count]) & 0xC0) == 0x80) count--;
        if (count == 0) count = MIN(length - offset, 64 * 1024);
        [engine dispatchEvent:@{
            @"kind": @"output",
            @"jobId": @(operationIdentifier),
            @"stream": stream == 2 ? @"stderr" : @"stdout",
            @"text": CPRString(data + offset, count)
        }];
        offset += count;
    }
}

static PyObject *CPRJSONResult(PyObject *value) {
    PyObject *module = PyImport_ImportModule("json");
    PyObject *dumps = module ? PyObject_GetAttrString(module, "dumps") : NULL;
    PyObject *arguments = dumps ? PyTuple_Pack(1, value) : NULL;
    PyObject *keywords = arguments ? PyDict_New() : NULL;
    PyObject *result = NULL;
    if (keywords != NULL &&
        PyDict_SetItemString(keywords, "ensure_ascii", Py_False) == 0 &&
        PyDict_SetItemString(keywords, "allow_nan", Py_False) == 0) {
        result = PyObject_Call(dumps, arguments, keywords);
    }
    Py_XDECREF(keywords);
    Py_XDECREF(arguments);
    Py_XDECREF(dumps);
    Py_XDECREF(module);
    return result;
}

typedef struct {
    PyObject *context;
} CPRBridgeState;

static PyObject *CPRBridgeOwner(PyObject *module) {
    if (module == NULL || !PyModule_Check(module)) {
        PyErr_SetString(PyExc_RuntimeError, "Python bridge module is unavailable");
        return NULL;
    }
    CPRBridgeState *state = PyModule_GetState(module);
    PyObject *owner = NULL;
    if (state == NULL || state->context == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "Python bridge context is unavailable");
        return NULL;
    }
    if (PyContextVar_Get(state->context, Py_None, &owner) < 0) return NULL;
    return owner;
}

static PyObject *CPRBridgeWrite(PyObject *self, PyObject *arguments) {
    int stream;
    PyObject *text;
    if (!PyArg_ParseTuple(arguments, "iU", &stream, &text)) return NULL;
    Py_ssize_t length;
    const char *utf8 = PyUnicode_AsUTF8AndSize(text, &length);
    if (utf8 == NULL) return NULL;
    PyObject *owner = CPRBridgeOwner(self);
    if (owner == NULL) return NULL;
    int64_t operationIdentifier = 0;
    int found = 0;
    int appended = 0;
    pthread_mutex_lock(&CPROperationMutex);
    if (CPRActiveOperation != NULL && CPRActiveOperation->owner == owner) {
        found = 1;
        operationIdentifier = CPRActiveOperation->identifier;
        CPRBuffer *buffer = stream == 2 ? &CPRActiveOperation->standardError : &CPRActiveOperation->standardOutput;
        appended = CPRBufferAppend(buffer, utf8, (size_t)length);
    }
    pthread_mutex_unlock(&CPROperationMutex);
    Py_DECREF(owner);
    if (found && !appended) {
        PyErr_NoMemory();
        return NULL;
    }
    if (found) CPRDispatchOutput(operationIdentifier, stream, utf8, (size_t)length);
    return PyLong_FromSsize_t(PyUnicode_GET_LENGTH(text));
}

static PyObject *CPRBridgeEmit(PyObject *self, PyObject *arguments) {
    const char *name;
    PyObject *value = Py_None;
    if (!PyArg_ParseTuple(arguments, "s|O", &name, &value)) return NULL;
    if (strlen(name) > 4096) {
        PyErr_SetString(PyExc_ValueError, "Flutter event or method name exceeds 4096 bytes");
        return NULL;
    }
    PyObject *encoded = CPRJSONResult(value);
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
    PyObject *owner = CPRBridgeOwner(self);
    if (owner == NULL) {
        Py_DECREF(encoded);
        return NULL;
    }
    int64_t operationIdentifier = 0;
    int64_t sessionIdentifier = 0;
    pthread_mutex_lock(&CPROperationMutex);
    if (CPRActiveOperation != NULL && CPRActiveOperation->owner == owner) {
        operationIdentifier = CPRActiveOperation->identifier;
        sessionIdentifier = CPRActiveOperation->sessionIdentifier;
    }
    pthread_mutex_unlock(&CPROperationMutex);
    Py_DECREF(owner);
    if (operationIdentifier == 0) {
        Py_DECREF(encoded);
        PyErr_SetString(PyExc_RuntimeError, "Flutter event requires a current Python job context");
        return NULL;
    }
    CPRPythonEngine *engine = CPRActiveEngine;
    if (engine != nil) {
        [engine dispatchEvent:@{
            @"kind": @"event",
            @"jobId": @(operationIdentifier),
            @"sessionId": sessionIdentifier == 0 ? [NSNull null] : @(sessionIdentifier),
            @"name": [NSString stringWithUTF8String:name] ?: @"",
            @"dataJson": CPRString(json, (size_t)length)
        }];
    }
    Py_DECREF(encoded);
    Py_RETURN_NONE;
}

static PyObject *CPRBridgeInvoke(PyObject *self, PyObject *arguments) {
    const char *method;
    PyObject *value = Py_None;
    if (!PyArg_ParseTuple(arguments, "s|O", &method, &value)) return NULL;
    if (strlen(method) > 4096) {
        PyErr_SetString(PyExc_ValueError, "Flutter event or method name exceeds 4096 bytes");
        return NULL;
    }
    PyObject *encoded = CPRJSONResult(value);
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
    PyObject *owner = CPRBridgeOwner(self);
    if (owner == NULL) {
        Py_DECREF(encoded);
        return NULL;
    }
    pthread_mutex_lock(&CPRHostCallMutex);
    if (CPRPendingHostCall.identifier != 0) {
        pthread_mutex_unlock(&CPRHostCallMutex);
        Py_DECREF(owner);
        Py_DECREF(encoded);
        PyErr_SetString(PyExc_RuntimeError, "another Flutter method call is already pending");
        return NULL;
    }
    int64_t operationIdentifier = 0;
    int64_t sessionIdentifier = 0;
    pthread_mutex_lock(&CPROperationMutex);
    if (CPRActiveOperation != NULL && CPRActiveOperation->owner == owner) {
        operationIdentifier = CPRActiveOperation->identifier;
        sessionIdentifier = CPRActiveOperation->sessionIdentifier;
    }
    pthread_mutex_unlock(&CPROperationMutex);
    Py_DECREF(owner);
    if (operationIdentifier == 0) {
        pthread_mutex_unlock(&CPRHostCallMutex);
        Py_DECREF(encoded);
        PyErr_SetString(PyExc_RuntimeError, "Flutter method call requires a current Python job context");
        return NULL;
    }
    CPRPendingHostCall.identifier = CPRNextHostCallIdentifier++;
    CPRPendingHostCall.operationIdentifier = operationIdentifier;
    int64_t callIdentifier = CPRPendingHostCall.identifier;
    CPRPythonEngine *engine = CPRActiveEngine;
    if (engine != nil) {
        [engine dispatchEvent:@{
            @"kind": @"methodCall",
            @"callId": @(callIdentifier),
            @"jobId": @(operationIdentifier),
            @"sessionId": sessionIdentifier == 0 ? [NSNull null] : @(sessionIdentifier),
            @"method": [NSString stringWithUTF8String:method] ?: @"",
            @"argumentsJson": CPRString(json, (size_t)length)
        }];
    }
    Py_DECREF(encoded);
    PyThreadState *thread = PyEval_SaveThread();
    while (!CPRPendingHostCall.completed) pthread_cond_wait(&CPRHostCallCondition, &CPRHostCallMutex);
    char *resultJSON = CPRPendingHostCall.resultJSON;
    char *error = CPRPendingHostCall.error;
    memset(&CPRPendingHostCall, 0, sizeof(CPRPendingHostCall));
    pthread_mutex_unlock(&CPRHostCallMutex);
    PyEval_RestoreThread(thread);
    if (error != NULL) {
        PyErr_SetString(PyExc_RuntimeError, error);
        free(error);
        free(resultJSON);
        return NULL;
    }
    PyObject *jsonModule = PyImport_ImportModule("json");
    PyObject *loads = jsonModule ? PyObject_GetAttrString(jsonModule, "loads") : NULL;
    PyObject *text = PyUnicode_FromString(resultJSON ?: "null");
    PyObject *result = loads && text ? PyObject_CallFunctionObjArgs(loads, text, NULL) : NULL;
    Py_XDECREF(text);
    Py_XDECREF(loads);
    Py_XDECREF(jsonModule);
    free(resultJSON);
    return result;
}

static PyMethodDef CPRBridgeMethods[] = {
    {"write", CPRBridgeWrite, METH_VARARGS, NULL},
    {"emit", CPRBridgeEmit, METH_VARARGS, NULL},
    {"invoke", CPRBridgeInvoke, METH_VARARGS, NULL},
    {NULL, NULL, 0, NULL}
};

static int CPRBridgeTraverse(PyObject *module, visitproc visit, void *arg) {
    CPRBridgeState *state = PyModule_GetState(module);
    if (state != NULL) Py_VISIT(state->context);
    return 0;
}

static int CPRBridgeClear(PyObject *module) {
    CPRBridgeState *state = PyModule_GetState(module);
    if (state != NULL) Py_CLEAR(state->context);
    return 0;
}

static void CPRBridgeFree(void *module) {
    CPRBridgeClear((PyObject *)module);
}

static struct PyModuleDef CPRBridgeModule = {
    PyModuleDef_HEAD_INIT,
    "_cpython_runtime_bridge",
    NULL,
    sizeof(CPRBridgeState),
    CPRBridgeMethods,
    NULL,
    CPRBridgeTraverse,
    CPRBridgeClear,
    CPRBridgeFree
};

PyMODINIT_FUNC PyInit__cpython_runtime_bridge(void) {
    PyObject *module = PyModule_Create(&CPRBridgeModule);
    if (module == NULL) return NULL;
    CPRBridgeState *state = PyModule_GetState(module);
    state->context = PyContextVar_New("flutter_python_bridge.job", Py_None);
    if (state->context == NULL) {
        Py_DECREF(module);
        return NULL;
    }
    return module;
}

static NSError *CPRError(NSString *message) {
    return [NSError errorWithDomain:@"dev.cpythonruntime" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static CPRContext *CPRGetContext(int64_t identifier, int create) {
    for (CPRContext *context = CPRContexts; context != NULL; context = context->next) {
        if (context->identifier == identifier) return context;
    }
    if (!create) return NULL;
    CPRContext *context = calloc(1, sizeof(CPRContext));
    if (context == NULL) return NULL;
    context->identifier = identifier;
    context->globals = PyDict_New();
    if (context->globals == NULL) {
        free(context);
        return NULL;
    }
    PyDict_SetItemString(context->globals, "__builtins__", PyEval_GetBuiltins());
    PyObject *name = PyUnicode_FromString("__main__");
    if (name != NULL) {
        PyDict_SetItemString(context->globals, "__name__", name);
        Py_DECREF(name);
    }
    context->next = CPRContexts;
    CPRContexts = context;
    return context;
}

static int CPRInstallStreams(PyObject **oldInput, PyObject **oldOutput, PyObject **oldError) {
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
    *oldInput = PySys_GetObject("stdin");
    *oldOutput = PySys_GetObject("stdout");
    *oldError = PySys_GetObject("stderr");
    Py_XINCREF(*oldInput);
    Py_XINCREF(*oldOutput);
    Py_XINCREF(*oldError);
    return PyRun_SimpleString(bootstrap) == 0;
}

static void CPRRestoreStreams(PyObject *input, PyObject *output, PyObject *error) {
    PySys_SetObject("stdin", input);
    PySys_SetObject("stdout", output);
    PySys_SetObject("stderr", error);
    Py_XDECREF(input);
    Py_XDECREF(output);
    Py_XDECREF(error);
}

static void CPRSetArguments(NSString *filename, NSArray<NSString *> *arguments) {
    PyObject *list = PyList_New((Py_ssize_t)arguments.count + 1);
    if (list == NULL) return;
    PyList_SET_ITEM(list, 0, PyUnicode_FromString(filename.UTF8String));
    for (NSUInteger index = 0; index < arguments.count; index++) {
        PyList_SET_ITEM(list, (Py_ssize_t)index + 1, PyUnicode_FromString(arguments[index].UTF8String));
    }
    PySys_SetObject("argv", list);
    Py_DECREF(list);
}

static CPRExceptionInfo CPRFetchException(void) {
    CPRExceptionInfo info = {0};
    PyErr_Fetch(&info.type, &info.value, &info.traceback);
    PyErr_NormalizeException(&info.type, &info.value, &info.traceback);
    info.typeText = info.type ? PyObject_GetAttrString(info.type, "__name__") : NULL;
    info.messageText = info.value ? PyObject_Str(info.value) : PyUnicode_FromString("");
    PyObject *module = PyImport_ImportModule("traceback");
    PyObject *formatter = module ? PyObject_GetAttrString(module, "format_exception") : NULL;
    PyObject *lines = formatter ? PyObject_CallFunctionObjArgs(formatter, info.type ?: Py_None, info.value ?: Py_None, info.traceback ?: Py_None, NULL) : NULL;
    PyObject *separator = lines ? PyUnicode_FromString("") : NULL;
    info.tracebackText = separator ? PyUnicode_Join(separator, lines) : NULL;
    if (info.tracebackText == NULL) {
        PyErr_Clear();
        info.tracebackText = info.messageText ? Py_NewRef(info.messageText) : PyUnicode_FromString("Python error");
    }
    Py_XDECREF(separator);
    Py_XDECREF(lines);
    Py_XDECREF(formatter);
    Py_XDECREF(module);
    return info;
}

static void CPRClearException(CPRExceptionInfo *info) {
    Py_XDECREF(info->type);
    Py_XDECREF(info->value);
    Py_XDECREF(info->traceback);
    Py_XDECREF(info->typeText);
    Py_XDECREF(info->messageText);
    Py_XDECREF(info->tracebackText);
    memset(info, 0, sizeof(*info));
}

static PyObject *CPRSysAttribute(const char *name) {
    PyObject *system = PyImport_ImportModule("sys");
    PyObject *value = system ? PyObject_GetAttrString(system, name) : NULL;
    Py_XDECREF(system);
    return value;
}

@implementation CPRPythonEngine

- (BOOL)initializeWithPythonHome:(NSString *)pythonHome error:(NSError **)error {
    pthread_mutex_lock(&CPRInitializationMutex);
    if (CPRActiveEngine != nil && CPRActiveEngine != self) {
        if (error) *error = CPRError(@"另一个 FlutterEngine 正在使用 PythonRuntime");
        pthread_mutex_unlock(&CPRInitializationMutex);
        return NO;
    }
    CPRActiveEngine = self;
    if (CPRInitialized) {
        pthread_mutex_unlock(&CPRInitializationMutex);
        return YES;
    }
    if (!CPRBridgeRegistered && PyImport_AppendInittab("_cpython_runtime_bridge", &PyInit__cpython_runtime_bridge) != 0) {
        CPRActiveEngine = nil;
        if (error) *error = CPRError(@"无法注册 Flutter Python 桥接模块");
        pthread_mutex_unlock(&CPRInitializationMutex);
        return NO;
    }
    CPRBridgeRegistered = 1;
    PyPreConfig preconfig;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    PyStatus status = Py_PreInitialize(&preconfig);
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.install_signal_handlers = 0;
    config.write_bytecode = 0;
    config.buffered_stdio = 0;
    if (!PyStatus_Exception(status)) status = PyConfig_SetBytesString(&config, &config.home, pythonHome.fileSystemRepresentation);
    if (!PyStatus_Exception(status)) {
        const char *arguments[] = {"cpython_runtime", NULL};
        status = PyConfig_SetBytesArgv(&config, 1, (char *const *)arguments);
    }
    if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
    if (PyStatus_Exception(status)) {
        CPRActiveEngine = nil;
        NSString *message = status.err_msg ? [NSString stringWithUTF8String:status.err_msg] : @"CPython 初始化失败";
        if (error) *error = CPRError(message ?: @"CPython 初始化失败");
        PyConfig_Clear(&config);
        pthread_mutex_unlock(&CPRInitializationMutex);
        return NO;
    }
    PyConfig_Clear(&config);
    CPRInitialized = 1;
    CPRMainThreadState = PyEval_SaveThread();
    pthread_mutex_unlock(&CPRInitializationMutex);
    return YES;
}

- (NSDictionary<NSString *, id> *)executeJob:(int64_t)jobId
                                    sessionId:(int64_t)sessionId
                                     evaluate:(BOOL)evaluate
                                       source:(NSString *)source
                                     filename:(NSString *)filename
                                    arguments:(NSArray<NSString *> *)arguments
                              workingDirectory:(NSString *)workingDirectory
                                  projectPath:(NSString *)projectPath {
    NSData *sourceData = [source dataUsingEncoding:NSUTF8StringEncoding];
    if (sourceData == nil || memchr(sourceData.bytes, '\0', sourceData.length) != NULL) {
        return @{ @"exitCode": @1, @"stdout": @"", @"stderr": @"", @"exceptionType": @"ValueError", @"exceptionMessage": @"Python 源码不能包含 NUL 字节", @"traceback": @"" };
    }
    CPROperation operation = {0};
    operation.identifier = jobId;
    operation.sessionIdentifier = sessionId;
    pthread_mutex_lock(&CPROperationMutex);
    if (CPRActiveOperation != NULL) {
        pthread_mutex_unlock(&CPROperationMutex);
        return @{ @"exitCode": @1, @"stdout": @"", @"stderr": @"", @"exceptionType": @"RuntimeError", @"exceptionMessage": @"同一时间只能运行一个 Python 任务", @"traceback": @"" };
    }
    CPRActiveOperation = &operation;
    pthread_mutex_unlock(&CPROperationMutex);
    PyGILState_STATE gil = PyGILState_Ensure();
    pthread_mutex_lock(&CPROperationMutex);
    operation.threadIdentifier = PyThread_get_thread_ident();
    pthread_mutex_unlock(&CPROperationMutex);
    PyObject *oldPath = NULL;
    PyObject *bridge = NULL;
    PyObject *contextToken = NULL;
    PyObject *oldInput = NULL;
    PyObject *oldOutput = NULL;
    PyObject *oldError = NULL;
    PyObject *result = NULL;
    PyObject *valueJSON = NULL;
    PyObject *valueRepresentation = NULL;
    PyObject *binaryValue = NULL;
    CPRExceptionInfo exception = {0};
    int exitCode = 1;
    char previousDirectory[PATH_MAX] = {0};
    int changedDirectory = 0;
    if (self.interruptionHandler != nil && self.interruptionHandler(jobId)) {
        PyErr_SetNone(PyExc_KeyboardInterrupt);
        exception = CPRFetchException();
        goto completed;
    }
    bridge = PyImport_ImportModule("_cpython_runtime_bridge");
    operation.owner = PyDict_New();
    if (bridge != NULL && operation.owner != NULL) {
        if (PyModule_Check(bridge) && PyModule_GetDef(bridge) == &CPRBridgeModule) {
            CPRBridgeState *state = PyModule_GetState(bridge);
            contextToken = PyContextVar_Set(state->context, operation.owner);
        } else {
            PyErr_SetString(PyExc_RuntimeError, "Python bridge module has been replaced");
        }
    }
    if (contextToken == NULL || !CPRInstallStreams(&oldInput, &oldOutput, &oldError)) {
        exception = CPRFetchException();
        goto completed;
    }
    CPRSetArguments(filename, arguments);
    if (projectPath != nil) {
        PyObject *path = PyUnicode_DecodeFSDefault(projectPath.fileSystemRepresentation);
        PyObject *searchPath = PySys_GetObject("path");
        oldPath = searchPath ? PySequence_List(searchPath) : NULL;
        if (path == NULL || oldPath == NULL || PyList_Insert(searchPath, 0, path) < 0) {
            Py_XDECREF(path);
            if (!PyErr_Occurred()) PyErr_SetString(PyExc_RuntimeError, "Unable to set Python project path");
            exception = CPRFetchException();
            goto completed;
        }
        Py_DECREF(path);
    }
    if (workingDirectory.length > 0) {
        if (getcwd(previousDirectory, sizeof(previousDirectory)) != NULL && chdir(workingDirectory.fileSystemRepresentation) == 0) {
            changedDirectory = 1;
        } else {
            PyErr_SetFromErrnoWithFilename(PyExc_OSError, workingDirectory.fileSystemRepresentation);
            exception = CPRFetchException();
            goto completed;
        }
    }
    PyObject *globals = NULL;
    int temporaryGlobals = sessionId == 0;
    if (temporaryGlobals) {
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
        CPRContext *context = CPRGetContext(sessionId, 1);
        globals = context ? context->globals : NULL;
    }
    if (globals == NULL) {
        PyErr_NoMemory();
    } else {
        PyObject *filenameObject = PyUnicode_FromString(filename.UTF8String);
        if (filenameObject != NULL) PyDict_SetItemString(globals, "__file__", filenameObject);
        PyObject *compiled = filenameObject ? Py_CompileStringObject(source.UTF8String, filenameObject, evaluate ? Py_eval_input : Py_file_input, NULL, -1) : NULL;
        result = compiled ? PyEval_EvalCode(compiled, globals, globals) : NULL;
        Py_XDECREF(compiled);
        Py_XDECREF(filenameObject);
    }
    if (result == NULL) {
        exception = CPRFetchException();
        if (exception.type != NULL && PyErr_GivenExceptionMatches(exception.type, PyExc_SystemExit)) {
            PyObject *code = exception.value ? PyObject_GetAttrString(exception.value, "code") : NULL;
            if (code == NULL || code == Py_None) {
                PyErr_Clear();
                exitCode = 0;
            } else if (PyLong_Check(code)) {
                long parsed = PyLong_AsLong(code);
                exitCode = parsed < 0 ? 1 : parsed > 255 ? 255 : (int)parsed;
            }
            Py_XDECREF(code);
            PyErr_Clear();
            if (exitCode == 0) CPRClearException(&exception);
        }
        if (exception.tracebackText != NULL) {
            PyObject *writeArguments = Py_BuildValue("(iO)", 2, exception.tracebackText);
            PyObject *ignored = writeArguments ? CPRBridgeWrite(bridge, writeArguments) : NULL;
            if (ignored == NULL) PyErr_Clear();
            Py_XDECREF(ignored);
            Py_XDECREF(writeArguments);
        }
    } else {
        exitCode = 0;
        if (evaluate) {
            if (PyBytes_Check(result)) {
                binaryValue = Py_NewRef(result);
            } else {
                valueJSON = CPRJSONResult(result);
                if (valueJSON == NULL) PyErr_Clear();
                if (valueJSON != NULL) {
                    Py_ssize_t length = 0;
                    if (PyUnicode_AsUTF8AndSize(valueJSON, &length) == NULL || length > 64 * 1024) {
                        PyErr_Clear();
                        Py_CLEAR(valueJSON);
                        exitCode = 1;
                        PyErr_SetString(PyExc_ValueError, "Python result exceeds 64 KiB");
                        exception = CPRFetchException();
                    }
                }
            }
            valueRepresentation = PyObject_Repr(result);
            if (valueRepresentation == NULL) PyErr_Clear();
        }
    }
    if (binaryValue != NULL && PyBytes_GET_SIZE(binaryValue) > 64 * 1024) {
        Py_CLEAR(binaryValue);
        exitCode = 1;
        PyErr_SetString(PyExc_ValueError, "Python result exceeds 64 KiB");
        exception = CPRFetchException();
    }
    Py_XDECREF(result);
    if (temporaryGlobals) Py_XDECREF(globals);

completed:
    if (oldPath != NULL) {
        if (PySys_SetObject("path", oldPath) < 0) PyErr_Clear();
        Py_DECREF(oldPath);
    }
    if (changedDirectory) chdir(previousDirectory);
    if (oldInput != NULL || oldOutput != NULL || oldError != NULL) CPRRestoreStreams(oldInput, oldOutput, oldError);
    NSMutableDictionary<NSString *, id> *response = [@{
        @"exitCode": @(exitCode),
        @"stdout": CPRString(operation.standardOutput.data, operation.standardOutput.length),
        @"stderr": CPRString(operation.standardError.data, operation.standardError.length)
    } mutableCopy];
    response[@"outputTruncated"] = @(operation.standardOutput.truncated || operation.standardError.truncated);
    NSString *jsonText = CPRPythonString(valueJSON, -1);
    if (jsonText != nil) response[@"valueJson"] = jsonText;
    if (binaryValue != NULL && PyBytes_GET_SIZE(binaryValue) <= 64 * 1024) {
        response[@"binaryValue"] = [NSData dataWithBytes:PyBytes_AS_STRING(binaryValue) length:(NSUInteger)PyBytes_GET_SIZE(binaryValue)];
    }
    NSString *representation = CPRPythonString(valueRepresentation, 64 * 1024);
    if (representation != nil) response[@"valueRepr"] = representation;
    NSString *exceptionType = CPRPythonString(exception.typeText, 4096);
    if (exceptionType != nil) {
        response[@"exceptionType"] = exceptionType;
        response[@"exceptionMessage"] = CPRPythonString(exception.messageText, 64 * 1024) ?: @"";
        response[@"traceback"] = CPRPythonString(exception.tracebackText, 64 * 1024) ?: @"";
    }
    Py_XDECREF(valueJSON);
    Py_XDECREF(binaryValue);
    Py_XDECREF(valueRepresentation);
    CPRClearException(&exception);
    pthread_mutex_lock(&CPROperationMutex);
    CPRActiveOperation = NULL;
    pthread_mutex_unlock(&CPROperationMutex);
    if (contextToken != NULL) {
        CPRBridgeState *state = PyModule_GetState(bridge);
        if (PyContextVar_Reset(state->context, contextToken) < 0) PyErr_Clear();
    }
    Py_XDECREF(contextToken);
    Py_XDECREF(operation.owner);
    Py_XDECREF(bridge);
    PyGILState_Release(gil);
    CPRBufferClear(&operation.standardOutput);
    CPRBufferClear(&operation.standardError);
    return response;
}

- (void)interruptJob:(int64_t)jobId {
    pthread_mutex_lock(&CPRInitializationMutex);
    pthread_mutex_lock(&CPROperationMutex);
    BOOL active = CPRActiveOperation != NULL && CPRActiveOperation->identifier == jobId;
    pthread_mutex_unlock(&CPROperationMutex);
    if (!active || !CPRInitialized || CPRActiveEngine != self) {
        pthread_mutex_unlock(&CPRInitializationMutex);
        return;
    }
    PyGILState_STATE gil = PyGILState_Ensure();
    pthread_mutex_lock(&CPROperationMutex);
    active = CPRActiveOperation != NULL && CPRActiveOperation->identifier == jobId;
    unsigned long threadIdentifier = active ? CPRActiveOperation->threadIdentifier : 0;
    pthread_mutex_unlock(&CPROperationMutex);
    if (!active) {
        PyGILState_Release(gil);
        pthread_mutex_unlock(&CPRInitializationMutex);
        return;
    }
    if (threadIdentifier != 0) {
        int affected = PyThreadState_SetAsyncExc(threadIdentifier, PyExc_KeyboardInterrupt);
        if (affected > 1) PyThreadState_SetAsyncExc(threadIdentifier, NULL);
    }
    PyGILState_Release(gil);
    pthread_mutex_unlock(&CPRInitializationMutex);
    pthread_mutex_lock(&CPRHostCallMutex);
    if (CPRPendingHostCall.identifier != 0 && CPRPendingHostCall.operationIdentifier == jobId && !CPRPendingHostCall.completed) {
        CPRPendingHostCall.error = strdup("Python job was cancelled");
        CPRPendingHostCall.completed = 1;
        pthread_cond_broadcast(&CPRHostCallCondition);
    }
    pthread_mutex_unlock(&CPRHostCallMutex);
}

- (void)destroySession:(int64_t)sessionId {
    if (!CPRInitialized) return;
    PyGILState_STATE gil = PyGILState_Ensure();
    CPRContext **cursor = &CPRContexts;
    while (*cursor != NULL) {
        if ((*cursor)->identifier == sessionId) {
            CPRContext *removed = *cursor;
            *cursor = removed->next;
            Py_DECREF(removed->globals);
            free(removed);
            break;
        }
        cursor = &(*cursor)->next;
    }
    PyGILState_Release(gil);
}

- (void)completeHostCall:(int64_t)callId resultJson:(NSString *)resultJson error:(NSString *)error {
    pthread_mutex_lock(&CPRHostCallMutex);
    if (CPRPendingHostCall.identifier == callId && !CPRPendingHostCall.completed) {
        CPRPendingHostCall.resultJSON = resultJson ? strdup(resultJson.UTF8String) : NULL;
        CPRPendingHostCall.error = error ? strdup(error.UTF8String) : NULL;
        CPRPendingHostCall.completed = 1;
        pthread_cond_broadcast(&CPRHostCallCondition);
    }
    pthread_mutex_unlock(&CPRHostCallMutex);
}

- (NSDictionary<NSString *, id> *)runtimeInfo {
    if (!CPRInitialized) return @{};
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *version = CPRSysAttribute("version");
    PyObject *platform = CPRSysAttribute("platform");
    PyObject *executable = CPRSysAttribute("executable");
    PyObject *prefix = CPRSysAttribute("prefix");
    PyObject *path = CPRSysAttribute("path");
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    if (path != NULL && PyList_Check(path)) {
        for (Py_ssize_t index = 0; index < PyList_GET_SIZE(path); index++) {
            NSString *item = CPRPythonString(PyList_GET_ITEM(path, index), -1);
            if (item != nil) [paths addObject:item];
        }
    }
    NSDictionary *result = @{
        @"version": CPRPythonString(version, -1) ?: @"",
        @"platform": CPRPythonString(platform, -1) ?: @"",
        @"executable": CPRPythonString(executable, -1) ?: @"",
        @"prefix": CPRPythonString(prefix, -1) ?: @"",
        @"moduleSearchPaths": paths
    };
    Py_XDECREF(path);
    Py_XDECREF(prefix);
    Py_XDECREF(executable);
    Py_XDECREF(platform);
    Py_XDECREF(version);
    PyGILState_Release(gil);
    return result;
}

- (void)dispose {
    pthread_mutex_lock(&CPRInitializationMutex);
    if (!CPRInitialized || CPRActiveEngine != self) {
        pthread_mutex_unlock(&CPRInitializationMutex);
        return;
    }
    pthread_mutex_lock(&CPRHostCallMutex);
    if (CPRPendingHostCall.identifier != 0 && !CPRPendingHostCall.completed) {
        CPRPendingHostCall.error = strdup("PythonRuntime has been disposed");
        CPRPendingHostCall.completed = 1;
        pthread_cond_broadcast(&CPRHostCallCondition);
    }
    pthread_mutex_unlock(&CPRHostCallMutex);
    PyEval_RestoreThread(CPRMainThreadState);
    CPRMainThreadState = NULL;
    while (CPRContexts != NULL) {
        CPRContext *removed = CPRContexts;
        CPRContexts = removed->next;
        Py_DECREF(removed->globals);
        free(removed);
    }
    CPRActiveEngine = nil;
    CPRInitialized = 0;
    Py_FinalizeEx();
    CPRBridgeRegistered = 0;
    pthread_mutex_unlock(&CPRInitializationMutex);
}

- (void)dispatchEvent:(NSDictionary<NSString *,id> *)event {
    CPRPythonEventHandler handler = self.eventHandler;
    if (handler != nil) handler(event);
}

@end
