// demo_autoquit.xc — an interactive demo closes ITSELF, so it cannot camp on the screen.
//
// These demos show a real window and take keyboard focus.  Left to wait for a human
// they hang until something kills them — and a killed demo reports nothing, which is
// indistinguishable from one that crashed.  A window that grabs focus and sits there
// is worse than useless while anything else is running.
//
// So the demo closes itself after UX_AUTOQUIT milliseconds (default 1500).  It goes by
// the SAME path the close box takes: the run loop unwinds, main returns, and whatever
// the demo prints on the way out is printed — so an unattended run proves as much as
// an attended one.
//
//   UX_AUTOQUIT unset            -> close after 1500 ms
//   UX_AUTOQUIT=<ms>             -> close after <ms> (below 200 is raised to it,
//                                   since the window may not have appeared yet)
//   UX_AUTOQUIT=0|off|no|none    -> don't; sit in the run loop for a human to poke,
//                                   which is what the demos are for when you ask
//
// The gate scripts wrap this as `--stay` (keep the window up) and `--auto-quit [ms]`;
// an XC main() takes no argv, so the option lives here and reaches the binary as an
// environment variable.
void ux_ak_close_after_ms(i32 ms);
u8* getenv(u8* name);

#define UX_AUTOQUIT_DEFAULT 1500
#define UX_AUTOQUIT_MIN 200 // below this the window may not have appeared

// True for an explicit "don't" — the only values that mean "wait for me".
bool uxAutoQuitOff(u8* v)
    {
    if (v[0] == (u8)'0' && v[1] == (u8)0)
        {
        return true;
        }
    if (v[0] == (u8)'o' && v[1] == (u8)'f' && v[2] == (u8)'f' && v[3] == (u8)0)
        {
        return true;
        }
    if (v[0] == (u8)'n' && v[1] == (u8)'o' && v[2] == (u8)0)
        {
        return true;
        }
    if (v[0] == (u8)'n' && v[1] == (u8)'o' && v[2] == (u8)'n' && v[3] == (u8)'e' && v[4] == (u8)0)
        {
        return true;
        }
    return false;
    }

// The delay in ms, or 0 for "wait for a human".
i32 uxAutoQuitMs(void)
    {
    u8* v = getenv((u8*)"UX_AUTOQUIT");
    if (v == (u8*)0 || v[0] == (u8)0)
        {
        return (i32)UX_AUTOQUIT_DEFAULT;
        }
    if (uxAutoQuitOff(v))
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
