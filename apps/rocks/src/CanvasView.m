// CanvasView.m — see CanvasView.h.

#import "CanvasView.h"
#import "GRender.h"
#import "GForm.h"
#import "GExport.h"

NSPasteboardType const GPaletteDragType = @"org.compile-xc.rocks.palette";

static const CGFloat kMargin = 40; // view-space padding around the dialog
static const CGFloat kHandle = 7;  // resize handle size (view space)
static const CGFloat kSnap = 5;    // snap threshold (model px)

typedef NS_ENUM(int, DragMode) { DM_NONE,
                                 DM_MOVE,
                                 DM_RESIZE,
                                 DM_MARQUEE };
typedef NS_ENUM(int, GHandle) {
    H_NONE,
    H_TL,
    H_T,
    H_TR,
    H_R,
    H_BR,
    H_B,
    H_BL,
    H_L
};

@implementation CanvasView
    {
    DragMode _mode;
    GHandle _handle;
    NSPoint _downModel;    // mouse-down point (model)
    NSData* _dragSnapshot; // resource state at drag start (for one undo)
    // per-object start geometry, keyed by object
    NSMapTable<GObject*, NSValue*>* _startFrames;
    NSRect _marquee;                // view space
    NSArray<NSValue*>* _guideLines; // horizontal/vertical guide segments (view space)
    BOOL _didDrag;
    int _activeMenu; // which menu title's dropdown is shown
    // test-drive state
    GObject* _focus;    // the editable field with the caret
    int _caret;         // caret position within _focus's value
    GObject* _pressing; // object currently held down
    GObject* _lastExit; // what the form last exited through
    // in-place text editing (double-click)
    NSTextField* _editor;  // the field overlaying the object being edited
    GObject* _editing;     // which object it belongs to
    NSData* _editSnapshot; // resource before the edit, for one undo step
    NSCursor* _ibeam;
    GObject* _openPopup;  // the G_POPUP whose list is showing
    GTree* _popupTree;    // its linked tree (ob_type high byte = tree index)
    NSPoint _popupOffset; // model-space offset that tree is drawn at
    }

- (instancetype)initWithFrame:(NSRect)f
    {
    if ((self = [super initWithFrame:f]))
        {
        _scale = 2.0;
        _showGrid = YES;
        _snapEnabled = YES;
        _showGuides = YES;
        _gridSize = 8;
        _mode = DM_NONE;
        _startFrames = [NSMapTable strongToStrongObjectsMapTable];
        [self registerForDraggedTypes:@[ GPaletteDragType ]];
        }
    return self;
    }

- (GObject*)activeMenuTitle
    {
    NSArray* titles = self.tree.menuTitles;
    return (_activeMenu >= 0 && _activeMenu < (int)titles.count) ? titles[_activeMenu] : nil;
    }
- (GObject*)activeMenuDropdown
    {
    return [self.tree dropdownUnderTitle:[self activeMenuTitle]];
    }
- (void)setActiveMenuTitle:(GObject*)t
    {
    NSUInteger i = [self.tree.menuTitles indexOfObject:t];
    if (i != NSNotFound)
        {
        _activeMenu = (int)i;
        self.needsDisplay = YES;
        }
    }

- (BOOL)isFlipped
    {
    return YES;
    }
- (BOOL)acceptsFirstResponder
    {
    return YES;
    }
- (BOOL)acceptsFirstMouse:(NSEvent*)e
    {
    return YES;
    }

- (GTree*)tree
    {
    return self.doc.tree;
    }

// MARK: test drive
//
// In test mode the canvas stops being an editor: no selection, no handles, no
// guides, no marquee, no palette drops.  Clicks and keys go to GForm instead,
// which applies the AES rules to the objects in place.

- (void)setTestMode:(BOOL)on
    {
    if (_testMode == on)
        return;
    [self endEditingCommit:YES];
    _testMode = on;
    [self.window invalidateCursorRectsForView:self];
    [self resetTestDrive];
    if (on)
        {
        [self.doc clearSelection];
        // Start on the first editable field, as form_do does.
        [self focusOn:[GForm editableObjectsIn:self.tree].firstObject];
        }
    self.needsDisplay = YES;
    }

- (void)resetTestDrive
    {
    _pressing = nil;
    _lastExit = nil;
    _openPopup = nil;
    _popupTree = nil;
    [self focusOn:nil];
    self.needsDisplay = YES;
    }

// A G_POPUP's choices live in a separate tree; the ob_type high byte says which
// (RSC-FORMAT §5).  Opening one drops that tree in place, just below the popup.
- (void)openPopupFor:(GObject*)o
    {
    int idx = o.extType;
    NSArray<GTree*>* trees = self.doc.resource.trees;
    // 0 = not linked
    if (idx <= 0 || idx >= (int)trees.count)
        {
        NSBeep();
        return;
        }
    _openPopup = o;
    _popupTree = trees[idx];
    NSPoint at = [self.tree absoluteOriginOf:o];
    // drop it directly under the popup, and undo the linked root's own origin
    _popupOffset = NSMakePoint(at.x - _popupTree.root.x, at.y + o.h - _popupTree.root.y);
    self.needsDisplay = YES;
    }

- (void)closePopup
    {
    _openPopup = nil;
    _popupTree = nil;
    self.needsDisplay = YES;
    }

// A click while a popup list is open: choose an item, or dismiss.
- (BOOL)handlePopupClickAt:(NSPoint)m
    {
    if (!_openPopup)
        return NO;
    NSPoint local = NSMakePoint(m.x - _popupOffset.x, m.y - _popupOffset.y);
    GObject* hit = [_popupTree hitTest:local];
    if (hit && hit != _popupTree.root && ![GForm isDisabled:hit])
        {
        NSString* choice = hit.text ?: hit.ted.text;
        if (choice.length)
            _openPopup.text = choice; // the chosen value comes back
        }
    [self closePopup]; // any click closes it, inside or out
    return YES;
    }

- (void)focusOn:(GObject*)o
    {
    _focus = o;
    _caret = o ? (int)(o.ted.text.length) : 0; // caret lands after the existing text
    [GRender setEditCaretObject:o slot:_caret];
    }

- (void)setCaret:(int)c
    {
    _caret = MAX(0, c);
    [GRender setEditCaretObject:_focus slot:_caret];
    }

// Move the edit focus by `delta` places through the tab order, wrapping.
- (void)cycleFocusBy:(int)delta
    {
    NSArray<GObject*>* fields = [GForm editableObjectsIn:self.tree];
    if (!fields.count)
        return;
    NSUInteger i = _focus ? [fields indexOfObject:_focus] : NSNotFound;
    NSInteger next = (i == NSNotFound) ? 0 : ((NSInteger)i + delta);
    next = (next % (NSInteger)fields.count + (NSInteger)fields.count) % (NSInteger)fields.count;
    [self focusOn:fields[next]];
    self.needsDisplay = YES;
    }

// The form leaving through `o` — report it, but keep the dialog live so the user
// can carry on poking at it.
- (void)exitThrough:(GObject*)o
    {
    if (!o)
        return;
    _lastExit = o;
    self.needsDisplay = YES;
    }

// MARK: in-place text editing
//
// Double-click an object that shows text and edit it right there, rather than
// going out to the inspector.  The text lives in different places depending on
// the type — a string spec, a TEDINFO's text or its template, an icon label — so
// the accessors below are the single place that knows which.

static BOOL objectHasCanvasText(GObject* o)
    {
    return [o hasStringSpec] || [o hasTedinfo] || o.type == GT_ICON ||
           o.type == GT_CICON || o.type == GT_CICONBLK || o.type == GT_BOXCHAR;
    }

static NSString* objectCanvasText(GObject* o)
    {
    if ([o hasStringSpec])
        return o.text ?: @"";
    if ([o hasTedinfo])
        {
        // A static label keeps its text in the template; a field keeps a value.
        BOOL isField = (o.flags & OF_EDITABLE) != 0;
        return (isField ? o.ted.text : o.ted.tmplt) ?: @"";
        }
    if (o.icon)
        return o.icon.label ?: @"";
    if (o.type == GT_BOXCHAR)
        return o.box.character ? [NSString stringWithFormat:@"%c", o.box.character] : @"";
    return @"";
    }

static void setObjectCanvasText(GObject* o, NSString* t)
    {
    if ([o hasStringSpec])
        {
        o.text = t;
        return;
        }
    if ([o hasTedinfo])
        {
        if (o.flags & OF_EDITABLE)
            o.ted.text = t;
        else
            o.ted.tmplt = t;
        return;
        }
    if (o.icon)
        {
        o.icon.label = t;
        return;
        }
    if (o.type == GT_BOXCHAR)
        o.box.character = t.length ? (uint8_t)[t characterAtIndex:0] : 0;
    }

- (void)beginEditing:(GObject*)o
    {
    if (!o || !objectHasCanvasText(o))
        {
        NSBeep();
        return;
        }
    [self endEditingCommit:YES];

    NSPoint ao = [self.tree absoluteOriginOf:o];
    if (isnan(ao.x))
        return;
    NSRect vr = [self viewRectFromModel:NSMakeRect(ao.x, ao.y, o.w, o.h)];
    vr = NSInsetRect(vr, 0, MAX(0, (vr.size.height - 22) / 2)); // keep it legible at any zoom
    vr.size.height = MAX(22, MIN(vr.size.height, 28));

    _editSnapshot = [self.doc snapshot];
    _editing = o;
    _editor = [[NSTextField alloc] initWithFrame:vr];
    _editor.stringValue = objectCanvasText(o);
    _editor.font = [NSFont systemFontOfSize:MAX(11, MIN(18, 11 * _scale / 2))];
    _editor.alignment = NSTextAlignmentCenter;
    _editor.drawsBackground = YES;
    _editor.backgroundColor = [NSColor whiteColor];
    _editor.bezeled = YES;
    _editor.delegate = (id<NSTextFieldDelegate>)self;
    _editor.target = self;
    _editor.action = @selector(editorCommitted:);
    [self addSubview:_editor];
    [self.window makeFirstResponder:_editor];
    [_editor selectText:nil];
    }

- (void)editorCommitted:(id)sender
    {
    [self endEditingCommit:YES];
    }

- (void)endEditingCommit:(BOOL)commit
    {
    if (!_editor)
        return;
    NSTextField* ed = _editor;
    GObject* o = _editing;
    NSData* before = _editSnapshot;
    _editor = nil;
    _editing = nil;
    _editSnapshot = nil;

    NSString* newText = ed.stringValue;
    [ed removeFromSuperview];
    [self.window makeFirstResponder:self];

    if (commit && o && ![objectCanvasText(o) isEqualToString:newText])
        {
        setObjectCanvasText(o, newText);
        if (before)
            [self.doc commit:@"Edit Text" from:before];
        else
            [self.doc notifyModel];
        }
    self.needsDisplay = YES;
    }

// Esc abandons the edit; Tab commits and moves on to the next text object.
- (BOOL)control:(NSControl*)ctl textView:(NSTextView*)tv doCommandBySelector:(SEL)cmd
    {
    if (ctl != _editor)
        return NO;
    if (cmd == @selector(cancelOperation:))
        {
        [self endEditingCommit:NO];
        return YES;
        }
    if (cmd == @selector(insertTab:) || cmd == @selector(insertBacktab:))
        {
        BOOL back = (cmd == @selector(insertBacktab:));
        GObject* from = _editing;
        [self endEditingCommit:YES];
        NSMutableArray<GObject*>* texts = [NSMutableArray array];
        [self.tree.root preorder:^(GObject* x) {
          if (x != self.tree.root && objectHasCanvasText(x))
              [texts addObject:x];
        }];
        if (!texts.count)
            return YES;
        NSUInteger i = from ? [texts indexOfObject:from] : NSNotFound;
        NSInteger n = (i == NSNotFound) ? 0 : (NSInteger)i + (back ? -1 : 1);
        n = (n % (NSInteger)texts.count + (NSInteger)texts.count) % (NSInteger)texts.count;
        [self.doc select:texts[n] extend:NO];
        [self beginEditing:texts[n]];
        return YES;
        }
    return NO;
    }

// MARK: cursor
//
// An I-beam over anything whose text can be edited, so it is discoverable that a
// double-click will do something.
- (void)resetCursorRects
    {
    [super resetCursorRects];
    if (_testMode)
        return;
    if (!_ibeam)
        _ibeam = [NSCursor IBeamCursor];
    GTree* tree = self.tree;
    [tree.root preorder:^(GObject* o) {
      if (o == tree.root || !objectHasCanvasText(o))
          return;
      NSPoint ao = [tree absoluteOriginOf:o];
      if (isnan(ao.x))
          return;
      [self addCursorRect:[self viewRectFromModel:NSMakeRect(ao.x, ao.y, o.w, o.h)]
                   cursor:self->_ibeam];
    }];
    }

// MARK: coordinate mapping

- (NSPoint)viewFromModel:(NSPoint)m
    {
    return NSMakePoint(kMargin + m.x * _scale, kMargin + m.y * _scale);
    }
- (NSPoint)modelFromView:(NSPoint)v
    {
    return NSMakePoint((v.x - kMargin) / _scale, (v.y - kMargin) / _scale);
    }
- (NSRect)viewRectFromModel:(NSRect)r
    {
    return NSMakeRect(kMargin + r.origin.x * _scale, kMargin + r.origin.y * _scale,
                      r.size.width * _scale, r.size.height * _scale);
    }

- (void)sizeToFitModel
    {
    GObject* root = self.tree.root;
    NSSize s = NSMakeSize(kMargin * 2 + root.w * _scale, kMargin * 2 + root.h * _scale);
    NSSize vis = self.enclosingScrollView.contentView.bounds.size;
    s.width = MAX(s.width, vis.width);
    s.height = MAX(s.height, vis.height);
    [self setFrameSize:s];
    }
- (void)refresh
    {
    int nt = (int)self.tree.menuTitles.count;
    if (_activeMenu >= nt)
        _activeMenu = 0;
    [self endEditingCommit:YES];
    [self sizeToFitModel];
    [self.window invalidateCursorRectsForView:self]; // the I-beam zones moved
    self.needsDisplay = YES;
    }

// MARK: drawing

- (void)drawRect:(NSRect)dirty
    {
    [[NSColor colorWithWhite:0.28 alpha:1] set];
    NSRectFill(self.bounds);

    GTree* tree = self.tree;
    GObject* root = tree.root;
    NSRect page = [self viewRectFromModel:NSMakeRect(0, 0, root.w, root.h)];
    // page shadow + surface
    [[NSColor colorWithWhite:0 alpha:0.35] set];
    NSRectFill(NSOffsetRect(page, 3, 3));
    [[NSColor colorWithWhite:0.93 alpha:1] set];
    NSRectFill(page);

    if (_showGrid)
        [self drawGridIn:page];

    // draw the object tree, scaled — nearest-neighbour keeps the pixel-art theme
    // crisp at the (integer) edit zoom instead of blurring it.
    NSGraphicsContext* gc = [NSGraphicsContext currentContext];
    [gc saveGraphicsState];
    gc.imageInterpolation = NSImageInterpolationNone;
    NSAffineTransform* tf = [NSAffineTransform transform];
    [tf translateXBy:kMargin yBy:kMargin];
    [tf scaleBy:_scale];
    [tf concat];
    if (tree.isMenu)
        [GRender drawMenuTree:tree activeIndex:_activeMenu];
    else
        [GRender drawTree:tree];

    // an open popup list sits above the dialog, at the popup's own position
    if (_testMode && _openPopup && _popupTree)
        {
        NSAffineTransform* pt = [NSAffineTransform transform];
        [pt translateXBy:_popupOffset.x yBy:_popupOffset.y];
        [pt concat];
        GObject* pr = _popupTree.root;
        NSRect box = NSMakeRect(pr.x, pr.y, pr.w, pr.h);
        [[NSColor colorWithWhite:0 alpha:0.3] set];
        NSRectFill(NSOffsetRect(box, 2, 2));
        [GRender drawTree:_popupTree];
        }
    [gc restoreGraphicsState];

    // no editor chrome while test-driving
    if (_testMode)
        {
        [self drawTestBanner];
        return;
        }

    // selection overlays
    for (GObject* o in self.doc.selection)
        {
        NSPoint ao = [tree absoluteOriginOf:o];
        if (isnan(ao.x))
            continue;
        NSRect vr = [self viewRectFromModel:NSMakeRect(ao.x, ao.y, o.w, o.h)];
        [[NSColor colorWithSRGBRed:0.15 green:0.5 blue:1 alpha:1] set];
        NSFrameRectWithWidth(NSInsetRect(vr, -0.5, -0.5), 1.5);
        }
    // resize handles on the anchor
    GObject* anchor = self.doc.anchor;
    if (anchor && self.doc.selection.count == 1)
        {
        for (NSValue* v in [self handleRectsFor:anchor])
            {
            NSRect hr = v.rectValue;
            [[NSColor whiteColor] set];
            NSRectFill(hr);
            [[NSColor colorWithSRGBRed:0.15 green:0.5 blue:1 alpha:1] set];
            NSFrameRect(hr);
            }
        }

    // alignment guides
    if (_guideLines.count)
        {
        [[NSColor colorWithSRGBRed:1 green:0.2 blue:0.5 alpha:0.9] set];
        for (NSValue* v in _guideLines)
            {
            NSRect seg = v.rectValue;
            NSBezierPath* p = [NSBezierPath bezierPath];
            [p moveToPoint:seg.origin];
            [p lineToPoint:NSMakePoint(seg.origin.x + seg.size.width, seg.origin.y + seg.size.height)];
            p.lineWidth = 1;
            [p stroke];
            }
        }

    // marquee
    if (_mode == DM_MARQUEE)
        {
        [[NSColor colorWithWhite:1 alpha:0.15] set];
        NSRectFill(_marquee);
        [[NSColor whiteColor] set];
        NSFrameRect(_marquee);
        }
    }

- (void)drawGridIn:(NSRect)page
    {
    [[NSColor colorWithWhite:0 alpha:0.08] set];
    CGFloat step = _gridSize * _scale;
    if (step < 4)
        return;
    for (CGFloat x = page.origin.x; x <= NSMaxX(page); x += step)
        {
        NSRectFill(NSMakeRect(x, page.origin.y, 1, page.size.height));
        }
    for (CGFloat y = page.origin.y; y <= NSMaxY(page); y += step)
        {
        NSRectFill(NSMakeRect(page.origin.x, y, page.size.width, 1));
        }
    }

- (NSArray<NSValue*>*)handleRectsFor:(GObject*)o
    {
    NSPoint ao = [self.tree absoluteOriginOf:o];
    if (isnan(ao.x))
        return @[];
    NSRect r = [self viewRectFromModel:NSMakeRect(ao.x, ao.y, o.w, o.h)];
    CGFloat mx = NSMidX(r), my = NSMidY(r);
    NSPoint pts[8] = {
        {r.origin.x, r.origin.y}, {mx, r.origin.y}, {NSMaxX(r), r.origin.y}, {NSMaxX(r), my}, {NSMaxX(r), NSMaxY(r)}, {mx, NSMaxY(r)}, {r.origin.x, NSMaxY(r)}, {r.origin.x, my}};
    NSMutableArray* out = [NSMutableArray array];
    for (int i = 0; i < 8; i++)
        [out addObject:[NSValue valueWithRect:NSMakeRect(pts[i].x - kHandle / 2, pts[i].y - kHandle / 2, kHandle, kHandle)]];
    return out;
    }

- (GHandle)handleAtView:(NSPoint)v for:(GObject *)o
    {
    NSArray* rects = [self handleRectsFor:o];
    for (int i = 0; i < (int)rects.count; i++)
        if (NSPointInRect(v, [rects[i] rectValue]))
            return (GHandle)(i + 1);
    return H_NONE;
    }

// MARK: context menu

- (NSMenu*)menuForEvent:(NSEvent*)e
    {
    if (_testMode)
        return nil; // the canvas is a running dialog, not an editor
    [self.window makeFirstResponder:self];
    NSPoint v = [self convertPoint:e.locationInWindow fromView:nil];
    GObject* hit = [self hitTestMenuAware:[self modelFromView:v]];
    if (hit && hit != self.tree.root)
        {
        [self.doc select:hit extend:NO];
        if (hit.type == GT_TITLE)
            [self setActiveMenuTitle:hit]; // edit this menu
        }
    else
        {
        [self.doc clearSelection];
        }
    self.needsDisplay = YES;

    NSMenu* menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    if (self.tree.isMenu)
        {
        [[menu addItemWithTitle:@"Add Menu Title" action:@selector(addMenuTitle:) keyEquivalent:@""] setTarget:nil];
        [[menu addItemWithTitle:@"Add Menu Item" action:@selector(addMenuItem:) keyEquivalent:@""] setTarget:nil];
        [menu addItem:[NSMenuItem separatorItem]];
        }
    BOOL haveSel = self.doc.selection.count > 0;
    NSMenuItem* dup = [menu addItemWithTitle:@"Duplicate" action:@selector(duplicateObject:) keyEquivalent:@""];
    NSMenuItem* del = [menu addItemWithTitle:@"Delete" action:@selector(deleteObject:) keyEquivalent:@""];
    dup.enabled = haveSel;
    del.enabled = haveSel;
    return menu;
    }

// MARK: mouse

- (void)mouseDown:(NSEvent*)e
    {
    NSPoint v = [self convertPoint:e.locationInWindow fromView:nil];
    NSPoint m = [self modelFromView:v];

    // a double-click on text edits it in place
    if (!_testMode && e.clickCount == 2)
        {
        GObject* hit = [self hitTestMenuAware:m];
        if (hit && hit != self.tree.root && objectHasCanvasText(hit))
            {
            [self.doc select:hit extend:NO];
            [self beginEditing:hit];
            return;
            }
        }
    [self endEditingCommit:YES]; // a click elsewhere commits an open edit
    [self.window makeFirstResponder:self];

    if (_testMode)
        {
        if ([self handlePopupClickAt:m])
            return; // an open list swallows the click
        GObject* hit = [self hitTestMenuAware:m];
        if (hit && hit.type == GT_POPUP && ![GForm isDisabled:hit])
            {
            [self openPopupFor:hit];
            return;
            }
        GObject* exit = nil;
        _pressing = [GForm pressed:hit inTree:self.tree exit:&exit];
        if (hit && [GForm isEditable:hit])
            [self focusOn:hit];
        [self exitThrough:exit]; // OF_TOUCHEXIT fires on the way down
        self.needsDisplay = YES;
        return;
        }

    _downModel = m;
    _didDrag = NO;
    _guideLines = nil;
    BOOL shift = (e.modifierFlags & NSEventModifierFlagShift) != 0;

    // resize handle on the single anchor?
    if (self.doc.selection.count == 1)
        {
        GHandle h = [self handleAtView:v for:self.doc.anchor];
        if (h != H_NONE)
            {
            _mode = DM_RESIZE;
            _handle = h;
            [self beginDragCapture];
            return;
            }
        }

    GObject* hit = [self hitTestMenuAware:m];
    // clicking a menu title switches which dropdown is shown
    if (hit && hit.type == GT_TITLE)
        {
        NSUInteger idx = [self.tree.menuTitles indexOfObject:hit];
        if (idx != NSNotFound)
            {
            _activeMenu = (int)idx;
            }
        }
    if (hit && hit != self.tree.root)
        {
        if (shift)
            {
            [self.doc select:hit extend:YES];
            }
        else if (![self.doc isSelected:hit])
            {
            [self.doc select:hit extend:NO];
            }
        _mode = DM_MOVE;
        [self beginDragCapture];
        }
    else if (hit == self.tree.root && !shift)
        {
        // clicking the dialog background: allow selecting/moving the root too
        [self.doc select:hit extend:NO];
        _mode = DM_MOVE;
        [self beginDragCapture];
        }
    else
        {
        if (!shift)
            [self.doc clearSelection];
        _mode = DM_MARQUEE;
        _marquee = NSMakeRect(v.x, v.y, 0, 0);
        }
    self.needsDisplay = YES;
    }

// Hit-test that ignores hidden menu dropdowns (only the active one is live).
- (GObject*)hitTestMenuAware:(NSPoint)m
    {
    GTree* tree = self.tree;
    if (!tree.isMenu)
        return [tree hitTest:m];
    NSArray<GObject*>* titles = tree.menuTitles;
    GObject* activeTitle = (_activeMenu >= 0 && _activeMenu < (int)titles.count) ? titles[_activeMenu] : nil;
    GObject* activeDrop = [tree dropdownUnderTitle:activeTitle];
    NSMutableSet* skip = [NSMutableSet set];
    for (GObject* dd in tree.menuDropdowns)
        if (dd != activeDrop)
            [dd preorder:^(GObject* o) {
              [skip addObject:o];
            }];
    __block GObject* best = nil;
    int px = (int)m.x, py = (int)m.y;
    void (^walk)(GObject*, int, int) = nil;
    __block __weak void (^weakWalk)(GObject*, int, int);
    weakWalk = walk = ^(GObject* o, int ax, int ay) {
      if ((o.flags & OF_HIDETREE) || [skip containsObject:o])
          return;
      int bx = ax + o.x, by = ay + o.y;
      if (px >= bx && py >= by && px < bx + o.w && py < by + o.h)
          best = o;
      for (GObject* c in o.children)
          weakWalk(c, bx, by);
    };
    walk(tree.root, 0, 0);
    return best;
    }

- (void)beginDragCapture
    {
    _dragSnapshot = [self.doc snapshot];
    [_startFrames removeAllObjects];
    for (GObject* o in self.doc.selection)
        [_startFrames setObject:[NSValue valueWithRect:NSMakeRect(o.x, o.y, o.w, o.h)] forKey:o];
    }

- (void)mouseDragged:(NSEvent*)e
    {
    if (_testMode)
        return; // a held button neither moves nor selects
    NSPoint v = [self convertPoint:e.locationInWindow fromView:nil];
    NSPoint m = [self modelFromView:v];
    CGFloat dx = m.x - _downModel.x, dy = m.y - _downModel.y;
    if (!_didDrag && (fabs(v.x - [self viewFromModel:_downModel].x) > 2 || fabs(dx) + fabs(dy) > 0.5))
        _didDrag = YES;

    if (_mode == DM_MOVE)
        {
        [self doMoveDX:dx DY:dy];
        }
    else if (_mode == DM_RESIZE)
        {
        [self doResizeDX:dx DY:dy];
        }
    else if (_mode == DM_MARQUEE)
        {
        _marquee = NSMakeRect(MIN(v.x, [self viewFromModel:_downModel].x),
                              MIN(v.y, [self viewFromModel:_downModel].y),
                              fabs(v.x - [self viewFromModel:_downModel].x),
                              fabs(v.y - [self viewFromModel:_downModel].y));
        [self selectInMarquee];
        }
    self.needsDisplay = YES;
    }

- (void)mouseUp:(NSEvent*)e
    {
    if (_testMode)
        {
        // The click only counts if it comes up on the object it went down on.
        NSPoint m = [self modelFromView:[self convertPoint:e.locationInWindow fromView:nil]];
        GObject* hit = [self hitTestMenuAware:m];
        if (_pressing)
            {
            if (hit == _pressing)
                [self exitThrough:[GForm released:_pressing inTree:self.tree]];
            else
                _pressing.state &= ~OS_SELECTED; // dragged off: drop the highlight
            }
        _pressing = nil;
        self.needsDisplay = YES;
        return;
        }
    if ((_mode == DM_MOVE || _mode == DM_RESIZE) && _didDrag)
        [self reparentByGeometry];
    _guideLines = nil;
    if ((_mode == DM_MOVE || _mode == DM_RESIZE) && _didDrag && _dragSnapshot)
        {
        [self.doc commit:(_mode == DM_RESIZE ? @"Resize" : @"Move") from:_dragSnapshot];
        }
    _mode = DM_NONE;
    _handle = H_NONE;
    _dragSnapshot = nil;
    self.needsDisplay = YES;
    }

// MARK: move + snapping

- (void)doMoveDX:(CGFloat)dx DY:(CGFloat)dy
    {
    // Snap the anchor's new origin (in its parent space) to sibling/parent edges
    // and grid; apply the same delta to every selected object.
    GObject* anchor = self.doc.anchor;
    NSRect a0 = [_startFrames objectForKey:anchor].rectValue;
    CGFloat nx = a0.origin.x + dx, ny = a0.origin.y + dy;

    NSMutableArray* guides = [NSMutableArray array];
    CGFloat sdx = 0, sdy = 0;
    [self snapOrigin:&nx
                   y:&ny
               width:a0.size.width
              height:a0.size.height
              parent:[self.tree parentOf:anchor]
             exclude:self.doc.selection
              guides:guides];
    sdx = nx - a0.origin.x;
    sdy = ny - a0.origin.y;

    for (GObject* o in self.doc.selection)
        {
        NSRect s0 = [_startFrames objectForKey:o].rectValue;
        o.x = (int)round(s0.origin.x + sdx);
        o.y = (int)round(s0.origin.y + sdy);
        }
    _guideLines = _showGuides ? guides : nil;
    [self.doc notifyModel];
    }

// Snap a rect origin to candidate lines; append guide segments (view space).
- (void)snapOrigin:(CGFloat*)nx y:(CGFloat*)ny width:(CGFloat)w height:(CGFloat)h
            parent:(GObject*)parent
           exclude:(NSArray<GObject*>*)excl
            guides:(NSMutableArray*)guides
    {
    if (!_snapEnabled)
        {
        if (_showGrid)
            {
            *nx = round(*nx / _gridSize) * _gridSize;
            *ny = round(*ny / _gridSize) * _gridSize;
            }
        return;
        }
    GObject* root = parent ?: self.tree.root;
    // candidate vertical lines (x values) and horizontal lines (y values) in parent space
    NSMutableArray<NSNumber*>* vx = [NSMutableArray array];
    NSMutableArray<NSNumber*>* hy = [NSMutableArray array];
    // parent content edges + centre
    [vx addObjectsFromArray:@[ @0, @(root.w / 2.0), @(root.w) ]];
    [hy addObjectsFromArray:@[ @0, @(root.h / 2.0), @(root.h) ]];
    for (GObject* c in root.children)
        {
        if ([excl containsObject:c])
            continue;
        [vx addObjectsFromArray:@[ @(c.x), @(c.x + c.w / 2.0), @(c.x + c.w) ]];
        [hy addObjectsFromArray:@[ @(c.y), @(c.y + c.h / 2.0), @(c.y + c.h) ]];
        }
    // our candidate edges: left, centre, right / top, mid, bottom
    CGFloat myX[3] = {*nx, *nx + w / 2, *nx + w};
    CGFloat myY[3] = {*ny, *ny + h / 2, *ny + h};

    CGFloat bestDX = kSnap + 1, snapX = 0;
    BOOL hitX = NO;
    CGFloat lineX = 0;
    for (NSNumber* cand in vx)
        {
        for (int i = 0; i < 3; i++)
            {
            CGFloat d = cand.doubleValue - myX[i];
            if (fabs(d) < fabs(bestDX))
                {
                bestDX = d;
                snapX = d;
                hitX = YES;
                lineX = cand.doubleValue;
                }
            }
        }
    CGFloat bestDY = kSnap + 1, snapY = 0;
    BOOL hitY = NO;
    CGFloat lineY = 0;
    for (NSNumber* cand in hy)
        {
        for (int i = 0; i < 3; i++)
            {
            CGFloat d = cand.doubleValue - myY[i];
            if (fabs(d) < fabs(bestDY))
                {
                bestDY = d;
                snapY = d;
                hitY = YES;
                lineY = cand.doubleValue;
                }
            }
        }
    if (hitX && fabs(bestDX) <= kSnap)
        {
        *nx += snapX;
        // vertical guide line spanning the page (view space)
        NSPoint top = [self viewFromModel:NSMakePoint((parent ? [self.tree absoluteOriginOf:parent].x : 0) + lineX, 0)];
        [guides addObject:[NSValue valueWithRect:NSMakeRect(top.x, kMargin, 0, self.tree.root.h * _scale)]];
        }
    else if (_showGrid)
        {
        *nx = round(*nx / _gridSize) * _gridSize;
        }
    if (hitY && fabs(bestDY) <= kSnap)
        {
        *ny += snapY;
        NSPoint lft = [self viewFromModel:NSMakePoint(0, (parent ? [self.tree absoluteOriginOf:parent].y : 0) + lineY)];
        [guides addObject:[NSValue valueWithRect:NSMakeRect(kMargin, lft.y, self.tree.root.w * _scale, 0)]];
        }
    else if (_showGrid)
        {
        *ny = round(*ny / _gridSize) * _gridSize;
        }
    }

// MARK: resize

- (void)doResizeDX:(CGFloat)dx DY:(CGFloat)dy
    {
    GObject* o = self.doc.anchor;
    NSRect s0 = [_startFrames objectForKey:o].rectValue;
    CGFloat x = s0.origin.x, y = s0.origin.y, w = s0.size.width, h = s0.size.height;
    switch (_handle)
        {
    case H_TL:
        x += dx;
        y += dy;
        w -= dx;
        h -= dy;
        break;
    case H_T:
        y += dy;
        h -= dy;
        break;
    case H_TR:
        y += dy;
        w += dx;
        h -= dy;
        break;
    case H_R:
        w += dx;
        break;
    case H_BR:
        w += dx;
        h += dy;
        break;
    case H_B:
        h += dy;
        break;
    case H_BL:
        x += dx;
        w -= dx;
        h += dy;
        break;
    case H_L:
        x += dx;
        w -= dx;
        break;
    default:
        break;
        }
    if (_snapEnabled || _showGrid)
        {
        x = round(x / _gridSize) * _gridSize;
        y = round(y / _gridSize) * _gridSize;
        w = round(w / _gridSize) * _gridSize;
        h = round(h / _gridSize) * _gridSize;
        }
    o.x = (int)x;
    o.y = (int)y;
    o.w = (int)MAX(w, 4);
    o.h = (int)MAX(h, 4);
    [self.doc notifyModel];
    }

// MARK: marquee

- (void)selectInMarquee
    {
    NSMutableArray* hits = [NSMutableArray array];
    for (GObject* o in self.tree.allObjects)
        {
        if (o == self.tree.root)
            continue;
        NSPoint ao = [self.tree absoluteOriginOf:o];
        NSRect vr = [self viewRectFromModel:NSMakeRect(ao.x, ao.y, o.w, o.h)];
        if (NSIntersectsRect(vr, _marquee))
            [hits addObject:o];
        }
    [self.doc setSelectionObjects:hits];
    }

// MARK: reparent on drop

// Re-derive the whole tree's parent/child structure from geometry: every object
// becomes a child of the SMALLEST box that fully encloses it (inclusive edges),
// so the tree mirrors what's on screen.  Objects keep their absolute positions.
// Idempotent for unchanged geometry — only objects whose enclosure changed move.
- (void)reparentByGeometry
    {
    GTree* tree = self.tree;
    NSArray<GObject*>* all = tree.allObjects; // preorder, root first
    if (all.count < 2)
        return;

    NSMapTable* rectFor = [NSMapTable strongToStrongObjectsMapTable];
    NSMapTable* idxFor = [NSMapTable strongToStrongObjectsMapTable];
    for (NSUInteger i = 0; i < all.count; i++)
        {
        GObject* o = all[i];
        NSPoint ao = [tree absoluteOriginOf:o];
        [rectFor setObject:[NSValue valueWithRect:NSMakeRect(ao.x, ao.y, o.w, o.h)] forKey:o];
        [idxFor setObject:@(i) forKey:o];
        }

    NSMapTable* parentFor = [NSMapTable strongToStrongObjectsMapTable];
    for (GObject* o in all)
        {
        if (o == tree.root)
            continue;
        NSRect r = [[rectFor objectForKey:o] rectValue];
        CGFloat oArea = r.size.width * r.size.height;
        int oi = [[idxFor objectForKey:o] intValue];
        GObject* best = tree.root;
        NSRect rootR = [[rectFor objectForKey:tree.root] rectValue];
        CGFloat bestArea = rootR.size.width * rootR.size.height;
        int bestIdx = 0;
        for (GObject* p in all)
            {
            if (p == o || ![p canHaveChildren])
                continue;
            NSRect pr = [[rectFor objectForKey:p] rectValue];
            BOOL enc = r.origin.x >= pr.origin.x && r.origin.y >= pr.origin.y &&
                       NSMaxX(r) <= NSMaxX(pr) && NSMaxY(r) <= NSMaxY(pr);
            if (!enc)
                continue;
            CGFloat pArea = pr.size.width * pr.size.height;
            int pi = [[idxFor objectForKey:p] intValue];
            if (pArea == oArea && pi >= oi)
                continue; // tie: only an earlier object may parent (no cycles)
            if (pArea < bestArea || (pArea == bestArea && pi < bestIdx))
                {
                best = p;
                bestArea = pArea;
                bestIdx = pi;
                }
            }
        [parentFor setObject:best forKey:o];
        }

    // rebuild children lists, preserving original order (z-order)
    NSMapTable* kidsFor = [NSMapTable strongToStrongObjectsMapTable];
    for (GObject* o in all)
        [kidsFor setObject:[NSMutableArray array] forKey:o];
    for (GObject* o in all)
        {
        if (o == tree.root)
            continue;
        [[kidsFor objectForKey:[parentFor objectForKey:o]] addObject:o];
        }
    for (GObject* o in all)
        {
        o.children = [kidsFor objectForKey:o];
        if (o == tree.root)
            continue;
        NSRect r = [[rectFor objectForKey:o] rectValue];
        NSRect pr = [[rectFor objectForKey:[parentFor objectForKey:o]] rectValue];
        o.x = (int)(r.origin.x - pr.origin.x);
        o.y = (int)(r.origin.y - pr.origin.y);
        }
    }

// Smallest container object whose rect fully encloses `rect` (used at drop time).
- (GObject*)containerEnclosing:(NSRect)rect excluding:(GObject*)skip
    {
    __block GObject* best = nil;
    void (^walk)(GObject*, int, int) = nil;
    __block __weak void (^weakWalk)(GObject*, int, int);
    weakWalk = walk = ^(GObject* o, int ax, int ay) {
      if (o == skip)
          return;
      int bx = ax + o.x, by = ay + o.y;
      if ([o canHaveChildren] &&
          rect.origin.x >= bx && rect.origin.y >= by &&
          NSMaxX(rect) <= bx + o.w && NSMaxY(rect) <= by + o.h)
          best = o;
      for (GObject* c in o.children)
          weakWalk(c, bx, by);
    };
    walk(self.tree.root, 0, 0);
    return best ?: self.tree.root;
    }

// A strip along the top of the canvas: that we are test-driving, and what the
// form last exited through — named with the same symbol the .h export emits, so
// what you read here is what you write in code.
- (void)drawTestBanner
    {
    NSString* msg = @"TEST DRIVE — click, Tab between fields, Return = default, Esc = cancel";
    NSColor* bg = [NSColor colorWithSRGBRed:0.15 green:0.45 blue:0.25 alpha:0.95];
    if (_lastExit)
        {
        NSString* sym = GExportSymbolForObject(self.doc.resource, _lastExit);
        int idx = (int)[[self.tree allObjects] indexOfObject:_lastExit];
        msg = [NSString stringWithFormat:@"exited through  %@  (object %d)",
                                         sym ?: (_lastExit.text ?: GObTypeName(_lastExit.type)), idx];
        bg = [NSColor colorWithSRGBRed:0.15 green:0.35 blue:0.7 alpha:0.95];
        }
    NSDictionary* a = @{NSFontAttributeName : [NSFont boldSystemFontOfSize:11],
                        NSForegroundColorAttributeName : [NSColor whiteColor]};
    NSSize sz = [msg sizeWithAttributes:a];
    NSRect bar = NSMakeRect(8, 8, sz.width + 16, sz.height + 8);
    [bg set];
    [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:4 yRadius:4] fill];
    [msg drawAtPoint:NSMakePoint(bar.origin.x + 8, bar.origin.y + 4) withAttributes:a];
    }

// MARK: keyboard

- (void)keyDown:(NSEvent*)e
    {
    if (_testMode)
        {
        [self testKeyDown:e];
        return;
        }
    unichar k = [e.charactersIgnoringModifiers length] ? [e.charactersIgnoringModifiers characterAtIndex:0] : 0;
    int step = (e.modifierFlags & NSEventModifierFlagShift) ? _gridSize : 1;
    int dx = 0, dy = 0;
    // Delete / Backspace
    if (k == 127 || k == 8 || k == NSDeleteFunctionKey)
        {
        [NSApp sendAction:@selector(deleteObject:) to:nil from:self];
        return;
        }
    if (k == NSLeftArrowFunctionKey)
        dx = -step;
    else if (k == NSRightArrowFunctionKey)
        dx = step;
    else if (k == NSUpArrowFunctionKey)
        dy = -step;
    else if (k == NSDownArrowFunctionKey)
        dy = step;
    else
        {
        [super keyDown:e];
        return;
        }
    if (self.doc.selection.count == 0)
        return;
    [self.doc perform:@"Nudge"
                block:^{
                  for (GObject* o in self.doc.selection)
                      {
                      o.x += dx;
                      o.y += dy;
                      }
                }];
    }

// Keys in test mode: Tab cycles fields, Return fires OF_DEFAULT, Esc fires
// OF_CANCEL, and anything printable goes through the field's validation mask.
- (void)testKeyDown:(NSEvent*)e
    {
    NSString* chars = e.charactersIgnoringModifiers;
    unichar k = chars.length ? [chars characterAtIndex:0] : 0;
    BOOL shift = (e.modifierFlags & NSEventModifierFlagShift) != 0;

    switch (k)
        {
    case '\t':
        [self cycleFocusBy:shift ? -1 : 1];
        return;
    case '\r':
    case 0x03:
        [self exitThrough:[GForm objectWithFlag:OF_DEFAULT in:self.tree]];
        return;
    case 0x1B:
        [self exitThrough:[GForm objectWithFlag:OF_CANCEL in:self.tree]];
        return;
        }
    if (!_focus)
        {
        NSBeep();
        return;
        }

    switch (k)
        {
    case NSLeftArrowFunctionKey:
        [self setCaret:_caret - 1];
        break;
    case NSRightArrowFunctionKey:
        [self setCaret:MIN(_caret + 1, (int)_focus.ted.text.length)];
        break;
    case NSHomeFunctionKey:
        [self setCaret:0];
        break;
    case NSEndFunctionKey:
        [self setCaret:(int)_focus.ted.text.length];
        break;
    case NSUpArrowFunctionKey:
        [self cycleFocusBy:-1];
        break;
    case NSDownArrowFunctionKey:
        [self cycleFocusBy:1];
        break;
    case 8:
    case 127: // Backspace
        if (![GForm deleteBackwardIn:_focus caret:&_caret])
            NSBeep();
        [GRender setEditCaretObject:_focus slot:_caret];
        break;
    case NSDeleteFunctionKey: // forward Delete
        if (![GForm deleteForwardIn:_focus caret:&_caret])
            NSBeep();
        break;
    default:
        {
        // e.characters (not charactersIgnoringModifiers) so Shift gives capitals
        NSString* typed = e.characters;
        if (!typed.length)
            {
            NSBeep();
            return;
            }
        BOOL any = NO;
        for (NSUInteger i = 0; i < typed.length; i++)
            any |= [GForm insert:[typed characterAtIndex:i] into:_focus caret:&_caret];
        if (!any)
            NSBeep(); // rejected by te_pvalid, or field full
        [GRender setEditCaretObject:_focus slot:_caret];
        break;
        }
        }
    self.needsDisplay = YES;
    }

// MARK: palette drop (create new objects)

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)s
    {
    return _testMode ? NSDragOperationNone : NSDragOperationCopy;
    }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)s
    {
    return NSDragOperationCopy;
    }

- (BOOL)performDragOperation:(id<NSDraggingInfo>)info
    {
    if (_testMode)
        return NO;
    NSString* typeStr = [info.draggingPasteboard stringForType:GPaletteDragType];
    if (!typeStr)
        return NO;
    GObType type = (GObType)typeStr.intValue;
    NSPoint v = [self convertPoint:info.draggingLocation fromView:nil];
    NSPoint m = [self modelFromView:v];

    NSSize def = [self defaultSizeFor:type];
    // drop at the cursor (root coords), then parent into the smallest box that
    // fully encloses the new object's rect.
    int ax = (int)round(m.x), ay = (int)round(m.y);
    if (_showGrid)
        {
        ax = (int)round((double)ax / _gridSize) * _gridSize;
        ay = (int)round((double)ay / _gridSize) * _gridSize;
        }
    GObject* target = [self containerEnclosing:NSMakeRect(ax, ay, def.width, def.height) excluding:nil];
    NSPoint tp = [self.tree absoluteOriginOf:target];
    int lx = ax - (int)tp.x, ly = ay - (int)tp.y;
    GObject* o = [GObject objectOfType:type frame:NSMakeRect(lx, ly, def.width, def.height)];

    [self.doc perform:@"Add Object"
                block:^{
                  [target.children addObject:o];
                  [self reparentByGeometry]; // adopt into/under boxes as needed
                }];
    [self.doc select:o extend:NO];
    return YES;
    }

- (NSSize)defaultSizeFor:(GObType)t
    {
    switch (t)
        {
    case GT_BUTTON:
        return NSMakeSize(72, 24);
    case GT_CHECKBOX:
    case GT_RADIO:
        return NSMakeSize(120, 18);
    case GT_STRING:
    case GT_TEXT:
    case GT_TITLE:
        return NSMakeSize(100, 16);
    case GT_FIELD:
    case GT_FTEXT:
    case GT_POPUP:
        return NSMakeSize(140, 20);
    case GT_BOX:
    case GT_IBOX:
        return NSMakeSize(120, 80);
    case GT_ICON:
    case GT_CICON:
        return NSMakeSize(48, 60);
    default:
        return NSMakeSize(80, 24);
        }
    }
@end
