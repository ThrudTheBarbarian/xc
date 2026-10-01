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


// SettingsStore.xc — arm64: CFPreferences on macOS and iOS.
// ======================================================
//
// Settings.standard(name) keeps its values in the user's preferences, the
// store `defaults` reads and NSUserDefaults is built on: domain `name`, current
// user, any host. A value set by `defaults write <name> key -int 3` reads back
// as "3", a boolean as "true"/"false"; what Settings writes is always a string.
//
// Android shares this support tree and has no CFPreferences: there the class
// is the fallback with no platform store, and Settings uses a text file.

#import "String.xc"
#import "Array.xc"
#import "Data.xc"

#if ARCH_arm64 && !PLATFORM_android

#import <CoreFoundation>

// The CoreFoundation calls this needs. CFIndex is a signed long, CFTypeID an
// unsigned one, Boolean a byte.
pointer CFStringCreateWithCString(pointer alloc, u8* cStr, u32 encoding);
i64 CFStringGetLength(pointer str);
i64 CFStringGetMaximumSizeForEncoding(i64 length, u32 encoding);
u8 CFStringGetCString(pointer str, u8* buffer, i64 bufferSize, u32 encoding);
u64 CFGetTypeID(pointer cf);
u64 CFStringGetTypeID(void);
u64 CFNumberGetTypeID(void);
u64 CFBooleanGetTypeID(void);
u8 CFNumberIsFloatType(pointer number);
u8 CFNumberGetValue(pointer number, i64 theType, pointer valuePtr);
u8 CFBooleanGetValue(pointer boolean);
i64 CFArrayGetCount(pointer theArray);
pointer CFArrayGetValueAtIndex(pointer theArray, i64 idx);
void CFRelease(pointer cf);
pointer CFPreferencesCopyKeyList(pointer applicationID, pointer userName, pointer hostName);
pointer CFPreferencesCopyAppValue(pointer key, pointer applicationID);
void CFPreferencesSetAppValue(pointer key, pointer value, pointer applicationID);
u8 CFPreferencesAppSynchronize(pointer applicationID);

#define CF_UTF8          $08000100
#define CF_NUMBER_SINT64 4
#define CF_NUMBER_DOUBLE 13

class SettingsStore
    {
    static bool native(void)
        {
        return true;
        }

    // The domain's keys in byte order, so a store reads back the same however
    // the system happened to keep them.
    static bool load(String* domain, Array* keys, Array* values)
        {
        keys.removeAll();
        values.removeAll();
        pointer app = SettingsStore._cf(domain);
        pointer user = SettingsStore._cf(String.withCString("kCFPreferencesCurrentUser"));
        pointer host = SettingsStore._cf(String.withCString("kCFPreferencesAnyHost"));
        pointer list = CFPreferencesCopyKeyList(app, user, host);
        if (list != (pointer)0)
            {
            i64 n = CFArrayGetCount(list);
            for (i64 i = (i64)0; i < n; i = i + (i64)1)
                {
                pointer key = CFArrayGetValueAtIndex(list, i);
                pointer value = CFPreferencesCopyAppValue(key, app);
                String* k = SettingsStore._string(key);
                String* v = value == (pointer)0 ? (String*)0 : SettingsStore._value(value);
                if (value != (pointer)0)
                    CFRelease(value);
                if (k != 0 && v != 0)
                    SettingsStore._insertSorted(keys, values, k, v);
                }
            CFRelease(list);
            }
        CFRelease(host);
        CFRelease(user);
        CFRelease(app);
        return true;
        }

    // Make the domain hold `keys`/`values`: a key no longer there is removed
    // (if it held text — see below), every value is written as a string, and
    // the change is flushed.
    static bool save(String* domain, Array* keys, Array* values)
        {
        pointer app = SettingsStore._cf(domain);
        pointer user = SettingsStore._cf(String.withCString("kCFPreferencesCurrentUser"));
        pointer host = SettingsStore._cf(String.withCString("kCFPreferencesAnyHost"));
        pointer list = CFPreferencesCopyKeyList(app, user, host);
        if (list != (pointer)0)
            {
            i64 n = CFArrayGetCount(list);
            for (i64 i = (i64)0; i < n; i = i + (i64)1)
                {
                pointer key = CFArrayGetValueAtIndex(list, i);
                String* k = SettingsStore._string(key);
                if (k == 0 || SettingsStore._contains(keys, k))
                    continue;
                // Only a value Settings could have read is removed: an array
                // or a date another program keeps in the same domain was never
                // in `keys`, and dropping it would lose it.
                pointer old = CFPreferencesCopyAppValue(key, app);
                bool text = old != (pointer)0 && SettingsStore._value(old) != 0;
                if (old != (pointer)0)
                    CFRelease(old);
                if (text)
                    CFPreferencesSetAppValue(key, (pointer)0, app);
                }
            CFRelease(list);
            }
        for (u32 i = (u32)0; i < keys.count(); i = i + (u32)1)
            {
            pointer k = SettingsStore._cf((String*)keys.get(i));
            pointer v = SettingsStore._cf((String*)values.get(i));
            CFPreferencesSetAppValue(k, v, app);
            CFRelease(v);
            CFRelease(k);
            }
        bool ok = CFPreferencesAppSynchronize(app) != (u8)0;
        CFRelease(host);
        CFRelease(user);
        CFRelease(app);
        return ok;
        }

    // ── internals ────────────────────────────────────────────────────────

    // A new CFString (the caller releases it).
    static pointer _cf(String* s)
        {
        return CFStringCreateWithCString((pointer)0, s.cString(), (u32)CF_UTF8);
        }

    static String* _string(pointer cfs)
        {
        if (cfs == (pointer)0 || CFGetTypeID(cfs) != CFStringGetTypeID())
            return (String*)0;
        i64 size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(cfs), (u32)CF_UTF8) + (i64)1;
        Data* buf = Data.withLength((u32)size);
        if (CFStringGetCString(cfs, buf.bytes(), size, (u32)CF_UTF8) == (u8)0)
            return (String*)0;
        return String.withCString(buf.bytes());
        }

    // A preference value as Settings text: a string as it is, a number in
    // decimal, a boolean as true/false. Anything else (data, a date, an
    // array) has no text form here and is left out.
    static String* _value(pointer v)
        {
        u64 t = CFGetTypeID(v);
        if (t == CFStringGetTypeID())
            return SettingsStore._string(v);
        if (t == CFBooleanGetTypeID())
            return String.withCString(CFBooleanGetValue(v) != (u8)0 ? "true" : "false");
        if (t == CFNumberGetTypeID())
            {
            if (CFNumberIsFloatType(v) != (u8)0)
                {
                double d = 0.0d;
                CFNumberGetValue(v, (i64)CF_NUMBER_DOUBLE, (pointer)&d);
                return String.withFormat("%g", d);
                }
            i64 n = (i64)0;
            CFNumberGetValue(v, (i64)CF_NUMBER_SINT64, (pointer)&n);
            return String.withI64(n);
            }
        return (String*)0;
        }

    static bool _contains(Array* keys, String* k)
        {
        for (u32 i = (u32)0; i < keys.count(); i = i + (u32)1)
            if (((String*)keys.get(i)).equals(k))
                return true;
        return false;
        }

    static void _insertSorted(Array* keys, Array* values, String* k, String* v)
        {
        u32 at = keys.count();
        while (at > (u32)0 && ((String*)keys.get(at - (u32)1)).compare(k) > (i8)0)
            at = at - (u32)1;
        keys.insert(at, (Object*)k);
        values.insert(at, (Object*)v);
        }
    }

#else

// Android: no platform store, so the fallback's answers.
class SettingsStore
    {
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

#endif
