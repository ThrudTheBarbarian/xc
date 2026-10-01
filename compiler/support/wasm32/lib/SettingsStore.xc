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


// SettingsStore.xc — wasm32: localStorage.
// =====================================
//
// Settings.standard(name) keeps its values in the page's localStorage, under
// the item `name`, as a JSON object of strings — so page script can read and
// change them as `JSON.parse(localStorage.getItem(name))`. The loader does the
// JSON; the two sides exchange `key = value` lines. Outside a browser (Node)
// there is no localStorage, and the store simply stays empty.

#import "String.xc"
#import "Array.xc"

#package browser
extern u8* _b_store_load(u8* domain, u32 dn);
extern u32 _b_store_save(u8* domain, u32 dn, u8* text, u32 tn);

class SettingsStore
    {
    static bool native(void)
        {
        return true;
        }

    static bool load(String* domain, Array* keys, Array* values)
        {
        keys.removeAll();
        values.removeAll();
        u8* p = _b_store_load(domain.cString(), domain.byteLength());
        if (p == 0)
            return false;
        u32 n = (u32)p[0] | ((u32)p[1] << (u32)8) | ((u32)p[2] << (u32)16) | ((u32)p[3] << (u32)24);
        String* text = String.withBytes(p + 4, n);
        delete p;
        Array* lines = text.splitOnByte((u8)'\n');
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
            {
            String* line = (String*)lines.get(i);
            u32 eq = line.indexOfByte((u8)'=');
            if (eq == String.notFound())
                continue;
            String* k = line.substringBytes((u32)0, eq).trimmed();
            if (k.byteLength() == (u32)0)
                continue;
            keys.add((Object*)k);
            values.add((Object*)line.substringFromByte(eq + (u32)1).trimmed());
            }
        return true;
        }

    // The item becomes exactly these values.
    static bool save(String* domain, Array* keys, Array* values)
        {
        String* text = String.withCString("");
        for (u32 i = (u32)0; i < keys.count(); i = i + (u32)1)
            {
            text.append((String*)keys.get(i));
            text.appendCString(" = ");
            text.append((String*)values.get(i));
            text.appendCString("\n");
            }
        return _b_store_save(domain.cString(), domain.byteLength(), text.cString(), text.byteLength()) != (u32)0;
        }
    }
