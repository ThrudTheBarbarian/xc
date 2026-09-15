// GForm.m — see GForm.h.  The AES form_do rules, with no view attached.

#import "GForm.h"

@implementation GForm

// ---- queries ---------------------------------------------------------------

+ (BOOL)isDisabled:(GObject*)o
    {
    return (o.state & OS_DISABLED) != 0;
    }

+ (BOOL)isEditable:(GObject*)o
    {
    return (o.flags & OF_EDITABLE) && [o hasTedinfo] && ![self isDisabled:o];
    }

// The AES marks radio buttons with OF_RBUTTON.  Rocks' themed G_RADIO widget is
// one by construction, whether or not the flag was set in the editor.
+ (BOOL)isRadio:(GObject*)o
    {
    return (o.flags & OF_RBUTTON) || o.type == GT_RADIO;
    }

+ (NSArray<GObject*>*)editableObjectsIn:(GTree*)tree
    {
    NSMutableArray* out = [NSMutableArray array];
    [tree.root preorder:^(GObject* o) {
      if ((o.flags & OF_HIDETREE) && o != tree.root)
          return;
      if ([self isEditable:o])
          [out addObject:o];
    }];
    return out;
    }

+ (int)slotCountOf:(GObject*)o
    {
    NSString* t = o.ted.tmplt ?: @"";
    int n = 0;
    for (NSUInteger i = 0; i < t.length; i++)
        if ([t characterAtIndex:i] == '_')
            n++;
    return n;
    }

+ (GObject*)objectWithFlag:(GFlags)flag in:(GTree*)tree
    {
    __block GObject* found = nil;
    [tree.root preorder:^(GObject* o) {
      if (found || o == tree.root)
          return; // the flag on the root is not a button
      if ((o.flags & flag) && ![self isDisabled:o])
          found = o;
    }];
    return found;
    }

// ---- mouse -----------------------------------------------------------------

// Whether clicking this object leaves the form at all.
static BOOL isExit(GObject* o)
    {
    return (o.flags & (OF_EXIT | OF_TOUCHEXIT)) != 0;
    }

// A momentary control lights while held and clears on release — a push button.
// Being a radio wins: real resources routinely mark radios OF_TOUCHEXIT (so the
// app can react at once) and they must still latch, not flash.  Order matters.
static BOOL isMomentary(GObject* o)
    {
    return isExit(o) && !((o.flags & OF_RBUTTON) || o.type == GT_RADIO);
    }

+ (void)clearRadioPeersOf:(GObject*)o inTree:(GTree*)tree
    {
    GObject* parent = [tree parentOf:o] ?: tree.root;
    for (GObject* sib in parent.children)
        if (sib != o && [self isRadio:sib])
            sib.state &= ~OS_SELECTED;
    }

// The selection effect of a completed click, independent of any exit.
+ (void)applyClickTo:(GObject*)o inTree:(GTree*)tree
    {
    if (!(o.flags & OF_SELECTABLE))
        return; // a plain label: nothing latches
    if ([self isRadio:o])
        {
        [self clearRadioPeersOf:o inTree:tree];
        o.state |= OS_SELECTED; // radios latch on; never off
        }
    else if (isMomentary(o))
        {
        o.state &= ~OS_SELECTED; // push button: highlight lets go
        }
    else
        {
        o.state ^= OS_SELECTED; // check box: latches and toggles
        }
    }

+ (GObject*)pressed:(GObject*)o inTree:(GTree*)tree exit:(GObject**)exit
    {
    *exit = nil;
    if (!o || o == tree.root || [self isDisabled:o])
        return nil;

    // OF_TOUCHEXIT leaves the form the moment it is touched, without waiting for
    // the button to come back up — but the AES still applies the click first, so
    // a TOUCHEXIT radio ends up selected.
    if (o.flags & OF_TOUCHEXIT)
        {
        [self applyClickTo:o inTree:tree];
        *exit = o;
        return nil;
        }
    if (isMomentary(o) && (o.flags & OF_SELECTABLE))
        {
        o.state |= OS_SELECTED; // held down
        return o;
        }
    return ((o.flags & OF_SELECTABLE) || [self isEditable:o]) ? o : nil;
    }

+ (GObject*)released:(GObject*)o inTree:(GTree*)tree
    {
    if (!o || o == tree.root || [self isDisabled:o])
        return nil;
    if (!(o.flags & OF_SELECTABLE) && ![self isEditable:o])
        return nil;
    [self applyClickTo:o inTree:tree];
    return isExit(o) ? o : nil;
    }

// ---- text editing ----------------------------------------------------------

static BOOL charIn(unichar c, const char* set)
    {
    for (const char* p = set; *p; p++)
        if ((unichar)*p == c)
            return YES;
    return NO;
    }
static BOOL isDigit(unichar c)
    {
    return c >= '0' && c <= '9';
    }
static BOOL isUpper(unichar c)
    {
    return c >= 'A' && c <= 'Z';
    }
static BOOL isLower(unichar c)
    {
    return c >= 'a' && c <= 'z';
    }
static BOOL isAlpha(unichar c)
    {
    return isUpper(c) || isLower(c);
    }

// DOS-ish filename / path character sets, as GEM's 'F' and 'P' masks use them.
static const char* kFileExtra = "_^$~!#%&-{}()@'`.?*";
static const char* kPathExtra = "_^$~!#%&-{}()@'`.?*\\:/";

+ (unichar)validate:(unichar)c slot:(int)slot in:(GObject*)o
    {
    if (c < 0x20 || c == 0x7F)
        return 0; // no control characters
    NSString* valid = o.ted.valid;
    if (!valid.length)
        return c; // no mask: accept anything printable

    // One mask character per slot.  Where the mask is shorter than the template
    // (common in hand-built resources) the last one governs the rest.
    NSUInteger vi = MIN((NSUInteger)MAX(slot, 0), valid.length - 1);
    unichar m = [valid characterAtIndex:vi];
    unichar up = isLower(c) ? (unichar)(c - 'a' + 'A') : c;

    switch (m)
        {
    case '9':
        return isDigit(c) ? c : 0;
    case 'A':
        return (isAlpha(c) || c == ' ') ? up : 0; // upper-case variants fold
    case 'a':
        return (isAlpha(c) || c == ' ') ? c : 0;
    case 'N':
        return (isAlpha(c) || isDigit(c) || c == ' ') ? up : 0;
    case 'n':
        return (isAlpha(c) || isDigit(c) || c == ' ') ? c : 0;
    case 'F':
        return (isAlpha(c) || isDigit(c) || charIn(c, kFileExtra)) ? up : 0;
    case 'f':
        return (isAlpha(c) || isDigit(c) || charIn(c, kFileExtra)) ? c : 0;
    case 'P':
        return (isAlpha(c) || isDigit(c) || charIn(c, kPathExtra)) ? up : 0;
    case 'p':
        return (isAlpha(c) || isDigit(c) || charIn(c, kPathExtra)) ? c : 0;
    case 'X':
        return up;
    case 'x':
    default:
        return c;
        }
    }

+ (BOOL)insert:(unichar)c into:(GObject*)o caret:(int*)caret
    {
    if (![self isEditable:o])
        return NO;
    GTedinfo* t = o.ted;
    NSMutableString* txt = [(t.text ?: @"") mutableCopy];
    int slots = [self slotCountOf:o];
    int pos = MAX(0, MIN(*caret, (int)txt.length));

    if (slots > 0 && (int)txt.length >= slots)
        return NO; // the template is full
    unichar ok = [self validate:c slot:pos in:o];
    if (!ok)
        return NO;

    [txt insertString:[NSString stringWithCharacters:&ok length:1] atIndex:pos];
    t.text = txt;
    *caret = pos + 1;
    return YES;
    }

+ (BOOL)deleteBackwardIn:(GObject*)o caret:(int*)caret
    {
    if (![self isEditable:o])
        return NO;
    GTedinfo* t = o.ted;
    NSMutableString* txt = [(t.text ?: @"") mutableCopy];
    int pos = MAX(0, MIN(*caret, (int)txt.length));
    if (pos == 0)
        return NO;
    [txt deleteCharactersInRange:NSMakeRange(pos - 1, 1)];
    t.text = txt;
    *caret = pos - 1;
    return YES;
    }

+ (BOOL)deleteForwardIn:(GObject*)o caret:(int*)caret
    {
    if (![self isEditable:o])
        return NO;
    GTedinfo* t = o.ted;
    NSMutableString* txt = [(t.text ?: @"") mutableCopy];
    int pos = MAX(0, MIN(*caret, (int)txt.length));
    if (pos >= (int)txt.length)
        return NO;
    [txt deleteCharactersInRange:NSMakeRange(pos, 1)];
    t.text = txt;
    return YES;
    }

@end
