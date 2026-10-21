// The stack canary's two runtime symbols, for the fixtures linked against a
// bare C stub instead of xcc's runtime (rt.c defines them there): a guard
// word, set before main, and the routine a failed check calls.
#include <stdio.h>
#include <stdlib.h>
unsigned long __xt_stack_guard;
__attribute__((constructor)) static void xt_stack_guard_set(void) { arc4random_buf(&__xt_stack_guard, sizeof __xt_stack_guard); __xt_stack_guard &= ~0xFFUL; }
void __xt_stack_fail(void) { fprintf(stderr, "stack smashing detected\n"); abort(); }
