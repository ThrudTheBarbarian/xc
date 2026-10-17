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

// KeyStore.xc — a secret the operating system keeps, for whoever asks for
// it by name: what `xcc --bundle-key keychain` keeps the publisher's signing
// key in (an opt-in; the default is a private 0600 file).
//
//     Data* k = KeyStore.load(String.withCString("bundle-key"));    // 0: none, or see lastError()
//     KeyStore.save(String.withCString("bundle-key"), k);
//
//   macOS    the login keychain, a generic password (service "xcc"), through
//            Security.framework loaded at run time. User interaction is turned
//            off first: a locked keychain, or a prompt nobody is there to
//            answer (an ssh session), is an error at once, never a wait.
//   Windows  DPAPI: the secret encrypted to this user, kept in
//            ~/.xcc/<name>.dpapi, with prompts forbidden.
//   Linux    the Secret Service (gnome-keyring, KWallet) through secret-tool,
//            when a session bus is there; a machine reached only by ssh has
//            none, and says so.
//
// lastError() says why a load or save failed; a load that finds nothing
// returns 0 with no error.
#import "Foundation.xc"
#import "Files.xc"
#import "PlatformCore.xc"

#if ARCH_win64
pointer LoadLibraryA(u8* name);
pointer GetProcAddress(pointer module, u8* name);
pointer LocalFree(pointer p);
typedef i32 KsCrypt_t(u8* blobIn, pointer desc, pointer entropy, pointer reserved, pointer prompt, u32 flags, u8* blobOut);
#elif ARCH_arm64 && !PLATFORM_ios && !PLATFORM_android
pointer dlopen(u8* path, i32 mode);
pointer dlsym(pointer handle, u8* name);
typedef i32 KsInteract_t(u8 allowed);
typedef i32 KsFind_t(pointer kc, u32 sl, u8* s, u32 al, u8* a, u32* pl, pointer* pd, pointer* item);
typedef i32 KsAdd_t(pointer kc, u32 sl, u8* s, u32 al, u8* a, u32 pl, u8* pd, pointer* item);
typedef i32 KsFree_t(pointer attrs, pointer data);
#elif ARCH_x86_64
pointer popen(u8* cmd, u8* mode);
i32 pclose(pointer f);
u64 fread(u8* p, u64 size, u64 n, pointer f);
u64 fwrite(u8* p, u64 size, u64 n, pointer f);
#endif

class KeyStore : Object
    {
    static String* _error;

    static String* lastError(void) { return _error; }

    static String* _fail(String* why)
        {
        _error = why;
        return (String*)0;
        }

    static Data* _failData(String* why)
        {
        _error = why;
        return (Data*)0;
        }

    static String* where(void)
        {
#if ARCH_win64
        return String.withCString("DPAPI (encrypted to this Windows user)");
#elif ARCH_arm64 && !PLATFORM_ios && !PLATFORM_android
        return String.withCString("the login keychain (service \"xcc\")");
#else
        return String.withCString("the Secret Service (secret-tool, service xcc)");
#endif
        }

    static String* _hex(Data* d)
        {
        String* s = new String();
        u8* b = d.bytes();
        for (u32 i = (u32)0; i < d.length(); i = i + (u32)1)
            s.appendFormat("%02x", (u32)b[i]);
        return s;
        }

    static Data* _unhex(String* s)
        {
        if ((s.byteLength() & (u32)1) != (u32)0)
            return (Data*)0;
        Data* d = Data.withLength(s.byteLength() / (u32)2);
        u8* b = d.bytes();
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)2)
            {
            u32 v = (u32)0;
            for (u32 k = (u32)0; k < (u32)2; k = k + (u32)1)
                {
                u8 c = s.byteAt(i + k);
                v = v << (u32)4;
                if (c >= (u8)'0' && c <= (u8)'9') v = v + (u32)(c - (u8)'0');
                else if (c >= (u8)'a' && c <= (u8)'f') v = v + (u32)(c - (u8)'a') + (u32)10;
                else return (Data*)0;
                }
            b[i / (u32)2] = (u8)v;
            }
        return d;
        }

#if ARCH_arm64 && !PLATFORM_ios && !PLATFORM_android
    static pointer _sec;

    static pointer _fn(u8* name)
        {
        if (_sec == (pointer)0)
            _sec = dlopen("/System/Library/Frameworks/Security.framework/Security", (i32)2);
        if (_sec == (pointer)0)
            return (pointer)0;
        KsInteract_t* off = (KsInteract_t*)dlsym(_sec, "SecKeychainSetUserInteractionAllowed");
        if (off != (KsInteract_t*)0)
            off((u8)0);
        return dlsym(_sec, name);
        }

    static String* _status(i32 st)
        {
        if (st == (i32)-25308)
            return String.withCString("the keychain would have to ask, and asking is off (locked, or an ssh session nobody can answer)");
        if (st == (i32)-25307 || st == (i32)-25294)
            return String.withCString("there is no default keychain here");
        return String.withFormat("the keychain refused (status %d)", st);
        }
#endif

#if ARCH_win64
    static String* _dpapiFile(String* name)
        {
        String* d = Platform.home();
        d.appendCString("/.xcc");
        Files.createDirectory(d);
        d.appendByte((u8)'/');
        d.append(name);
        d.appendCString(".dpapi");
        return d;
        }

    static KsCrypt_t* _crypt(u8* fn)
        {
        pointer m = LoadLibraryA("crypt32.dll");
        if (m == (pointer)0)
            return (KsCrypt_t*)0;
        return (KsCrypt_t*)GetProcAddress(m, fn);
        }
#endif

#if ARCH_x86_64 && !ARCH_win64
    // secret-tool runs only where a session bus is: a machine reached by ssh
    // alone has none, and a store there would fail or wait.
    static bool _session(void)
        {
        return Platform.env(String.withCString("DBUS_SESSION_BUS_ADDRESS")).byteLength() > (u32)0;
        }
#endif

    static Data* load(String* name)
        {
        _error = (String*)0;
#if ARCH_arm64 && !PLATFORM_ios && !PLATFORM_android
        KsFind_t* find = (KsFind_t*)KeyStore._fn("SecKeychainFindGenericPassword");
        KsFree_t* fr = (KsFree_t*)KeyStore._fn("SecKeychainItemFreeContent");
        if (find == (KsFind_t*)0 || fr == (KsFree_t*)0)
            return KeyStore._failData(String.withCString("Security.framework could not be loaded"));
        u32 pl = (u32)0;
        pointer pd = (pointer)0;
        i32 st = find((pointer)0, (u32)3, "xcc", name.byteLength(), name.cString(), &pl, &pd, (pointer*)0);
        if (st == (i32)-25300)
            return (Data*)0;
        if (st != (i32)0)
            return KeyStore._failData(KeyStore._status(st));
        String* hex = String.withBytes((u8*)pd, pl);
        fr((pointer)0, pd);
        Data* d = KeyStore._unhex(hex);
        if (d == (Data*)0)
            return KeyStore._failData(String.withCString("the keychain item is not a key"));
        return d;
#elif ARCH_win64
        Data* blob = Files.readData(KeyStore._dpapiFile(name));
        if (blob == (Data*)0)
            return (Data*)0;
        KsCrypt_t* un = KeyStore._crypt("CryptUnprotectData");
        if (un == (KsCrypt_t*)0)
            return KeyStore._failData(String.withCString("crypt32.dll could not be loaded"));
        u8[16] inB;
        u8[16] outB;
        *(u32*)&inB[0] = blob.length();
        *(u8**)&inB[8] = blob.bytes();
        *(u32*)&outB[0] = (u32)0;
        *(u8**)&outB[8] = (u8*)0;
        // CRYPTPROTECT_UI_FORBIDDEN
        if (un(&inB[0], (pointer)0, (pointer)0, (pointer)0, (pointer)0, (u32)1, &outB[0]) == (i32)0)
            return KeyStore._failData(String.withCString("DPAPI could not decrypt it (another user's, or this logon has no key to)"));
        Data* d = Data.withBytes(*(u8**)&outB[8], *(u32*)&outB[0]);
        LocalFree((pointer)*(u8**)&outB[8]);
        return d;
#elif ARCH_x86_64
        if (!KeyStore._session())
            return KeyStore._failData(String.withCString("no Secret Service here (no session bus: an ssh-only machine has none)"));
        String* cmd = String.withFormat("secret-tool lookup service xcc account '%s' 2>/dev/null", name.cString());
        pointer f = popen(cmd.cString(), "r");
        if (f == (pointer)0)
            return KeyStore._failData(String.withCString("secret-tool could not be run"));
        u8[256] buf;
        u64 n = fread(&buf[0], (u64)1, (u64)255, f);
        i32 rc = pclose(f);
        String* hex = String.withBytes(&buf[0], (u32)n);
        while (hex.byteLength() > (u32)0 && (hex.byteAt(hex.byteLength() - (u32)1) == (u8)10))
            hex = hex.substringBytes((u32)0, hex.byteLength() - (u32)1);
        if (hex.byteLength() == (u32)0)
            return (Data*)0;
        Data* d = KeyStore._unhex(hex);
        if (d == (Data*)0)
            return KeyStore._failData(String.withCString("the Secret Service item is not a key"));
        return d;
#else
        return KeyStore._failData(String.withCString("no keychain on this target"));
#endif
        }

    static bool save(String* name, Data* secret)
        {
        _error = (String*)0;
#if ARCH_arm64 && !PLATFORM_ios && !PLATFORM_android
        KsAdd_t* add = (KsAdd_t*)KeyStore._fn("SecKeychainAddGenericPassword");
        if (add == (KsAdd_t*)0)
            {
            KeyStore._fail(String.withCString("Security.framework could not be loaded"));
            return false;
            }
        String* hex = KeyStore._hex(secret);
        i32 st = add((pointer)0, (u32)3, "xcc", name.byteLength(), name.cString(), hex.byteLength(), hex.cString(),
                     (pointer*)0);
        if (st != (i32)0)
            {
            KeyStore._fail(KeyStore._status(st));
            return false;
            }
        return true;
#elif ARCH_win64
        KsCrypt_t* pr = KeyStore._crypt("CryptProtectData");
        if (pr == (KsCrypt_t*)0)
            {
            KeyStore._fail(String.withCString("crypt32.dll could not be loaded"));
            return false;
            }
        u8[16] inB;
        u8[16] outB;
        *(u32*)&inB[0] = secret.length();
        *(u8**)&inB[8] = secret.bytes();
        *(u32*)&outB[0] = (u32)0;
        *(u8**)&outB[8] = (u8*)0;
        if (pr(&inB[0], (pointer)0, (pointer)0, (pointer)0, (pointer)0, (u32)1, &outB[0]) == (i32)0)
            {
            KeyStore._fail(String.withCString("DPAPI could not encrypt it"));
            return false;
            }
        Data* blob = Data.withBytes(*(u8**)&outB[8], *(u32*)&outB[0]);
        LocalFree((pointer)*(u8**)&outB[8]);
        if (!Files.writeData(KeyStore._dpapiFile(name), blob))
            {
            KeyStore._fail(String.withCString("the encrypted key could not be written"));
            return false;
            }
        return true;
#elif ARCH_x86_64
        if (!KeyStore._session())
            {
            KeyStore._fail(String.withCString("no Secret Service here (no session bus: an ssh-only machine has none)"));
            return false;
            }
        // The secret on secret-tool's stdin, never on a command line.
        String* cmd = String.withFormat("secret-tool store --label='xcc %s' service xcc account '%s' 2>/dev/null",
                                        name.cString(), name.cString());
        pointer f = popen(cmd.cString(), "w");
        if (f == (pointer)0)
            {
            KeyStore._fail(String.withCString("secret-tool could not be run"));
            return false;
            }
        String* hex = KeyStore._hex(secret);
        fwrite(hex.cString(), (u64)1, (u64)hex.byteLength(), f);
        if (pclose(f) != (i32)0)
            {
            KeyStore._fail(String.withCString("secret-tool would not store it (is a keyring unlocked in this session?)"));
            return false;
            }
        return true;
#else
        KeyStore._fail(String.withCString("no keychain on this target"));
        return false;
#endif
        }
    }
