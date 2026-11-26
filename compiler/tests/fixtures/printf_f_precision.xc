// %.Nf keeps N decimals, rounded at the Nth, and %.0f keeps none — no
// decimal point either (#703). On xt6502 %.0f printed six decimals, a
// precision of 0 being read as "none given".
#import "Stdio.xc"

i32 main(void)
    {
    Stdio.printf("[%.0f] [%.0f] [%.1f] [%.2f]\n", 2.5, 3.5, 0.25, 0.126);
    Stdio.printf("[%.3f] [%f] [%.2f]\n", 1.0625, 0.5, 9.999);
    return 0;
    }
