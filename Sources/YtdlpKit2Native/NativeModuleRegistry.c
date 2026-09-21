#include "YtdlpKit2Native.h"
#include <dlfcn.h>

typedef struct _object PyObject;
typedef PyObject *(*init_function)(void);
typedef int (*append_inittab_function)(const char *, init_function);

extern PyObject *PyInit__ytdlpkit_native(void);
#ifdef YTDLPKIT_HAS_BROTLI
extern PyObject *PyInit__brotli(void);
#endif

int YtdlpKit2_RegisterNativePythonModules(void) {
    append_inittab_function append =
        (append_inittab_function)dlsym(RTLD_DEFAULT, "PyImport_AppendInittab");
    if (append == 0) return -1;
    if (append("_ytdlpkit_native", PyInit__ytdlpkit_native) != 0) return -1;
#ifdef YTDLPKIT_HAS_BROTLI
    if (append("_brotli", PyInit__brotli) != 0) return -1;
#endif
    return 0;
}
