// UXBinaryHeap.xc — a priority queue (CFBinaryHeap in shape), neutral across backends.
//
// A binary min-heap over an Array: the smallest priority is always at index 0, insert and
// removeMinimum are O(log n) via sift-up / sift-down, and the array's parent/child arithmetic
// (parent = (i-1)/2, children = 2i+1, 2i+2) keeps it a complete tree with no pointers.
//
// Items carry an explicit integer priority (lower = comes out first) rather than a comparator
// callback — simpler, and the caller can compute any ordering key it likes (a deadline, a distance,
// a -score for a max-heap).
//
//     UXBinaryHeap* q = new UXBinaryHeap();
//     q.insert(taskA, (i32)5); q.insert(taskB, (i32)2);
//     q.removeMinimum();   // taskB (priority 2)
#import "Array.xc"

class UXHeapEntry : Object
    {
    Object* obj;
    i32 pri;
    void init(void)
        {
        obj = (Object*)0;
        pri = (i32)0;
        }
    }

    class UXBinaryHeap
    {
    Array<UXHeapEntry>* items; // complete binary tree, min-heap ordered by pri; items[0] = minimum
    void init(void)
        {
        items = new Array();
        }

    UXHeapEntry* at(i32 i)
        { return (UXHeapEntry* ?)items.get((u16)i);
        }
    void swap(i32 i, i32 j)
        {
        UXHeapEntry* a = self.at(i);
        UXHeapEntry* b = self.at(j);
        items.set((u16)i, b);
        items.set((u16)j, a);
        }

    i32 count(void)
        {
        return (i32)items.count();
        }
    bool isEmpty(void)
        {
        return items.count() == (u16)0;
        }

    void insert(Object* o, i32 pri)
        {
        UXHeapEntry* e = new UXHeapEntry();
        e.obj = o;
        e.pri = pri;
        items.add(e);
        self.siftUp((i32)items.count() - (i32)1);
        }
    void siftUp(i32 i)
        {
        while (i > (i32)0)
            {
            i32 parent = (i - (i32)1) / (i32)2;
            if (self.at(parent).pri <= self.at(i).pri)
                {
                break;
                }
            self.swap(i, parent);
            i = parent;
            }
        }

    Object* minimum(void)
        {
        return items.count() == (u16)0 ? (Object*)0 : self.at((i32)0).obj;
        }
    i32 minimumPriority(void)
        {
        return items.count() == (u16)0 ? (i32)0 : self.at((i32)0).pri;
        }

    Object* removeMinimum(void)
        {
        i32 n = (i32)items.count();
        if (n == (i32)0)
            {
            return (Object*)0;
            }
        Object* min = self.at((i32)0).obj;
        i32 last = n - (i32)1;
        // move the last leaf to the root
        if (last > (i32)0)
            {
            self.swap((i32)0, last);
            }
        items.removeLast();
        if (items.count() > (u16)0)
            {
            self.siftDown((i32)0);
            }
        return min;
        }
    void siftDown(i32 i)
        {
        i32 n = (i32)items.count();
        while (true)
            {
            i32 l = (i32)2 * i + (i32)1;
            i32 r = l + (i32)1;
            i32 smallest = i;
            if (l < n && self.at(l).pri < self.at(smallest).pri)
                {
                smallest = l;
                }
            if (r < n && self.at(r).pri < self.at(smallest).pri)
                {
                smallest = r;
                }
            if (smallest == i)
                {
                break;
                }
            self.swap(i, smallest);
            i = smallest;
            }
        }
    void removeAll(void)
        {
        items.removeAll();
        }
    }
