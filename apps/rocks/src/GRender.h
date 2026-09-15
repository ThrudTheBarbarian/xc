// GRender.h — draw a GEM OBJECT tree into the current graphics context.
// Coordinates are model space (top-left origin); use inside a flipped view.

#import <AppKit/AppKit.h>
#import "GModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface GRender : NSObject
// VDI pen index (0..15) -> NSColor (classic GEM 16-colour palette).
+ (NSColor*)penColor:(int)index;
// Draw the whole tree at its absolute model coordinates.
+ (void)drawTree:(GTree*)tree;
// Draw the tree, skipping any object in `hidden` (and its subtree).
+ (void)drawTree:(GTree*)tree hidden:(nullable NSSet<GObject*>*)hidden;
// Draw a menu tree: the bar plus only the active title's dropdown.
+ (void)drawMenuTree:(GTree*)tree activeIndex:(int)active;
// Draw a single object's chrome at absolute origin (used for drag previews).
+ (void)drawObject:(GObject*)o at:(NSPoint)origin;

// Test-drive mode: show a text caret in `o` at template slot `slot`.  Pass nil
// to clear it.  The caret is drawn only for the object set here.
+ (void)setEditCaretObject:(nullable GObject*)o slot:(int)slot;
@end

NS_ASSUME_NONNULL_END
