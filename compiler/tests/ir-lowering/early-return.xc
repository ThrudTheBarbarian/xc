// early-return — pins the per-block memory-token rule (§12.5
// relaxed to "no double-consume *within a block*"). Two Returns
// reachable from the entry block share the entry's mem token; the
// verifier accepts because the two consumers live in different
// blocks (CondBranch makes them runtime-mutually-exclusive).
i16 early(i16 n)
    {
    if (n <= 0)
        return 0;
    return n + 1;
    }
