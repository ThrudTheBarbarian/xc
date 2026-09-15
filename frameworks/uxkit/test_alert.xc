// test_alert.xc — alerts, and the first MODAL thing in the toolkit.
//
// form_alert blocks: it builds the dialog, saves what is underneath, and runs its own
// event loop until a button is chosen.  So a headless test needs to FEED it input —
// and it can, because the AES's input source is pluggable (aes_set_events).
//
// That is the same seam gemd depends on (a client reads the server's channel instead
// of sys_input), so this test exercises it as a side-effect.
#import <Stdio.xc>
#import <GEM>
#import "UXApplication.xc"
#import "UXGemDriver.xc"
#import "UXAlert.xc"
#import "UXBoot.xc"

// Our fake input source.  form_alert's loop calls this instead of the keyboard.
// Return (0x0D) fires the OF_DEFAULT button, so the alert returns defaultButton.
i32 gFeeds;
i32 fake_events(pointer evp, i32 timeout_ms)
    {
    aes_event* ev = (aes_event*)evp;
    gFeeds = gFeeds + (i32)1;
    ev.type = (i32)AES_KEY;
    ev.key = (i32)13; // Return
    ev.shift = (i32)0;
    ev.mx = (i32)0;
    ev.my = (i32)0;
    ev.button = (i32)0;
    ev.wheel = (i32)0;
    return (i32)AES_KEY;
    }

class Controller : Object<UXApplicationDelegate>
    {
    void init(void)
        {
        }

    i32 applicationDidStart(UXApplication* a)
        {
        // The alert must FIT the screen: gemd sizes the dialog window's surface to the alert
        // and refuses one taller/wider than the plane. The qemu test screen is only 200x120
        // (the pixel tests depend on that), and a GEM alert's icon alone is 46px tall, which
        // pushes the box to 128 — over the 120px screen. So we run icon-less here (box height
        // 100). A real display shows the icon and full multi-line text; what THIS test verifies
        // is the modal loop and the returned button, not the layout.
        UXAlert* al = new UXAlert();
        al.icon = (i32)0; // no icon — keep the box under the 120px screen
        al.addLine("Discard?");
        al.addButton("Yes");
        al.addButton("No");
        al.defaultButton = (i32)2; // "No" is the safe default

        Stdio.printf("1. alert model: icon=%d lines=%s buttons=%s default=%d\n",
                     al.icon, al.lines, al.buttons, al.defaultButton);

        // plug in the fake source, then run the MODAL dialog
        gFeeds = (i32)0;
        aes_set_events((pointer)&fake_events);
        i32 btn = al.runModal();
        Stdio.printf("2. runModal() -> button %d (Return fires the default, which is 2)\n", btn);
        Stdio.printf("3. the fake input source was called %d time(s)\n", gFeeds);

        // and again with a different default, to prove it is not a fluke
        UXAlert* b = new UXAlert();
        b.icon = (i32)0; // icon-less, same reason as above
        b.addLine("Save?");
        b.addButton("Save");
        b.addButton("No");
        b.defaultButton = (i32)1;
        i32 btn2 = b.runModal();
        Stdio.printf("4. second alert, default 1 -> button %d\n", btn2);

        if (btn == (i32)2 && btn2 == (i32)1 && gFeeds > (i32)0)
            {
            Stdio.printf("PASS: model -> alert string -> form_alert -> modal loop -> button.\n");
            Stdio.printf("      And the AES's input source really is pluggable, which is\n");
            Stdio.printf("      the seam gemd routes its clients' input through.\n");
            }
        else
            {
            Stdio.printf("FAIL: btn=%d btn2=%d feeds=%d\n", btn, btn2, gFeeds);
            }
        a.stop();
        return (i32)0;
        }
    }

    void
    main(void)
    {
    // qemu has no SD card, so init started no gemd.  TEST-ONLY (UXBoot.xc).
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }

    gDriver = new UXGemDriver(); // select the GEM backend (UXApplication is neutral)
    UXApplication* app = new UXApplication();
    Controller* c = new Controller();
    app.setDelegate(c);
    app.run();
    }
