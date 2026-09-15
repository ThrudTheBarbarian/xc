// Document.h — editor state: resource, current tree, selection, undo.

#import "GModel.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString* const GModelChangedNotification; // structure/geometry changed
extern NSString* const GSelectionChangedNotification;

@interface Document : NSObject
@property(strong) GResource* resource;
@property int currentTreeIndex;
@property(nullable, copy) NSURL* url;
@property(weak) NSUndoManager* undoManager;
@property(readonly) NSArray<GObject*>* selection; // ordered, unique; first = anchor

- (instancetype)initWithResource:(GResource*)r;
- (GTree*)tree;
- (nullable GObject*)anchor;
- (BOOL)isSelected:(GObject*)o;

- (void)setSelectionObjects:(NSArray<GObject*>*)objs;
- (void)select:(GObject*)o extend:(BOOL)extend;
- (void)clearSelection;

// Perform an undoable edit.  Snapshots the whole resource (documents are small)
// so undo is always correct; selection is re-derived after undo.
- (void)perform:(NSString*)name block:(void (^)(void))block;

// For live drags: snapshot before, mutate directly, then commit once at the end.
- (NSData*)snapshot;
- (void)commit:(NSString*)name from:(NSData*)before;

- (void)notifyModel;
- (void)notifySelection;
@end

NS_ASSUME_NONNULL_END
