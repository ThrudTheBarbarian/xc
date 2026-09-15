// printf_precision.xc — `%.Nf` / `%.Nlf` precision modifier.
//
// Standard printf precision after the decimal point. xtc Stdio.printf
// historically defaulted to the host fp2Asc / dp2Asc widths (6 dp for
// float, 10 for double); `.N` between `%` and `f` truncates the output
// to N digits past the decimal point. Truncation, not rounding —
// sufficient for cross-arch oracle matching where the trailing 6dp
// digits differ between IEEE 32-bit (arm64) and xtc 5-byte float
// (xt6502) for the same nominal value.
//
// Cross-arch: same source, same oracle on both backends.

#import "Stdio.xc"

void main(void)
{
    // T1: default (no `.N`) — 6dp on float, historic behaviour.
    Stdio.printf("%f\n", 1.5);

    // T2: `.3f` truncates to 3 decimal places.
    Stdio.printf("%.3f\n", 3.566666);

    // T3: `.1f` — single decimal place.
    Stdio.printf("%.1f\n", 2.71828);

    // T4: `.4f` — extra precision (still bounded by the float's actual
    // bits, but the truncation is at exactly 4dp).
    Stdio.printf("%.4f\n", 0.125);

    Stdio.printf("DONE 4\n");
}
