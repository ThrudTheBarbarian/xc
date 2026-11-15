/* A small shared library that frees, reallocs and sizes memory it did not
   allocate, as a C library that takes ownership of a buffer does. */
#include <stdlib.h>
#ifdef __APPLE__
#include <malloc/malloc.h>
size_t lib_usable(void* p) { return malloc_size(p); }
#else
#include <malloc.h>
size_t lib_usable(void* p) { return malloc_usable_size(p); }
#endif
void lib_free(void* p) { free(p); }
void* lib_realloc(void* p, size_t n) { return realloc(p, n); }
