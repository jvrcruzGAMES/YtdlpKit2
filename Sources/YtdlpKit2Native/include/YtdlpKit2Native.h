#ifndef YTDLPKIT2_NATIVE_H
#define YTDLPKIT2_NATIVE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Registers all statically linked Python extension modules. Call after the
/// CPython image is loaded, but before Py_Initialize.
int YtdlpKit2_RegisterNativePythonModules(void);
void YtdlpKit2_SetRuntimeRoot(const char *path);

typedef void (*YtdlpKit2EventCallback)(const char *operation_id, const char *payload_json);
typedef void (*YtdlpKit2LogCallback)(const char *operation_id, const char *level, const char *message);
typedef int (*YtdlpKit2CancellationCallback)(const char *operation_id);
/// Returned JSON must be allocated with malloc; the bridge releases it with free.
typedef char *(*YtdlpKit2MediaCallback)(const char *operation_id,
                                       const char *kind,
                                       const char *arguments_json);

void YtdlpKit2_SetEventCallback(YtdlpKit2EventCallback callback);
void YtdlpKit2_SetLogCallback(YtdlpKit2LogCallback callback);
void YtdlpKit2_SetCancellationCallback(YtdlpKit2CancellationCallback callback);
void YtdlpKit2_SetMediaCallback(YtdlpKit2MediaCallback callback);
void YtdlpKit2_EmitEvent(const char *operation_id, const char *payload_json);
void YtdlpKit2_EmitLog(const char *operation_id, const char *level, const char *message);
int YtdlpKit2_IsCancelled(const char *operation_id);
char *YtdlpKit2_ExecuteMedia(const char *operation_id, const char *kind,
                            const char *arguments_json);
void YtdlpKit2_ReleaseInitialGIL(void);
void *YtdlpKit2_AcquireGIL(void);
void YtdlpKit2_ReleaseGIL(void *state);

#ifdef __cplusplus
}
#endif
#endif
