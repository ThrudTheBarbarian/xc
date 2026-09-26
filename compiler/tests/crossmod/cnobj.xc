// cnobj.xc — the `-c` object half of classnames.sh. Its classes reach the
// program only by being linked in; the program imports this object's
// interface.
class Token
    {
    i32 tag;
    void init(void)
        {
        tag = (i32)42;
        }
    }

class Marker : Token
    {
    }

Token* makeMarker(void)
    {
    return new Marker();
    }
