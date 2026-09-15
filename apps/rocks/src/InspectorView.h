// InspectorView.h — the RHS property inspector bound to the current selection.

#import <AppKit/AppKit.h>
#import "Document.h"

@interface InspectorView : NSView
@property(weak) Document* doc;
- (void)rebuild; // selection changed
@end
