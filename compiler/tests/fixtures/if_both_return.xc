// if_both_return.xc — an if/else where BOTH arms return.
//
//     i16 pick(bool c, i16 a, i16 b) { if (c) { return a; } else { return b; } }
//
// About as ordinary as code gets, and it did not compile:
//
//     xtc: IR verifier rejected module:
//       §12.10: block 'bb_1_join' in 'pick' is unreachable from entry
//
// The lowering always builds a join block for an `if`. When both arms `return`, nothing
// branches to it, so it is unreachable — and the verifier threw out the whole module.
// The lowering even knew: its comment read "the verifier's §12.10 will flag it. Leave
// it." It did flag it, and the build failed.
//
// A block that TERMINATES IN Unreachable is now allowed to be unreachable — it is saying
// so. Still an error for any other terminator: a block no path reaches that nonetheless
// branches or returns is a real lowering bug.
//
// (Deleting the block instead is worse — it orphans the lowering's current block, and a
// nested `if` then reports the orphan as a live exit to the ENCLOSING arm, which just
// moves the unreachable block one level out. `nest` below is what caught that.)

#import "Stdio.xc"

i16 pick(bool c, i16 a, i16 b) { if (c) { return a; } else { return b; } }

// NESTED: the outer arm's last statement is itself an if/else where both arms return.
i16 nest(i16 v)
{
    if (v > (i16)0) {
        if (v > (i16)10) { return (i16)2; } else { return (i16)1; }
    } else {
        return (i16)0;
    }
}

// Diverging arms INSIDE a loop (continue / fall-through), not returns.
i16 loopy(i16 n)
{
    i16 t = (i16)0;
    for (i16 i = (i16)0; i < n; i = i + (i16)1) {
        if (i == (i16)2) { continue; } else { t = t + i; }
    }
    return t;
}

i16 main(void)
{
    Stdio.printf("pick=%d %d\n", pick(true, (i16)1, (i16)2), pick(false, (i16)1, (i16)2));
    Stdio.printf("nest=%d %d %d\n", nest((i16)-1), nest((i16)5), nest((i16)20));
    Stdio.printf("loop=%d\n", loopy((i16)5));      // 0 + 1 + 3 + 4  (2 skipped)
    return 0;
}
