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

// SecureRandom.xc — bytes from the operating system's random source, for
// keys and nonces (never a userspace PRNG):
//
//     u8 seed[32];
//     if (!SecureRandom.fill(&seed[0], (u32)32)) { ... }   // false: no source
//
// getentropy on Apple and Linux (glibc, musl, bionic), BCryptGenRandom on
// Windows, crypto.getRandomValues on the web (the wasm32 loader).
#import "Foundation.xc"

#if OS_windows
pointer LoadLibraryA(u8* name);
pointer GetProcAddress(pointer module, u8* name);
typedef i32 bcryptGenRandom_t(pointer alg, u8* buf, u32 n, u32 flags);
#elif ARCH_wasm32
i32 _xt_random_fill(u8* p, u32 n);
#elif ARCH_arm64 || ARCH_x86_64 || OS_android
i32 getentropy(pointer buf, u64 n);
#endif

class SecureRandom
    {
#if OS_windows
    static bcryptGenRandom_t* _gen;
#endif

    // n random bytes at p; false when the system has no source (or it failed).
    static bool fill(u8* p, u32 n)
        {
#if OS_windows
        if (_gen == (bcryptGenRandom_t*)0)
            {
            pointer lib = LoadLibraryA("bcrypt.dll");
            if (lib == (pointer)0)
                return false;
            _gen = (bcryptGenRandom_t*)GetProcAddress(lib, "BCryptGenRandom");
            if (_gen == (bcryptGenRandom_t*)0)
                return false;
            }
        // BCRYPT_USE_SYSTEM_PREFERRED_RNG (2), no algorithm handle.
        return _gen((pointer)0, p, n, (u32)2) == (i32)0;
#elif ARCH_wasm32
        return _xt_random_fill(p, n) == (i32)0;
#elif ARCH_arm64 || ARCH_x86_64 || OS_android
        // getentropy gives at most 256 bytes a call.
        u32 at = (u32)0;
        while (at < n)
            {
            u32 k = n - at > (u32)256 ? (u32)256 : n - at;
            if (getentropy((pointer)(p + at), (u64)k) != (i32)0)
                return false;
            at = at + k;
            }
        return true;
#else
        return false;
#endif
        }

    // n random bytes as Data, or 0.
    static Data* bytes(u32 n)
        {
        Data* d = Data.withLength(n);
        if (!SecureRandom.fill(d.bytes(), n))
            return (Data*)0;
        return d;
        }
    }
