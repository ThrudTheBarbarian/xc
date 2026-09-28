// shadow_field.xc — a local or parameter that SHADOWS a field name must bind
// the local for reads AND writes; it must not silently store into the field
// (bug 562). Both compilers used to read the local and write the field, so the
// local never changed and the field was clobbered.
#import "Stdio.xc"
#import "Foundation.xc"

class Box
{
    i32 field;

    i32 shadowLocal(void)
        {
        i32 field = (i32)10;
        field = field + (i32)5;      // the LOCAL, not the ivar
        return field;
        }

    i32 shadowParam(i32 field)
        {
        field = field + (i32)1;      // the PARAMETER, not the ivar
        return field;
        }

    i32 shadowBump(void)
        {
        i32 field = (i32)0;
        field++;                     // ++/-- on the LOCAL too
        return field;
        }

    i32 getField(void) { return field; }
}

i32 main(void)
{
    Box* b = new Box();
    b.field = 100;
    i32 a = b.shadowLocal();
    i32 c = b.shadowParam(20);
    i32 d = b.shadowBump();
    i32 f = b.getField();
    Stdio.printf("%d %d %d %d\n", a, c, d, f);
    return 0;
}
