// OutlineController.m — see OutlineController.h.

#import "OutlineController.h"

// Outline view that forwards Delete/Backspace to the standard delete action.
@interface GOutlineView : NSOutlineView
@end
@implementation GOutlineView
- (void)keyDown:(NSEvent*)e
    {
    unichar k = e.charactersIgnoringModifiers.length ? [e.charactersIgnoringModifiers characterAtIndex:0] : 0;
    if (k == 127 || k == 8 || k == NSDeleteFunctionKey)
        {
        [NSApp sendAction:@selector(deleteObject:) to:nil from:self];
        return;
        }
    [super keyDown:e];
    }
@end

// Row view that always draws the emphasized (blue) selection, so a selection
// made from the canvas still reads clearly even when the outline isn't focused.
@interface GRowView : NSTableRowView
@end
@implementation GRowView
- (BOOL)isEmphasized
    {
    return YES;
    }
@end

@interface OutlineController () <NSOutlineViewDataSource, NSOutlineViewDelegate>
@end

@implementation OutlineController
    {
    NSScrollView* _scroll;
    NSOutlineView* _ov;
    BOOL _syncing;
    }

- (instancetype)initWithDocument:(Document*)doc
    {
    if ((self = [super init]))
        {
        _doc = doc;
        _scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
        _scroll.hasVerticalScroller = YES;
        _scroll.drawsBackground = YES;
        _scroll.backgroundColor = [NSColor colorWithWhite:0.18 alpha:1];
        _ov = [[GOutlineView alloc] initWithFrame:_scroll.bounds];
        NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:@"c"];
        col.width = 180;
        [_ov addTableColumn:col];
        _ov.outlineTableColumn = col;
        _ov.headerView = nil;
        _ov.rowSizeStyle = NSTableViewRowSizeStyleSmall;
        _ov.backgroundColor = [NSColor colorWithWhite:0.18 alpha:1];
        _ov.dataSource = self;
        _ov.delegate = self;
        _ov.allowsMultipleSelection = YES;
        _scroll.documentView = _ov;
        }
    return self;
    }

- (NSView*)view
    {
    return _scroll;
    }
- (void)reload
    {
    [_ov reloadData];
    [_ov expandItem:nil expandChildren:YES];
    [self syncSelection];
    }

- (void)syncSelection
    {
    _syncing = YES;
    NSMutableIndexSet* idx = [NSMutableIndexSet indexSet];
    for (GObject* o in self.doc.selection)
        {
        NSInteger r = [_ov rowForItem:o];
        if (r >= 0)
            [idx addIndex:r];
        }
    [_ov selectRowIndexes:idx byExtendingSelection:NO];
    _syncing = NO;
    }

// data source
- (NSInteger)outlineView:(NSOutlineView*)ov numberOfChildrenOfItem:(id)item
    {
    if (!item)
        return 1; // the root
    return [(GObject*)item children].count;
    }
- (id)outlineView:(NSOutlineView*)ov child:(NSInteger)i ofItem:(id)item
    {
    if (!item)
        return self.doc.tree.root;
    return [(GObject*)item children][i];
    }
- (BOOL)outlineView:(NSOutlineView*)ov isItemExpandable:(id)item
    {
    return [(GObject*)item children].count > 0;
    }
- (id)outlineView:(NSOutlineView*)ov objectValueForTableColumn:(NSTableColumn*)c byItem:(id)item
    {
    GObject* o = item;
    NSString* extra = o.text.length ? o.text : (o.ted.text.length ? o.ted.text : (o.icon.label.length ? o.icon.label : @""));
    return extra.length ? [NSString stringWithFormat:@"%@  “%@”", GObTypeName(o.type), extra]
                        : GObTypeName(o.type);
    }
- (NSView*)outlineView:(NSOutlineView*)ov viewForTableColumn:(NSTableColumn*)col item:(id)item
    {
    NSTextField* tf = [ov makeViewWithIdentifier:@"cell" owner:self];
    if (!tf)
        {
        tf = [[NSTextField alloc] init];
        tf.identifier = @"cell";
        tf.bordered = NO;
        tf.editable = NO;
        tf.drawsBackground = NO;
        tf.font = [NSFont systemFontOfSize:11];
        tf.textColor = [NSColor colorWithWhite:0.9 alpha:1];
        }
    tf.stringValue = [self outlineView:ov objectValueForTableColumn:col byItem:item];
    return tf;
    }

- (NSTableRowView*)outlineView:(NSOutlineView*)ov rowViewForItem:(id)item
    {
    GRowView* rv = [ov makeViewWithIdentifier:@"row" owner:self];
    if (!rv)
        {
        rv = [[GRowView alloc] init];
        rv.identifier = @"row";
        }
    return rv;
    }

- (void)outlineViewSelectionDidChange:(NSNotification*)n
    {
    if (_syncing)
        return;
    NSMutableArray* objs = [NSMutableArray array];
    [_ov.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL* stop) {
      id it = [_ov itemAtRow:row];
      if (it)
          [objs addObject:it];
    }];
    [self.doc setSelectionObjects:objs];
    }
@end
