// CanvasView.h — the WYSIWYG drag/drop work area.

#import <AppKit/AppKit.h>
#import "Document.h"

NS_ASSUME_NONNULL_BEGIN

// Drag pasteboard type carrying a palette widget's GObType (as a number string).
extern NSPasteboardType const GPaletteDragType;

@interface CanvasView : NSView
@property(weak) Document* doc;
@property CGFloat scale;
@property BOOL showGrid;
@property BOOL snapEnabled;
@property BOOL showGuides;
@property int gridSize;
// Test-drive: the canvas stops editing the tree and starts behaving like the AES
// (see GForm.h). The caller snapshots the resource before turning this on and
// restores it after, so nothing done here reaches the document or the undo stack.
@property(nonatomic) BOOL testMode;
- (void)resetTestDrive; // clear focus/highlight and the last exit result
- (void)refresh;        // model changed: resize + redraw
- (void)sizeToFitModel;
- (void)reparentByGeometry; // re-derive containment hierarchy from geometry
// menu editing context (the currently-shown title / its dropdown)
- (GObject*)activeMenuTitle;
- (GObject*)activeMenuDropdown;
- (void)setActiveMenuTitle:(GObject*)t;
@end

NS_ASSUME_NONNULL_END
