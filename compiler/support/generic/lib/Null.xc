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
// Null.xc — the one "nothing here" object (NSNull in shape).
//
// A collection stores Object*, and a null reference usually means "absent".
// Sometimes a slot needs an explicit "there is nothing here" that is still an
// object: a sparse row, a JSON null, a cleared entry that must keep its place.
// Null.null() is one shared instance that stands for exactly that, and
// isNull() recognises it.
//
//     Array* row = new Array();
//     row.add(Null.null());                 // a gap that keeps its index
//     if (Null.isNothing(row.get((u32)0)))  // null reference or Null.null()
//         …
#import "Object.xc"

Null* _gNull;

class Null : Object
    {
    void init(void)
        {
        }

    // The one shared instance.
    static Null* null(void)
        {
        if (_gNull == (Null*)0)
            _gNull = new Null();
        return _gNull;
        }

    // Whether `o` is the shared instance (a null reference is not).
    static bool isNull(Object* o)
        {
        return o != (Object*)0 && o == (Object*)Null.null();
        }

    // Whether `o` is a null reference or the shared instance.
    static bool isNothing(Object* o)
        {
        return o == (Object*)0 || o == (Object*)Null.null();
        }

    String* description(void)
        {
        return String.withCString("null");
        }
    }
