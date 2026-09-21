#include "YtdlpKit2Native.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <stdint.h>

static pthread_mutex_t root_lock = PTHREAD_MUTEX_INITIALIZER;
static char *runtime_root = NULL;
static YtdlpKit2EventCallback event_callback = NULL;
static YtdlpKit2LogCallback log_callback = NULL;
static YtdlpKit2CancellationCallback cancellation_callback = NULL;
static YtdlpKit2MediaCallback media_callback = NULL;

void YtdlpKit2_SetRuntimeRoot(const char *path) {
    pthread_mutex_lock(&root_lock);
    free(runtime_root);
    runtime_root = path ? strdup(path) : NULL;
    pthread_mutex_unlock(&root_lock);
}

const char *YtdlpKit2_CopyRuntimeRoot(void) {
    const char *result;
    pthread_mutex_lock(&root_lock);
    result = runtime_root ? strdup(runtime_root) : strdup("");
    pthread_mutex_unlock(&root_lock);
    return result;
}

void YtdlpKit2_SetEventCallback(YtdlpKit2EventCallback callback) {
    pthread_mutex_lock(&root_lock); event_callback = callback; pthread_mutex_unlock(&root_lock);
}
void YtdlpKit2_SetLogCallback(YtdlpKit2LogCallback callback) {
    pthread_mutex_lock(&root_lock); log_callback = callback; pthread_mutex_unlock(&root_lock);
}
void YtdlpKit2_SetCancellationCallback(YtdlpKit2CancellationCallback callback) {
    pthread_mutex_lock(&root_lock); cancellation_callback = callback; pthread_mutex_unlock(&root_lock);
}
void YtdlpKit2_SetMediaCallback(YtdlpKit2MediaCallback callback) {
    pthread_mutex_lock(&root_lock); media_callback = callback; pthread_mutex_unlock(&root_lock);
}
void YtdlpKit2_EmitEvent(const char *operation_id, const char *payload_json) {
    pthread_mutex_lock(&root_lock); YtdlpKit2EventCallback callback = event_callback; pthread_mutex_unlock(&root_lock);
    if (callback) callback(operation_id, payload_json);
}
void YtdlpKit2_EmitLog(const char *operation_id, const char *level, const char *message) {
    pthread_mutex_lock(&root_lock); YtdlpKit2LogCallback callback = log_callback; pthread_mutex_unlock(&root_lock);
    if (callback) callback(operation_id, level, message);
}
int YtdlpKit2_IsCancelled(const char *operation_id) {
    pthread_mutex_lock(&root_lock); YtdlpKit2CancellationCallback callback = cancellation_callback; pthread_mutex_unlock(&root_lock);
    return callback ? callback(operation_id) : 0;
}
char *YtdlpKit2_ExecuteMedia(const char *operation_id, const char *kind,
                            const char *arguments_json) {
    pthread_mutex_lock(&root_lock); YtdlpKit2MediaCallback callback = media_callback; pthread_mutex_unlock(&root_lock);
    if (callback) return callback(operation_id, kind, arguments_json);
    return strdup("{\"returncode\":127,\"stdout\":\"\",\"stderr\":\"FFmpegKitNext is not bundled\",\"cancelled\":false}");
}

void YtdlpKit2_ReleaseInitialGIL(void) {
    void *(*save_thread)(void) = (void *(*)(void))dlsym(RTLD_DEFAULT, "PyEval_SaveThread");
    if (save_thread) (void)save_thread();
}

void *YtdlpKit2_AcquireGIL(void) {
    int (*ensure)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "PyGILState_Ensure");
    return ensure ? (void *)(intptr_t)(ensure() + 1) : NULL;
}

void YtdlpKit2_ReleaseGIL(void *state) {
    void (*release)(int) = (void (*)(int))dlsym(RTLD_DEFAULT, "PyGILState_Release");
    if (release && state) release((int)((intptr_t)state - 1));
}
