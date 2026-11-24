/* The C side of global_instance_c: g names the instance's fields, laid out
   as a struct with the vtable pointer first, as a heap reference does. */
#include <stdint.h>
struct P { void* vtable; int32_t a; int32_t b; };
extern struct P g;
int32_t c_sum(void) { return g.a + g.b; }
void c_set(int32_t a) { g.a = a; }
void* c_addr(void) { return &g; }
uint32_t c_count(void) { return ((uint32_t*)&g)[-1]; }
