/* Genuinely foreign C (clang), C ABI. Stands in for a native toolkit that
   calls your registered handler with a user_data context word. */
void run_callback_n(void (*cb)(void*), void* ctx, int n)
    {
    for (int i = 0; i < n; i++)
        cb(ctx);
    }
