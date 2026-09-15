#import "Stdio.xc"
#import <objcshim>

// objc-runtime primitives (the per-signature msgSend casts live in the C shim)
pointer xt_getClass(pointer n);
pointer xt_sel(pointer n);
pointer xt_msg(pointer o, pointer s);
pointer xt_msg_p(pointer o, pointer s, pointer a);
pointer xt_alloc_class(pointer sup, pointer n);
void xt_register_class(pointer c);
i32 xt_add_method(pointer c, pointer sel, pointer imp, pointer types);
pointer xt_make_window(i32 x, i32 y, i32 w, i32 h);

// The xtc IMP — AppKit invokes THIS as the button's action (self,_cmd,sender).
void onClick(pointer self, pointer cmd, pointer sender)
    {
    Stdio.printf("onClick fired, sender=%d\n", (i32)(sender != (pointer)0));
    }

void main(void)
    {
    // 1. bring AppKit up
    pointer app = xt_msg(xt_getClass((pointer) "NSApplication"), xt_sel((pointer) "sharedApplication"));
    Stdio.printf("app=%d\n", (i32)(app != (pointer)0));

    // 2. a real NSWindow (NSRect struct arg handled in the shim)
    pointer win = xt_make_window((i32)0, (i32)0, (i32)320, (i32)240);
    Stdio.printf("window=%d\n", (i32)(win != (pointer)0));

    // 3. a real NSButton
    pointer btn = xt_msg(xt_msg(xt_getClass((pointer) "NSButton"), xt_sel((pointer) "alloc")),
                         xt_sel((pointer) "init"));
    Stdio.printf("button=%d\n", (i32)(btn != (pointer)0));

    // 4. register an xtc function as an ObjC method on a runtime-created class
    pointer cls = xt_alloc_class(xt_getClass((pointer) "NSObject"), (pointer) "XtTarget");
    pointer sel = xt_sel((pointer) "onClick:");
    Stdio.printf("addMethod=%d\n", xt_add_method(cls, sel, &onClick, (pointer) "v@:@"));
    xt_register_class(cls);

    // 5. wire target/action
    pointer target = xt_msg(xt_msg(cls, xt_sel((pointer) "alloc")), xt_sel((pointer) "init"));
    xt_msg_p(btn, xt_sel((pointer) "setTarget:"), target);
    xt_msg_p(btn, xt_sel((pointer) "setAction:"), sel);

    // 6. fire it — AppKit sends the action to the target, into xtc's onClick
    xt_msg_p(btn, xt_sel((pointer) "performClick:"), (pointer)0);

    Stdio.printf("done\n");
    }
