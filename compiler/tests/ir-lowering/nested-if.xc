// nested-if — regression for §12.4 phi-pred mismatch. The outer if
// has no else; the inner if's else-fallthrough chains back via
// bb_entry, so the outer join's phi pair order has to match the
// verifier's source-block iteration order (entry first, then-exit
// second). Used to record (thenExit, entry); now records correctly.
u16 nested(u8 n)
    {
    u16 acc = 0;
    if (n > 0)
        {
        if (n > 1)
            {
            acc = acc + 2;
            }
        else
            {
            acc = acc + 1;
            }
        }
    return acc;
    }
