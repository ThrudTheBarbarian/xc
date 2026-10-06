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
// BinaryHeap.xc — a priority queue (CFBinaryHeap in shape).
//
// A binary min-heap: the member with the smallest priority is always first,
// and insert / removeMinimum are O(log n). Each member carries an integer
// priority (lower comes out first) rather than a comparator, so the caller
// orders by any key it likes: a deadline, a distance, a negated score for a
// max-heap.
//
//     BinaryHeap* q = new BinaryHeap();
//     q.insert(taskA, (i32)5);
//     q.insert(taskB, (i32)2);
//     q.removeMinimum();   // taskB
//
// Storage is two parallel arrays — the members and their priorities — in heap
// order (parent (i-1)/2, children 2i+1 and 2i+2), grown by doubling, so an
// insert allocates nothing until the arrays are full. Members of equal priority
// come out in no promised order. The heap holds a strong reference to each
// member while it is in the heap.
//
// Heap-capable targets only.

void _bheap_release(pointer p)
    {
    __arc_release(p);
    }

void _bheap_retain(pointer p)
    {
    __arc_retain(p);
    }

class BinaryHeap
    {
    pointer* _objs; // members in heap order
    i32* _pris;     // the priority beside each
    u32 _count;
    u32 _capacity;

    void init(void)
        {
        _objs = (pointer*)0;
        _pris = (i32*)0;
        _count = (u32)0;
        _capacity = (u32)0;
        }

    // Buffer access through a local copy of the pointer (banked-heap targets,
    // see Set.xc).
    pointer _obj(u32 i)
        {
        pointer* b = _objs;
        return b[i];
        }
    i32 _pri(u32 i)
        {
        i32* b = _pris;
        return b[i];
        }
    void _put(u32 i, pointer o, i32 p)
        {
        pointer* b = _objs;
        i32* q = _pris;
        b[i] = o;
        q[i] = p;
        }
    void _swap(u32 i, u32 j)
        {
        pointer o = _obj(i);
        i32 p = _pri(i);
        _put(i, _obj(j), _pri(j));
        _put(j, o, p);
        }

    void _grow(void)
        {
        u32 cap = _capacity == (u32)0 ? (u32)16 : _capacity * (u32)2;
        pointer* nb = new pointer[cap];
        i32* np = new i32[cap];
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            {
            nb[i] = _obj(i);
            np[i] = _pri(i);
            }
        _bheap_release((pointer)_objs);
        _bheap_release((pointer)_pris);
        _objs = nb;
        _pris = np;
        _capacity = cap;
        }

    void _siftUp(u32 i)
        {
        while (i > (u32)0)
            {
            u32 parent = (i - (u32)1) / (u32)2;
            if (_pri(parent) <= _pri(i))
                break;
            _swap(i, parent);
            i = parent;
            }
        }

    void _siftDown(u32 i)
        {
        while (true)
            {
            u32 l = (u32)2 * i + (u32)1;
            u32 r = l + (u32)1;
            u32 smallest = i;
            if (l < _count && _pri(l) < _pri(smallest))
                smallest = l;
            if (r < _count && _pri(r) < _pri(smallest))
                smallest = r;
            if (smallest == i)
                break;
            _swap(i, smallest);
            i = smallest;
            }
        }

    // ── API ──────────────────────────────────────────────────────

    // The number of members.
    i32 count(void)
        {
        return (i32)_count;
        }

    bool isEmpty(void)
        {
        return _count == (u32)0;
        }

    // Adds `o` with priority `pri` (lower comes out first). Null is ignored.
    void insert(Object* o, i32 pri)
        {
        if (o == (Object*)0)
            return;
        if (_count == _capacity)
            _grow();
        _bheap_retain((pointer)o);
        _put(_count, (pointer)o, pri);
        _count = _count + (u32)1;
        _siftUp(_count - (u32)1);
        }

    // The member that would come out next (null when empty); it stays in the heap.
    Object* minimum(void)
        {
        return _count == (u32)0 ? (Object*)0 : (Object*)_obj((u32)0);
        }

    // Its priority (0 when empty).
    i32 minimumPriority(void)
        {
        return _count == (u32)0 ? (i32)0 : _pri((u32)0);
        }

    // Takes out and returns the member with the smallest priority (null when empty).
    Object* removeMinimum(void)
        {
        if (_count == (u32)0)
            return (Object*)0;
        // The caller's reference is taken before the heap's is dropped, so the
        // member cannot be freed in between.
        Object* min = (Object*)_obj((u32)0);
        pointer held = _obj((u32)0);
        u32 last = _count - (u32)1;
        if (last > (u32)0)
            _put((u32)0, _obj(last), _pri(last));
        _put(last, (pointer)0, (i32)0);
        _count = last;
        if (_count > (u32)0)
            _siftDown((u32)0);
        _bheap_release(held);
        return min;
        }

    // Empties the heap, releasing every member.
    void removeAll(void)
        {
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            {
            _bheap_release(_obj(i));
            _put(i, (pointer)0, (i32)0);
            }
        _count = (u32)0;
        }

    void dealloc(void)
        {
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            _bheap_release(_obj(i));
        _bheap_release((pointer)_objs);
        _bheap_release((pointer)_pris);
        }
    }
