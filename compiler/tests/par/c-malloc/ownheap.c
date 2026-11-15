/* A custom allocator: malloc, calloc, realloc and free from a static pool,
   each block with its size in front. The program that defines them keeps
   them: xcc's heap stays out (ownmain.c uses them, alone or as a second
   object). */
#include <stddef.h>
#include <string.h>

#define POOL (48u << 20)
static unsigned char pool[POOL] __attribute__((aligned(16)));
static size_t used;
int pool_has(const void* p) { return (const unsigned char*)p >= pool && (const unsigned char*)p < pool + POOL; }

void* malloc(size_t n)
    {
    n = (n + 15) & ~(size_t)15;
    if (used + n + 16 > POOL)
        return 0;
    unsigned char* p = pool + used + 16;
    *(size_t*)(p - 16) = n;
    used += n + 16;
    return p;
    }
void free(void* p) { (void)p; }
void* calloc(size_t a, size_t b)
    {
    void* p = malloc(a * b);
    if (p)
        memset(p, 0, a * b);
    return p;
    }
void* realloc(void* p, size_t n)
    {
    void* q = malloc(n);
    if (q && p)
        {
        size_t old = *(size_t*)((unsigned char*)p - 16);
        memcpy(q, p, old < n ? old : n);
        }
    return q;
    }
