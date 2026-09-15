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

// Array.xc — NSMutableArray-style resizable list of Object*.
// =================================================================
//
// First Foundation container. Holds heap-class pointers as u16 bits
// internally and exposes Object* at the API surface. Number / String
// / Data — and any user class — fit because the runtime's built-in
// Object root makes every parentless `class X` an implicit child of
// Object, so an `X*` is always a valid `Object*`.
//
// Usage:
//   Array* a = new Array();
//   a.add(Number.withI16(-42));
//   a.add(String.withCString("hi"));
//
//   for (u16 i = (u16)0; i < a.count(); i++) {
//       Object* o = a.get(i);
//       Number* n = (Number* ?)o;            // safe-checked cast
//       if (n != 0) Stdio.printf("%d\n", n.asI16());
//   }
//
// Storage: a heap-allocated raw byte buffer (`u8*`) where each
// pair of bytes holds the 2-byte pointer of an Object* — the
// codegen rejects `new u16[N]` with a runtime-valued N today, so
// we deposit the bytes manually at offset `i*2` (lo) and `i*2+1`
// (hi) per element.
//
// Ownership: the Array holds a +1 strong reference on every
// element it stores. `add` / `insert` retain the incoming object,
// `set` releases the old slot's pointer before retaining the new
// one, and `removeAt` / `removeFirst` / `removeLast` /
// `removeAll` release the slot they vacate. Banked-heap targets
// carry the implicit constraint that every element must live in
// `heap_bank_first` (the only bank a 2-byte slot can address);
// the retain / release helpers default Y = heap_bank_first when
// no bank byte is in scope.
//
// Dealloc walks any remaining elements on drop and releases
// each — an Array that goes out of scope at refcount 0 cleanly
// reclaims every retained element without the caller needing
// to `removeAll()` first.
//
// Capacity grows geometrically: starts at 8, doubles when full.
// `withCapacity` lets the caller pre-size when the rough total is
// known up front (avoids the resize copy).
//
// Heap-capable targets only.
//
// ── xt6502 build of this class ───────────────────────────────────────────
// The 6502 Foundation. Counts, indices and lengths are u16 and the hash is
// u8, because on an 8-bit CPU a 32-bit index is four bytes of arithmetic on
// every compare and every increment, and a container that could address more
// than 65535 elements could not fit them anyway — one heap block is capped
// at a 12 KB bank. The 32-bit machines (arm64, arm9, m68k, x86_64) use
// `support/generic/lib/` instead, which is uncapped and hashes 32-bit.
//
// Same API, different implementation. Neither target pays for the other's
// constraints.
//
// Only the files whose WIDTHS differ live here. Everything width-neutral —
// Object, Comparable, Sort, the Foundation umbrella — exists once, in
// generic/lib, and is shared: a library file's `#import "X.xc"` resolves
// through the platform's lib dir first and generic/lib second, never against
// its own directory. So generic/lib/Object.xc picks up THIS String and THIS
// Hashable when the target is the 6502.
//

#import "Object.xc"
#import "Enumerable.xc"
#import "Comparable.xc"

// File-scope helpers that retain / release a stored element pointer.
// Both forward to the `__arc_retain` / `__arc_release` language primitives
// — the sanctioned manual-refcount path for the type-erased `pointer` slots
// ARC can't see. Each lowers to the compiler's own Retain / Release
// (null-safe, bank-carrying), so they behave identically on both backends:
// arm64 genuinely retains and frees its elements (no leak), xt6502 routes
// through the real free-list ARC. The old inline-6502-asm bodies were
// no-ops on the arm64 backend.

void _array_arc_retain(pointer ptr)
    {
    __arc_retain(ptr);
    }

void _array_arc_release(pointer ptr)
    {
    __arc_release(ptr);
    }

// Free a raw slot buffer — straight `_heap_free`, no refcount and no
// destructor dispatch. That distinction matters on this target: a raw
// `new pointer[N]` block carries no destructor descriptor, so routing it
// through the ARC release path (which dispatches one) walks into garbage.
// The 32-bit Foundation can use `__arc_release` here; the 6502 cannot.
// Null-safe.
void _array_slots_free(pointer* buf)
    {
    asm {
        LDA buf
        LDX buf+1
        ORA buf+1
        BEQ .bf_done
        LDA buf
        LDX buf+1
#if XTC_POINTER_WIDTH == 3
        LDY buf+2
#elif XTC_POINTER_WIDTH == 4
        LDA buf+3
        STA $89
        LDA buf
        LDX buf+1
        LDY buf+2
#else
        LDY #heap_bank_first
#endif
        JSR _heap_free
.bf_done:
    }
    }

// A comparator over two elements: < 0 if a sorts before b, 0 if they sort
// equally, > 0 if a sorts after — the C / NSComparisonResult convention.
// `Array.sortUsing` takes it as a `^`, so a plain function widens into one and
// a bound method (`&self.byColumn`) carries its receiver along with it.
typedef i8 cmp2_t(Object*, Object*);

// The three shapes the functional methods take. Each is a `^`, so a plain
// function widens into one and a bound method carries its receiver — which is
// what lets a predicate close over state (`&filter.matches`) without a global.
typedef bool pred_t(Object*);     // filtered / firstWhere / anySatisfy …
typedef Object* xform_t(Object*); // mapped
typedef void visit_t(Object*);    // forEach

// The comparator behind `Array.sort()`: defer to the elements' own Comparable
// `compare` slot. sort() has already established that the elements implement it
// (an unimplemented optional method leaves a null vtable slot, so `&e.compare`
// comes back null), which is why this can dispatch without re-checking on every
// single comparison.
//
// A null element sorts first, and an element that turns out not to implement
// compare after all sorts equal — neither can happen through sort(), but a
// caller is free to pass this to sortUsing() directly.
// Value equality between two elements, for `Array.isEqualToArray`. Every class
// conforms to Comparable — `Object` itself does, with pointer identity — so the
// cast is always sound and an element that defines no value equality falls back
// to being equal only to itself.
//
// Identity is checked first, which also makes two nulls equal.
bool _array_elem_equals(Object* a, Object* b)
    {
    if (a == b)
        return true;
    if (a == 0 || b == 0)
        return false;
    Comparable* ca = (Comparable*)a;
    return ca.equals(b);
    }

i8 _array_natural_cmp(Object* a, Object* b)
    {
    if (a == 0)
        return (b == 0) ? (i8)0 : (i8)-1;
    if (b == 0)
        return (i8)1;
    Comparable* ca = (Comparable*)a;
    callback f i8(Object * other) = &ca.compare;
    if (!f)
        return (i8)0;
    return f(b);
    }

class Array<Enumerable>
    {
    pointer* _slots; // heap pointer-cell buffer, length == _capacity
    u16 _count;      // number of valid elements
    u16 _capacity;   // slot count (each slot is sizeof(pointer))

    void init(void)
        {
        _slots = (pointer*)0;
        _count = (u16)0;
        _capacity = (u16)0;
        }

    // Pre-size the backing store. Useful when the caller knows the
    // approximate working count and wants to avoid the geometric-
    // resize copy.
    static Array* withCapacity(u16 cap)
        {
        Array* a = new Array();
        if (cap > (u16)0)
            {
            a._slots = new pointer[cap];
            a._capacity = cap;
            }
        return a;
        }

    // Internal: ensure room for at least one more element. Doubles
    // capacity (starts at 8) and copies existing slots over.
    void _grow(void)
        {
        u16 newCap = (_capacity == (u16)0)
                         ? (u16)8
                         : _capacity * (u16)2;
        pointer* fresh = new pointer[newCap];
        pointer* old = _slots;
        for (u16 i = (u16)0; i < _count; i++)
            {
            fresh[i] = old[i];
            }
        _slots = fresh;
        _capacity = newCap;
        // Reclaim the buffer we just copied out of. Only the slot bytes are
        // freed — the elements themselves are merely relocated, so their
        // refcounts do not move. Without this every growth leaked the old
        // buffer, on every backend.
        _array_slots_free(old);
        }

    // ── Accessors ────────────────────────────────────────────────
    u16 count(void)
        {
        return _count;
        }
    // alias
    u16 length(void)
        {
        return _count;
        }
    bool isEmpty(void)
        {
        return _count == (u16)0;
        }
    u16 capacity(void)
        {
        return _capacity;
        }

    Object* get(u16 i)
        {
        pointer* s = _slots;
        return (Object*)s[i];
        }

    Object* first(void)
        {
        if (_count == (u16)0)
            return (Object*)0;
        return get((u16)0);
        }

    Object* last(void)
        {
        if (_count == (u16)0)
            return (Object*)0;
        return get(_count - (u16)1);
        }

    // ── Mutation ────────────────────────────────────────────────
    // Internal pointer-write at slot i. All writers funnel through
    // here so the cell deposit lives in one place. Reads/writes
    // through a local copy of _slots to dodge a codegen path that
    // treats the encoded ivar address as an absolute literal.
    void _writeSlot(u16 i, pointer ptr)
        {
        pointer* s = _slots;
        s[i] = ptr;
        }

    pointer _readSlot(u16 i)
        {
        pointer* s = _slots;
        return s[i];
        }

    void set(u16 i, Object* obj)
        {
        if (i >= _count)
            return;
        // Retain the incoming element BEFORE releasing the outgoing one:
        // `a.set(i, a.get(i))` would otherwise free the object between the
        // two statements and store a dangling pointer.
        _array_arc_retain((pointer)obj);
        _array_arc_release(_readSlot(i));
        _writeSlot(i, (pointer)obj);
        }

    void add(Object* obj)
        {
        if (_count >= _capacity)
            _grow();
        _array_arc_retain((pointer)obj);
        _writeSlot(_count, (pointer)obj);
        _count = _count + (u16)1;
        }

    // Insert `obj` at `i`, shifting elements [i..count-1] one slot
    // up. `i == count` is the same as `add`.
    void insert(u16 i, Object* obj)
        {
        if (i > _count)
            return;
        if (_count >= _capacity)
            _grow();
        if (_count > i)
            {
            pointer* s = _slots;
            for (u16 j = _count; j > i; j = j - (u16)1)
                {
                s[j] = s[j - (u16)1];
                }
            }
        _array_arc_retain((pointer)obj);
        _writeSlot(i, (pointer)obj);
        _count = _count + (u16)1;
        }

    void removeAt(u16 i)
        {
        if (i >= _count)
            return;
        // Drop the slot's strong reference before the shift
        // overwrites it. The shift then closes the gap.
        _array_arc_release(_readSlot(i));
        pointer* s = _slots;
        for (u16 j = i; j + (u16)1 < _count; j = j + (u16)1)
            {
            s[j] = s[j + (u16)1];
            }
        _count = _count - (u16)1;
        }

    void removeFirst(void)
        {
        removeAt((u16)0);
        }

    void removeLast(void)
        {
        if (_count == (u16)0)
            return;
        _array_arc_release(_readSlot(_count - (u16)1));
        _count = _count - (u16)1;
        }

    void removeAll(void)
        {
        for (u16 i = (u16)0; i < _count; i = i + (u16)1)
            {
            _array_arc_release(_readSlot(i));
            }
        _count = (u16)0;
        }

    // ── Insert / remove / replace ────────────────────────────────
    // The NSMutableArray surface M1 found missing (insertObjects:,
    // removeObject:, replaceObjectsInRange:, removeObjectsInRange:, setArray:,
    // isEqualToArray:). All of it is insert/remove/replace over the existing
    // growable buffer, and all of it keeps the container's ownership rule: a
    // slot that goes away is released, a slot that arrives is retained.
    //
    // Ranges CLAMP rather than reject, as `subarray` already does.

    // `replaceObjectAtIndex:` — the same thing as `set`, under the name the
    // Foundation call sites use.
    void replaceAt(u16 i, Object* obj)
        {
        set(i, obj);
        }

    // Insert every element of `other` starting at `at`, order preserved.
    void insertAll(u16 at, Array* other)
        {
        if (other == 0 || other.count() == (u16)0)
            return;
        if (at > _count)
            at = _count;
        // Inserting an Array into ITSELF would read slots that the insertion is
        // busy shifting — take a snapshot first.
        Array* src = (other == self) ? Array.withArray(self) : other;
        u16 n = src.count();
        for (u16 i = (u16)0; i < n; i = i + (u16)1)
            insert(at + i, src.get(i));
        }

    // Remove the first element with this IDENTITY (removeObjectIdenticalTo:).
    // Returns whether one was found.
    bool remove(Object* obj)
        {
        u16 i = indexOf(obj);
        if (i == $FFFF)
            return false;
        removeAt(i);
        return true;
        }

    // Remove the first element EQUAL to this one (removeObject:), by value.
    bool removeEqual(Comparable* obj)
        {
        u16 i = indexOfEqual(obj);
        if (i == $FFFF)
            return false;
        removeAt(i);
        return true;
        }

    // Remove `len` elements at `at`. One pass of releases and ONE shift, rather
    // than `len` calls to removeAt each shifting the whole tail.
    void removeRange(u16 at, u16 len)
        {
        if (at >= _count)
            return;
        u16 avail = _count - at;
        if (len > avail)
            len = avail;
        if (len == (u16)0)
            return;

        for (u16 i = (u16)0; i < len; i = i + (u16)1)
            _array_arc_release(_readSlot(at + i));

        pointer* s = _slots;
        for (u16 j = at; j + len < _count; j = j + (u16)1)
            s[j] = s[j + len];
        _count = _count - len;
        }

    // Replace `len` elements at `at` with all of `other` — the two lengths need
    // not match.
    void replaceRange(u16 at, u16 len, Array* other)
        {
        // Snapshot BEFORE the removal: `other` may be this same Array, and the
        // removal would then delete what we are about to insert.
        Array* src = (other == 0) ? (Array*)0
                                  : ((other == self) ? Array.withArray(self) : other);
        if (at > _count)
            at = _count;
        removeRange(at, len);
        insertAll(at, src);
        }

    // Become `other` — setArray:.
    void setTo(Array* other)
        {
        if (other == self)
            return;
        removeAll();
        addAll(other);
        }

    // isEqualToArray: — same count, and elements equal PAIRWISE BY VALUE
    // (identity first, then the element's own Comparable equality).
    //
    // Under its own name, NOT as an `equals(Array*)` overload. Array does not
    // define `equals(Object*)` of its own — it inherits Object's identity
    // version — and an added typed overload loses to the inherited one at the
    // call site, silently answering "same pointer?" to a question about
    // contents. (String gets away with the overload because it defines BOTH.)
    // Leaving identity as Array's `equals` is also what keeps an Array usable
    // as a Map key or a Set member, where identity is the contract today.
    bool isEqualToArray(Array* other)
        {
        if (other == self)
            return true;
        if (other == 0)
            return false;
        if (other.count() != _count)
            return false;
        for (u16 i = (u16)0; i < _count; i = i + (u16)1)
            {
            if (!_array_elem_equals(get(i), other.get(i)))
                return false;
            }
        return true;
        }

    // arrayWithObject: / arrayWithObjects: for the small fixed counts that
    // cover the call sites. xtc has no nil-terminated vararg convention to
    // borrow, and a literal list of two or three is what those sites are.
    static Array* with(Object* a)
        {
        Array* out = Array.withCapacity((u16)1);
        out.add(a);
        return out;
        }

    static Array* with(Object* a, Object* b)
        {
        Array* out = Array.withCapacity((u16)2);
        out.add(a);
        out.add(b);
        return out;
        }

    static Array* with(Object* a, Object* b, Object* c)
        {
        Array* out = Array.withCapacity((u16)3);
        out.add(a);
        out.add(b);
        out.add(c);
        return out;
        }

    static Array* with(Object* a, Object* b, Object* c, Object* d)
        {
        Array* out = Array.withCapacity((u16)4);
        out.add(a);
        out.add(b);
        out.add(c);
        out.add(d);
        return out;
        }

    // arrayByAddingObject: — a copy with one more element; the receiver is
    // untouched.
    Array* adding(Object* obj)
        {
        Array* out = Array.withCapacity(_count + (u16)1);
        for (u16 i = (u16)0; i < _count; i = i + (u16)1)
            out.add(get(i));
        out.add(obj);
        return out;
        }

    // ── Destruction ──────────────────────────────────────────────
    // Drop every element's strong reference, then free the slots
    // buffer. Codegen invokes this from the scope-exit / `delete`
    // path after the Array's own refcount hits zero. `_slots` is
    // a `pointer*` (not a class pointer) so the auto-aggregate
    // walker doesn't free it for us — handle it here.
    void dealloc(void)
        {
        u16 i = (u16)0;
        while (i < _count)
            {
            _array_arc_release(_readSlot(i));
            i = i + (u16)1;
            }
        _array_slots_free(_slots);
        }

    // ── Enumerable protocol slots ─────────────────────────────────
    u16 enumLength(void)
        {
        return _count;
        }
    Object* enumAt(u16 i)
        {
        return get(i);
        }

    // ── Search ───────────────────────────────────────────────────
    // Pointer-equality only — does NOT dispatch a `.equals(..)` call
    // on the elements. Two distinct Number(42) instances return
    // false even though their values match. Use a typed walk if
    // value-equality is needed.
    u16 indexOf(Object* obj)
        {
        pointer needle = (pointer)obj;
        for (u16 i = (u16)0; i < _count; i++)
            {
            if (_readSlot(i) == needle)
                return i;
            }
        return $FFFF;
        }

    bool contains(Object* obj)
        {
        return indexOf(obj) != $FFFF;
        }

    // Value equality: dispatches `equals` on each element through the
    // Comparable protocol slot.
    u16 indexOfEqual(Comparable* obj)
        {
        if (obj == 0)
            return $FFFF;
        for (u16 i = (u16)0; i < _count; i++)
            {
            Object* e = get(i);
            if (e != 0 && obj.equals(e))
                return i;
            }
        return $FFFF;
        }

    bool containsEqual(Comparable* obj)
        {
        return indexOfEqual(obj) != $FFFF;
        }

    // Returned by indexOf / indexOfEqual when the element is not present.
    static u16 notFound(void)
        {
        return $FFFF;
        }

    // ── Sorting ──────────────────────────────────────────────────
    // In-place quicksort over the slot cells. Only the POINTERS move — no
    // element is retained or released, because sorting doesn't change who owns
    // what, just the order.
    //
    //     a.sortUsing(&byLastName);      // any comparator: free fn, or &obj.m
    //     a.sort();                      // the elements' own Comparable order
    //
    // sortUsing takes a `cmp2_t^` — a bound method or a plain function widened
    // into one — so a comparator can capture a receiver (`&self.byColumn`)
    // without a global.
    void sortUsing(callback cmp i8(Object* a, Object* b))
        {
        if (!cmp)
            return;
        if (_count < (u16)2)
            return;
        _qsort((u16)0, _count - (u16)1, cmp);
        }

    void _qsort(u16 lo, u16 hi, callback cmp i8(Object* a, Object* b))
        {
        if (lo >= hi)
            return;
        pointer* s = _slots;

        // Lomuto partition, pivot at hi.
        pointer pivot = s[hi];
        u16 i = lo;
        for (u16 j = lo; j < hi; j = j + (u16)1)
            {
            // Guarded not because cmp can be null here (_qsort is only
            // reached through sort, which sets it) but because the
            // unguarded-action warning is RIGHT as a rule — and a library
            // must not teach every hello-world to ignore warnings.
            i8 c = (i8)0;
            if (cmp)
                {
                c = cmp((Object*)s[j], (Object*)pivot);
                }
            if (c <= (i8)0)
                {
                pointer t = s[i];
                s[i] = s[j];
                s[j] = t;
                i = i + (u16)1;
                }
            }
        pointer t = s[i];
        s[i] = s[hi];
        s[hi] = t;

        if (i > lo)
            _qsort(lo, i - (u16)1, cmp);
        _qsort(i + (u16)1, hi, cmp);
        }

    // Sort by the elements' OWN order — Comparable's optional `compare` slot.
    //
    // Returns false, and leaves the array untouched, when the elements do not
    // implement `compare`. Ordering is optional precisely because not every
    // value has one, and inventing an arbitrary order for things that don't
    // define one would be a lie that only surfaces much later, in the output.
    // If you want those sorted, say what the order is: sortUsing(&yourCmp).
    bool sort(void)
        {
        if (_count < (u16)2)
            return true;

        // `&e.compare` on an element that doesn't implement the optional slot
        // is a NULL bound method — that IS respondsTo, no runtime query needed.
        Object* first = get((u16)0);
        if (first == 0)
            return false;
        Comparable* c0 = (Comparable*)first;
        callback probe i8(Object * other) = &c0.compare;
        if (!probe)
            return false;

        sortUsing(&_array_natural_cmp);
        return true;
        }

    // Sorted COPY — the receiver is left alone. The copy holds its own strong
    // reference to every element, as any Array does.
    Array* sortedUsing(callback cmp i8(Object* a, Object* b))
        {
        Array* out = Array.withCapacity(_count);
        for (u16 i = (u16)0; i < _count; i = i + (u16)1)
            out.add(get(i));
        out.sortUsing(cmp);
        return out;
        }

    Array* sorted(void)
        {
        Array* out = Array.withCapacity(_count);
        for (u16 i = (u16)0; i < _count; i = i + (u16)1)
            out.add(get(i));
        out.sort();
        return out;
        }

    // Is the array in non-descending order under `cmp`? Cheap check, useful in
    // tests and as a guard before a merge.
    bool isSortedUsing(callback cmp i8(Object* a, Object* b))
        {
        if (!cmp)
            return false;
        for (u16 i = (u16)1; i < _count; i = i + (u16)1)
            {
            if (cmp(get(i - (u16)1), get(i)) > (i8)0)
                return false;
            }
        return true;
        }

    // ── Functional ───────────────────────────────────────────────
    // Each takes a `^`, so the predicate can be a plain function OR a bound
    // method that carries its receiver — which is the whole point:
    //
    //     class Filter { String* needle;  bool matches(Object* o) { … } }
    //     Array* hits = rows.filtered(&filter.matches);
    //
    // The filter's state lives on the filter, not in a global, and the same
    // Array can be filtered two different ways at once.

    // Elements the predicate keeps, in order. A new Array; the receiver is
    // untouched, and the survivors are retained by the result as normal.
    Array* filtered(callback keep bool(Object* o))
        {
        Array* out = new Array();
        if (!keep)
            return out;
        for (u16 i = (u16)0; i < _count; i = i + (u16)1)
            {
            Object* e = get(i);
            if (keep(e))
                out.add(e);
            }
        return out;
        }

    // Each element through `f`. A null result is skipped rather than stored, so
    // `mapped` doubles as a filtering transform.
    Array* mapped(callback f Object*(Object* o))
        {
        Array* out = Array.withCapacity(_count);
        if (!f)
            return out;
        for (u16 i = (u16)0; i < _count; i = i + (u16)1)
            {
            Object* r = f(get(i));
            if (r != 0)
                out.add(r);
            }
        return out;
        }

    void forEach(callback fn void(Object* o))
        {
        if (!fn)
            return;
        for (u16 i = (u16)0; i < _count; i = i + (u16)1)
            fn(get(i));
        }

    // First element satisfying the predicate, or null. Stops at the first hit.
    Object* firstWhere(callback p bool(Object* o))
        {
        if (!p)
            return (Object*)0;
        for (u16 i = (u16)0; i < _count; i = i + (u16)1)
            {
            Object* e = get(i);
            if (p(e))
                return e;
            }
        return (Object*)0;
        }

    u16 indexWhere(callback p bool(Object* o))
        {
        if (!p)
            return $FFFF;
        for (u16 i = (u16)0; i < _count; i = i + (u16)1)
            {
            if (p(get(i)))
                return i;
            }
        return $FFFF;
        }

    u16 countWhere(callback p bool(Object* o))
        {
        u16 n = (u16)0;
        if (!p)
            return n;
        for (u16 i = (u16)0; i < _count; i = i + (u16)1)
            {
            if (p(get(i)))
                n = n + (u16)1;
            }
        return n;
        }

    bool anySatisfy(callback p bool(Object* o))
        {
        return indexWhere(p) != $FFFF;
        }

    bool allSatisfy(callback p bool(Object* o))
        {
        if (!p)
            return false;
        for (u16 i = (u16)0; i < _count; i = i + (u16)1)
            {
            if (!p(get(i)))
                return false;
            }
        return true;
        }

    // ── Bulk / structural ────────────────────────────────────────
    static Array* withArray(Array* other)
        {
        Array* out = new Array();
        out.addAll(other);
        return out;
        }

    void addAll(Array* other)
        {
        if (other == 0)
            return;
        for (u16 i = (u16)0; i < other.count(); i = i + (u16)1)
            add(other.get(i));
        }

    // A slice as a new Array. Out of range clamps to empty, as String does.
    Array* subarray(u16 from, u16 len)
        {
        Array* out = new Array();
        if (from >= _count)
            return out;
        u16 avail = _count - from;
        u16 n = (len < avail) ? len : avail;
        for (u16 i = (u16)0; i < n; i = i + (u16)1)
            out.add(get(from + i));
        return out;
        }

    void swapAt(u16 i, u16 j)
        {
        if (i >= _count || j >= _count || i == j)
            return;
        pointer* s = _slots;
        pointer t = s[i];
        s[i] = s[j];
        s[j] = t;
        }

    // Reverse in place — only the slot cells move, so no refcount changes.
    void reverse(void)
        {
        if (_count < (u16)2)
            return;
        u16 lo = (u16)0;
        u16 hi = _count - (u16)1;
        while (lo < hi)
            {
            swapAt(lo, hi);
            lo = lo + (u16)1;
            hi = hi - (u16)1;
            }
        }

    Array* reversed(void)
        {
        Array* out = Array.withCapacity(_count);
        u16 i = _count;
        while (i > (u16)0)
            {
            i = i - (u16)1;
            out.add(get(i));
            }
        return out;
        }
    }
