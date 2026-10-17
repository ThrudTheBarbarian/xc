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

// BundleRules.xc — what a bundle's manifest and file names must look like
// before anything in the bundle is read or written (bundles-and-plugins.md
// §4 steps 1-2, reviews 3, 5, 16 and 17):
//
//     BundleRules.validPath(s)     segments of [A-Za-z0-9._-] joined by '/':
//                                  no empty, "." or ".." segment, nothing
//                                  absolute, no backslash, colon or NUL
//     BundleRules.validName(s)     the same characters without '.' or '/'
//                                  (a bundle's name, a property key)
//     BundleRules.collision(paths) the first path that names the same file as
//                                  an earlier one on a case-insensitive file
//                                  system, or 0 (the grammar is ASCII, so
//                                  case-folding is all Unicode normalisation
//                                  could add)
//     BundleRules.parseManifest(d) the manifest's bytes, parsed once, strictly
//                                  (JSON.parseStrict: no key twice, capped)
#import "Foundation.xc"
#import "JSON.xc"

#define BUNDLE_MANIFEST_BYTES (1024 * 1024)
#define BUNDLE_MANIFEST_DEPTH 16
#define BUNDLE_STRING_BYTES 4096
#define BUNDLE_PATH_BYTES 1024

class BundleRules
    {
    static bool _nameChar(u8 c)
        {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'0' && c <= (u8)'9')
            || c == (u8)'_' || c == (u8)'-';
        }

    // A path inside the bundle, as the grammar says.
    static bool validPath(String* s)
        {
        if (s == (String*)0 || s.byteLength() == (u32)0 || s.byteLength() > (u32)BUNDLE_PATH_BYTES)
            return false;
        u32 n = s.byteLength();
        u32 segStart = (u32)0;
        for (u32 i = (u32)0; i <= n; i = i + (u32)1)
            {
            if (i == n || s.byteAt(i) == (u8)'/')
                {
                u32 len = i - segStart;
                if (len == (u32)0)
                    return false;                       // leading '/', '//', trailing '/'
                if (len == (u32)1 && s.byteAt(segStart) == (u8)'.')
                    return false;
                if (len == (u32)2 && s.byteAt(segStart) == (u8)'.' && s.byteAt(segStart + (u32)1) == (u8)'.')
                    return false;
                segStart = i + (u32)1;
                continue;
                }
            u8 c = s.byteAt(i);
            if (!BundleRules._nameChar(c) && c != (u8)'.')
                return false;                           // '\\', ':', NUL, spaces, non-ASCII
            }
        return true;
        }

    // A bundle's name or a property key.
    static bool validName(String* s)
        {
        if (s == (String*)0 || s.byteLength() == (u32)0 || s.byteLength() > (u32)128)
            return false;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            if (!BundleRules._nameChar(s.byteAt(i)))
                return false;
        return true;
        }

    static String* _folded(String* s)
        {
        String* r = new String();
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if (c >= (u8)'A' && c <= (u8)'Z')
                c = c + (u8)32;
            r.appendByte(c);
            }
        return r;
        }

    // The first of paths (Strings) that names the same file as an earlier one
    // once case is folded, or 0 when they are all distinct.
    static String* collision(Array* paths)
        {
        Map* seen = new Map();
        for (u32 i = (u32)0; i < paths.count(); i = i + (u32)1)
            {
            String* p = (String*)paths.get(i);
            String* f = BundleRules._folded(p);
            if (seen.get((Hashable*)f) != (Object*)0)
                return p;
            seen.set((Hashable*)f, (Object*)p);
            }
        return (String*)0;
        }

    // The manifest's exact bytes, parsed once with the strict parser.
    static Object* parseManifest(Data* bytes) throws
        {
        return JSON.parseStrict(bytes, (u32)BUNDLE_MANIFEST_BYTES, (u32)BUNDLE_MANIFEST_DEPTH, (u32)BUNDLE_STRING_BYTES);
        }
    }
