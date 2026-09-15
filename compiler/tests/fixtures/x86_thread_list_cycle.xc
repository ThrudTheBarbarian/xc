//xtc-na: xt6502,wasm32,win64,m68k,arm9 — needs a host pthread thread list (musl on x86_64, libSystem on arm64); no threads on xt6502, wasm threads unwired, win64 has no pthread_key_*
// x86_thread_list_cycle.xc — guards the x86_64 crt thread-list setup.
//
// The main thread's `struct pthread` must be a circular list of one
// (self->prev = self->next = self), the way musl's __init_tp sets it. If the
// crt leaves prev/next NULL, any code that WALKS the list faults on the second
// node: pthread_key_delete does `do td->tsd[k]=0; while ((td=td->next)!=self)`,
// and pthread_create's list insert touches self->next->prev. libpq exposed this
// at process exit — OpenSSL registers a key-cleanup via atexit and it segfaulted
// walking a NULL `next`. A libpq-free repro: create a key, then delete it.
#use Stdio
i32 pthread_key_create(pointer keyp, pointer destr);
i32 pthread_key_delete(u32 key);
i32 main(i32 argc, u8** argv)
{
    u32 key = (u32)0;
    if (pthread_key_create(&key, (pointer)0) != (i32)0) { printf("create-failed\n"); return (i32)1; }
    pthread_key_delete(key);   // walks the circular thread list; a NULL next crashed here
    printf("thread-list-ok\n");
    return (i32)0;
}
