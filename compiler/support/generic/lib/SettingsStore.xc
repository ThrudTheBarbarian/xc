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


// SettingsStore.xc — where Settings.standard() keeps its values.
// ==========================================================
//
// One class, resolved per target like Stdio: a target with a platform settings
// store (macOS and iOS, Windows, a browser) has its own SettingsStore.xc ahead
// of this one on the include path. This is the fallback, for every target
// without one: there is no platform store, and Settings.standard() uses a text
// file instead.
//
// A store is a set of string keys and string values under a name (the domain).
// load() fills the two arrays, in key order; save() makes the domain hold
// exactly what the arrays hold, removing keys that are no longer there.

#import "String.xc"
#import "Array.xc"

class SettingsStore
    {
    // Does this target have a platform store for Settings.standard()?
    static bool native(void)
        {
        return false;
        }

    static bool load(String* domain, Array* keys, Array* values)
        {
        return false;
        }

    static bool save(String* domain, Array* keys, Array* values)
        {
        return false;
        }

    }
