//xtc-flags: target=xt6502, expect=sema-error
// class_names_xt6502.xc — runtime class names are not on the 6502: Object
// there has no className(), and calling it is a compile error rather than a
// silent null.
#import "Stdio.xc"

class Point
    {
    i32 x;
    }

void main(void)
    {
    Object* p = (Object*)new Point();
    Stdio.printf("%s\n", p.className().cString());
    }
