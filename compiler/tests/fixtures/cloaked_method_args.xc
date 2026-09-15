//xtc-na: arm64,arm9,x86_64,win64 — exercises 6502 bank-switching / cloaking
// cloaked_method_args.xc — stage-4 codegen regression coverage.
//
// Before the fix, a :cloaked class method with parameters received
// garbled args because the cloaked-emission hw-stack frame save (PHA
// for every ZP frame slot) disrupted the method prologue's PLA-based
// argument pop. The prologue expected the return address on top of
// the hw stack with args immediately underneath; the 8+ PHAs
// inserted by the diverted frame save clobbered that layout. Cloaked
// free functions weren't affected — they take args through the
// $B0..$BF register window, not hw-stack.
//
// The fix switches :cloaked methods to the register-window calling
// convention at both caller (emitMethodCallExpr) and callee
// (emitSingleMethodDecl) sides. This fixture exercises a cloaked
// method with u8, u16, and a 3-u8-param combo so both narrow and
// multi-byte, single and multi-arg paths are covered.

#import "Stdio.xc"

class Sink {
    static void oneByte(u8 n) : cloaked {
        u8* p = (u8*)$0400;
        *p = n;
    }
    static void twoBytes(u16 n) : cloaked {
        u16* p = (u16*)$0401;
        *p = n;
    }
    static void threeArgs(u8 a, u8 b, u8 c) : cloaked {
        u8* p = (u8*)$0403;
        *p = a;
        p = p + 1;
        *p = b;
        p = p + 1;
        *p = c;
    }
}

void main(void) {
    Sink.oneByte((u8)$A5);
    Sink.twoBytes((u16)$1234);
    Sink.threeArgs((u8)$11, (u8)$22, (u8)$33);

    u8*  p0 = (u8*)$0400;
    u16* p1 = (u16*)$0401;
    u8*  p3 = (u8*)$0403;
    u8*  p4 = (u8*)$0404;
    u8*  p5 = (u8*)$0405;

    if (*p0 == $A5 && *p1 == $1234 &&
        *p3 == $11 && *p4 == $22 && *p5 == $33) {
        Stdio.printf("T1 PASS\n");
    } else {
        Stdio.printf("T1 FAIL p0=%x p1=%x p3=%x p4=%x p5=%x\n",
            (u16)*p0, *p1, (u16)*p3, (u16)*p4, (u16)*p5);
    }
}
