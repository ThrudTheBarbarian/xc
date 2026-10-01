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


// SettingsStore.xc — win64: the registry.
// ====================================
//
// Settings.standard(name) keeps its values under
// HKEY_CURRENT_USER\Software\<name>, one string value per setting, as Windows
// programs do. A DWORD or QWORD value another program left there reads back in
// decimal; what Settings writes is always a string (REG_SZ).

#import "String.xc"
#import "Array.xc"
#import "Data.xc"

// The ADVAPI32 calls this needs; the linker imports only what is used. A
// registry handle is a pointer, LONG/DWORD are 32 bits.
i32 RegOpenKeyExA(pointer hKey, u8* subKey, u32 options, u32 samDesired, pointer phkResult);
i32 RegCreateKeyExA(pointer hKey, u8* subKey, u32 reserved, u8* cls, u32 options, u32 samDesired,
                    pointer security, pointer phkResult, pointer disposition);
i32 RegQueryInfoKeyA(pointer hKey, u8* cls, pointer clsLen, pointer reserved, pointer subKeys,
                     pointer maxSubKeyLen, pointer maxClassLen, pointer values, pointer maxValueNameLen,
                     pointer maxValueLen, pointer securityDescriptor, pointer lastWriteTime);
i32 RegEnumValueA(pointer hKey, u32 index, u8* valueName, pointer valueNameLen, pointer reserved,
                  pointer type, u8* data, pointer dataLen);
i32 RegSetValueExA(pointer hKey, u8* valueName, u32 reserved, u32 type, u8* data, u32 dataLen);
i32 RegDeleteValueA(pointer hKey, u8* valueName);
i32 RegCloseKey(pointer hKey);

#define REG_SZ        1
#define REG_EXPAND_SZ 2
#define REG_DWORD     4
#define REG_QWORD     11
#define KEY_READ      $20019
#define KEY_READWRITE $2001F

class SettingsStore
    {
    static bool native(void)
        {
        return true;
        }

    // The values under the key, in byte order of their names.
    static bool load(String* domain, Array* keys, Array* values)
        {
        keys.removeAll();
        values.removeAll();
        pointer h = (pointer)0;
        if (RegOpenKeyExA(SettingsStore._hkcu(), SettingsStore._subKey(domain).cString(), (u32)0,
                          (u32)KEY_READ, (pointer)&h) != (i32)0)
            return true;    // no key yet: an empty store
        SettingsStore._read(h, keys, values);
        RegCloseKey(h);
        return true;
        }

    // Make the key hold `keys`/`values`: a value no longer there is removed
    // (if it held text or a number — anything else another program keeps
    // there is left alone), and every value is written as a string.
    static bool save(String* domain, Array* keys, Array* values)
        {
        pointer h = (pointer)0;
        u32 disposition = (u32)0;
        if (RegCreateKeyExA(SettingsStore._hkcu(), SettingsStore._subKey(domain).cString(), (u32)0,
                            (u8*)0, (u32)0, (u32)KEY_READWRITE, (pointer)0, (pointer)&h,
                            (pointer)&disposition) != (i32)0)
            return false;
        Array* oldKeys = new Array();
        Array* oldValues = new Array();
        SettingsStore._read(h, oldKeys, oldValues);
        for (u32 i = (u32)0; i < oldKeys.count(); i = i + (u32)1)
            {
            String* k = (String*)oldKeys.get(i);
            bool keep = false;
            for (u32 j = (u32)0; j < keys.count(); j = j + (u32)1)
                if (((String*)keys.get(j)).equals(k))
                    keep = true;
            if (!keep)
                RegDeleteValueA(h, k.cString());
            }
        bool ok = true;
        for (u32 i = (u32)0; i < keys.count(); i = i + (u32)1)
            {
            String* v = (String*)values.get(i);
            if (RegSetValueExA(h, ((String*)keys.get(i)).cString(), (u32)0, (u32)REG_SZ, v.cString(),
                               v.byteLength() + (u32)1) != (i32)0)
                ok = false;
            }
        RegCloseKey(h);
        return ok;
        }

    // ── internals ────────────────────────────────────────────────────────

    // HKEY_CURRENT_USER: the LONG 0x80000001, sign-extended to a handle.
    static pointer _hkcu(void)
        {
        return (pointer)(i64)(i32)$80000001;
        }

    static String* _subKey(String* domain)
        {
        return String.withCString("Software\\").appending(domain);
        }

    // Every text or numeric value under `h`, sorted by name. Values of other
    // types (binary, multi-string) have no Settings form and are skipped.
    static void _read(pointer h, Array* keys, Array* values)
        {
        u32 count = (u32)0;
        u32 maxName = (u32)0;
        u32 maxData = (u32)0;
        if (RegQueryInfoKeyA(h, (u8*)0, (pointer)0, (pointer)0, (pointer)0, (pointer)0, (pointer)0,
                             (pointer)&count, (pointer)&maxName, (pointer)&maxData, (pointer)0,
                             (pointer)0) != (i32)0)
            return;
        Data* name = Data.withLength(maxName + (u32)1);
        Data* data = Data.withLength(maxData + (u32)9);
        for (u32 i = (u32)0; i < count; i = i + (u32)1)
            {
            u32 nameLen = maxName + (u32)1;
            u32 dataLen = maxData + (u32)8;
            u32 type = (u32)0;
            if (RegEnumValueA(h, i, name.bytes(), (pointer)&nameLen, (pointer)0, (pointer)&type,
                              data.bytes(), (pointer)&dataLen) != (i32)0)
                continue;
            String* v = SettingsStore._value(type, data.bytes(), dataLen);
            if (v == 0)
                continue;
            SettingsStore._insertSorted(keys, values, String.withBytes(name.bytes(), nameLen), v);
            }
        }

    static String* _value(u32 type, u8* b, u32 n)
        {
        if (type == (u32)REG_SZ || type == (u32)REG_EXPAND_SZ)
            {
            u32 len = (u32)0;
            while (len < n && b[len] != (u8)0)
                len = len + (u32)1;
            return String.withBytes(b, len);
            }
        if (type == (u32)REG_DWORD && n >= (u32)4)
            return String.withI64((i64)*(u32*)(pointer)b);
        if (type == (u32)REG_QWORD && n >= (u32)8)
            return String.withI64(*(i64*)(pointer)b);
        return (String*)0;
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
