// UXViewTree.xc — the OBJECT[] array the AES actually walks, and the parallel
// array of UXViews that gives each object its behaviour.
//
// This is the heart of the design.  The hierarchy is NOT a private xtc structure
// that we later hand to GEM — it IS a real AES OBJECT tree.  So objc_draw walks
// it, objc_find hit-tests it, objc_offset positions it, and the theme draws every
// standard widget in it, all for free.
//
// The AES speaks in indices; we speak in objects.  views[i] backs tree[i], both
// ways, O(1) — no map, no lookup, no reflection.
//
//     ob_next / ob_head / ob_tail are i16 indices RELATIVE to the tree root, so
//     addSubview / removeFromSuperview are pure relinking of a flat array.  That
//     is exactly what the classic AES objc_add / objc_delete / objc_order do.

#import "Array.xc"
#import "UXGem.xc"
#import "UXGeometry.xc"
#import "UXLibc.xc"
#import "UXViewDriver.xc"

class UXViewTree
    {
    // The realization tree is the DRIVER's (§6); we hold only an opaque handle and never
    // allocate or relink it ourselves.  views[i] backs object i — the reverse map plus the
    // strong refs that keep the views alive, O(1) both ways.
    pointer structHandle;
    Array* views;

    // The union of every rect marked dirty since the last repaint, in ABSOLUTE
    // coordinates.  It lives HERE, not on UXWindow, so a view can mark itself dirty
    // without knowing what a window is — UXView already holds its tree, and an
    // UXView -> UXWindow import would be a cycle.
    UXRect dirty;
    bool hasDirty;

    void init(void)
        {
        dirty = UXGeom.zero();
        hasDirty = false;
        structHandle = gDriver.structNew();
        views = new Array();
        }

    void dealloc(void)
        {
        gDriver.structFree(structHandle);
        }

    // Adopt a structure somebody else owns — a tree straight out of a .rsc.  The raw handle
    // is opaque here; only the backend (and the GEM-specific nib loader) knows its shape.
    void adopt(pointer t, u16 n)
        {
        gDriver.structAdopt(structHandle, t, (i32)n);
        views = new Array();
        }

    // Bind a view to an object that already exists (the adopt path).
    void bind(u16 i, Object* view)
        {
        views.add(view);
        }

    // The raw backend structure, opaque — for the draw seam and hit-test, which hand it
    // straight back to the driver.  The neutral layer never dereferences it.
    pointer objects(void)
        {
        return gDriver.structObjects(structHandle);
        }
    u16 length(void)
        {
        return (u16)gDriver.structLength(structHandle);
        }

    // ---- damage -------------------------------------------------------------
    void markDirty(UXRect abs)
        {
        if (UXGeom.isEmpty(abs))
            {
            return;
            }
        dirty = hasDirty ? UXGeom.unite(dirty, abs) : abs;
        hasDirty = true;
        }
    bool isDirty(void)
        {
        return hasDirty;
        }
    UXRect takeDirty(void)
        {
        UXRect d = dirty;
        dirty = UXGeom.zero();
        hasDirty = false;
        return d;
        }

    // Append a view of the given neutral kind; the driver owns the slot.  Returns the index.
    u16 append(i32 kind, UXRect f, Object* view)
        {
        i32 i = gDriver.structAppend(structHandle, kind,
                                     (i32)f.x, (i32)f.y, (i32)f.w, (i32)f.h);
        views.add(view);
        return (u16)i;
        }

    Object* viewAt(u16 i)
        {
        if (i >= self.length())
            {
            return (Object*)0;
            }
        return views.get(i);
        }

    // ---- structure (the driver's; §6) ---------------------------------------
    void addChild(u16 parent, u16 child)
        {
        gDriver.structAddChild(structHandle, (i32)parent, (i32)child);
        }
    void removeChild(u16 parent, u16 child)
        {
        gDriver.structRemoveChild(structHandle, (i32)parent, (i32)child);
        }
    void finalise(void)
        {
        gDriver.structFinalise(structHandle);
        }

    // ---- per-object geometry + state (delegated to the driver) --------------
    UXRect frameOf(u16 i)
        {
        i32 x = (i32)0;
        i32 y = (i32)0;
        i32 w = (i32)0;
        i32 h = (i32)0;
        gDriver.structFrame(structHandle, (i32)i, &x, &y, &w, &h);
        return UXGeom.make((i16)x, (i16)y, (i16)w, (i16)h);
        }
    void setFrameOf(u16 i, UXRect f)
        {
        gDriver.structSetFrame(structHandle, (i32)i, (i32)f.x, (i32)f.y, (i32)f.w, (i32)f.h);
        }
    bool hiddenOf(u16 i)
        {
        return gDriver.structIsHidden(structHandle, (i32)i) != (i32)0;
        }
    void setHiddenOf(u16 i, bool on)
        {
        gDriver.structSetHidden(structHandle, (i32)i, on ? (i32)1 : (i32)0);
        }
    bool enabledOf(u16 i)
        {
        return gDriver.structIsEnabled(structHandle, (i32)i) != (i32)0;
        }
    void setEnabledOf(u16 i, bool on)
        {
        gDriver.structSetEnabled(structHandle, (i32)i, on ? (i32)1 : (i32)0);
        }
    bool selectedOf(u16 i)
        {
        return gDriver.structIsSelected(structHandle, (i32)i) != (i32)0;
        }
    void setSelectedOf(u16 i, bool on)
        {
        gDriver.structSetSelected(structHandle, (i32)i, on ? (i32)1 : (i32)0);
        }
    void setClipsOf(u16 i, bool on)
        {
        gDriver.structSetClips(structHandle, (i32)i, on ? (i32)1 : (i32)0);
        }

    // ---- control realization (delegated to the driver) ----------------------
    void setSpecOf(u16 i, pointer spec)
        {
        gDriver.structSetSpec(structHandle, (i32)i, spec);
        }
    void setPeerOf(u16 i, pointer peer)
        {
        gDriver.structSetPeer(structHandle, (i32)i, peer);
        }
    void setAutoresizeOf(u16 i, i32 mask)
        {
        gDriver.structSetAutoresize(structHandle, (i32)i, mask);
        }
    void setSelectableOf(u16 i, bool on)
        {
        gDriver.structSetSelectable(structHandle, (i32)i, on ? (i32)1 : (i32)0);
        }
    void setEditableOf(u16 i, bool on)
        {
        gDriver.structSetEditable(structHandle, (i32)i, on ? (i32)1 : (i32)0);
        }

    // GEM's edit engine operates the field in place; index the object, carry the caret.
    i32 editText(u16 i, i32 key, i32* caret, i32 mode)
        {
        return gDriver.editText(gDriver.structObjects(structHandle), (i32)i, key, caret, mode);
        }

    // Absolute frame of an object — the driver walks the parent links and reports the rect.
    UXRect absoluteFrame(u16 i)
        {
        i32 ax = (i32)0;
        i32 ay = (i32)0;
        i32 aw = (i32)0;
        i32 ah = (i32)0;
        gDriver.structAbsFrame(structHandle, (i32)i, &ax, &ay, &aw, &ah);
        return UXGeom.make((i16)ax, (i16)ay, (i16)aw, (i16)ah);
        }

    // Hit-test.  Deepest object containing the point, or -1 — a driver structural query.
    i32 hitTest(i16 px, i16 py)
        {
        return gDriver.treeHitTest(self.objects(), (i32)0, (i32)px, (i32)py);
        }
    }
