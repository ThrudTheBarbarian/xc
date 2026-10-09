// twiceclient.xc — a library named twice in one file and again in a file it
// imports (bug 636). Each `#import <CnLib>` after the first is a no-op, as a
// repeated source import is; it used to put the interface in again and every
// class of the library was a redefinition.
#import "Stdio.xc"
#import <CnLib>
#import <CnLib>
#import "twiceother.xc"

i32 main(void)
    {
    Square* s = new Square();
    Stdio.printf("%d %d\n", s.count(), sidesOf());
    return (i32)0;
    }
