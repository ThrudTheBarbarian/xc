// twiceother.xc — the second file of twiceclient.xc's build; it names the
// library itself, as every file of a multi-file client does (bug 636).
#import <CnLib>

i32 sidesOf(void)
    {
    Shape* sh = new Shape();
    return sh.count();
    }
