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
// Cache.xc — a bounded least-recently-used cache (NSCache in shape).
//
// Values stored under string keys, at most `capacity` of them: a set that
// would go over evicts the entry used least recently, and every get and set
// counts as a use. What a thumbnail, image or parsed-resource cache uses to
// stay bounded.
//
//     Cache* thumbs = new Cache();
//     thumbs.setCapacity((i32)64);
//     thumbs.set("a.png", image);
//     Image* i = (Image* ?)thumbs.get("a.png");   // null once evicted
//
// A Map from each key (copied into a String the cache owns, so the caller's
// buffer may change or go away) to its entry, and a doubly linked list of the
// entries from most to least recently used: get, set and eviction are all
// close to O(1). The cache holds a strong reference to each value while it is
// cached.
//
// Heap-capable targets only.
#import "Map.xc"
#import "String.xc"

class _CacheEntry : Object
    {
    String* key;
    Object* value;
    _CacheEntry* newer; // towards the most recently used
    _CacheEntry* older; // towards the least recently used
    void init(void)
        {
        key = (String*)0;
        value = (Object*)0;
        newer = (_CacheEntry*)0;
        older = (_CacheEntry*)0;
        }
    }

class Cache
    {
    Map* _byKey;         // String key -> _CacheEntry
    _CacheEntry* _first; // most recently used
    _CacheEntry* _last;  // least recently used: the next to go
    i32 _capacity;

    void init(void)
        {
        _byKey = new Map();
        _first = (_CacheEntry*)0;
        _last = (_CacheEntry*)0;
        _capacity = (i32)16;
        }

    // Takes `e` out of the recency list.
    void _unlink(_CacheEntry* e)
        {
        if (e.newer != (_CacheEntry*)0)
            e.newer.older = e.older;
        else
            _first = e.older;
        if (e.older != (_CacheEntry*)0)
            e.older.newer = e.newer;
        else
            _last = e.newer;
        // The list links are strong references both ways; clearing them is what
        // lets the entry go.
        e.newer = (_CacheEntry*)0;
        e.older = (_CacheEntry*)0;
        }

    // Puts `e` at the most recently used end.
    void _pushFirst(_CacheEntry* e)
        {
        e.newer = (_CacheEntry*)0;
        e.older = _first;
        if (_first != (_CacheEntry*)0)
            _first.newer = e;
        _first = e;
        if (_last == (_CacheEntry*)0)
            _last = e;
        }

    void _evictToFit(void)
        {
        while ((i32)_byKey.count() > _capacity && _last != (_CacheEntry*)0)
            {
            _CacheEntry* victim = _last;
            _unlink(victim);
            _byKey.remove(victim.key);
            }
        }

    // ── API ──────────────────────────────────────────────────────

    // At most n entries (at least 1); evicts down to it now.
    void setCapacity(i32 n)
        {
        _capacity = n < (i32)1 ? (i32)1 : n;
        _evictToFit();
        }

    i32 capacity(void)
        {
        return _capacity;
        }

    // The number of entries.
    i32 count(void)
        {
        return (i32)_byKey.count();
        }

    // Stores `value` under `key`, replacing what was there, and marks it most
    // recently used; then evicts the least recently used past the capacity.
    void set(u8* key, Object* value)
        {
        String* k = String.withCString(key);
        _CacheEntry* e = (_CacheEntry* ?)_byKey.get(k);
        if (e != (_CacheEntry*)0)
            {
            e.value = value;
            _unlink(e);
            _pushFirst(e);
            return;
            }
        e = new _CacheEntry();
        e.key = k;
        e.value = value;
        _byKey.set(k, e);
        _pushFirst(e);
        _evictToFit();
        }

    // The value under `key` (null if absent or evicted); marks it most recently used.
    Object* get(u8* key)
        {
        _CacheEntry* e = (_CacheEntry* ?)_byKey.get(String.withCString(key));
        if (e == (_CacheEntry*)0)
            return (Object*)0;
        _unlink(e);
        _pushFirst(e);
        return e.value;
        }

    // Whether `key` is cached; does not count as a use.
    bool contains(u8* key)
        {
        return _byKey.contains(String.withCString(key));
        }

    void remove(u8* key)
        {
        String* k = String.withCString(key);
        _CacheEntry* e = (_CacheEntry* ?)_byKey.get(k);
        if (e == (_CacheEntry*)0)
            return;
        _unlink(e);
        _byKey.remove(k);
        }

    void removeAll(void)
        {
        while (_last != (_CacheEntry*)0)
            _unlink(_last);
        _byKey.removeAll();
        }

    void dealloc(void)
        {
        // Break the list's links so every entry can be freed with the map.
        while (_last != (_CacheEntry*)0)
            _unlink(_last);
        }
    }
