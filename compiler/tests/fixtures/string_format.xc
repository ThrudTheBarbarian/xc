// string_format.xc — String.appendFormat, the printf-style formatter.
//
// The highest-traffic item in the Foundation surface the compiler consumes
// (private:docs/Design/m1-foundation-surface.md): NSMutableString's appendFormat: alone
// is most of its 1,640 call sites, and %@ is 1,674.
//
// It lives in String rather than Stdio because Stdio is PER-PLATFORM (six
// copies) and its emitters write straight to the console, so it cannot be reused
// as a formatter. String is generic, and platform code can depend on it — so
// Stdio can delegate here later, not the reverse.
//
// Renderings match Stdio.printf so a format string moves between the two
// unchanged: %d/%u are 16-bit, %ld/%lu 32-bit, %x is 4 UPPERCASE hex digits and
// %lx is 8. The one divergence is %f (3dp here, 6dp in Stdio) — see String.xc.

#import "Stdio.xc"
#import "String.xc"
#import "Number.xc"

void main(void)
{
    String* s = String.withCString("");
    s.appendFormat("d=%d ld=%ld u=%u lu=%lu\n", (i16)-5, (i32)-100000, (u16)7, (u32)70000);
    s.appendFormat("s=%s c=%c pct=%% x=%x lx=%lx\n", "abc", (u16)65, (u16)255, (u32)48879);
    s.appendFormat("pad=[%04lu] [%3d]\n", (u32)42, (i16)7);
    s.appendFormat("obj=%@\n", (Object*)Number.with((u32)99));
    Stdio.printf("%s", s.cString());
}
