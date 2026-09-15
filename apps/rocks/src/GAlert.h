// GAlert.h — a GEM alert: form_alert's string, parsed, rendered and formatted.
//
// An alert is not an OBJECT tree.  It is a *string*, which an app fetches with
// rsrc_gaddr(R_STRING, i) and hands to form_alert(), and the AES builds the
// dialog from it at run time:
//
//      [icon][line|line|line][button|button]
//
//   icon     0 none, 1 note, 2 wait, 3 stop  (the theme has all three)
//   lines    up to 5, up to ~30 characters each
//   buttons  1 to 3, up to ~10 characters each
//
// So alerts live in the resource's free-string table, and export as
// #define STR_… like any other free string.  The default button is NOT part of
// the string — it is form_alert's first argument — but the wizard tracks it so
// the preview can show which button GEM would outline.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int, GAlertIcon) {
    GAlertNone = 0,
    GAlertNote = 1,
    GAlertWait = 2,
    GAlertStop = 3
};

@interface GAlert : NSObject
@property GAlertIcon icon;
@property(copy) NSArray<NSString*>* lines;   // 1..5
@property(copy) NSArray<NSString*>* buttons; // 1..3
@property int defaultButton;                 // 1-based; form_alert's argument

// Parse "[1][Delete this file?|It cannot be undone][Cancel|OK]".  Returns nil if
// the string is not an alert.  Tolerant: missing brackets/sections are defaulted.
+ (nullable instancetype)alertFromString:(NSString*)s;
+ (BOOL)looksLikeAlert:(NSString*)s;

// The canonical form_alert string.
- (NSString*)stringValue;

// Draw the alert the way the AES lays it out — icon left, text, buttons along the
// bottom — using the theme's alert icons and button slices.
- (NSSize)preferredSize;
- (void)drawInRect:(NSRect)r;
@end

NS_ASSUME_NONNULL_END
