// A method whose return type is an undeclared name used as a pointer: an
// opaque handle, as everywhere else. Both parsers read it as a method; the
// reference used to read it as fields and report every token after it.

class Holder
{
    u32 n;
    Missing* find(u32 d)
        {
        return (Missing*)0;
        }
}

use Stdio;

void main(void)
{
    Holder* h = new Holder();
    h.n = 3;
    printf("%u %u\n", h.n, h.find(1) == (Missing*)0 ? 1 : 0);
}
