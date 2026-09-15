// AlertWizard.h — compose a GEM alert and see it as the AES would draw it.
//
// An alert is just a form_alert string (see GAlert.h), so the wizard's output is
// a free string: it is added to the resource's free-string table and exports as
// #define STR_… like any other.  Existing alert strings can be picked up and
// edited again.

#import <AppKit/AppKit.h>
#import "Document.h"

NS_ASSUME_NONNULL_BEGIN

@interface AlertWizard : NSWindowController
// `index` is a free-string index to edit, or -1 to compose a new one.
- (instancetype)initWithDocument:(Document*)doc editingIndex:(int)index;
@end

NS_ASSUME_NONNULL_END
