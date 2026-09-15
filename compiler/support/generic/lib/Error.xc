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

// Error.xc — the protocol a value must conform to in order to be `throw`n.
//
// An error is an ordinary heap object, not a special kind of value: it follows
// ARC like anything else, and a caught error is a strong local released at the
// end of its `catch` scope. That is deliberate — it means errors reuse
// protocols, RTTI and the object model already in the language rather than
// adding a new mechanism beside them. See private:docs/Design/exceptions-and-defer.md §3.
//
// Conformance:
//
//     class IOError <Error>
//     {
//         String* msg;
//         void init(String* m)  { msg = m; }
//         String* message(void) { return msg; }
//     }
//
//     i32 readCount(String* path) throws
//     {
//         File* f = File.open(path);
//         if (!f) throw new IOError(String.withCString("cannot open"));
//         defer { f.close(); }          // runs on the throw path too
//         return f.readInt();
//     }
//
// `message()` is the single requirement, so a handler can always say something
// useful about what it caught without knowing the concrete type:
//
//     try   { i32 n = readCount(p); }
//     catch (e) { Stdio.printf("failed: %s\n", e.message().cString()); }
//
// Typed handlers — `catch (IOError e)` — are E2; they resolve through the same
// RTTI downcast that already works across module boundaries, so the protocol
// needs nothing added for them.

#import "String.xc"

protocol Error
    {
    String* message(void);
    }
