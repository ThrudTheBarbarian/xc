// test_nav.xc — UXNavigationController model: the stack, forward/back, the
// §5 lifecycle notifications, and back-affordance truth (no window needed).
#import <Stdio.xc>
#import "UXNavigationController.xc"
#import "UXView.xc"

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
bool streq(u8* a, u8* b)
    {
    i32 i = (i32)0;
    while (a[i] != (u8)0 && b[i] != (u8)0)
        {
        if (a[i] != b[i])
            {
            return false;
            }
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }
void eq(u8* what, u8* got, u8* want)
    {
    if (streq(got, want))
        {
        Stdio.printf("  ok   %s = \"%s\"\n", what, got);
        }
    else
        {
        Stdio.printf("  FAIL %s = \"%s\" (want \"%s\")\n", what, got, want);
        gFails = gFails + (i32)1;
        }
    }

// The lifecycle log: every notification appended as a (kind, depth) pair.
i32 gEvN;
i32 gEvKind[16]; // 1 = willShow, 2 = didHide
i32 gEvDepth[16];
UXView* gEvView[16];
class Watcher : Object<UXNavigationDelegate>
    {
    void formWillShow(UXNavigationController* n, UXView* content, i32 depth)
        {
        gEvKind[gEvN] = (i32)1;
        gEvDepth[gEvN] = depth;
        gEvView[gEvN] = content;
        gEvN = gEvN + (i32)1;
        }
    void formDidHide(UXNavigationController* n, UXView* content, i32 depth)
        {
        gEvKind[gEvN] = (i32)2;
        gEvDepth[gEvN] = depth;
        gEvView[gEvN] = content;
        gEvN = gEvN + (i32)1;
        }
    }

    void
    main(void)
    {
    gFails = (i32)0;
    gEvN = (i32)0;
    UXNavigationController* nav = new UXNavigationController();
    Watcher* w = new Watcher();
    nav.setDelegate(w);
    UXView* list = new UXView();
    UXView* detail = new UXView();
    UXView* editor = new UXView();

    check("empty depth", nav.depth(), (i32)0);
    check("no back at root", nav.canGoBack() ? (i32)1 : (i32)0, (i32)0);

    nav.push((u8*)"Contacts", list);
    check("depth 1", nav.depth(), (i32)1);
    eq("top title", nav.topTitle(), (u8*)"Contacts");
    check("top content is list", nav.topContent() == list ? (i32)1 : (i32)0, (i32)1);
    check("still no back", nav.canGoBack() ? (i32)1 : (i32)0, (i32)0);
    eq("back title empty", nav.backTitle(), (u8*)"");
    check("push notified willShow", gEvKind[0], (i32)1);
    check("at depth 1", gEvDepth[0], (i32)1);

    nav.push((u8*)"Alice", detail);
    check("depth 2", nav.depth(), (i32)2);
    eq("top title alice", nav.topTitle(), (u8*)"Alice");
    check("back appears", nav.canGoBack() ? (i32)1 : (i32)0, (i32)1);
    eq("back reads contacts", nav.backTitle(), (u8*)"Contacts");
    check("form 0 covered", nav.isFormVisible((i32)0) ? (i32)1 : (i32)0, (i32)0);
    check("form 1 visible", nav.isFormVisible((i32)1) ? (i32)1 : (i32)0, (i32)1);
    check("cover notified didHide first", gEvKind[1], (i32)2);
    check("didHide was the list", gEvView[1] == list ? (i32)1 : (i32)0, (i32)1);
    check("then willShow detail", gEvKind[2], (i32)1);
    check("willShow at depth 2", gEvDepth[2], (i32)2);

    nav.push((u8*)"Edit", editor);
    check("depth 3", nav.depth(), (i32)3);
    eq("back reads alice", nav.backTitle(), (u8*)"Alice");

    nav.pop();
    check("popped to 2", nav.depth(), (i32)2);
    eq("top back to alice", nav.topTitle(), (u8*)"Alice");
    check("pop notified didHide editor", gEvView[gEvN - (i32)2] == editor ? (i32)1 : (i32)0, (i32)1);
    check("pop re-shows detail", gEvView[gEvN - (i32)1] == detail ? (i32)1 : (i32)0, (i32)1);
    check("re-show is willShow", gEvKind[gEvN - (i32)1], (i32)1);

    nav.popToRoot();
    check("back at root", nav.depth(), (i32)1);
    eq("root title", nav.topTitle(), (u8*)"Contacts");
    check("root never pops", nav.canGoBack() ? (i32)1 : (i32)0, (i32)0);
    nav.pop();
    check("pop at root is a no-op", nav.depth(), (i32)1);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: the navigation stack model is correct\n");
        }
    else
        {
        Stdio.printf("FAIL: %d checks\n", (i16)gFails);
        }
    }
