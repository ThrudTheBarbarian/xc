// Document.m — see Document.h.

#import "Document.h"
#import "GProject.h"

NSString* const GModelChangedNotification = @"GModelChanged";
NSString* const GSelectionChangedNotification = @"GSelectionChanged";

@interface Document ()
@property(strong) NSMutableArray<GObject*>* sel;
@end

@implementation Document

- (instancetype)initWithResource:(GResource*)r
    {
    if ((self = [super init]))
        {
        _resource = r ?: [GResource emptyDialog];
        _sel = [NSMutableArray array];
        _currentTreeIndex = 0;
        }
    return self;
    }

- (NSArray<GObject*>*)selection
    {
    return [_sel copy];
    }

- (GTree*)tree
    {
    int i = MIN(_currentTreeIndex, (int)_resource.trees.count - 1);
    return _resource.trees[MAX(i, 0)];
    }

- (GObject*)anchor
    {
    return _sel.firstObject;
    }
- (BOOL)isSelected:(GObject*)o
    {
    return [_sel containsObject:o];
    }

- (void)setSelectionObjects:(NSArray<GObject*>*)objs
    {
    NSMutableArray* out = [NSMutableArray array];
    for (GObject* o in objs)
        if (![out containsObject:o])
            [out addObject:o];
    _sel = out;
    [self notifySelection];
    }
- (void)select:(GObject*)o extend:(BOOL)extend
    {
    if (extend)
        {
        if ([_sel containsObject:o])
            [_sel removeObject:o];
        else
            [_sel addObject:o];
        }
    else
        {
        _sel = [NSMutableArray arrayWithObject:o];
        }
    [self notifySelection];
    }
- (void)clearSelection
    {
    _sel = [NSMutableArray array];
    [self notifySelection];
    }

- (void)notifyModel
    {
    [[NSNotificationCenter defaultCenter] postNotificationName:GModelChangedNotification object:self];
    }
- (void)notifySelection
    {
    [[NSNotificationCenter defaultCenter] postNotificationName:GSelectionChangedNotification object:self];
    }

- (void)perform:(NSString*)name block:(void (^)(void))block
    {
    NSData* before = GResourceToJSON(_resource);
    block();
    NSData* after = GResourceToJSON(_resource);
    if (before && after && ![before isEqualToData:after])
        {
        [self registerUndo:name snapshot:before];
        }
    [self notifyModel];
    }

- (NSData*)snapshot
    {
    return GResourceToJSON(_resource);
    }

- (void)commit:(NSString*)name from:(NSData*)before
    {
    NSData* after = GResourceToJSON(_resource);
    if (before && after && ![before isEqualToData:after])
        {
        [self registerUndo:name snapshot:before];
        }
    [self notifyModel];
    }

- (void)registerUndo:(NSString*)name snapshot:(NSData*)snapshot
    {
    [_undoManager registerUndoWithTarget:self
                                 handler:^(Document* doc) {
                                   NSData* redoSnap = GResourceToJSON(doc.resource);
                                   GResource* restored = GResourceFromJSON(snapshot);
                                   if (restored)
                                       {
                                       doc.resource = restored;
                                       doc.sel = [NSMutableArray array]; // identities changed
                                       doc.currentTreeIndex = MIN(doc.currentTreeIndex, (int)restored.trees.count - 1);
                                       [doc notifyModel];
                                       [doc notifySelection];
                                       if (redoSnap)
                                           [doc registerUndo:name snapshot:redoSnap];
                                       }
                                 }];
    [_undoManager setActionName:name];
    }
@end
