// A method declared `throws`, called with no `try` from a caller that does
// not throw: refused in sema, by name (the shipped compiler left it to the
// lowering, which said "unsupported: raising call").
// xtc: error "'parse' is declared 'throws'"

#import "Error.xc"

class ParseError <Error>
    {
    String* message(void) { return String.withCString("bad"); }
    }

class Parser
    {
    u32 parse(u32 c) throws
        {
        if (c == (u32)0)
            throw new ParseError();
        return c;
        }
    }

void main(void)
    {
    Parser* p = new Parser();
    u32 v = p.parse((u32)3);
    }
