// xcc runtime library.
//
// Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
//
// This file is part of the xcc runtime library: the code that is combined
// with a program when xcc compiles it. It is free software; you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// Under Section 7 of GPL version 3, you are granted additional permissions
// described in the GCC Runtime Library Exception, version 3.1, as published
// by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
// parent.
//
// The effect of that exception is the point: a program compiled by xcc
// contains parts of this file, and the exception is what leaves that program
// under whatever licence its author chooses, including a proprietary one.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

// System.xc — process control for xtc
// ====================================
//
// Usage (static — no instance needed):
//   #import <System.xc>
//
//   System.exit(0);
//
// System.exit(value) terminates the program by jumping through the
// Atari DOSVEC at $0A/$0B, which returns control to DOS. The exit
// value is stored at $02FD/$02FE (otherwise-unused OS page 2 bytes)
// for any caller that cares; DOS itself ignores it.

class System
    {
    u8 dummy;

    void init(void)
        {
        }

    // ── exit: terminate program, returning `value` ──────────────────

    static void exit(i16 value)
        {
        asm
        {
            LDA value
            STA $02FD
            LDA value+1
            STA $02FE
            JMP ($000A)
        }
        }
    }
