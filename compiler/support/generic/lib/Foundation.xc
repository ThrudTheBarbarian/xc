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

// Foundation.xc — umbrella import for the Foundation library.
//
// Pulling in this single file makes every Foundation class
// available — the primitive wrappers (Number, String, Data), the
// container classes (Array, Map, Set), and the shared protocols
// they conform to.
//
//     #import "Foundation.xc"
//
//     Number* n = Number.with((i32)42);
//     Array*  a = new Array();
//     a.add(n);
//
// The same effect as importing each file separately; lives here so
// callers don't have to track the per-class header roster as it
// grows.

#import "Object.xc"
#import "Comparable.xc"
#import "Enumerable.xc"
#import "Hashable.xc"
#import "CharacterSet.xc"
#import "Number.xc"
#import "String.xc"
#import "Data.xc"
#import "Array.xc"
#import "Map.xc"
#import "Set.xc"
