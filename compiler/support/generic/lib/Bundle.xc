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

// Bundle.xc — where a program's own files live (the NSBundle-shaped hole).
// =================================================================
//
// A program that ships a shader, a font, a template, a dictionary or a set of
// fixtures needs to find them at run time, and "the directory I was started
// from" is not the answer: a launcher, a desktop icon and a test harness each
// start it somewhere else. Bundle names the one directory the program's
// resources live in, and resolves a resource name inside it.
//
//   Bundle* b = Bundle.main();
//   String* t = b.textForResource(String.withCString("greeting"), String.withCString("txt"));
//   if (t == 0) { ... }                     // missing — NOT empty
//
// Bundle.main() is the directory of the RUNNING EXECUTABLE (argv[0]), with
// $XCC_BUNDLE_ROOT overriding it when set — the escape hatch for a layout
// where the resources are not beside the binary. Bundle.withRoot() names any
// directory, which is what a test wants.
//
// resourcePath() is <root>/Resources when such a directory exists and <root>
// otherwise, so the same source works for an app that has a Resources folder
// and for one that keeps everything flat.
//
// Not ambient: `#import "Bundle.xc"` names it, as it does Files.

#import "String.xc"
#import "Data.xc"
#import "Platform.xc"

#if ARCH_6502
// A 6502 has no filesystem and no argv: the root is the working directory (or
// whatever $XCC_BUNDLE_ROOT would be, which is always unset there) and no
// resource can be found. Files.xc is not imported, so nothing here can reach
// the link as an undefined `_xt_file_*`.
#else
#import "Files.xc"
#import "Process.xc"
#endif

// The running image's own path, from the OS where it says (argv[0] is only
// what the caller typed: plain `myapp` from PATH names no directory).
#if ARCH_win64
u32 GetModuleFileNameA(pointer module, u8* buf, u32 size);
#elif ARCH_arm64 && !PLATFORM_android
i32 _NSGetExecutablePath(u8* buf, u32* size);
#endif

class Bundle
    {
    String* _root;

    void init(void)
        {
        _root = String.withCString(".");
        }

    // ── construction ─────────────────────────────────────────────────────

    static Bundle* withRoot(String* root)
        {
        Bundle* b = new Bundle();
        b._root = (root == 0 || root.byteLength() == (u32)0)
                  ? String.withCString(".")
                  : String.withString(root);
        return b;
        }

    // The running executable's directory, or $XCC_BUNDLE_ROOT when that is
    // set and non-empty.
    static Bundle* main(void)
        {
        String* over = Platform.env(String.withCString("XCC_BUNDLE_ROOT"));
        if (over != 0 && over.byteLength() > (u32)0)
            return Bundle.withRoot(over);
#if ARCH_6502
        return Bundle.withRoot(String.withCString("."));
#else
        String* exe = Bundle.executablePath();
        if (exe == 0 || exe.byteLength() == (u32)0)
            return Bundle.withRoot(String.withCString("."));
        String* dir = Bundle.directoryOf(exe);
        return Bundle.withRoot(dir);
#endif
        }

    // The same answer, but reading a named variable — a program with several
    // bundles, or one with a variable of its own, does not have to share the
    // default's name.
    static Bundle* mainFrom(String* envName)
        {
        if (envName == 0 || envName.byteLength() == (u32)0)
            return Bundle.main();
        String* over = Platform.env(envName);
        if (over != 0 && over.byteLength() > (u32)0)
            return Bundle.withRoot(over);
        return Bundle.main();
        }

    // Where the running executable is. The OS says on Windows
    // (GetModuleFileNameA) and on Apple platforms (_NSGetExecutablePath).
    // Elsewhere argv[0] is the answer when it names a directory, and when it
    // does not (`myapp`, started from PATH) the PATH is searched as the shell
    // did. It used to be argv[0] alone, so a program started from PATH looked
    // for its resources in whatever directory it was started from.
    since("0.66") static String* executablePath(void)
        {
#if ARCH_6502
        return (String*)0;
#else
#if ARCH_win64
        u8 wbuf[1024];
        u32 wn = GetModuleFileNameA((pointer)0, &wbuf[0], (u32)1024);
        if (wn > (u32)0 && wn < (u32)1024)
            return String.withBytes(&wbuf[0], wn);
#elif ARCH_arm64 && !PLATFORM_android
        u8 mbuf[1024];
        u32 msize = (u32)1024;
        if (_NSGetExecutablePath(&mbuf[0], &msize) == (i32)0)
            return String.withCString(&mbuf[0]);
#endif
        String* a0 = Process.argument((u32)0);
        if (a0 == 0 || a0.byteLength() == (u32)0)
            return (String*)0;
        for (u32 i = (u32)0; i < a0.byteLength(); i = i + (u32)1)
            if (a0.byteAt(i) == (u8)'/' || a0.byteAt(i) == (u8)'\\')
                return a0;
        String* path = Platform.env(String.withCString("PATH"));
        if (path == 0)
            return a0;
#if ARCH_win64
        u8 sep = (u8)';';
#else
        u8 sep = (u8)':';
#endif
        Array* dirs = path.splitOnByte(sep);
        for (u32 i = (u32)0; i < dirs.count(); i = i + (u32)1)
            {
            String* d = (String*)dirs.get(i);
            if (d.byteLength() == (u32)0)
                continue;
            String* cand = d.appendingPathComponent(a0);
            if (Files.exists(cand))
                return cand;
            }
        return a0;
#endif
        }

    // ── paths ────────────────────────────────────────────────────────────

    static String* directoryOf(String* path)
        {
        if (path == 0)
            return (String*)0;
        u32 n = path.byteLength();
        i32 slash = (i32)-1;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            u8 c = path.byteAt(i);
            if (c == (u8)'/' || c == (u8)'\\')
                slash = (i32)i;
            }
        if (slash < (i32)0)
            return String.withCString(".");
        if (slash == (i32)0)
            return String.withCString("/");
        return path.substringBytes((u32)0, (u32)slash);
        }

    since("0.64") String* root(void)
        {
        return _root;
        }

    // <root>/Resources when that directory exists, <root> otherwise.
    since("0.64") String* resourcePath(void)
        {
#if ARCH_6502
        return _root;
#else
        String* r = _root.appending(String.withCString("/Resources"));
        return Files.exists(r) ? r : _root;
#endif
        }

    // A path inside the resources, whether or not the file is there.
    since("0.64") String* pathFor(String* relative)
        {
        if (relative == 0 || relative.byteLength() == (u32)0)
            return resourcePath();
        return resourcePath().appending(String.withCString("/")).appending(relative);
        }

    // <resourcePath>/<subdir>/<name>.<ext>. An empty `ext` drops the dot, so
    // an extensionless resource is nameable; an empty `subdir` is the root.
    since("0.64") String* pathForResource(String* name, String* ext, String* subdir)
        {
        String* p = resourcePath();
        if (subdir != 0 && subdir.byteLength() > (u32)0)
            p = p.appending(String.withCString("/")).appending(subdir);
        p = p.appending(String.withCString("/")).appending(name);
        if (ext != 0 && ext.byteLength() > (u32)0)
            p = p.appending(String.withCString(".")).appending(ext);
        return p;
        }

    since("0.64") String* pathForResource(String* name, String* ext)
        {
        return pathForResource(name, ext, (String*)0);
        }

    since("0.64") bool resourceExists(String* name, String* ext)
        {
#if ARCH_6502
        return false;
#else
        return Files.exists(pathForResource(name, ext, (String*)0));
#endif
        }

    // ── contents ─────────────────────────────────────────────────────────

    // The resource's bytes as text, or 0 when it is missing — NOT an empty
    // string, so "there is no such resource" and "the resource is empty" are
    // different answers.
    since("0.64") String* textForResource(String* name, String* ext)
        {
#if ARCH_6502
        return (String*)0;
#else
        return Files.readText(pathForResource(name, ext, (String*)0));
#endif
        }

    since("0.64") Data* dataForResource(String* name, String* ext)
        {
#if ARCH_6502
        return (Data*)0;
#else
        return Files.readData(pathForResource(name, ext, (String*)0));
#endif
        }
    }
