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

// mapData.xc — bank-switch the data area at $8000-$9FFF
// ======================================================
//
// void mapData(i16 page)
//
// If page == -1: maps the same page as the current code page
//   (copies $82 → $83), giving the calling class/function its own
//   8KB data area at $8000-$9FFF.
//
// If page >= 0: maps the specified page number (0-255) into $83,
//   selecting which 8KB data page appears at $8000-$9FFF.
//
// This is a global function available to all code.

void mapData(i16 page)
    {
    if (page < 0)
        {
        // Map same page as code area: copy $82 → $83
        asm
        {
            LDA $82
            STA $83
        }
        }
    else
        {
        // Map the specified page into the data area
        u8 pageVal;
        pageVal = page;
        asm
        {
            LDA pageVal
            STA $83
        }
        }
    }
