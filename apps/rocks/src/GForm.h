// GForm.h — AES form behaviour, with no view attached.
//
// This is what `form_do` does to an OBJECT tree: clicking selects, radio groups
// stay exclusive, exit buttons report themselves, and editable fields accept
// typing through their TEDINFO template (te_ptmplt) and validation mask
// (te_pvalid).  CanvasView drives it in test-drive mode; keeping it separate
// means the semantics can be exercised without a window (see --formtest).
//
// Everything here mutates the objects in place (ob_state, te_ptext).  Test-drive
// mode snapshots the resource before it starts and restores it on the way out,
// so nothing a click does here ever reaches the document or the undo stack.

#import <Foundation/Foundation.h>
#import "GModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface GForm : NSObject

// ---- queries ----
+ (BOOL)isDisabled:(GObject*)o;
+ (BOOL)isEditable:(GObject*)o; // OF_EDITABLE + carries a TEDINFO
+ (BOOL)isRadio:(GObject*)o;    // OF_RBUTTON, or a G_RADIO widget
// Tab order: pre-order, which is the order the AES itself walks the tree.
+ (NSArray<GObject*>*)editableObjectsIn:(GTree*)tree;
// Editable slots in the template ('_' positions). 0 = free text, no template.
+ (int)slotCountOf:(GObject*)o;
+ (nullable GObject*)objectWithFlag:(GFlags)flag in:(GTree*)tree; // OF_DEFAULT / OF_CANCEL

// ---- mouse ----
// A click that has gone down but not yet come up. Returns the object to draw
// held-down, or nil. OF_TOUCHEXIT fires on the way down, so *exit may be set here.
+ (nullable GObject*)pressed:(nullable GObject*)o
                      inTree:(GTree*)tree
                        exit:(GObject* _Nullable* _Nonnull)exit;
// The click completing on `o` (nil if released outside the pressed object).
// Applies selection/radio/toggle semantics and reports an exit object, if any.
+ (nullable GObject*)released:(nullable GObject*)o inTree:(GTree*)tree;

// ---- keyboard ----
// Insert one typed character, honouring te_pvalid. Returns NO if the mask
// rejected it or the field is full. `caret` is a slot index and is advanced.
+ (BOOL)insert:(unichar)c into:(GObject*)o caret:(int*)caret;
+ (BOOL)deleteBackwardIn:(GObject*)o caret:(int*)caret;
+ (BOOL)deleteForwardIn:(GObject*)o caret:(int*)caret;

// The validation mask applied to one slot: returns the character to store
// (possibly case-folded), or 0 if the mask rejects it.
+ (unichar)validate:(unichar)c slot:(int)slot in:(GObject*)o;

@end

NS_ASSUME_NONNULL_END
