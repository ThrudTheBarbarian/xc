/* Memory passed between a C program and C libraries, with the program's own
   blocks of 64 KB and more allocated by xcc's runtime (rt-cmalloc.c): a
   large buffer getline reallocs, then the program frees; strdup's and
   asprintf's memory the program frees; large blocks a linked library and a
   dlopen()ed one realloc, size and free. calloc'd blocks are used where the
   C library's own free could not take a runtime block, so a call that missed
   the runtime would fail here. `roundtrip <file with a long line> <libfree>` */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#ifdef __APPLE__
#include <malloc/malloc.h>
#define usable(p) malloc_size(p)
#else
#include <malloc.h>
#define usable(p) malloc_usable_size(p)
#endif

void lib_free(void* p);
void* lib_realloc(void* p, size_t n);
size_t lib_usable(void* p);

static unsigned long sum(const unsigned char* p, size_t n)
    {
    unsigned long s = 0;
    for (size_t i = 0; i < n; i++)
        s = s * 31 + p[i];
    return s;
    }

int main(int argc, char** argv)
    {
    if (argc < 3)
        return 2;
    /* getline grows the program's 64 KB buffer (the line is longer). */
    FILE* f = fopen(argv[1], "r");
    if (!f)
        return 2;
    size_t cap = 1 << 16;
    char* line = calloc(cap, 1);
    ssize_t n = getline(&line, &cap, f);
    printf("getline: %zd bytes, sum %lu, capacity grown %d\n", n, sum((unsigned char*)line, (size_t)n), cap > (1 << 16));
    free(line);
    fclose(f);
    /* The C library's memory, freed by the program. */
    char* d = strdup("a string strdup made");
    char* a = 0;
    if (asprintf(&a, "%s %d", "asprintf made", 42) < 0)
        return 3;
    printf("%s / %s\n", d, a);
    free(d);
    free(a);
    /* A large block the linked library reallocs, sizes and frees. */
    unsigned char* b = calloc(1 << 20, 1);
    for (int i = 0; i < (1 << 20); i++)
        b[i] = (unsigned char)(i * 7);
    printf("usable here %d, in the library %d\n", usable(b) >= (1 << 20), lib_usable(b) == usable(b));
    b = lib_realloc(b, 3 << 20);
    printf("after the library's realloc: sum %lu, usable %d\n", sum(b, 1 << 20), usable(b) >= (3 << 20));
    b = realloc(b, 1 << 19);
    printf("after the program's realloc: sum %lu\n", sum(b, 1 << 19));
    lib_free(b);
    unsigned char* m = malloc(200000);
    memset(m, 5, 200000);
    lib_free(m);
    /* And a dlopen()ed one. */
    void* h = dlopen(argv[2], RTLD_NOW);
    if (!h)
        {
        printf("dlopen: %s\n", dlerror());
        return 4;
        }
    void (*dfree)(void*) = (void (*)(void*))dlsym(h, "lib_free");
    void* (*drealloc)(void*, size_t) = (void* (*)(void*, size_t))dlsym(h, "lib_realloc");
    size_t (*dusable)(void*) = (size_t (*)(void*))dlsym(h, "lib_usable");
    unsigned char* c = calloc(1 << 18, 1);
    c[5] = 3;
    c = drealloc(c, 1 << 21);
    printf("dlopen: usable %d, sum %lu\n", dusable(c) == usable(c), sum(c, 1 << 18));
    dfree(c);
    /* Small blocks are the C library's, both ways. */
    char* s = malloc(100);
    strcpy(s, "small");
    s = lib_realloc(s, 200);
    printf("%s\n", s);
    lib_free(s);
    printf("done\n");
    return 0;
    }
