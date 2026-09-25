// delete_array_still_allowed.xc — `delete` frees struct and primitive arrays.
//
// The refusal of `delete` on a class instance must not reach these: ARC never
// manages a struct or primitive array, so `delete` is the only way to free one.
// See delete_class_instance_refused.xc.
struct Pt
    {
    i32 x;
    i32 y;
    }

i32 main(void)
    {
    Pt* a = new Pt[4];
    a[1].x = 5;
    i32 v = a[1].x;
    delete a;
    u8* b = new u8[20];
    b[3] = (u8)2;
    v = v + (i32)b[3];
    delete b;
    Stdio.printf("v=%ld\n", v);
    return 0;
    }
