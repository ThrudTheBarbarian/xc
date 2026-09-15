// mem_ssa.xc — Memory SSA test suite
//
// Verifies that store-to-load forwarding through named variables
// works correctly across basic block boundaries.
//
// T1: cross-block phi (different values)
// T2: cross-block phi (same value)
// T3: nested if-else
// T4: intra-block identity optimization
// T5: multiple variables at join point

#import "Stdio.xc"

u8 main(void) {
    // ── T1: if-else, different values ──
    {
        u8 flag = 42;
        u8 y;
        if (flag > 5) {
            y = 100;
        } else {
            y = 200;
        }
        if (y == 100) {
            Stdio.printf("T1 PASS\n");
        } else {
            Stdio.printf("T1 FAIL: y=%d\n", y);
        }
    }
    
    // ── T2: if-else, same value both branches ──
    {
        u8 flag = 3;
        u8 y;
        if (flag > 5) {
            y = 99;
        } else {
            y = 99;
        }
        if (y == 99) {
            Stdio.printf("T2 PASS\n");
        } else {
            Stdio.printf("T2 FAIL: y=%d\n", y);
        }
    }
    
    // ── T3: nested if-else ──
    {
        u8 c = 5, z;
        if (c > 10) {
            z = 100;
        } else if (c > 3) {
            z = 200;
        } else {
            z = 300;
        }
        if (z == 200) {
            Stdio.printf("T3 PASS\n");
        } else {
            Stdio.printf("T3 FAIL: z=%d\n", z);
        }
    }
    
    // ── T4: intra-block x - x = 0 ──
    {
        u8 x = 42;
        u8 y = x - x;
        if (y == 0) {
            Stdio.printf("T4 PASS\n");
        } else {
            Stdio.printf("T4 FAIL: y=%d\n", y);
        }
    }
    
    // ── T5: multiple variables at join point ──
    {
        u8 a = 10, b = 20, x, y;
        if (a > b) {
            x = 1; y = 2;
        } else {
            x = 3; y = 4;
        }
        if (x == 3 && y == 4) {
            Stdio.printf("T5 PASS\n");
        } else {
            Stdio.printf("T5 FAIL: x=%d y=%d\n", x, y);
        }
    }
    
    Stdio.printf("DONE 5\n");
    return 0;
}
