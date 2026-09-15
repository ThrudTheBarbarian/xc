// test_notify.xc — the neutral notification centre: post / observe / filter / remove / weak-prune.
//
// Pure toolkit logic, no backend: it runs natively (xtc -A arm64), naming no GEM or AppKit code.
//
//   Build+run:  xtc -A arm64 -I . test_notify.xc -o t && ./t
#import <Stdio.xc>
#import "UXNotificationCenter.xc"

#define NAME_A (u8*)"evt.a"
#define NAME_B (u8*)"evt.b"

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }

// A sender identity (notifications carry it as `object`); it holds no state.
class Sender : Object
    {
    void init(void)
        {
        }
    }

    // An observer: counts what it hears and remembers the last payload.
    class Watcher : Object
    {
    i32 hits;
    i32 lastA;
    i32 lastB;
    void init(void)
        {
        hits = (i32)0;
        lastA = (i32)0;
        lastB = (i32)0;
        }
    void onEvent(UXNotification* n)
        {
        hits = hits + (i32)1;
        lastA = n.a;
        lastB = n.b;
        }
    }

    void
    main(void)
    {
    gFails = (i32)0;
    UXNotificationCenter* c = UXNotificationCenter.shared();

    Sender* s1 = new Sender();
    Sender* s2 = new Sender();
    Watcher* w = new Watcher();

    // 1. a name-only subscription hears matching posts, with the payload
    c.addObserver((Object*)w, &w.onEvent, NAME_A, (Object*)0);
    c.postWith(NAME_A, (Object*)s1, (i32)11, (i32)22);
    check("heard the matching post", w.hits, (i32)1);
    check("payload a delivered", w.lastA, (i32)11);
    check("payload b delivered", w.lastB, (i32)22);

    // 2. a different name is NOT heard
    c.postWith(NAME_B, (Object*)s1, (i32)0, (i32)0);
    check("a different name is ignored", w.hits, (i32)1);

    // 3. remove, and posts stop arriving
    c.removeObserver((Object*)w);
    c.postWith(NAME_A, (Object*)s1, (i32)0, (i32)0);
    check("after removeObserver, silence", w.hits, (i32)1);

    // 4. sender filter: only posts from s1 count
    Watcher* w2 = new Watcher();
    c.addObserver((Object*)w2, &w2.onEvent, NAME_A, (Object*)s1);
    c.postWith(NAME_A, (Object*)s2, (i32)0, (i32)0); // wrong sender
    check("wrong sender filtered out", w2.hits, (i32)0);
    c.postWith(NAME_A, (Object*)s1, (i32)0, (i32)0); // right sender
    check("right sender delivered", w2.hits, (i32)1);
    c.removeObserver((Object*)w2);

    // 5. an any-name observer (name 0) hears everything
    Watcher* w3 = new Watcher();
    c.addObserver((Object*)w3, &w3.onEvent, (u8*)0, (Object*)0);
    c.postWith(NAME_A, (Object*)s1, (i32)0, (i32)0);
    c.postWith(NAME_B, (Object*)s2, (i32)0, (i32)0);
    check("any-name observer hears both", w3.hits, (i32)2);
    c.removeObserver((Object*)w3);

    // 6. a dropped observer is auto-pruned: its weak method zeroes, so a post neither
    //    calls it nor crashes.  (We cannot force dealloc here, but a live post after every
    //    observer removed must simply do nothing.)
    c.postWith(NAME_A, (Object*)s1, (i32)0, (i32)0);
    check("no observers -> no delivery, no crash", w3.hits, (i32)2);

    Stdio.printf(gFails == (i32)0
                     ? "PASS: the neutral notification centre (post / filter / remove) is correct\n"
                     : "FAIL: %d notification checks failed\n",
                 (i16)gFails);
    }
