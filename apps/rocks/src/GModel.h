// GModel.h — in-memory GEM resource model (Objective-C).
//
// A resource is a list of named trees; each tree is a root OBJECT with nested
// children.  We keep the classic OBJECT fields plus the XT GEM extended
// widget types (G_CHECKBOX..G_CICON) and carry type-specific payloads on the
// node (string / TEDINFO / box colour word / icon).  The flat classic linked
// layout is rebuilt only at .rsc write time.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ---- Object types (classic + XT GEM extensions) -----------------------
typedef NS_ENUM(uint16_t, GObType) {
    GT_BOX = 20,
    GT_TEXT = 21,
    GT_BOXTEXT = 22,
    GT_IMAGE = 23,
    GT_USERDEF = 24,
    GT_IBOX = 25,
    GT_BUTTON = 26,
    GT_BOXCHAR = 27,
    GT_STRING = 28,
    GT_FTEXT = 29,
    GT_FBOXTEXT = 30,
    GT_ICON = 31,
    GT_TITLE = 32,
    // The standard Atari colour icon (a CICONBLK). Distinct from GT_CICON below,
    // which is Rocks' own RGBA PAM icon — see rsc.h.
    GT_CICONBLK = 33,
    // XT GEM themed extensions (aes/aes.h)
    GT_CHECKBOX = 40,
    GT_RADIO = 41,
    GT_POPUP = 42,
    GT_FIELD = 43,
    GT_CICON = 44
};

// ---- Flags / state ---------------------------------------------------------
typedef NS_OPTIONS(uint16_t, GFlags) {
    OF_NONE = 0x00,
    OF_SELECTABLE = 0x01,
    OF_DEFAULT = 0x02,
    OF_EXIT = 0x04,
    OF_EDITABLE = 0x08,
    OF_RBUTTON = 0x10,
    OF_LASTOB = 0x20,
    OF_TOUCHEXIT = 0x40,
    OF_HIDETREE = 0x80,
    OF_INDIRECT = 0x100,
    OF_SUBMENU = 0x800,
    // XT GEM runtime extensions (reuse freed 3D-flag bit positions)
    OF_CANCEL = 0x200,  // Esc fires this object (Cancel affordance)
    OF_MOVEABLE = 0x400 // on the tree ROOT: the dialog is movable
};
typedef NS_OPTIONS(uint16_t, GState) {
    OS_NORMAL = 0x00,
    OS_SELECTED = 0x01,
    OS_CROSSED = 0x02,
    OS_CHECKED = 0x04,
    OS_DISABLED = 0x08,
    OS_OUTLINED = 0x10,
    OS_SHADOWED = 0x20,
    OS_WHITEBAK = 0x40 // mnemonic present: bits 8-14 hold the shortcut char index
};
#define GS_MNEMONIC_INDEX(st) (((st) >> 8) & 0x7F)

typedef NS_ENUM(int, GTreeKind) { GK_DIALOG = 0,
                                  GK_MENU = 1,
                                  GK_FREE = 2 };

// Box corner rounding — stored in the ob_type high byte (extType), bits 4-7.
// One bit per corner so any combination can be rounded.
enum
    {
    BOX_ROUND_TL = 0x10,
    BOX_ROUND_TR = 0x20,
    BOX_ROUND_BR = 0x40,
    BOX_ROUND_BL = 0x80,
    BOX_ROUND_ALL = 0xF0
    };

// ---- GEM 16-bit colour word ------------------------------------------------
// border(15-12) text(11-8) textMode(7: 1=replace,0=transparent) fill(6-4) inside(3-0)
typedef struct
    {
    int border; // 0..15 (VDI pen index; 1 = black, 0 = white)
    int text;
    BOOL replace;
    int pattern; // 0..7 fill pattern
    int inside;
    } GColorWord;

static inline uint16_t gcw_pack(GColorWord c)
    {
    return (uint16_t)(((c.border & 0xF) << 12) | ((c.text & 0xF) << 8) |
                      ((c.replace ? 1 : 0) << 7) | ((c.pattern & 0x7) << 4) |
                      (c.inside & 0xF));
    }
static inline GColorWord gcw_unpack(uint16_t r)
    {
    GColorWord c;
    c.border = (r >> 12) & 0xF;
    c.text = (r >> 8) & 0xF;
    c.replace = (r & 0x80) != 0;
    c.pattern = (r >> 4) & 0x7;
    c.inside = r & 0xF;
    return c;
    }
static inline GColorWord gcw_default(void)
    {
    GColorWord c = {1, 1, NO, 0, 0};
    return c; // black border/text, hollow, white
    }

// ---- Payloads --------------------------------------------------------------

@interface GTedinfo : NSObject
@property(copy) NSString* text;  // te_ptext
@property(copy) NSString* tmplt; // te_ptmplt
@property(copy) NSString* valid; // te_pvalid
@property int font;              // 3 = large, 5 = small
@property int fontId;
@property int just; // 0 left, 1 right, 2 centre
@property(assign) GColorWord color;
@property int fontsize;
@property int thickness;
@end

@interface GBox : NSObject
@property uint8_t character; // G_BOXCHAR char (0 = none)
@property int thickness;     // border thickness (negative = inside)
@property(assign) GColorWord color;
@end

// A classic monochrome bitmap (BITBLK): 1bpp, `wb` bytes per row, `hl` rows.
// Set bits are drawn in VDI pen `color`; clear bits are transparent — a BITBLK is
// a bit *form* and has no mask.  Carried by G_IMAGE objects and by the free-image
// table (rsrc_gaddr(R_IMAGE, i)).
@interface GBitblk : NSObject
@property(nullable, copy) NSData* data; // wb * hl bytes
@property int wb, hl, x, y, color;
@property(nullable, strong) NSImage* cachedImage;
- (nullable NSImage*)image;
- (BOOL)isMform; // an AES mouse cursor stored inside this bit form
@end

@interface GIcon : NSObject
@property BOOL isColor;
@property(copy) NSString* label;
// colour / PAM
@property(nullable, copy) NSData* pam; // embedded P7 PAM bytes
// The original CICONBLK, verbatim, when this icon came from a real Atari file.
// Kept so re-export is byte-faithful even though we render the derived PAM.
@property(nullable, copy) NSData* ciconRaw;
@property(nullable, copy) NSData* selPam;         // the SELECTED form, if the file had one
@property(nullable, copy) NSString* externalPath; // reference instead of embedding
// classic mono ICONBLK (preserved from imported standard .rsc)
@property(nullable, copy) NSData* monoData; // ib_pdata
@property(nullable, copy) NSData* monoMask; // ib_pmask
@property int iconChar, charX, charY;
@property int textX, textY, textW, textH;
@property int iconX, iconY, iconW, iconH;
// transient: rendered bitmap for the canvas
@property(nullable, strong) NSImage* cachedImage;
- (nullable NSImage*)image; // build/return a display image
@end

// ---- Object node -----------------------------------------------------------

@interface GObject : NSObject
@property GObType type;
// The ob_type high byte, when it carries ROCKS' meaning: corner rounding (bits
// 4-7), the "rounded field" / group-box flag (bit 0), a G_POPUP's linked tree.
@property uint8_t extType;
// The same byte when it came from someone ELSE's resource.  Other editors use it
// as a free "extended type" field, so it is kept verbatim and written back out,
// but is not allowed to mean anything here — otherwise a legacy G_BUTTON with
// 0x12 would come in as a rounded box.  See RSC_VRSN_ROCKS in rsc.h.
@property uint8_t legacyExtType;
@property GFlags flags;
@property GState state;
@property int x, y, w, h;
// Symbolic name for source export (see GExport.h). Optional: when nil the
// exporter derives one from the text/label, then from the type.
@property(nullable, copy) NSString* name;
@property(nullable, copy) NSString* text; // string spec
@property(nullable, strong) GTedinfo* ted;
@property(nullable, strong) GBox* box;
@property(nullable, strong) GIcon* icon;
@property(nullable, strong) GBitblk* bitblk; // a classic G_IMAGE's bit form
@property(strong) NSMutableArray<GObject*>* children;

+ (instancetype)objectOfType:(GObType)type frame:(NSRect)f;
- (void)seedPayload;
- (GObject*)deepCopy;

// tree helpers
- (void)preorder:(void (^)(GObject*))block;
- (nullable GObject*)parentOf:(GObject*)target;

// type capability queries
- (BOOL)hasStringSpec;
- (BOOL)hasTedinfo;
- (BOOL)hasBox;
- (BOOL)hasIcon;
- (BOOL)hasBitblk;
- (BOOL)canHaveChildren;
@end

NSString* GObTypeName(GObType t);

// ---- Tree / resource -------------------------------------------------------

@interface GTree : NSObject
@property(copy) NSString* name;
@property GTreeKind kind;
@property(strong) GObject* root;

- (nullable GObject*)parentOf:(GObject*)node;
- (NSPoint)absoluteOriginOf:(GObject*)node; // screen coords; (NAN,NAN) if absent
- (nullable GObject*)hitTest:(NSPoint)p;    // top-most containing object
- (NSArray<GObject*>*)allObjects;

// Menu trees: a bar of G_TITLEs + one dropdown G_BOX per title.
- (BOOL)isMenu;
- (NSArray<GObject*>*)menuTitles;
- (nullable GObject*)menuBar;                                     // parent of the titles
- (NSArray<GObject*>*)menuDropdowns;                              // pulldown boxes (any box holding item strings)
- (nullable GObject*)dropdownUnderTitle:(nullable GObject*)title; // matched by X position
@end

// A flattened node for the classic OBJECT array.
typedef struct
    {
    __unsafe_unretained GObject* obj;
    int next, head, tail;
    } GFlatNode;

@interface GResource : NSObject
@property(strong) NSMutableArray<GTree*>* trees;
// Free strings: rsrc_gaddr(R_STRING, i).  They hang off no object, so nothing in
// the tree references them — but real resources are full of them.
@property(strong) NSMutableArray<NSString*>* freeStrings;
// Free images: rsrc_gaddr(R_IMAGE, i).  Like free strings, they hang off no object.
@property(strong) NSMutableArray<GBitblk*>* freeImages;
@property BOOL bigEndian;    // classic 68000 GEM fidelity
@property BOOL packedCoords; // char/pixel packing on write
@property BOOL embedIcons;   // embed PAM vs external path
@property int charWidth, charHeight;

+ (instancetype)emptyDialog;
// flatten a tree to classic pre-order; returns count, fills *outNodes (caller frees).
- (int)flatten:(GTree*)tree into:(GFlatNode* _Nullable* _Nonnull)outNodes;
@end

NS_ASSUME_NONNULL_END
