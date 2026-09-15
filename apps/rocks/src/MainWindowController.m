// MainWindowController.m — see MainWindowController.h.

#import "MainWindowController.h"
#import "Document.h"
#import "CanvasView.h"
#import "PaletteView.h"
#import "InspectorView.h"
#import "OutlineController.h"
#import "GProject.h"
#import "GRsc.h"
#import "GExport.h"
#import "GAlert.h"
#import "AlertWizard.h"
#import "GHelp.h"
#import "GImage.h"

@interface MainWindowController () <NSWindowDelegate>
@end

@implementation MainWindowController
    {
    Document* _doc;
    NSUndoManager* _undo;
    CanvasView* _canvas;
    NSScrollView* _canvasScroll;
    InspectorView* _inspector;
    OutlineController* _outline;
    NSArray<GObject*>* _clipboard;
    NSSplitView* _split;
    NSSplitView* _rightSplit;
    NSView* _canvasContainer;
    NSPopUpButton* _treePopup;
    NSTextView* _helpText;
    NSSplitView* _cvSplit;
    NSData* _testSnapshot;     // resource state before test-drive; restored on exit
    AlertWizard* _alertWizard; // held so it is not deallocated while open
    }

static const CGFloat kPaletteW = 158;
static const CGFloat kRightW = 320;

- (instancetype)init
    {
    NSRect frame = NSMakeRect(0, 0, 1180, 760);
    NSWindow* w = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                         NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.title = @"Rocks — Untitled";
    [w center];
    if ((self = [super initWithWindow:w]))
        {
        w.delegate = self;
        _undo = [[NSUndoManager alloc] init];
        _doc = [[Document alloc] initWithResource:[GResource emptyDialog]];
        _doc.undoManager = _undo;
        [self buildUI];
        [self observe];
        if (getenv("ROCKS_DEMO"))
            [self loadDemo];
        const char* op = getenv("ROCKS_OPEN");
        if (op)
            {
            NSData* d = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:op]];
            NSString* e = nil;
            GResource* r = d ? GRscRead(d, &e) : nil;
            if (r)
                {
                _doc.resource = r;
                const char* ti = getenv("ROCKS_TREE");
                _doc.currentTreeIndex = ti ? atoi(ti) : 0;
                [self refreshAll];
                }
            }
        [self refreshAll];
        }
    return self;
    }

- (NSUndoManager*)windowWillReturnUndoManager:(NSWindow*)window
    {
    return _undo;
    }

- (void)showWindow:(id)sender
    {
    [super showWindow:sender];
    [self positionDividers];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self positionDividers];
      CGFloat h = self->_cvSplit.bounds.size.height;
      if (h > 200)
          [self->_cvSplit setPosition:h - 170 ofDividerAtIndex:0]; // ~170px help pane
    });
    }

- (void)buildUI
    {
    NSSplitView* split = [[NSSplitView alloc] initWithFrame:self.window.contentView.bounds];
    split.vertical = YES;
    split.dividerStyle = NSSplitViewDividerStyleThin;
    split.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // palette (left)
    PaletteView* palette = [[PaletteView alloc] initWithFrame:NSMakeRect(0, 0, 150, 700)];
    NSScrollView* palScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 150, 700)];
    palScroll.hasVerticalScroller = YES;
    palScroll.drawsBackground = NO;
    palette.frame = NSMakeRect(0, 0, 150, MAX(700, 16 * 30));
    palScroll.documentView = palette;

    // canvas (centre) — a top toolbar (tree picker) over the scrollable canvas
    _canvasContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 700, 700)];
    NSView* toolbar = [[NSView alloc] initWithFrame:NSMakeRect(0, 670, 700, 30)];
    toolbar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    toolbar.wantsLayer = YES;
    toolbar.layer.backgroundColor = [NSColor colorWithWhite:0.22 alpha:1].CGColor;

    NSTextField* lbl = [NSTextField labelWithString:@"Tree:"];
    lbl.textColor = [NSColor colorWithWhite:0.7 alpha:1];
    lbl.font = [NSFont systemFontOfSize:11];
    lbl.frame = NSMakeRect(8, 7, 36, 16);
    [toolbar addSubview:lbl];

    _treePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(44, 4, 260, 22)];
    _treePopup.target = self;
    _treePopup.action = @selector(treeChanged:);
    _treePopup.font = [NSFont systemFontOfSize:11];
    [toolbar addSubview:_treePopup];

    NSButton* addBtn = [[NSButton alloc] initWithFrame:NSMakeRect(312, 3, 96, 24)];
    addBtn.title = @"New Dialog";
    addBtn.bezelStyle = NSBezelStyleRounded;
    addBtn.font = [NSFont systemFontOfSize:11];
    addBtn.target = self;
    addBtn.action = @selector(newTree:);
    [toolbar addSubview:addBtn];

    NSButton* menuBtn = [[NSButton alloc] initWithFrame:NSMakeRect(410, 3, 90, 24)];
    menuBtn.title = @"New Menu";
    menuBtn.bezelStyle = NSBezelStyleRounded;
    menuBtn.font = [NSFont systemFontOfSize:11];
    menuBtn.target = self;
    menuBtn.action = @selector(newMenu:);
    [toolbar addSubview:menuBtn];

    NSButton* delBtn = [[NSButton alloc] initWithFrame:NSMakeRect(502, 3, 90, 24)];
    delBtn.title = @"Delete Tree";
    delBtn.bezelStyle = NSBezelStyleRounded;
    delBtn.font = [NSFont systemFontOfSize:11];
    delBtn.target = self;
    delBtn.action = @selector(deleteTree:);
    [toolbar addSubview:delBtn];

    // help panel pinned to the bottom of the canvas pane
    CGFloat helpH = 150;
    NSScrollView* helpScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 700, helpH)];
    helpScroll.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    helpScroll.hasVerticalScroller = YES;
    helpScroll.drawsBackground = YES;
    helpScroll.backgroundColor = [NSColor colorWithWhite:0.14 alpha:1];
    helpScroll.borderType = NSNoBorder;
    _helpText = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 700, helpH)];
    _helpText.editable = NO;
    _helpText.selectable = YES;
    _helpText.drawsBackground = YES;
    _helpText.backgroundColor = [NSColor colorWithWhite:0.14 alpha:1];
    _helpText.textContainerInset = NSMakeSize(10, 8);
    _helpText.autoresizingMask = NSViewWidthSizable;
    _helpText.textContainer.widthTracksTextView = YES;
    helpScroll.documentView = _helpText;

    _canvasScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 700, 670 - helpH)];
    _canvasScroll.hasVerticalScroller = YES;
    _canvasScroll.hasHorizontalScroller = YES;
    _canvasScroll.allowsMagnification = NO;
    _canvas = [[CanvasView alloc] initWithFrame:NSMakeRect(0, 0, 700, 670)];
    _canvas.doc = _doc;
    _canvasScroll.documentView = _canvas;

    // canvas over help, split by a draggable horizontal divider
    NSSplitView* cvSplit = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 700, 670)];
    cvSplit.vertical = NO;
    cvSplit.dividerStyle = NSSplitViewDividerStyleThin;
    cvSplit.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [cvSplit addSubview:_canvasScroll];
    [cvSplit addSubview:helpScroll];
    [cvSplit setHoldingPriority:NSLayoutPriorityDefaultLow forSubviewAtIndex:0];  // canvas absorbs resize
    [cvSplit setHoldingPriority:NSLayoutPriorityDefaultHigh forSubviewAtIndex:1]; // help holds height
    _cvSplit = cvSplit;

    [_canvasContainer addSubview:toolbar];
    [_canvasContainer addSubview:cvSplit];

    // right: outline over inspector
    _outline = [[OutlineController alloc] initWithDocument:_doc];
    _inspector = [[InspectorView alloc] initWithFrame:NSMakeRect(0, 0, 300, 500)];
    _inspector.doc = _doc;
    NSSplitView* rightSplit = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 300, 700)];
    rightSplit.vertical = NO;
    rightSplit.dividerStyle = NSSplitViewDividerStyleThin;
    [rightSplit addSubview:_outline.view];
    [rightSplit addSubview:_inspector];

    [split addSubview:palScroll];
    [split addSubview:_canvasContainer];
    [split addSubview:rightSplit];
    self.window.contentView = split;
    _split = split;
    _rightSplit = rightSplit;
    split.delegate = self; // we lay the three panes out ourselves
    [self positionDividers];
    }

// Deterministic three-pane layout: palette + inspector fixed width, canvas rest.
- (void)splitView:(NSSplitView*)sv resizeSubviewsWithOldSize:(NSSize)old
    {
    if (sv != _split)
        {
        [sv adjustSubviews];
        return;
        }
    NSArray* subs = sv.subviews;
    if (subs.count < 3)
        {
        [sv adjustSubviews];
        return;
        }
    CGFloat W = sv.bounds.size.width, H = sv.bounds.size.height, d = sv.dividerThickness;
    CGFloat pal = kPaletteW, right = kRightW;
    CGFloat canvas = W - pal - right - 2 * d;
    if (canvas < 160)
        {
        canvas = 160;
        right = MAX(W - pal - canvas - 2 * d, 120);
        }
    [(NSView*)subs[0] setFrame:NSMakeRect(0, 0, pal, H)];
    [(NSView*)subs[1] setFrame:NSMakeRect(pal + d, 0, canvas, H)];
    [(NSView*)subs[2] setFrame:NSMakeRect(pal + d + canvas + d, 0, right, H)];
    }

- (void)positionDividers
    {
    [_split adjustSubviews];
    NSRect c = [self.window contentRectForFrameRect:self.window.frame];
    [_rightSplit setPosition:MAX(c.size.height * 0.34, 200) ofDividerAtIndex:0];
    [_canvas refresh];
    }

- (void)windowDidResize:(NSNotification*)n
    {
    [self positionDividers];
    }

- (void)observe
    {
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(modelChanged:) name:GModelChangedNotification object:_doc];
    [nc addObserver:self selector:@selector(selectionChanged:) name:GSelectionChangedNotification object:_doc];
    }

- (void)loadDemo
    {
    GObject* root = _doc.tree.root;
    GObject* title = [GObject objectOfType:GT_STRING frame:NSMakeRect(16, 12, 200, 16)];
    title.text = @"Preferences";
    GObject* fld = [GObject objectOfType:GT_FIELD frame:NSMakeRect(16, 44, 200, 20)];
    fld.ted.tmplt = @"Name: ______________";
    fld.ted.text = @"Ada";
    fld.extType = 0x01; // rounded (demo)
    GObject* chk = [GObject objectOfType:GT_CHECKBOX frame:NSMakeRect(16, 76, 180, 18)];
    chk.text = @"Enable sound";
    chk.state = OS_CHECKED;
    chk.flags = OF_SELECTABLE;
    GObject* rad1 = [GObject objectOfType:GT_RADIO frame:NSMakeRect(16, 100, 90, 18)];
    rad1.text = @"Colour";
    rad1.state = OS_CHECKED;
    rad1.flags = OF_SELECTABLE | OF_RBUTTON;
    GObject* rad2 = [GObject objectOfType:GT_RADIO frame:NSMakeRect(116, 100, 90, 18)];
    rad2.text = @"Mono";
    rad2.flags = OF_SELECTABLE | OF_RBUTTON;
    GObject* cancel = [GObject objectOfType:GT_BUTTON frame:NSMakeRect(150, 160, 72, 24)];
    cancel.text = @"Cancel";
    cancel.flags = OF_SELECTABLE | OF_EXIT;
    GObject* ok = [GObject objectOfType:GT_BUTTON frame:NSMakeRect(236, 160, 72, 24)];
    ok.text = @"OK";
    ok.flags = OF_SELECTABLE | OF_EXIT | OF_DEFAULT;
    GObject* apply = [GObject objectOfType:GT_BUTTON frame:NSMakeRect(24, 160, 72, 24)];
    apply.text = @"Apply";
    apply.flags = OF_SELECTABLE;
    apply.state = OS_DISABLED;
    for (GObject* o in @[ title, fld, chk, rad1, rad2, apply, cancel, ok ])
        [root.children addObject:o];
    [_doc notifyModel];
    [_doc setSelectionObjects:@[ ok ]];
    }

- (void)modelChanged:(NSNotification*)n
    {
    [self reloadTreePicker];
    [_canvas refresh];
    [_outline reload];
    }
- (void)selectionChanged:(NSNotification*)n
    {
    [_canvas setNeedsDisplay:YES];
    [_inspector rebuild];
    [_outline syncSelection];
    [self updateHelp];
    }
- (void)updateHelp
    {
    [_helpText.textStorage setAttributedString:GHelpForObject(_doc.anchor)];
    }
- (void)refreshAll
    {
    [self reloadTreePicker];
    [_canvas refresh];
    [_outline reload];
    [_inspector rebuild];
    [self updateHelp];
    }

- (void)reloadTreePicker
    {
    [_treePopup removeAllItems];
    int i = 0;
    for (GTree* t in _doc.resource.trees)
        {
        NSString* kind = [t isMenu]          ? @"Menu"
                         : t.kind == GK_FREE ? @"Free"
                                             : @"Dialog";
        [_treePopup addItemWithTitle:[NSString stringWithFormat:@"%d — %@  (%@, %lu obj)",
                                                                i, t.name.length ? t.name : @"tree", kind, (unsigned long)t.allObjects.count]];
        i++;
        }
    int cur = _doc.currentTreeIndex;
    if (cur >= 0 && cur < (int)_doc.resource.trees.count)
        [_treePopup selectItemAtIndex:cur];
    }

- (void)treeChanged:(id)sender
    {
    NSInteger idx = [_treePopup indexOfSelectedItem];
    if (idx < 0 || idx >= (NSInteger)_doc.resource.trees.count)
        return;
    _doc.currentTreeIndex = (int)idx;
    [_doc clearSelection];
    [_canvas refresh];
    [_outline reload];
    [_inspector rebuild];
    }

- (NSString*)promptName:(NSString*)title default:(NSString*)def
    {
    NSAlert* a = [[NSAlert alloc] init];
    a.messageText = title;
    NSTextField* tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
    tf.stringValue = def ?: @"";
    a.accessoryView = tf;
    [a addButtonWithTitle:@"OK"];
    [a addButtonWithTitle:@"Cancel"];
    [a.window setInitialFirstResponder:tf];
    if ([a runModal] != NSAlertFirstButtonReturn)
        return nil;
    NSString* v = [tf.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return v.length ? v : def;
    }

- (void)newTree:(id)sender
    {
    NSString* name = [self promptName:@"Name for the new dialog tree:"
                              default:[NSString stringWithFormat:@"TREE%lu", (unsigned long)_doc.resource.trees.count]];
    if (!name)
        return;
    [_doc perform:@"New Tree"
            block:^{
              GObject* root = [GObject objectOfType:GT_BOX frame:NSMakeRect(0, 0, 320, 200)];
              root.box.thickness = 2;
              root.flags = OF_LASTOB;
              GTree* t = [GTree new];
              t.name = name;
              t.kind = GK_DIALOG;
              t.root = root;
              [_doc.resource.trees addObject:t];
            }];
    _doc.currentTreeIndex = (int)_doc.resource.trees.count - 1;
    [_doc clearSelection];
    [self refreshAll];
    }

- (void)newMenu:(id)sender
    {
    // Standard GEM menu: root IBox → { bar Box of Titles, active IBox of dropdown
    // Boxes each holding String items }.  A ready-to-edit Desk/File template.
    NSString* name = [self promptName:@"Name for the new menu tree:"
                              default:[NSString stringWithFormat:@"MENU%lu", (unsigned long)_doc.resource.trees.count]];
    if (!name)
        return;
    const int W = 640, BARH = 22, ITEMH = 20;
    NSArray* defs = @[ @{@"t" : @"Desk", @"items" : @[ @"  About…  " ]},
                       @{@"t" : @"File", @"items" : @[ @"  New  ", @"  Open…  ", @"  Save  ", @"  Quit  " ]} ];
    [_doc perform:@"New Menu"
            block:^{
              GObject* root = [GObject objectOfType:GT_IBOX frame:NSMakeRect(0, 0, W, 400)];
              GObject* bar = [GObject objectOfType:GT_BOX frame:NSMakeRect(0, 0, W, BARH)];
              GObject* active = [GObject objectOfType:GT_IBOX frame:NSMakeRect(0, BARH, W, 400 - BARH)];
              int tx = 0;
              for (NSDictionary* d in defs)
                  {
                  NSString* tname = d[@"t"];
                  int tw = (int)tname.length * 9 + 28;
                  GObject* title = [GObject objectOfType:GT_TITLE frame:NSMakeRect(tx, 0, tw, BARH)];
                  title.text = tname;
                  [bar.children addObject:title];

                  NSArray<NSString*>* items = d[@"items"];
                  int maxlen = 0;
                  for (NSString* s in items)
                      maxlen = MAX(maxlen, (int)s.length);
                  int ddw = maxlen * 8 + 16, ddh = (int)items.count * ITEMH + 8;
                  GObject* dd = [GObject objectOfType:GT_BOX frame:NSMakeRect(tx, 0, ddw, ddh)]; // rel. to active
                  dd.box.thickness = 1;
                  int iy = 4;
                  for (NSString* s in items)
                      {
                      GObject* item = [GObject objectOfType:GT_STRING frame:NSMakeRect(4, iy, ddw - 8, ITEMH)];
                      item.text = s;
                      item.flags = OF_SELECTABLE;
                      [dd.children addObject:item];
                      iy += ITEMH;
                      }
                  [active.children addObject:dd];
                  tx += tw;
                  }
              [root.children addObject:bar];
              [root.children addObject:active];
              GTree* t = [GTree new];
              t.name = name;
              t.kind = GK_MENU;
              t.root = root;
              [_doc.resource.trees addObject:t];
            }];
    _doc.currentTreeIndex = (int)_doc.resource.trees.count - 1;
    [_doc clearSelection];
    [self refreshAll];
    }

- (void)addMenuTitle:(id)sender
    {
    GTree* tree = _doc.tree;
    if (!tree.isMenu)
        {
        [self alert:@"Menu titles belong to a Menu tree — click “New Menu” first."];
        return;
        }
    GObject* bar = tree.menuBar;
    if (!bar)
        return;
    __block GObject* newTitle = nil;
    [_doc perform:@"Add Menu Title"
            block:^{
              int tx = 0;
              for (GObject* t in bar.children)
                  if (t.type == GT_TITLE)
                      tx = MAX(tx, t.x + t.w);
              newTitle = [GObject objectOfType:GT_TITLE frame:NSMakeRect(tx, 0, 80, bar.h)];
              newTitle.text = @"Title";
              [bar.children addObject:newTitle];
              // a dropdown under the new title, holding one starter item
              GObject* ddParent = tree.menuDropdowns.count ? [tree parentOf:tree.menuDropdowns.firstObject] : tree.root;
              NSPoint pp = [tree absoluteOriginOf:ddParent];
              NSPoint barp = [tree absoluteOriginOf:bar];
              GObject* dd = [GObject objectOfType:GT_BOX
                                            frame:NSMakeRect((int)(barp.x + tx - pp.x), (int)(barp.y + bar.h - pp.y), 130, 28)];
              dd.box.thickness = 1;
              GObject* item = [GObject objectOfType:GT_STRING frame:NSMakeRect(4, 4, 122, 20)];
              item.text = @"  Item  ";
              item.flags = OF_SELECTABLE;
              [dd.children addObject:item];
              [ddParent.children addObject:dd];
            }];
    [self refreshAll];
    if (newTitle)
        {
        [_canvas setActiveMenuTitle:newTitle];
        [_doc setSelectionObjects:@[ newTitle ]];
        }
    }

- (void)addMenuItem:(id)sender
    {
    GObject* dd = [_canvas activeMenuDropdown];
    if (!dd)
        {
        [self alert:@"Click a menu title to open its dropdown first (or Add Menu Title)."];
        return;
        }
    __block GObject* item = nil;
    [_doc perform:@"Add Menu Item"
            block:^{
              int maxY = 4;
              for (GObject* it in dd.children)
                  maxY = MAX(maxY, it.y + it.h);
              item = [GObject objectOfType:GT_STRING frame:NSMakeRect(4, maxY, MAX(dd.w - 8, 40), 20)];
              item.text = @"  Item  ";
              item.flags = OF_SELECTABLE;
              [dd.children addObject:item];
              dd.h = maxY + 24; // grow the dropdown box to fit
            }];
    [self refreshAll];
    if (item)
        [_doc setSelectionObjects:@[ item ]];
    }

- (void)deleteTree:(id)sender
    {
    if (_doc.resource.trees.count <= 1)
        {
        [self alert:@"A resource must keep at least one tree."];
        return;
        }
    int idx = _doc.currentTreeIndex;
    [_doc perform:@"Delete Tree"
            block:^{
              [_doc.resource.trees removeObjectAtIndex:idx];
              // keep popup→tree links valid: drop links to the removed tree, shift the rest
              for (GTree* t in _doc.resource.trees)
                  [t.root preorder:^(GObject* o) {
                    if (o.type != GT_POPUP)
                        return;
                    if (o.extType == idx)
                        o.extType = 0;
                    else if (o.extType > idx)
                        o.extType -= 1;
                  }];
            }];
    _doc.currentTreeIndex = MIN(idx, (int)_doc.resource.trees.count - 1);
    [_doc clearSelection];
    [self refreshAll];
    }

// MARK: helpers

- (GTree*)tree
    {
    return _doc.tree;
    }
- (GObject*)parentOf:(GObject*)o
    {
    return [_doc.tree parentOf:o] ?: _doc.tree.root;
    }

// MARK: File

- (void)newDocument:(id)sender
    {
    [_doc setSelectionObjects:@[]];
    _doc.resource = [GResource emptyDialog];
    _doc.url = nil;
    self.window.title = @"Rocks — Untitled";
    [_undo removeAllActions];
    [self refreshAll];
    }

- (void)openDocument:(id)sender
    {
    NSOpenPanel* p = [NSOpenPanel openPanel];
    p.allowedFileTypes = @[ @"gemproj", @"json", @"rsc", @"rsrc" ];
    if ([p runModal] != NSModalResponseOK)
        return;
    [self openURL:p.URLs.firstObject];
    }

- (void)openFileAtPath:(NSString*)path
    {
    [self openURL:[NSURL fileURLWithPath:path.stringByExpandingTildeInPath]];
    }

- (void)openURL:(NSURL*)u
    {
    NSData* d = [NSData dataWithContentsOfURL:u];
    NSString* ext = u.pathExtension.lowercaseString;
    NSString* err = nil;
    GResource* r;
    if ([ext isEqualToString:@"rsc"] || [ext isEqualToString:@"rsrc"])
        {
        r = d ? GRscRead(d, &err) : nil;
        }
    else
        {
        r = d ? GResourceFromJSON(d) : nil;
        if (!r)
            err = @"Could not open project.";
        }
    if (!r)
        {
        [self alert:err ?: @"Could not open file."];
        return;
        }
    _doc.resource = r;
    _doc.url = [ext isEqualToString:@"gemproj"] ? u : nil;
    [_doc setSelectionObjects:@[]];
    self.window.title = [@"Rocks — " stringByAppendingString:u.lastPathComponent];
    [_undo removeAllActions];
    [self refreshAll];
    }

- (void)saveDocument:(id)sender
    {
    NSSavePanel* p = [NSSavePanel savePanel];
    p.allowedFileTypes = @[ @"gemproj" ];
    p.nameFieldStringValue = _doc.url ? _doc.url.lastPathComponent : @"resource.gemproj";
    if ([p runModal] != NSModalResponseOK)
        return;
    NSData* json = GResourceToJSON(_doc.resource);
    [json writeToURL:p.URL atomically:YES];
    _doc.url = p.URL;
    self.window.title = [@"Rocks — " stringByAppendingString:p.URL.lastPathComponent];
    }

- (void)importRsc:(id)sender
    {
    NSOpenPanel* p = [NSOpenPanel openPanel];
    p.allowedFileTypes = @[ @"rsc", @"rsrc" ];
    if ([p runModal] != NSModalResponseOK)
        return;
    NSData* d = [NSData dataWithContentsOfURL:p.URLs.firstObject];
    NSString* err = nil;
    GResource* r = d ? GRscRead(d, &err) : nil;
    if (!r)
        {
        [self alert:err ?: @"Could not read .rsc file."];
        return;
        }
    NSString* warn = GRscLastImportWarning();
    _doc.resource = r;
    _doc.url = nil;
    [_doc setSelectionObjects:@[]];
    if (warn)
        [self alert:warn];
    self.window.title = [@"Rocks — " stringByAppendingString:p.URLs.firstObject.lastPathComponent];
    [_undo removeAllActions];
    [self refreshAll];
    }

- (void)exportRsc:(id)sender
    {
    NSSavePanel* p = [NSSavePanel savePanel];
    p.allowedFileTypes = @[ @"rsc" ];
    p.nameFieldStringValue = @"resource.rsc";
    if ([p runModal] != NSModalResponseOK)
        return;
    NSString* err = nil;
    NSData* d = GRscWrite(_doc.resource, &err);
    if (!d)
        {
        [self alert:err ?: @"Export failed."];
        return;
        }
    [d writeToURL:p.URL atomically:YES];
    }

// MARK: alerts
//
// A GEM alert is a form_alert string, not an OBJECT tree, so it lives in the
// free-string table and exports as a #define like any other free string.

- (void)newAlert:(id)sender
    {
    _alertWizard = [[AlertWizard alloc] initWithDocument:_doc editingIndex:-1];
    [_alertWizard showWindow:nil];
    }

- (void)editAlerts:(id)sender
    {
    // offer the free strings that actually look like alerts
    NSMutableArray<NSNumber*>* idxs = [NSMutableArray array];
    NSMenu* menu = [[NSMenu alloc] init];
    NSArray<NSString*>* fs = _doc.resource.freeStrings;
    for (int i = 0; i < (int)fs.count; i++)
        {
        if (![GAlert looksLikeAlert:fs[i]])
            continue;
        [idxs addObject:@(i)];
        GAlert* a = [GAlert alertFromString:fs[i]];
        NSString* title = a.lines.firstObject.length ? a.lines.firstObject : fs[i];
        NSMenuItem* it = [menu addItemWithTitle:[NSString stringWithFormat:@"%d — %@", i, title]
                                         action:@selector(editAlertPicked:)
                                  keyEquivalent:@""];
        it.target = self;
        it.tag = i;
        }
    if (!menu.numberOfItems)
        {
        [self alert:@"This resource has no alert strings yet. Use Object ▸ New Alert… to make one."];
        return;
        }
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(60, 60) inView:_canvas];
    }

- (void)editAlertPicked:(NSMenuItem*)item
    {
    _alertWizard = [[AlertWizard alloc] initWithDocument:_doc editingIndex:(int)item.tag];
    [_alertWizard showWindow:nil];
    }

// MARK: source export
//
// Same emitters rockscli uses, so the File menu and a Makefile produce identical
// output. See GExport.h.

// The output base name: from the project's own name when it has one.
- (NSString*)exportStem
    {
    NSString* s = _doc.url.lastPathComponent.stringByDeletingPathExtension;
    return s.length ? s : @"resource";
    }

- (BOOL)writeText:(NSString*)text to:(NSString*)path
    {
    NSError* e = nil;
    if ([text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&e])
        return YES;
    [self alert:e.localizedDescription ?: @"Could not write the file."];
    return NO;
    }

- (void)exportCSource:(id)sender
    {
    NSSavePanel* p = [NSSavePanel savePanel];
    p.allowedFileTypes = @[ @"h" ];
    p.nameFieldStringValue = [[self exportStem] stringByAppendingPathExtension:@"h"];
    p.message = @"Writes a .h of symbolic names and a .c of the object trees.";
    if ([p runModal] != NSModalResponseOK)
        return;

    NSString* stem = p.URL.path.stringByDeletingPathExtension;
    NSString* base = stem.lastPathComponent;
    if ([self writeText:GExportHeader(_doc.resource, base)
                     to:[stem stringByAppendingPathExtension:@"h"]])
        [self writeText:GExportCSource(_doc.resource, base)
                     to:[stem stringByAppendingPathExtension:@"c"]];
    }

- (void)exportXtc:(id)sender
    {
    NSSavePanel* p = [NSSavePanel savePanel];
    p.allowedFileTypes = @[ @"xt" ];
    p.nameFieldStringValue = [[self exportStem] stringByAppendingPathExtension:@"xt"];
    p.message = @"Writes an .xt holding the trees and a fixup to call at start-up.";
    if ([p runModal] != NSModalResponseOK)
        return;

    NSString* stem = p.URL.path.stringByDeletingPathExtension;
    [self writeText:GExportXtc(_doc.resource, stem.lastPathComponent)
                 to:[stem stringByAppendingPathExtension:@"xt"]];
    }

- (void)alert:(NSString*)msg
    {
    NSAlert* a = [[NSAlert alloc] init];
    a.messageText = msg;
    [a runModal];
    }

// MARK: Edit

- (void)undo:(id)sender
    {
    if (_undo.canUndo)
        [_undo undo];
    }
- (void)redo:(id)sender
    {
    if (_undo.canRedo)
        [_undo redo];
    }

- (void)copyObject:(id)sender
    {
    NSMutableArray* copies = [NSMutableArray array];
    for (GObject* o in _doc.selection)
        if (o != _doc.tree.root)
            [copies addObject:[o deepCopy]];
    if (copies.count)
        _clipboard = copies;
    }
- (void)cutObject:(id)sender
    {
    [self copyObject:sender];
    [self deleteObject:sender];
    }

- (void)pasteObject:(id)sender
    {
    if (!_clipboard.count)
        return;
    NSMutableArray* added = [NSMutableArray array];
    GObject* parent = _doc.tree.root;
    [_doc perform:@"Paste"
            block:^{
              for (GObject* o in _clipboard)
                  {
                  GObject* c = [o deepCopy];
                  c.x += 8;
                  c.y += 8;
                  [parent.children addObject:c];
                  [added addObject:c];
                  }
            }];
    [_doc setSelectionObjects:added];
    }

- (void)duplicateObject:(id)sender
    {
    NSArray* sel = _doc.selection;
    if (!sel.count)
        return;
    NSMutableArray* added = [NSMutableArray array];
    [_doc perform:@"Duplicate"
            block:^{
              for (GObject* o in sel)
                  {
                  if (o == _doc.tree.root)
                      continue;
                  GObject* parent = [self parentOf:o];
                  GObject* c = [o deepCopy];
                  c.x += 8;
                  c.y += 8;
                  [parent.children addObject:c];
                  [added addObject:c];
                  }
            }];
    if (added.count)
        [_doc setSelectionObjects:added];
    }

- (void)deleteObject:(id)sender
    {
    NSArray* sel = _doc.selection;
    if (!sel.count)
        return;
    [_doc perform:@"Delete"
            block:^{
              for (GObject* o in sel)
                  {
                  if (o == _doc.tree.root)
                      continue;
                  GObject* parent = [_doc.tree parentOf:o];
                  [parent.children removeObject:o];
                  }
            }];
    [_doc setSelectionObjects:@[]];
    }

- (void)selectAllObjects:(id)sender
    {
    NSMutableArray* all = [NSMutableArray array];
    for (GObject* o in _doc.tree.allObjects)
        if (o != _doc.tree.root)
            [all addObject:o];
    [_doc setSelectionObjects:all];
    }

// MARK: Object — align / distribute / order

- (NSArray<GObject*>*)movable
    {
    NSMutableArray* m = [NSMutableArray array];
    for (GObject* o in _doc.selection)
        if (o != _doc.tree.root)
            [m addObject:o];
    return m;
    }

typedef void (^AlignBlock)(GObject* o, int minX, int minY, int maxX, int maxY);
- (void)alignLeft:(id)s
    {
    [self align:^(GObject* o, int a, int b, int c, int d) {
      o.x = a;
    }];
    }
- (void)alignRight:(id)s
    {
    [self align:^(GObject* o, int a, int b, int c, int d) {
      o.x = c - o.w;
    }];
    }
- (void)alignTop:(id)s
    {
    [self align:^(GObject* o, int a, int b, int c, int d) {
      o.y = b;
    }];
    }
- (void)alignBottom:(id)s
    {
    [self align:^(GObject* o, int a, int b, int c, int d) {
      o.y = d - o.h;
    }];
    }
- (void)alignCenterH:(id)s
    {
    [self align:^(GObject* o, int a, int b, int c, int d) {
      o.x = (a + c) / 2 - o.w / 2;
    }];
    }
- (void)alignCenterV:(id)s
    {
    [self align:^(GObject* o, int a, int b, int c, int d) {
      o.y = (b + d) / 2 - o.h / 2;
    }];
    }

- (void)align:(AlignBlock)fn
    {
    NSArray* objs = [self movable];
    if (objs.count < 2)
        return;
    int minX = INT_MAX, minY = INT_MAX, maxX = INT_MIN, maxY = INT_MIN;
    for (GObject* o in objs)
        {
        minX = MIN(minX, o.x);
        minY = MIN(minY, o.y);
        maxX = MAX(maxX, o.x + o.w);
        maxY = MAX(maxY, o.y + o.h);
        }
    [_doc perform:@"Align"
            block:^{
              for (GObject* o in objs)
                  fn(o, minX, minY, maxX, maxY);
            }];
    }

- (void)distributeH:(id)sender
    {
    [self distribute:YES];
    }
- (void)distributeV:(id)sender
    {
    [self distribute:NO];
    }
- (void)distribute:(BOOL)horiz
    {
    NSArray* objs = [[self movable] sortedArrayUsingComparator:^NSComparisonResult(GObject* a, GObject* b) {
      int av = horiz ? a.x : a.y, bv = horiz ? b.x : b.y;
      return av < bv ? NSOrderedAscending : av > bv ? NSOrderedDescending
                                                    : NSOrderedSame;
    }];
    if (objs.count < 3)
        return;
    GObject *first = objs.firstObject, *last = objs.lastObject;
    int start = horiz ? first.x : first.y;
    int end = horiz ? last.x : last.y;
    int gap = (end - start) / (int)(objs.count - 1);
    [_doc perform:@"Distribute"
            block:^{
              for (int i = 1; i < (int)objs.count - 1; i++)
                  {
                  GObject* o = objs[i];
                  if (horiz)
                      o.x = start + gap * i;
                  else
                      o.y = start + gap * i;
                  }
            }];
    }

- (void)bringToFront:(id)sender
    {
    [self reorderToFront:YES];
    }
- (void)sendToBack:(id)sender
    {
    [self reorderToFront:NO];
    }
- (void)reorderToFront:(BOOL)front
    {
    NSArray* objs = [self movable];
    if (!objs.count)
        return;
    [_doc perform:(front ? @"Bring to Front" : @"Send to Back")
            block:^{
              for (GObject* o in objs)
                  {
                  GObject* parent = [self parentOf:o];
                  if (![parent.children containsObject:o])
                      continue;
                  [parent.children removeObject:o];
                  if (front)
                      [parent.children addObject:o];
                  else
                      [parent.children insertObject:o atIndex:0];
                  }
            }];
    }

// MARK: View

// Test-drive: the canvas behaves like the AES instead of like an editor (GForm.h).
// Clicking a check box or typing in a field really does mutate the objects, so we
// snapshot the resource on the way in and put it back on the way out — the
// document is untouched and the undo stack never sees any of it.
- (void)toggleTestDrive:(id)sender
    {
    BOOL on = !_canvas.testMode;
    if (on)
        {
        _testSnapshot = [_doc snapshot];
        }
    else if (_testSnapshot)
        {
        _doc.resource = GResourceFromJSON(_testSnapshot);
        _testSnapshot = nil;
        [_doc setSelectionObjects:@[]];
        [self refreshAll];
        }
    _canvas.testMode = on;
    [(NSMenuItem*)sender setState:on ? NSControlStateValueOn : NSControlStateValueOff];
    _inspector.hidden = on; // its fields would edit objects the restore then discards
    [self.window makeFirstResponder:_canvas];
    _canvas.needsDisplay = YES;
    }

- (void)toggleSnap:(id)sender
    {
    _canvas.snapEnabled = !_canvas.snapEnabled;
    [(NSMenuItem*)sender setState:_canvas.snapEnabled ? NSControlStateValueOn : NSControlStateValueOff];
    _canvas.needsDisplay = YES;
    }
- (void)toggleGuides:(id)sender
    {
    _canvas.showGuides = !_canvas.showGuides;
    [(NSMenuItem*)sender setState:_canvas.showGuides ? NSControlStateValueOn : NSControlStateValueOff];
    }
- (void)zoomIn:(id)sender
    {
    _canvas.scale = MIN(_canvas.scale * 1.25, 8);
    [_canvas refresh];
    }
- (void)zoomOut:(id)sender
    {
    _canvas.scale = MAX(_canvas.scale / 1.25, 0.5);
    [_canvas refresh];
    }
// true 1:1 pixels
- (void)zoomActual:(id)sender
    {
    _canvas.scale = 1.0;
    [_canvas refresh];
    }

- (void)dealloc
    {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
@end
