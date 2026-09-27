// weakapp.xc — a dynamic client linked with weakobj.py's object, whose weak
// undefined `weakthing` resolves to absolute 0. Both probes must read 0: one
// through a GOT load, one through a `.quad weakthing` data word.
#import "Stdio.xc"
#import <Adder>
i64 probe_got(void);
i64 probe_word(void);
i32 main(void)
    {
    Stdio.printf("twice=%ld\n", twice((i32)21));
    Stdio.printf("got=%ld word=%ld\n", (i32)probe_got(), (i32)probe_word());
    return 0;
    }
