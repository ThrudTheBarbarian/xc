// GRsc.h — classic GEM .rsc binary reader/writer.
//
// Read: parses standard .rsc files produced by other editors (Interface, ORCS,
// WERCS, RCS…) — big-endian by default with a little-endian fallback, classic
// RSHDR + OBJECT + TEDINFO + ICONBLK + free strings + tree index, char/pixel
// packed coordinates unpacked to pixels.
//
// Write: emits a classic big-endian .rsc with packed coordinates so the same
// tools can read it back; extended XT GEM widgets (G_CHECKBOX..G_CICON) keep
// their type numbers, and G_CICON colour icons embed a P7 PAM blob.

#import "GModel.h"

NS_ASSUME_NONNULL_BEGIN

GResource* _Nullable GRscRead(NSData* data, NSString* _Nullable* _Nullable err);
NSData* _Nullable GRscWrite(GResource* r, NSString* _Nullable* _Nullable err);

// After a GRscRead, whatever the file carried that Rocks does not yet preserve
// (BITBLKs, free images).  nil when the import was lossless.  An import must
// never be silently lossy.
NSString* _Nullable GRscLastImportWarning(void);

// Rocks stamps a signature as the LAST free string:
//
//     RoCkS;v=<editor version>;f=<file format version>
//
// Last, not first, because free strings are indexed — rsrc_gaddr(R_STRING, i) —
// so prepending one would shift every index an app already relies on.  It is
// stripped on read, so it never shows up as a user string or in the export.
// After a GRscRead this says what wrote the file, or nil.
extern NSString* const GRscSignaturePrefix;
NSString* _Nullable GRscLastSignature(void); // e.g. "RoCkS;v=1.0;f=1"
int GRscLastFileVersion(void);               // the f= value, or 0

NS_ASSUME_NONNULL_END
