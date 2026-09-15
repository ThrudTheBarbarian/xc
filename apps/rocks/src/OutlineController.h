// OutlineController.h — NSOutlineView of the object tree, synced to selection.

#import <AppKit/AppKit.h>
#import "Document.h"

@interface OutlineController : NSObject
@property(weak) Document* doc;
@property(readonly) NSView* view;
- (instancetype)initWithDocument:(Document*)doc;
- (void)reload;
- (void)syncSelection;
@end
