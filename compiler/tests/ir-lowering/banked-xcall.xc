// banked-xcall — focused cross-bank-call golden (task #60).
//
// With the test model's `bankEachUserFunction` knob, each non-entry
// function lands in its OWN 16 KB code bank:
//   main  → unbanked (the entry; reached by the harness's direct JSR)
//   leaf  → bank 1
//   mid   → bank 2
// so main()→mid() is an unbanked→bank-2 cross-bank call and mid()→leaf()
// is a bank-2→bank-1 cross-bank call (nested). Both route through the
// `_xcall` trampoline + a $82 swap. The returned value (142) depends on
// BOTH banked functions executing from their own banks, so a wrong bank
// mapping or a clobbered $82 produces a different number.

i16 leaf(void)
    {
    return 42;
    }

i16 mid(void)
    {
    return leaf() + 100;
    }

i16 main(void)
    {
    return mid();
    }
