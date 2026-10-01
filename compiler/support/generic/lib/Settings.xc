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

// Settings.xc — persistent key/value settings, the same on every target.
// =================================================================
//
// The library has Files (whole-file I/O) and Platform (the environment) but
// nothing that turns either into *settings*: a small named set of values a
// program reads at startup and writes back when it changes. That is the
// NSUserDefaults-shaped hole, and it is the one thing an app of any size
// reaches for first, so it is here rather than in each app.
//
// Three layers, each usable on its own:
//
//   Settings.memory()        in-memory only. Every target, including the ones
//                            with no filesystem at all.
//   Settings.open(path)      memory plus a file: read once here, rewritten in
//                            full by save(). Needs Files.
//   Settings.standard(name)  open() at the conventional per-user path
//                            ($XCC_SETTINGS_DIR, else $HOME/.config/xcc),
//                            falling back to memory() where there is no home.
//
// The FILE is text: one `key = value` per line, `#` starts a comment, blank
// lines are ignored, and both sides are trimmed. A value cannot contain a
// newline; a key cannot contain '=' or '#'. That is the entire format — it is
// meant to be read and edited by hand, and it round-trips byte for byte.
//
// The store keeps INSERTION ORDER, so save() writes what was set, in the order
// it was set, and saving an unchanged store rewrites the same bytes.
//
//   Settings* s = Settings.standard(String.withCString("demo"));
//   u32 runs = s.getInt(String.withCString("runs"), (i32)0);
//   s.setInt(String.withCString("runs"), (i32)runs + (i32)1);
//   s.save();
//
// Not ambient: `#import "Settings.xc"` names it, as it does Files.

#import "String.xc"
#import "Array.xc"
#import "Platform.xc"

#if ARCH_6502
// A 6502 has no filesystem: the store stays in memory and save()/reload()
// report false rather than pretending. Files.xc is not even imported, so no
// `_xt_file_*` reference can reach the link.
#else
#import "Files.xc"
#endif

class Settings
    {
    Array* _keys;    // String*, in insertion order
    Array* _values;  // String*, parallel to _keys
    String* _path;   // the backing file, or 0 for memory-only

    void init(void)
        {
        _keys = new Array();
        _values = new Array();
        _path = (String*)0;
        }

    // ── construction ─────────────────────────────────────────────────────

    static Settings* memory(void)
        {
        return new Settings();
        }

    // Memory plus `path`: an existing file is read now, a missing one is an
    // empty store rather than an error — the first save() creates it.
    static Settings* open(String* path)
        {
        Settings* s = new Settings();
        if (path == 0 || path.byteLength() == (u32)0)
            return s;
        s._path = String.withString(path);
#if ARCH_6502
        return s;
#else
        String* text = Files.readText(s._path);
        if (text != 0)
            s.loadText(text);
        return s;
#endif
        }

    // The conventional location for an app called `name`: $XCC_SETTINGS_DIR
    // when it is set, else $HOME/.config/xcc. Where there is no home to read
    // — a 6502, a bare ARM9, a browser tab — this is memory().
    static Settings* standard(String* name)
        {
        String* dir = Platform.env(String.withCString("XCC_SETTINGS_DIR"));
        if (dir == 0 || dir.byteLength() == (u32)0)
            {
            String* home = Platform.home();
            if (home == 0 || home.byteLength() == (u32)0)
                return Settings.memory();
            dir = home.appending(String.withCString("/.config/xcc"));
            }
        String* path = dir.appending(String.withCString("/")).appending(name)
                      .appending(String.withCString(".conf"));
        return Settings.open(path);
        }

    // ── reading ──────────────────────────────────────────────────────────

    // The value for `key`, or 0 when there is none. A caller that would rather
    // not test uses the two-argument form.
    since("0.64") String* get(String* key)
        {
        i32 at = _indexOf(key);
        return at < (i32)0 ? (String*)0 : (String*)_values.get((u32)at);
        }

    since("0.64") String* get(String* key, String* fallback)
        {
        String* v = get(key);
        return v == 0 ? fallback : v;
        }

    since("0.64") bool has(String* key)
        {
        return _indexOf(key) >= (i32)0;
        }

    // A decimal integer, or `fallback` when the key is absent or the value is
    // not an integer. The stored text is not changed by reading it.
    since("0.64") i32 getInt(String* key, i32 fallback)
        {
        String* v = get(key);
        if (v == 0)
            return fallback;
        u8* b = v.cString();
        u32 n = v.byteLength();
        u32 i = (u32)0;
        bool neg = false;
        if (n > (u32)0 && (b[0] == (u8)'-' || b[0] == (u8)'+'))
            {
            neg = b[0] == (u8)'-';
            i = (u32)1;
            }
        if (i >= n)
            return fallback;
        i32 acc = (i32)0;
        while (i < n)
            {
            u8 c = b[i];
            if (c < (u8)'0' || c > (u8)'9')
                return fallback;
            acc = acc * (i32)10 + (i32)(c - (u8)'0');
            i = i + (u32)1;
            }
        return neg ? -acc : acc;
        }

    // "true"/"yes"/"1", "false"/"no"/"0", anything else `fallback`.
    since("0.64") bool getBool(String* key, bool fallback)
        {
        String* v = get(key);
        if (v == 0)
            return fallback;
        String* t = v.trimmed();
        if (t.equals(String.withCString("true")) || t.equals(String.withCString("yes"))
            || t.equals(String.withCString("1")))
            return true;
        if (t.equals(String.withCString("false")) || t.equals(String.withCString("no"))
            || t.equals(String.withCString("0")))
            return false;
        return fallback;
        }

    since("0.64") u32 count(void)
        {
        return _keys.count();
        }

    // The keys, in insertion order, as a fresh Array.
    since("0.64") Array* keys(void)
        {
        Array* out = Array.withCapacity(_keys.count());
        for (u32 i = (u32)0; i < _keys.count(); i = i + (u32)1)
            out.add(_keys.get(i));
        return out;
        }

    // ── writing ──────────────────────────────────────────────────────────

    since("0.64") void set(String* key, String* value)
        {
        if (key == 0 || key.byteLength() == (u32)0)
            return;
        String* v = String.withString(value == 0 ? String.withCString("") : value);
        i32 at = _indexOf(key);
        if (at >= (i32)0)
            {
            _values.set((u32)at, (Object*)v);
            return;
            }
        _keys.add((Object*)String.withString(key));
        _values.add((Object*)v);
        }

    since("0.64") void setInt(String* key, i32 value)
        {
        set(key, String.withI32(value));
        }

    since("0.64") void setBool(String* key, bool value)
        {
        set(key, String.withCString(value ? "true" : "false"));
        }

    since("0.64") void remove(String* key)
        {
        i32 at = _indexOf(key);
        if (at < (i32)0)
            return;
        _keys.removeAt((u32)at);
        _values.removeAt((u32)at);
        }

    since("0.64") void removeAll(void)
        {
        _keys.removeAll();
        _values.removeAll();
        }

    // ── persistence ──────────────────────────────────────────────────────

    since("0.64") String* path(void)
        {
        return _path;
        }

    // The whole store as the file text, comments and all.
    since("0.64") String* serialise(void)
        {
        String* out = String.withCString("");
        for (u32 i = (u32)0; i < _keys.count(); i = i + (u32)1)
            {
            out.append((String*)_keys.get(i));
            out.appendCString(" = ");
            out.append((String*)_values.get(i));
            out.appendCString("\n");
            }
        return out;
        }

    // Replace the store with what `text` says. Comments and blank lines are
    // dropped, so a save() after a load() does NOT preserve them — the file is
    // a settings file, not a document.
    since("0.64") void loadText(String* text)
        {
        _keys.removeAll();
        _values.removeAll();
        if (text == 0)
            return;
        Array* lines = text.splitOnByte((u8)'\n');
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
            {
            String* line = ((String*)lines.get(i)).trimmed();
            if (line.byteLength() == (u32)0)
                continue;
            if (line.byteAt((u32)0) == (u8)'#')
                continue;
            // The sentinel is the PLATFORM's index type: a 6502 String index
            // is u16, so `notFound()` is $FFFF there and 0xFFFFFFFF on the
            // 32-bit targets. Comparing against a u32 literal silently
            // accepted every line with no '=' on xt6502.
            u32 eq = line.indexOfByte((u8)'=');
            if (eq == String.notFound())
                continue;
            String* k = line.substringBytes((u32)0, eq).trimmed();
            if (k.byteLength() == (u32)0)
                continue;
            set(k, line.substringFromByte(eq + (u32)1).trimmed());
            }
        }

    // Write the store to the backing file. False when there is no file to
    // write (memory-only, or a target with no filesystem) — the caller can
    // then say so instead of believing the settings persisted.
    since("0.64") bool save(void)
        {
        if (_path == 0)
            return false;
#if ARCH_6502
        return false;
#else
        Settings._makeParents(_path);
        return Files.writeText(_path, serialise());
#endif
        }

#if !ARCH_6502
    // Create every directory above `path` that is missing, so the first save
    // to ~/.config/xcc on a machine that has never had one succeeds. One that
    // is already there is fine; one that cannot be made shows up as the write
    // failing.
    static void _makeParents(String* path)
        {
        u32 n = path.byteLength();
        for (u32 i = (u32)1; i < n; i = i + (u32)1)
            if (path.byteAt(i) == (u8)'/')
                Files.createDirectory(path.substringBytes((u32)0, i));
        }
#endif

    // Re-read the backing file. A file that has since gone leaves the store
    // EMPTY, not stale: the file is the truth.
    since("0.64") bool reload(void)
        {
        if (_path == 0)
            return false;
#if ARCH_6502
        return false;
#else
        String* text = Files.readText(_path);
        if (text == 0)
            {
            _keys.removeAll();
            _values.removeAll();
            return true;
            }
        loadText(text);
        return true;
#endif
        }

    // ── internals ────────────────────────────────────────────────────────

    i32 _indexOf(String* key)
        {
        if (key == 0)
            return (i32)-1;
        for (u32 i = (u32)0; i < _keys.count(); i = i + (u32)1)
            {
            if (((String*)_keys.get(i)).equals(key))
                return (i32)i;
            }
        return (i32)-1;
        }
    }
