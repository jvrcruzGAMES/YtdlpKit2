#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>

typedef intptr_t Py_ssize_t;
typedef struct _object {
    Py_ssize_t ob_refcnt;
    void *ob_type;
} PyObject;
typedef PyObject *(*PyCFunction)(PyObject *, PyObject *);
typedef struct PyMethodDef {
    const char *ml_name;
    PyCFunction ml_meth;
    int ml_flags;
    const char *ml_doc;
} PyMethodDef;
typedef struct PyModuleDef_Base {
    PyObject ob_base;
    PyObject *(*m_init)(void);
    Py_ssize_t m_index;
    PyObject *m_copy;
} PyModuleDef_Base;
typedef struct PyModuleDef {
    PyModuleDef_Base m_base;
    const char *m_name;
    const char *m_doc;
    Py_ssize_t m_size;
    PyMethodDef *m_methods;
    void *m_slots, *m_traverse, *m_clear, *m_free;
} PyModuleDef;

#define METH_VARARGS 0x0001
#define METH_NOARGS 0x0004

extern const char *YtdlpKit2_CopyRuntimeRoot(void);
extern void YtdlpKit2_EmitEvent(const char *, const char *);
extern void YtdlpKit2_EmitLog(const char *, const char *, const char *);
extern int YtdlpKit2_IsCancelled(const char *);
extern char *YtdlpKit2_ExecuteMedia(const char *, const char *, const char *);

static void *symbol(const char *name) { return dlsym(RTLD_DEFAULT, name); }

static PyObject *python_none(void) {
    PyObject *(*get_constant)(unsigned int) = symbol("Py_GetConstant");
    return get_constant ? get_constant(0) : NULL;
}

static PyObject *native_log(PyObject *self, PyObject *args) {
    (void)self;
    const char *message = NULL;
    int (*parse)(PyObject *, const char *, ...) = symbol("PyArg_ParseTuple");
    if (!parse || !parse(args, "s", &message)) return NULL;
    (void)message; /* Hook point for a future Swift log callback. */
    return python_none();
}

static PyObject *native_emit_event(PyObject *self, PyObject *args) {
    (void)self;
    const char *operation_id = NULL, *payload = NULL;
    int (*parse)(PyObject *, const char *, ...) = symbol("PyArg_ParseTuple");
    if (!parse || !parse(args, "ss", &operation_id, &payload)) return NULL;
    YtdlpKit2_EmitEvent(operation_id, payload);
    return python_none();
}

static PyObject *native_emit_log(PyObject *self, PyObject *args) {
    (void)self;
    const char *operation_id = NULL, *level = NULL, *message = NULL;
    int (*parse)(PyObject *, const char *, ...) = symbol("PyArg_ParseTuple");
    if (!parse || !parse(args, "sss", &operation_id, &level, &message)) return NULL;
    YtdlpKit2_EmitLog(operation_id, level, message);
    return python_none();
}

static PyObject *native_is_cancelled(PyObject *self, PyObject *args) {
    (void)self;
    const char *operation_id = NULL;
    int (*parse)(PyObject *, const char *, ...) = symbol("PyArg_ParseTuple");
    PyObject *(*from_long)(long) = symbol("PyBool_FromLong");
    if (!parse || !parse(args, "s", &operation_id)) return NULL;
    return from_long ? from_long(YtdlpKit2_IsCancelled(operation_id)) : NULL;
}

static PyObject *native_media(PyObject *args, const char *kind) {
    const char *operation_id = NULL, *arguments_json = NULL;
    int (*parse)(PyObject *, const char *, ...) = symbol("PyArg_ParseTuple");
    PyObject *(*from_string)(const char *) = symbol("PyUnicode_FromString");
    void *(*save_thread)(void) = symbol("PyEval_SaveThread");
    void (*restore_thread)(void *) = symbol("PyEval_RestoreThread");
    if (!parse || !parse(args, "ss", &operation_id, &arguments_json)) return NULL;
    /* Native execution may block. Release the GIL while Swift/FFmpegKitNext runs. */
    void *thread_state = save_thread ? save_thread() : NULL;
    char *json = YtdlpKit2_ExecuteMedia(operation_id, kind, arguments_json);
    if (restore_thread && thread_state) restore_thread(thread_state);
    PyObject *result = from_string ? from_string(json ? json : "") : NULL;
    free(json);
    return result;
}

static PyObject *native_ffmpeg(PyObject *self, PyObject *args) {
    (void)self; return native_media(args, "ffmpeg");
}
static PyObject *native_ffprobe(PyObject *self, PyObject *args) {
    (void)self; return native_media(args, "ffprobe");
}

static PyObject *native_bridge_version(PyObject *self, PyObject *args) {
    (void)self; (void)args;
    PyObject *(*from_string)(const char *) = symbol("PyUnicode_FromString");
    return from_string ? from_string("1") : NULL;
}

static PyObject *native_runtime_root(PyObject *self, PyObject *args) {
    (void)self; (void)args;
    PyObject *(*from_string)(const char *) = symbol("PyUnicode_FromString");
    const char *root = YtdlpKit2_CopyRuntimeRoot();
    PyObject *result = from_string ? from_string(root) : NULL;
    free((void *)root);
    return result;
}

static PyMethodDef methods[] = {
    {"log", native_log, METH_VARARGS, "Write a message through the native bridge."},
    {"bridge_version", native_bridge_version, METH_NOARGS, "Return the bridge ABI version."},
    {"runtime_root", native_runtime_root, METH_NOARGS, "Return the writable runtime root."},
    {"emit_download_event", native_emit_event, METH_VARARGS, "Emit structured download JSON."},
    {"emit_log", native_emit_log, METH_VARARGS, "Emit a structured log message."},
    {"is_cancelled", native_is_cancelled, METH_VARARGS, "Query an operation cancellation flag."},
    {"ffmpeg", native_ffmpeg, METH_VARARGS, "Execute FFmpeg through the signed native backend."},
    {"ffprobe", native_ffprobe, METH_VARARGS, "Execute FFprobe through the signed native backend."},
    {NULL, NULL, 0, NULL}
};

static PyModuleDef module = {
    {{1, NULL}, NULL, 0, NULL}, "_ytdlpkit_native",
    "YtdlpKit2's stable native bridge.", -1, methods,
    NULL, NULL, NULL, NULL
};

__attribute__((visibility("default")))
PyObject *PyInit__ytdlpkit_native(void) {
    PyObject *(*create)(PyModuleDef *, int) = symbol("PyModule_Create2");
    /* PYTHON_API_VERSION has remained 1013 since Python 3.2. */
    return create ? create(&module, 1013) : NULL;
}
