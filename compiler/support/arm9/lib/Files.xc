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

// Files.xc — whole-file I/O on the host.
// =================================================================
//
// arm9 (XTOS, loader-hosted PIC) — the same source as support/arm64/lib, over
// the same `_xt_` primitives; only what implements them differs. On the host
// they are C library calls (support/arm64/runtime/libxt.c); here they are XTOS
// syscalls issued directly (support/arm9/runtime/libxt-pic.c), because a PIC
// program's libc.so has its own view of what a file is and the syscall numbers
// are the frozen ABI.
//
// Originally arm64 only, and deliberately so. `FILE.xc` in this directory
// covers CONSOLE streams — stdout, and a stdin stubbed to EOF — because that is
// all a corpus fixture needs. A compiler written in xtc needs to open the file
// it was asked to compile, which is a different job (private:docs/Design/self-hosting.md
// M4).
//
// It is layered on the host C runtime (support/arm64/runtime/libxt.c), the same
// way Time and Math already are: the primitives are plain C functions with
// standardized `_xt_` names, and because libxt is linked as a static archive a
// program that never touches a file pulls none of it in.
//
// Files are integer HANDLES rather than host pointers, so nothing here has to
// name a 64-bit FILE*. Eight may be open at once — a compiler driver's budget,
// not a server's.
//
// The class is `Files`, not `File`, because macOS filesystems are
// case-insensitive: a `File.xc` beside the existing `FILE.xc` is the SAME FILE
// here and two different ones on Linux, which is the kind of difference that
// only shows up on someone else's machine.
//
// Usage:
//   String* src = Files.readText(String.withCString("prog.xc"));
//   if (src == 0) { ... }              // missing / unreadable — NOT empty
//
// Still not on the other targets: xt6502 has no filesystem, and x86_64 /
// win64 have no runtime of their own. When they get one this class moves to a
// shared layer rather than being copied a third time.

#import "Foundation.xc"

// Host primitives — see support/arm64/runtime/libxt.c.
i32 _xt_file_open(u8* path, u8* mode);
i32 _xt_file_read(i32 handle, u8* buf, u32 n);
i32 _xt_file_write(i32 handle, u8* buf, u32 n);
void _xt_file_close(i32 handle);
i32 _xt_file_size(u8* path);
i32 _xt_mkdir(u8* path);
i32 _xt_file_exists(u8* path);
i32 _xt_file_exists_exact(u8* path);

class Files
    {
    u8 _unused; // no instances: every entry point is static

    void init(void)
        {
        _unused = (u8)0;
        }

    // ── Whole-file reads ─────────────────────────────────────────
    // The whole file as a String, or NULL when it cannot be read. An empty file
    // yields an EMPTY STRING, not null — "missing" and "empty" are different
    // answers and a caller usually cares which one it got.
    static String* readText(String* path)
        {
        if (path == 0)
            return (String*)0;
        i32 size = _xt_file_size(path.cString());
        if (size < (i32)0)
            return (String*)0;

        i32 h = _xt_file_open(path.cString(), (u8*)"rb");
        if (h < (i32)0)
            return (String*)0;

        u8* buf = new u8[(u32)size + (u32)1];
        i32 got = (size > (i32)0) ? _xt_file_read(h, buf, (u32)size) : (i32)0;
        _xt_file_close(h);
        if (got < (i32)0)
            return (String*)0;

        // withBytes copies and adds the NUL that a byte count does not imply —
        // the file's own bytes may contain one.
        return String.withBytes(buf, (u32)got);
        }

    static Data* readData(String* path)
        {
        if (path == 0)
            return (Data*)0;
        i32 size = _xt_file_size(path.cString());
        if (size < (i32)0)
            return (Data*)0;

        i32 h = _xt_file_open(path.cString(), (u8*)"rb");
        if (h < (i32)0)
            return (Data*)0;

        u8* buf = new u8[(u32)size + (u32)1];
        i32 got = (size > (i32)0) ? _xt_file_read(h, buf, (u32)size) : (i32)0;
        _xt_file_close(h);
        if (got < (i32)0)
            return (Data*)0;
        return Data.withBytes(buf, (u32)got);
        }

    // ── Whole-file writes ────────────────────────────────────────
    // True only when EVERY byte was written: a short write is a failure, not a
    // partial success for whoever reads the file next to discover.
    static bool writeText(String* path, String* text)
        {
        if (path == 0 || text == 0)
            return false;
        i32 h = _xt_file_open(path.cString(), (u8*)"wb");
        if (h < (i32)0)
            return false;
        u32 n = text.byteLength();
        i32 put = (n > (u32)0) ? _xt_file_write(h, text.cString(), n) : (i32)0;
        _xt_file_close(h);
        return put == (i32)n;
        }

    static bool writeData(String* path, Data* data)
        {
        if (path == 0 || data == 0)
            return false;
        i32 h = _xt_file_open(path.cString(), (u8*)"wb");
        if (h < (i32)0)
            return false;
        u32 n = data.length();
        i32 put = (n > (u32)0) ? _xt_file_write(h, data.bytes(), n) : (i32)0;
        _xt_file_close(h);
        return put == (i32)n;
        }

    static bool appendText(String* path, String* text)
        {
        if (path == 0 || text == 0)
            return false;
        i32 h = _xt_file_open(path.cString(), (u8*)"ab");
        if (h < (i32)0)
            return false;
        u32 n = text.byteLength();
        i32 put = (n > (u32)0) ? _xt_file_write(h, text.cString(), n) : (i32)0;
        _xt_file_close(h);
        return put == (i32)n;
        }

    // ── Queries ──────────────────────────────────────────────────
    // Create a directory, tolerating one that is already there. The caller that
    // needs this is a compiler writing a cache under $HOME on a machine that
    // has never run it — so "already exists" is success, not a clash.
    static bool createDirectory(String* path)
        {
        if (path == 0 || path.byteLength() == (u32)0)
            return false;
        return _xt_mkdir(path.cString()) != (i32)0;
        }

    static bool exists(String* path)
        {
        if (path == 0)
            return false;
        return _xt_file_exists(path.cString()) != (i32)0;
        }

    // Does this path exist with EXACTLY this spelling?
    //
    // `exists` asks the filesystem, and macOS filesystems are case-preserving
    // but case-INSENSITIVE: exists("Sort.xc") is true when the file is really
    // named sort.xc. Anything resolving a name the user typed — an #import, a
    // library lookup — has to ask this instead, or it silently opens a
    // different file than the one that was named.
    static bool existsExact(String* path)
        {
        if (path == 0)
            return false;
        return _xt_file_exists_exact(path.cString()) != (i32)0;
        }

    // Bytes, or -1 when the file cannot be opened.
    static i32 size(String* path)
        {
        if (path == 0)
            return (i32)-1;
        return _xt_file_size(path.cString());
        }
    }
