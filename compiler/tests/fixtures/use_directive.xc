// use_directive.xc — `use Klass;` and `#use Klass` sugar.
//
// `use Klass;` promotes the named class's static methods into the
// bare-identifier call lookup space for the rest of the file. After
// `use Stdio;` the user can call `printf(...)` directly instead of
// `Stdio.printf(...)`. `#use Klass` is the combined form — expands
// to `#import "Klass.xc"` followed by `use Klass;`.
//
// Coverage:
//   T1: `use Stdio;` after explicit #import — bare printf resolves
//       to Stdio.printf.
//   T2: `#use Math` combined form (#import + use in one) — bare
//       setSeed() resolves to Math.setSeed().
//   T3: a second bare call into a different use'd class also
//       resolves correctly — multiple use directives compose.

#import "Stdio.xc"
use Stdio;

#use Math

void main(void)
{
    // T1: bare printf via `use Stdio;`
    printf("T1 PASS\n");

    // T2: bare setSeed() via `#use Math`
    setSeed((u16)42);
    printf("T2 PASS\n");

    // T3: second bare call into Math, after T2 already exercised one.
    u8 r = rand((u8)100);
    // rand(100) is 0..100 inclusive, so 100 is a valid draw (the strict
    // `< 100` was a latent bug only the Atari xorshift's seed happened to
    // dodge — the host PRNG can return the boundary).
    if (r <= 100) { printf("T3 PASS\n"); }
    else          { printf("T3 FAIL r=%u\n", r); }

    return;
}
