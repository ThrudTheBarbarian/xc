// A global initialised from a string literal is an ADDRESS, which no byte
// image can bake — it used to warn and zero-fill, so the first subscript of
// a base32 alphabet crashed on null. main's prologue now runs the deferred
// stores before any user statement can read the slot. Every target.
#import "Stdio.xc"
u8* ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
string GREET = "hello";
u32 COMPUTED = (u32)6 * (u32)7;
void main(void)
{
    Stdio.printf("%c%c%c %c %lu %d\n",
                 ALPHA[0], ALPHA[25], ALPHA[31], GREET[1], COMPUTED,
                 ALPHA == (u8*)0 ? (i16)1 : (i16)0);
}
