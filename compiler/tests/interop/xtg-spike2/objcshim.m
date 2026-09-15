#import <Cocoa/Cocoa.h>
#include <objc/runtime.h>
#include <objc/message.h>

void* xt_getClass(const char* n)
    {
    return (void*)objc_getClass(n);
    }
void* xt_sel(const char* n)
    {
    return (void*)sel_registerName(n);
    }
void* xt_msg(void* o, void* s)
    {
    return (void*)((id (*)(id, SEL))objc_msgSend)((id)o, (SEL)s);
    }
void* xt_msg_p(void* o, void* s, void* a)
    {
    return (void*)((id (*)(id, SEL, id))objc_msgSend)((id)o, (SEL)s, (id)a);
    }
void* xt_alloc_class(void* sup, const char* n)
    {
    return (void*)objc_allocateClassPair((Class)sup, n, 0);
    }
void xt_register_class(void* c)
    {
    objc_registerClassPair((Class)c);
    }
int xt_add_method(void* c, void* sel, void* imp, const char* types)
    {
    return class_addMethod((Class)c, (SEL)sel, (IMP)imp, types);
    }
// NSRect struct arg → done in C
void* xt_make_window(int x, int y, int w, int h)
    {
    NSRect r = NSMakeRect(x, y, w, h);
    return (void*)[[NSWindow alloc] initWithContentRect:r
                                              styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered
                                                  defer:YES];
    }
