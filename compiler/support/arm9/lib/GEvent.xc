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

// GEvent.xc — a single UI event delivered to the GApplication run loop.
//
// Events are the currency of the framework: the loop pulls a GEvent, decides
// who should handle it (a window, a control, or the app itself), and dispatches.
// For now the payload is a flat (x, y, data) triple — enough for mouse and key
// events; richer events can subclass GEvent later.

enum GEventKind = {
    GEventNone = 0,      // no event (idle)
    GEventTerminate = 1, // the app should quit the run loop
    GEventRedraw = 2,    // a window/region needs repainting
    GEventMouseDown = 3,
    GEventMouseUp = 4,
    GEventMouseMove = 5,
    GEventKeyDown = 6,
    GEventKeyUp = 7};

class GEvent
    {
    u8 kind; // a GEventKind
    i16 x;   // mouse position (mouse events)
    i16 y;
    u16 data; // button mask (mouse) / key code (key events)

    void init(void)
        {
        kind = (u8)GEventNone;
        x = (i16)0;
        y = (i16)0;
        data = (u16)0;
        }

    u8 getKind(void)
        {
        return kind;
        }
    i16 getX(void)
        {
        return x;
        }
    i16 getY(void)
        {
        return y;
        }
    u16 getData(void)
        {
        return data;
        }

    void setKind(u8 k)
        {
        kind = k;
        }
    void setPosition(i16 px, i16 py)
        {
        x = px;
        y = py;
        }
    void setData(u16 d)
        {
        data = d;
        }
    }
