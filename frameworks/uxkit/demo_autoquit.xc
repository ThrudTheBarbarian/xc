// demo_autoquit.xc — let an interactive demo close itself.
//
// The demos exist to be looked at and poked, so they sit in their run loop
// until the window is closed.  That makes them unusable in an unattended sweep:
// they hang until something kills them, and a killed demo reports nothing —
// it looks identical to one that crashed.
//
// So: UX_AUTOQUIT, in milliseconds.  Unset, nothing changes and the demo waits
// for you as before.  Set, the demo closes itself after that long, by the SAME
// path the close box takes — the run loop unwinds, main returns, and whatever
// the demo prints on the way out gets printed.  An auto-quit that killed the
// process instead would make the unattended run prove less than the attended
// one, which defeats the point of running it at all.
//
// The gate scripts wrap this as `--auto-quit [ms]`, so the option lives where
// options already live; an XC main() takes no argv.
void ux_ak_close_after_ms(i32 ms);
u8* getenv(u8* name);

#define UX_AUTOQUIT_DEFAULT 1500
#define UX_AUTOQUIT_MIN 200 // below this the window may not have appeared

// The requested delay in ms, or 0 for "don't".
i32 uxAutoQuitMs(void)
    {
    u8* v = getenv((u8*)"UX_AUTOQUIT");
    if (v == (u8*)0 || v[0] == (u8)0)
        {
        return (i32)0;
        }
    i32 ms = (i32)0;
    i32 i = (i32)0;
    bool digits = false;
    while (v[i] >= (u8)48 && v[i] <= (u8)57)
        {
        ms = ms * (i32)10 + ((i32)v[i] - (i32)48);
        i = i + (i32)1;
        digits = true;
        }
    // Set but not a number ("yes", "1s", "on") still means "quit by yourself" —
    // reading it as zero would silently hang, which is the failure this exists
    // to remove.
    if (!digits || ms <= (i32)0)
        {
        return (i32)UX_AUTOQUIT_DEFAULT;
        }
    if (ms < (i32)UX_AUTOQUIT_MIN)
        {
        return (i32)UX_AUTOQUIT_MIN;
        }
    return ms;
    }

// Call once, just before app.run().
void uxAutoQuit(void)
    {
    i32 ms = uxAutoQuitMs();
    if (ms > (i32)0)
        {
        ux_ak_close_after_ms(ms);
        }
    }
