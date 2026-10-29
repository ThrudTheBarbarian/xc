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

// Directory.xc — a directory's entries, with what each one is:
//
//     Array* es = Directory.list(String.withCString("Resources"));
//     DirEntry* e = (DirEntry*)es.get(0);   // e.name, e.kind
//
// kind is DIR_FILE, DIR_DIRECTORY, DIR_LINK (a symbolic link or reparse
// point, never followed) or DIR_OTHER (a device, a socket, or a file system
// that does not say). "." and ".." are left out. 0 when the directory cannot
// be read, and always on targets without a file system.
#import "Foundation.xc"

#define DIR_OTHER 0
#define DIR_FILE 1
#define DIR_DIRECTORY 2
#define DIR_LINK 3

#if OS_windows
u8* FindFirstFileA(u8* pattern, u8* data);
i32 FindNextFileA(u8* h, u8* data);
i32 FindClose(u8* h);
i32 DeleteFileA(u8* path);
i32 RemoveDirectoryA(u8* path);
i32 MoveFileExA(u8* from, u8* to, u32 flags);
#elif ARCH_arm64 || ARCH_x86_64 || OS_android
u8* opendir(u8* path);
u8* readdir(u8* d);
i32 closedir(u8* d);
i32 unlink(u8* path);
i32 rmdir(u8* path);
i32 rename(u8* from, u8* to);
#endif

class DirEntry : Object
    {
    String* name;
    u8 kind;
    }

class Directory
    {
    // Remove path: a file, a link (not what it names), or a directory and
    // everything under it. True when nothing is left there.
    static bool remove(String* path)
        {
        Array* es = Directory.list(path);
        if (es != (Array*)0)
            {
            for (u32 i = (u32)0; i < es.count(); i = i + (u32)1)
                {
                DirEntry* e = (DirEntry*)es.get(i);
                String* p = String.withString(path);
                p.appendByte((u8)'/');
                p.append(e.name);
                if (e.kind == (u8)DIR_DIRECTORY)
                    Directory.remove(p);
                else
                    Directory._unlink(p);
                }
#if OS_windows
            return RemoveDirectoryA(path.cString()) != (i32)0;
#elif ARCH_arm64 || ARCH_x86_64 || OS_android
            return rmdir(path.cString()) == (i32)0;
#else
            return false;
#endif
            }
        return Directory._unlink(path);
        }

    static bool _unlink(String* path)
        {
#if OS_windows
        return DeleteFileA(path.cString()) != (i32)0;
#elif ARCH_arm64 || ARCH_x86_64 || OS_android
        return unlink(path.cString()) == (i32)0;
#else
        return false;
#endif
        }

    // Move from to to (the same volume); a file there is replaced, a
    // directory there must be empty or absent.
    static bool move(String* from, String* to)
        {
#if OS_windows
        return MoveFileExA(from.cString(), to.cString(), (u32)1) != (i32)0;   // MOVEFILE_REPLACE_EXISTING
#elif ARCH_arm64 || ARCH_x86_64 || OS_android
        return rename(from.cString(), to.cString()) == (i32)0;
#else
        return false;
#endif
        }

    static Array* list(String* path)
        {
        Array* out = new Array();
#if OS_windows
        // WIN32_FIND_DATAA: attributes at 0, the name at 44 (320 bytes in all).
        String* pat = String.withString(path);
        pat.appendCString("\\*");
        u8 fd[320];
        u8* h = FindFirstFileA(pat.cString(), &fd[0]);
        if (h == (u8*)0 || h == (u8*)(i64)-1)
            return (Array*)0;
        bool more = true;
        while (more)
            {
            u32 attr = *(u32*)&fd[0];
            String* nm = String.withCString(&fd[44]);
            if (!nm.equals(String.withCString(".")) && !nm.equals(String.withCString("..")))
                {
                DirEntry* e = new DirEntry();
                e.name = nm;
                e.kind = (attr & (u32)0x400) != (u32)0 ? (u8)DIR_LINK
                       : (attr & (u32)0x10) != (u32)0 ? (u8)DIR_DIRECTORY : (u8)DIR_FILE;
                out.add((Object*)e);
                }
            more = FindNextFileA(h, &fd[0]) != (i32)0;
            }
        FindClose(h);
        return out;
#elif ARCH_arm64 || ARCH_x86_64 || OS_android
        u8* d = opendir(path.cString());
        if (d == (u8*)0)
            return (Array*)0;
        // struct dirent: d_type then d_name, at 20 / 21 on Apple, 18 / 19 on
        // Linux (glibc, musl and bionic agree).
#if ARCH_arm64 && !OS_android
        u32 typeAt = (u32)20;
#else
        u32 typeAt = (u32)18;
#endif
        while (true)
            {
            u8* ent = readdir(d);
            if (ent == (u8*)0)
                break;
            String* nm = String.withCString(ent + typeAt + (u32)1);
            if (nm.equals(String.withCString(".")) || nm.equals(String.withCString("..")))
                continue;
            u8 t = ent[typeAt];
            DirEntry* e = new DirEntry();
            e.name = nm;
            // DT_REG 8, DT_DIR 4, DT_LNK 10; anything else (DT_UNKNOWN too) is other.
            e.kind = t == (u8)8 ? (u8)DIR_FILE : t == (u8)4 ? (u8)DIR_DIRECTORY : t == (u8)10 ? (u8)DIR_LINK : (u8)DIR_OTHER;
            out.add((Object*)e);
            }
        closedir(d);
        return out;
#else
        return (Array*)0;
#endif
        }
    }
