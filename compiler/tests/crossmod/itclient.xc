// itclient.xc — uses itlib's struct, enum and typedef through its interface
// alone, from outside the library. See iface-types.sh.
#use <ItLib>
#import "Stdio.xc"

i32 main(void)
    {
    TBox* b = new TBox((i16)4, (i16)5);
    TRect f = b.frame();
    TRect m = TBox.make((i16)9, (i16)8);
    TCount c = b.colourSum();
    Stdio.printf("frame %d %d %d %d\n", (i32)f.x, (i32)f.y, f.w, f.h);
    Stdio.printf("made %d %d %d %d\n", (i32)m.x, (i32)m.y, m.w, m.h);
    Stdio.printf("area %d sum %d blue %d\n", b.area(m), (i32)c, (i32)kBlue);
    return 0;
    }
