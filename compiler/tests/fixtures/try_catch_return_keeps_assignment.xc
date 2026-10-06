// try_catch_return_keeps_assignment.xc — an assignment made inside a `try`
// survives to the code after it when every catch arm returns, so the join is
// reached from the guarded block alone (UXKit: the value from before the try
// came back instead). Also: the arm returning on a throw, two names assigned,
// typed arms that both return, and an arm that falls through.
#import <Stdio.xc>
#import "Error.xc"
#import "String.xc"

class Boom : Object<Error>
    {
    String* message(void) { return String.withCString((u8*)"boom"); }
    }
class Bang : Object<Error>
    {
    String* message(void) { return String.withCString((u8*)"bang"); }
    }

i32 maybe(bool fail) throws
    {
    if (fail) { throw new Boom(); }
    return (i32)7;
    }

i32 catchReturns(bool fail)
    {
    i32 got = (i32)0;
    try
        {
        got = maybe(fail);
        }
    catch (e)
        {
        return (i32)-1;
        }
    return got;
    }

i32 twoNames(bool fail)
    {
    i32 a = (i32)1;
    i32 b = (i32)2;
    try
        {
        a = maybe(fail);
        b = a * (i32)3;
        }
    catch (e)
        {
        return (i32)-1;
        }
    return a * (i32)100 + b;
    }

i32 typedArms(bool fail)
    {
    i32 got = (i32)0;
    try
        {
        got = maybe(fail) + (i32)1;
        }
    catch (Bang e)
        {
        return (i32)-2;
        }
    catch (e)
        {
        return (i32)-3;
        }
    return got;
    }

i32 fallsThrough(bool fail)
    {
    i32 got = (i32)0;
    try
        {
        got = maybe(fail);
        }
    catch (e)
        {
        got = (i32)5;
        }
    return got;
    }

i32 main(void)
    {
    Stdio.printf("catch returns: %d %d\n", catchReturns(false), catchReturns(true));
    Stdio.printf("two names: %d %d\n", twoNames(false), twoNames(true));
    Stdio.printf("typed arms: %d %d\n", typedArms(false), typedArms(true));
    Stdio.printf("falls through: %d %d\n", fallsThrough(false), fallsThrough(true));
    return (i32)0;
    }
