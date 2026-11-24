// simain.xc — links siobj.o (-c, #655): Base40's statics are used only in the
// object, and its static init runs there. Printed with Stdio.print: arm9
// does not yet pass a variadic tail through a virtual call, which a printf in
// a module built with -c makes.
#import "Stdio.xc"

i32 fromObject(void);

i32 main(void)
    {
    Stdio.print("object ");
    Stdio.print(fromObject());
    Stdio.print("\n");
    return 0;
    }
