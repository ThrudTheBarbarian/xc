//xtc-flags: target=arm64, expect=sema-error, --migrate=0.3:0.4
// string_migrate_03.xc — the --migrate=0.3:0.4 guard.
//
// A 0.3-era program: `charAt` here EXISTS in 0.4 (as the code-point method)
// and would compile silently with changed meaning; under --migrate every
// since("0.4") member vanishes from lookup, so BOTH calls fail loudly with
// a position — which is the whole point of the flag (string-utf8.md §5).
#import "Stdio.xc"
#import "String.xc"
void main(void)
{
    String* s = String.withCString("abc");
    Stdio.printf("%c %lu\n", s.charAt((u32)1), s.length());
}
