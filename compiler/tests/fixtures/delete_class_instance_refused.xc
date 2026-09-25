//xtc-flags: expect=sema-error
// delete_class_instance_refused.xc — `delete` on a class instance.
//
// ARC owns a class instance's refcount, so a hand-written `delete` frees an
// object that may still be aliased and the scope exit then releases it again.
// The shipped compiler accepted this with no diagnostic; it must be refused.
// `delete` on a struct or primitive array stays legal (ARC never manages
// those); delete_array_still_allowed.xc covers that half.
class Holder
    {
    u32 n;
    }

i32 main(void)
    {
    Holder* h = new Holder();
    delete h;
    return 0;
    }
