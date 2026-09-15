// GExport.m — see GExport.h.
//
// The three emitters share one pass: buildPlan() assigns every tree and object a
// unique symbol and pools the strings / TEDINFOs / ICONBLKs / CICONs / bitmaps
// that the objects point at.  Each emitter then walks the same plan, so the .h,
// .c and .xt always agree on indices and on what points where.
//
// Object order is pre-order, matching -[GResource flatten:into:] and therefore
// the object numbering in the .rsc the editor writes.

#import "GExport.h"
#import "GImage.h"

// ---- symbol naming ---------------------------------------------------------

// "Save as…" -> "SAVE_AS"; returns nil if nothing usable survives.  A string
// with no letters or digits yields nil rather than a symbol — an edit field's
// "____________" template must fall through to the type name, not become "____".
static NSString *sanitizeSym(NSString *s) {
    if (!s.length) return nil;
    NSMutableString *out = [NSMutableString string];
    BOOL pendingSep = NO, hasAlnum = NO;
    for (NSUInteger i = 0; i < s.length && out.length < 24; i++) {
        unichar c = [s characterAtIndex:i];
        BOOL alnum = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
        if (alnum || c == '_') {
            if (pendingSep && out.length) [out appendString:@"_"];
            pendingSep = NO;
            hasAlnum |= alnum;
            [out appendFormat:@"%c", (char)toupper((int)c)];
        } else if (out.length) {
            pendingSep = YES;   // collapse any run of separators into one "_"
        }
    }
    if (!hasAlnum) return nil;
    while ([out hasPrefix:@"_"]) [out deleteCharactersInRange:NSMakeRange(0, 1)];
    while ([out hasSuffix:@"_"]) [out deleteCharactersInRange:NSMakeRange(out.length - 1, 1)];
    if (!out.length) return nil;
    unichar f = [out characterAtIndex:0];
    if (f >= '0' && f <= '9') [out insertString:@"_" atIndex:0];
    return out;
}

// An object's leaf symbol: explicit name, else its text/label, else its type.
static NSString *leafSym(GObject *o, BOOL isRoot) {
    NSString *s = sanitizeSym(o.name);
    if (!s && isRoot) return @"ROOT";
    if (!s) s = sanitizeSym(o.text);
    if (!s && o.ted) s = sanitizeSym(o.ted.text.length ? o.ted.text : o.ted.tmplt);
    if (!s && o.icon) s = sanitizeSym(o.icon.label);
    if (!s) s = sanitizeSym(GObTypeName(o.type));
    return s ?: @"OBJ";
}

static NSString *uniqueSym(NSMutableSet *used, NSString *want, int idx) {
    NSString *s = want;
    if ([used containsObject:s]) s = [NSString stringWithFormat:@"%@_%d", want, idx];
    int n = 2;
    while ([used containsObject:s]) s = [NSString stringWithFormat:@"%@_%d_%d", want, idx, n++];
    [used addObject:s];
    return s;
}

// ---- the plan --------------------------------------------------------------

@interface GXTree : NSObject
@property (strong) GTree *tree;
@property (copy) NSString *sym;                     // MAIN
@property (copy) NSString *var;                     // rs_main
@property (strong) NSArray<GObject *> *objects;     // pre-order
@property (strong) NSArray<NSString *> *syms;       // parallel: MAIN_OK, ...
@end
@implementation GXTree
@end

@interface GXPlan : NSObject
@property (strong) NSArray<GXTree *> *trees;
@property (strong) NSArray<NSString *> *freeStrings;   // rsrc_gaddr(R_STRING, i)
@property (strong) NSArray<NSString *> *freeSyms;      // parallel: STR_SAVE_AS, ...
@property (strong) NSMutableArray<NSString *> *strings;
@property (strong) NSMutableDictionary<NSString *, NSNumber *> *strIndex;
@property (strong) NSMutableArray<GObject *> *teds;    // objects with a TEDINFO
@property (strong) NSMutableArray<GObject *> *icons;   // G_ICON -> ICONBLK
@property (strong) NSMutableArray<GObject *> *cicons;  // G_CICON / G_IMAGE -> CICON
@property (strong) NSMutableArray<GBitblk *> *bitblks; // BITBLKs: objects' and free
@property (strong) NSMutableArray<NSData *> *blobs;    // bitplanes + PAM payloads
@property (strong) NSMutableDictionary<NSData *, NSNumber *> *blobIndex;
@end
@implementation GXPlan
@end

static int internStr(GXPlan *p, NSString *s) {
    s = s ?: @"";
    NSNumber *n = p.strIndex[s];
    if (n) return n.intValue;
    int i = (int)p.strings.count;
    [p.strings addObject:s];
    p.strIndex[s] = @(i);
    return i;
}
static int internBlob(GXPlan *p, NSData *d) {
    if (!d.length) return -1;
    NSNumber *n = p.blobIndex[d];
    if (n) return n.intValue;
    int i = (int)p.blobs.count;
    [p.blobs addObject:d];
    p.blobIndex[d] = @(i);
    return i;
}

// Which pool an object's ob_spec points at. Mirrors the dispatch in GRsc.m.
static BOOL specIsBox(GObject *o)    { return [o hasBox]; }
static BOOL specIsString(GObject *o) { return [o hasStringSpec]; }
static BOOL specIsTed(GObject *o)    { return [o hasTedinfo]; }
static BOOL specIsIcon(GObject *o)   { return o.type == GT_ICON; }
// A CICONBLK imported from a real Atari file already carries a derived RGBA PAM,
// so it exports through the same path as Rocks' own colour icons.
static BOOL specIsCicon(GObject *o)  { return o.type == GT_CICON || o.type == GT_CICONBLK; }
// A classic G_IMAGE points at a BITBLK bit form.
static BOOL specIsBitblk(GObject *o) { return o.type == GT_IMAGE && o.bitblk != nil; }

// The PAM bytes a colour icon will export (embedded, external file, or rendered).
static NSData *cicoPAM(GObject *o) {
    GIcon *gi = o.icon;
    if (!gi) return nil;
    if (gi.pam.length) return gi.pam;
    if (gi.externalPath) {
        NSData *d = [NSData dataWithContentsOfFile:gi.externalPath];
        if (d.length) return d;
    }
    NSImage *img = [gi image];
    return img ? GPAMFromImage(img) : nil;
}

static GXPlan *buildPlan(GResource *res) {
    GXPlan *p = [GXPlan new];
    p.strings = [NSMutableArray array];   p.strIndex = [NSMutableDictionary dictionary];
    p.teds = [NSMutableArray array];      p.icons = [NSMutableArray array];
    p.cicons = [NSMutableArray array];    p.blobs = [NSMutableArray array];
    p.bitblks = [NSMutableArray array];
    p.blobIndex = [NSMutableDictionary dictionary];

    NSMutableSet *used = [NSMutableSet set];
    NSMutableArray<GXTree *> *out = [NSMutableArray array];

    for (int ti = 0; ti < (int)res.trees.count; ti++) {
        GTree *t = res.trees[ti];
        GXTree *xt = [GXTree new];
        xt.tree = t;
        NSString *want = sanitizeSym(t.name) ?: [NSString stringWithFormat:@"TREE%d", ti];
        xt.sym = uniqueSym(used, want, ti);
        xt.var = [@"rs_" stringByAppendingString:xt.sym.lowercaseString];

        NSArray<GObject *> *objs = [t allObjects];   // pre-order
        NSMutableArray *syms = [NSMutableArray array];
        for (int i = 0; i < (int)objs.count; i++) {
            GObject *o = objs[i];
            NSString *leaf = leafSym(o, i == 0);
            [syms addObject:uniqueSym(used, [NSString stringWithFormat:@"%@_%@", xt.sym, leaf], i)];

            // pool whatever this object's ob_spec will point at
            if (specIsString(o)) {
                internStr(p, o.text);
            } else if (specIsTed(o)) {
                GTedinfo *td = o.ted ?: [GTedinfo new];
                internStr(p, td.text); internStr(p, td.tmplt); internStr(p, td.valid);
                [p.teds addObject:o];
            } else if (specIsIcon(o)) {
                GIcon *gi = o.icon ?: [GIcon new];
                internStr(p, gi.label);
                internBlob(p, gi.monoData); internBlob(p, gi.monoMask);
                [p.icons addObject:o];
            } else if (specIsCicon(o)) {
                GIcon *gi = o.icon ?: [GIcon new];
                internStr(p, gi.label);
                internBlob(p, cicoPAM(o));
                [p.cicons addObject:o];
            } else if (specIsBitblk(o)) {
                internBlob(p, o.bitblk.data);
                [p.bitblks addObject:o.bitblk];
            }
        }
        xt.objects = objs;
        xt.syms = syms;
        [out addObject:xt];
    }
    // Free strings belong to no object, but code still needs to name them.
    NSMutableArray *fs = [NSMutableArray array], *fsym = [NSMutableArray array];
    for (int i = 0; i < (int)res.freeStrings.count; i++) {
        NSString *txt = res.freeStrings[i];
        [fs addObject:txt];
        NSString *leaf = sanitizeSym(txt) ?: [NSString stringWithFormat:@"%d", i];
        [fsym addObject:uniqueSym(used, [@"STR_" stringByAppendingString:leaf], i)];
        internStr(p, txt);
    }
    p.freeStrings = fs;
    p.freeSyms = fsym;

    for (GBitblk *bb in res.freeImages) {
        internBlob(p, bb.data);
        [p.bitblks addObject:bb];
    }

    p.trees = out;
    return p;
}

// ---- encoding helpers ------------------------------------------------------

static NSData *latin1(NSString *s) {
    return [(s ?: @"") dataUsingEncoding:NSISOLatin1StringEncoding allowLossyConversion:YES]
           ?: [NSData data];
}
// GEM's te_txtlen / te_tmplen count the terminating NUL.
static int lenWithNul(NSString *s) { return (int)latin1(s).length + 1; }

// A C string literal. Always uses 3-digit octal so a following digit can't be
// swallowed into the escape.
static NSString *cQuote(NSString *s) {
    NSData *d = latin1(s);
    const uint8_t *b = d.bytes;
    NSMutableString *o = [NSMutableString stringWithString:@"\""];
    for (NSUInteger i = 0; i < d.length; i++) {
        uint8_t c = b[i];
        switch (c) {
            case '\\': [o appendString:@"\\\\"]; break;
            case '"':  [o appendString:@"\\\""]; break;
            case '\n': [o appendString:@"\\n"];  break;
            case '\r': [o appendString:@"\\r"];  break;
            case '\t': [o appendString:@"\\t"];  break;
            default:
                if (c < 0x20 || c >= 0x7F) [o appendFormat:@"\\%03o", c];
                else                       [o appendFormat:@"%c", (char)c];
        }
    }
    [o appendString:@"\""];
    return o;
}

// The same text as an xtc byte list: { 79, 75, 0 }
static NSString *xtBytes(NSString *s) {
    NSData *d = latin1(s);
    const uint8_t *b = d.bytes;
    NSMutableString *o = [NSMutableString stringWithString:@"{ "];
    for (NSUInteger i = 0; i < d.length; i++) [o appendFormat:@"%u, ", b[i]];
    [o appendString:@"0 }"];
    return o;
}

// A blob as a wrapped hex byte list, shared by both back-ends via `radix`.
static NSString *byteList(NSData *d, BOOL xtc, NSString *indent) {
    const uint8_t *b = d.bytes;
    NSMutableString *o = [NSMutableString string];
    for (NSUInteger i = 0; i < d.length; i++) {
        if (i % 16 == 0) [o appendFormat:@"%@%@", i ? @"\n" : @"", indent];
        [o appendString:xtc ? [NSString stringWithFormat:@"$%02X", b[i]]
                            : [NSString stringWithFormat:@"0x%02X", b[i]]];
        if (i + 1 < d.length) [o appendString:@", "];
    }
    return o;
}

// NSString's %@ ignores any field width, so pad the ob_spec column by hand —
// the generated tables are meant to be read.
static NSString *padTo(NSString *s, NSUInteger w) {
    NSMutableString *o = [s mutableCopy];
    while (o.length < w) [o appendString:@" "];
    return o;
}

// The ob_type high byte: ours if we have one, else the legacy byte handed back
// untouched — exactly what GRscWrite does.  See RSC_VRSN_ROCKS in rsc.h.
static uint16_t obTypeWord(GObject *o) {
    uint8_t hi = o.extType ?: o.legacyExtType;
    return (uint16_t)((hi << 8) | (o.type & 0xFF));
}

// The inline box word: (char << 24) | (thickness << 16) | colour.
static uint32_t boxWord(GObject *o) {
    GBox *b = o.box ?: [GBox new];
    return (((uint32_t)b.character & 0xFF) << 24) |
           (((uint32_t)(b.thickness & 0xFF)) << 16) | gcw_pack(b.color);
}

// Sibling/child links, tree-relative, matching -[GResource flatten:into:].
static void linksFor(GXTree *xt, int i, int *next, int *head, int *tail) {
    NSArray<GObject *> *objs = xt.objects;
    GObject *o = objs[i];
    NSUInteger (^idx)(GObject *) = ^NSUInteger(GObject *x) { return [objs indexOfObject:x]; };
    *head = o.children.count ? (int)idx(o.children.firstObject) : -1;
    *tail = o.children.count ? (int)idx(o.children.lastObject)  : -1;
    *next = -1;
    if (i == 0) return;                       // the root never has a sibling
    GObject *parent = [xt.tree parentOf:o];
    if (!parent) return;
    NSUInteger k = [parent.children indexOfObject:o];
    *next = (k + 1 < parent.children.count) ? (int)idx(parent.children[k + 1])
                                            : (int)idx(parent);   // last child -> parent
}

static NSString *kindName(GTreeKind k) {
    switch (k) { case GK_MENU: return @"menu"; case GK_FREE: return @"free"; default: return @"dialog"; }
}
static NSString *identFrom(NSString *stem) {
    NSString *s = sanitizeSym(stem) ?: @"RSC";
    return s.lowercaseString;
}

// ---- symbol table (public) -------------------------------------------------

NSDictionary<NSString *, NSNumber *> *GExportSymbols(GResource *res) {
    GXPlan *p = buildPlan(res);
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (int ti = 0; ti < (int)p.trees.count; ti++) {
        GXTree *xt = p.trees[ti];
        m[xt.sym] = @(ti);
        for (int i = 0; i < (int)xt.syms.count; i++) m[xt.syms[i]] = @(i);
    }
    for (int i = 0; i < (int)p.freeSyms.count; i++) m[p.freeSyms[i]] = @(i);
    return m;
}

NSString *GExportSymbolForObject(GResource *res, GObject *o) {
    if (!o) return nil;
    GXPlan *p = buildPlan(res);
    for (GXTree *xt in p.trees) {
        NSUInteger i = [xt.objects indexOfObject:o];
        if (i != NSNotFound) return xt.syms[i];
    }
    return nil;
}

// ---- .h --------------------------------------------------------------------

NSString *GExportHeader(GResource *res, NSString *stem) {
    GXPlan *p = buildPlan(res);
    NSString *guard = [NSString stringWithFormat:@"%@_H", sanitizeSym(stem) ?: @"RSC"];
    NSMutableString *s = [NSMutableString string];

    [s appendFormat:@"/* %@.h — generated by Rocks.  Do not edit; regenerate instead. */\n", stem];
    [s appendFormat:@"#ifndef %@\n#define %@\n\n", guard, guard];

    [s appendString:
     @"/* AES structures.  Define ROCKS_AES_TYPES before including this header to\n"
      " * supply your own (from aes.h); if your OBJECT.ob_spec is a LONG rather than\n"
      " * a pointer, also #define RS_SPEC(x) ((LONG)(x)) before compiling the .c. */\n"
      "#ifndef ROCKS_AES_TYPES\n"
      "#define ROCKS_AES_TYPES\n"
      "#include <stdint.h>\n\n"
      "typedef struct {\n"
      "    char    *te_ptext, *te_ptmplt, *te_pvalid;\n"
      "    int16_t  te_font, te_fontid, te_just;\n"
      "    uint16_t te_color;\n"
      "    int16_t  te_fontsize, te_thickness, te_txtlen, te_tmplen;\n"
      "} TEDINFO;\n\n"
      "typedef struct {\n"
      "    uint8_t *ib_pmask, *ib_pdata;\n"
      "    char    *ib_ptext;\n"
      "    int16_t  ib_char, ib_xchar, ib_ychar;\n"
      "    int16_t  ib_xicon, ib_yicon, ib_wicon, ib_hicon;\n"
      "    int16_t  ib_xtext, ib_ytext, ib_wtext, ib_htext;\n"
      "} ICONBLK;\n\n"
      "/* Rocks extension: a colour icon/image held as a self-delimiting P7 PAM. */\n"
      "typedef struct {\n"
      "    uint8_t *pam;\n"
      "    uint32_t pam_len;\n"
      "    char    *text;\n"
      "} CICON;\n\n"
      "/* A monochrome bit form: 1bpp, bi_wb bytes per row, bi_hl rows. */\n"
      "typedef struct {\n"
      "    uint8_t *bi_pdata;\n"
      "    int16_t  bi_wb, bi_hl, bi_x, bi_y, bi_color;\n"
      "} BITBLK;\n\n"
      "typedef struct {\n"
      "    int16_t  ob_next, ob_head, ob_tail;\n"
      "    uint16_t ob_type, ob_flags, ob_state;\n"
      "    void    *ob_spec;\n"
      "    int16_t  ob_x, ob_y, ob_w, ob_h;\n"
      "} OBJECT;\n"
      "#endif /* ROCKS_AES_TYPES */\n\n"];

    [s appendString:@"/* ---- trees ------------------------------------------------------------ */\n"];
    for (int ti = 0; ti < (int)p.trees.count; ti++)
        [s appendFormat:@"#define %-28s %d\n", p.trees[ti].sym.UTF8String, ti];
    [s appendFormat:@"#define %-28s %d\n\n", "NUM_TREES", (int)p.trees.count];

    for (GXTree *xt in p.trees) {
        [s appendFormat:@"/* ---- %@ (%@, %d objects) */\n", xt.sym,
                        kindName(xt.tree.kind), (int)xt.objects.count];
        for (int i = 0; i < (int)xt.syms.count; i++) {
            GObject *o = xt.objects[i];
            [s appendFormat:@"#define %-28s %-4d /* %@ */\n",
                            xt.syms[i].UTF8String, i, GObTypeName(o.type)];
        }
        [s appendString:@"\n"];
    }

    if (p.freeStrings.count) {
        [s appendString:@"/* ---- free strings — rsrc_gaddr(R_STRING, i) --------------------------- */\n"];
        for (int i = 0; i < (int)p.freeSyms.count; i++)
            [s appendFormat:@"#define %-28s %-4d /* %@ */\n",
                            p.freeSyms[i].UTF8String, i, cQuote(p.freeStrings[i])];
        [s appendFormat:@"#define %-28s %d\n\n", "NUM_FREE_STRINGS", (int)p.freeStrings.count];
    }

    if (res.freeImages.count) {
        [s appendString:@"/* ---- free images — rsrc_gaddr(R_IMAGE, i) ----------------------------- */\n"];
        for (int i = 0; i < (int)res.freeImages.count; i++) {
            GBitblk *bb = res.freeImages[i];
            [s appendFormat:@"#define IMG_%-24d %-4d /* %dx%d */\n", i, i, bb.wb * 8, bb.hl];
        }
        [s appendFormat:@"#define %-28s %d\n\n", "NUM_FREE_IMAGES", (int)res.freeImages.count];
    }

    [s appendString:@"/* ---- data (defined in the generated .c) -------------------------------- */\n"];
    for (GXTree *xt in p.trees)
        [s appendFormat:@"extern OBJECT %@[%d];\n", xt.var, (int)xt.objects.count];
    [s appendFormat:@"extern OBJECT *rs_trees[%d];\n", (int)p.trees.count];
    if (p.freeStrings.count)
        [s appendFormat:@"extern char *rs_free_strings[%d];\n", (int)p.freeStrings.count];
    if (res.freeImages.count)
        [s appendFormat:@"extern BITBLK *rs_free_images[%d];\n", (int)res.freeImages.count];
    [s appendString:@"\n"];
    [s appendFormat:@"#endif /* %@ */\n", guard];
    return s;
}

// ---- .c --------------------------------------------------------------------

NSString *GExportCSource(GResource *res, NSString *stem) {
    GXPlan *p = buildPlan(res);
    NSMutableString *s = [NSMutableString string];

    [s appendFormat:@"/* %@.c — generated by Rocks.  Do not edit; regenerate instead.\n"
                     " *\n"
                     " * C folds address constants, so every ob_spec is resolved at compile time:\n"
                     " * there is nothing to call before handing a tree to the AES. */\n\n", stem];
    [s appendFormat:@"#include \"%@.h\"\n\n", stem];
    [s appendString:@"#ifndef RS_SPEC\n#define RS_SPEC(x) ((void *)(x))\n#endif\n\n"];

    // strings
    if (p.strings.count) {
        [s appendString:@"/* ---- strings ---------------------------------------------------------- */\n"];
        for (int i = 0; i < (int)p.strings.count; i++)
            [s appendFormat:@"static char rs_str%d[] = %@;\n", i, cQuote(p.strings[i])];
        [s appendString:@"\n"];
    }
    // bitmaps
    if (p.blobs.count) {
        [s appendString:@"/* ---- bitmaps (icon bitplanes / PAM payloads) -------------------------- */\n"];
        for (int i = 0; i < (int)p.blobs.count; i++) {
            NSData *d = p.blobs[i];
            [s appendFormat:@"static uint8_t rs_blob%d[%lu] = {\n%@\n};\n",
                            i, (unsigned long)d.length, byteList(d, NO, @"    ")];
        }
        [s appendString:@"\n"];
    }
    // TEDINFOs
    NSMutableDictionary<NSValue *, NSNumber *> *tedOf = [NSMutableDictionary dictionary];
    if (p.teds.count) {
        [s appendString:@"/* ---- TEDINFO ---------------------------------------------------------- */\n"];
        [s appendFormat:@"static TEDINFO rs_ted[%d] = {\n", (int)p.teds.count];
        for (int i = 0; i < (int)p.teds.count; i++) {
            GObject *o = p.teds[i];
            tedOf[[NSValue valueWithNonretainedObject:o]] = @(i);
            GTedinfo *t = o.ted ?: [GTedinfo new];
            [s appendFormat:@"    { rs_str%d, rs_str%d, rs_str%d, %d, %d, %d, 0x%04X, %d, %d, %d, %d },\n",
                internStr(p, t.text), internStr(p, t.tmplt), internStr(p, t.valid),
                t.font, t.fontId, t.just, gcw_pack(t.color), t.fontsize, t.thickness,
                lenWithNul(t.text), lenWithNul(t.tmplt)];
        }
        [s appendString:@"};\n\n"];
    }
    // ICONBLKs
    NSMutableDictionary<NSValue *, NSNumber *> *iconOf = [NSMutableDictionary dictionary];
    if (p.icons.count) {
        [s appendString:@"/* ---- ICONBLK (monochrome icons) --------------------------------------- */\n"];
        [s appendFormat:@"static ICONBLK rs_ib[%d] = {\n", (int)p.icons.count];
        for (int i = 0; i < (int)p.icons.count; i++) {
            GObject *o = p.icons[i];
            iconOf[[NSValue valueWithNonretainedObject:o]] = @(i);
            GIcon *g = o.icon ?: [GIcon new];
            int mk = internBlob(p, g.monoMask), dt = internBlob(p, g.monoData);
            [s appendFormat:@"    { %@, %@, rs_str%d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d },\n",
                mk < 0 ? @"0" : [NSString stringWithFormat:@"rs_blob%d", mk],
                dt < 0 ? @"0" : [NSString stringWithFormat:@"rs_blob%d", dt],
                internStr(p, g.label), g.iconChar, g.charX, g.charY,
                g.iconX, g.iconY, g.iconW, g.iconH, g.textX, g.textY, g.textW, g.textH];
        }
        [s appendString:@"};\n\n"];
    }
    // CICONs
    NSMutableDictionary<NSValue *, NSNumber *> *cicoOf = [NSMutableDictionary dictionary];
    if (p.cicons.count) {
        [s appendString:@"/* ---- CICON (colour icons / images, P7 PAM) ---------------------------- */\n"];
        [s appendFormat:@"static CICON rs_ci[%d] = {\n", (int)p.cicons.count];
        for (int i = 0; i < (int)p.cicons.count; i++) {
            GObject *o = p.cicons[i];
            cicoOf[[NSValue valueWithNonretainedObject:o]] = @(i);
            GIcon *g = o.icon ?: [GIcon new];
            NSData *pam = cicoPAM(o);
            int bi = internBlob(p, pam);
            [s appendFormat:@"    { %@, %luUL, rs_str%d },\n",
                bi < 0 ? @"0" : [NSString stringWithFormat:@"rs_blob%d", bi],
                (unsigned long)pam.length, internStr(p, g.label)];
        }
        [s appendString:@"};\n\n"];
    }

    // BITBLKs (classic G_IMAGE bit forms, and the free-image table)
    NSMutableDictionary<NSValue *, NSNumber *> *bbOf = [NSMutableDictionary dictionary];
    if (p.bitblks.count) {
        [s appendString:@"/* ---- BITBLK (monochrome bit forms) ------------------------------------ */\n"];
        [s appendFormat:@"static BITBLK rs_bb[%d] = {\n", (int)p.bitblks.count];
        for (int i = 0; i < (int)p.bitblks.count; i++) {
            GBitblk *bb = p.bitblks[i];
            bbOf[[NSValue valueWithNonretainedObject:bb]] = @(i);
            int bi = internBlob(p, bb.data);
            [s appendFormat:@"    { %@, %d, %d, %d, %d, %d },\n",
                bi < 0 ? @"0" : [NSString stringWithFormat:@"rs_blob%d", bi],
                bb.wb, bb.hl, bb.x, bb.y, bb.color];
        }
        [s appendString:@"};\n\n"];
    }

    // object trees
    [s appendString:@"/* ---- object trees ----------------------------------------------------- */\n"];
    for (GXTree *xt in p.trees) {
        [s appendFormat:@"OBJECT %@[%d] = {\n", xt.var, (int)xt.objects.count];
        for (int i = 0; i < (int)xt.objects.count; i++) {
            GObject *o = xt.objects[i];
            int nx, hd, tl; linksFor(xt, i, &nx, &hd, &tl);
            NSString *spec = @"RS_SPEC(0)";
            if (specIsBox(o))
                spec = [NSString stringWithFormat:@"RS_SPEC((uintptr_t)0x%08XUL)", boxWord(o)];
            else if (specIsString(o))
                spec = [NSString stringWithFormat:@"RS_SPEC(rs_str%d)", internStr(p, o.text)];
            else if (specIsTed(o))
                spec = [NSString stringWithFormat:@"RS_SPEC(&rs_ted[%@])",
                                 tedOf[[NSValue valueWithNonretainedObject:o]]];
            else if (specIsIcon(o))
                spec = [NSString stringWithFormat:@"RS_SPEC(&rs_ib[%@])",
                                 iconOf[[NSValue valueWithNonretainedObject:o]]];
            else if (specIsCicon(o))
                spec = [NSString stringWithFormat:@"RS_SPEC(&rs_ci[%@])",
                                 cicoOf[[NSValue valueWithNonretainedObject:o]]];
            else if (specIsBitblk(o))
                spec = [NSString stringWithFormat:@"RS_SPEC(&rs_bb[%@])",
                                 bbOf[[NSValue valueWithNonretainedObject:o.bitblk]]];

            [s appendFormat:@"    { %4d, %4d, %4d, 0x%04X, 0x%04X, 0x%04X, %@ %4d, %4d, %4d, %4d },"
                             "  /* %@ */\n",
                nx, hd, tl, obTypeWord(o),
                (uint16_t)o.flags, (uint16_t)o.state,
                padTo([spec stringByAppendingString:@","], 33),
                o.x, o.y, o.w, o.h, xt.syms[i]];
        }
        [s appendString:@"};\n\n"];
    }

    [s appendFormat:@"OBJECT *rs_trees[%d] = {\n", (int)p.trees.count];
    for (GXTree *xt in p.trees) [s appendFormat:@"    %@,\n", xt.var];
    [s appendString:@"};\n"];

    if (p.freeStrings.count) {
        [s appendFormat:@"\nchar *rs_free_strings[%d] = {\n", (int)p.freeStrings.count];
        for (int i = 0; i < (int)p.freeStrings.count; i++)
            [s appendFormat:@"    rs_str%d,%@/* %@ */\n", internStr(p, p.freeStrings[i]),
                            @"   ", p.freeSyms[i]];
        [s appendString:@"};\n"];
    }
    if (res.freeImages.count) {
        [s appendFormat:@"\nBITBLK *rs_free_images[%d] = {\n", (int)res.freeImages.count];
        for (int i = 0; i < (int)res.freeImages.count; i++)
            [s appendFormat:@"    &rs_bb[%@],\n",
                            bbOf[[NSValue valueWithNonretainedObject:res.freeImages[i]]]];
        [s appendString:@"};\n"];
    }
    return s;
}

// ---- .xt -------------------------------------------------------------------


// xtc will not constant-fold a global whose type contains a pointer, so every
// table here is pure integer: ob_spec is the AES 32-bit LONG (which is exactly
// what it is on a real Atari), and <stem>_fixup() pokes the addresses in at run
// time — the job rsrc_load does on real GEM.
//
// Keeping the tables integer-only also side-steps xtc's arm64 backend, which
// currently reports sizeof(u8@) == 2 and mis-lays-out any struct with a pointer
// member.  Targets m68k and 6502; see RSC-FORMAT.md for the arm64 caveat.
NSString *GExportXtc(GResource *res, NSString *stem) {
    GXPlan *p = buildPlan(res);
    NSString *ident = identFrom(stem);
    NSMutableString *s = [NSMutableString string];

    [s appendFormat:
     @"// %@.xt — generated by Rocks.  Do not edit; regenerate instead.\n"
      "//\n"
      "// Call %@_fixup() once at start-up, before handing any tree to the AES.\n"
      "//\n"
      "// xtc will not constant-fold a global whose type contains a pointer, so the\n"
      "// tables below are pure integers — ob_spec is the AES 32-bit LONG — and the\n"
      "// addresses are filled in by the fixup.  That is what rsrc_load does on real\n"
      "// GEM.  Targets m68k and 6502.\n\n",
     stem, ident];

    [s appendString:@"// ---- trees -----------------------------------------------------------\n"];
    for (int ti = 0; ti < (int)p.trees.count; ti++)
        [s appendFormat:@"#define %-28s %d\n", p.trees[ti].sym.UTF8String, ti];
    [s appendFormat:@"#define %-28s %d\n\n", "NUM_TREES", (int)p.trees.count];

    for (GXTree *xt in p.trees) {
        [s appendFormat:@"// %@ (%@, %d objects)\n", xt.sym,
                        kindName(xt.tree.kind), (int)xt.objects.count];
        for (int i = 0; i < (int)xt.syms.count; i++)
            [s appendFormat:@"#define %-28s %-4d // %@\n",
                            xt.syms[i].UTF8String, i, GObTypeName(xt.objects[i].type)];
        [s appendString:@"\n"];
    }

    if (p.freeStrings.count) {
        [s appendString:@"// ---- free strings — rsrc_gaddr(R_STRING, i) ---------------------------\n"];
        for (int i = 0; i < (int)p.freeSyms.count; i++)
            [s appendFormat:@"#define %-28s %-4d // %@\n",
                            p.freeSyms[i].UTF8String, i, cQuote(p.freeStrings[i])];
        [s appendFormat:@"#define %-28s %d\n\n", "NUM_FREE_STRINGS", (int)p.freeStrings.count];
    }

    [s appendString:
     @"// ---- AES structures --------------------------------------------------\n"
      "// Every pointer slot is a u32 (the AES LONG) so these tables constant-fold;\n"
      "// the fixup fills them in.\n"
      "typedef struct {\n"
      "    u32 te_ptext; u32 te_ptmplt; u32 te_pvalid;\n"
      "    i16 te_font; i16 te_fontid; i16 te_just;\n"
      "    u16 te_color;\n"
      "    i16 te_fontsize; i16 te_thickness; i16 te_txtlen; i16 te_tmplen;\n"
      "} TEDINFO;\n\n"
      "typedef struct {\n"
      "    u32 ib_pmask; u32 ib_pdata; u32 ib_ptext;\n"
      "    i16 ib_char; i16 ib_xchar; i16 ib_ychar;\n"
      "    i16 ib_xicon; i16 ib_yicon; i16 ib_wicon; i16 ib_hicon;\n"
      "    i16 ib_xtext; i16 ib_ytext; i16 ib_wtext; i16 ib_htext;\n"
      "} ICONBLK;\n\n"
      "// Rocks extension: a colour icon/image held as a self-delimiting P7 PAM.\n"
      "typedef struct {\n"
      "    u32 pam; u32 pam_len; u32 text;\n"
      "} CICON;\n\n"
      "// A monochrome bit form: 1bpp, bi_wb bytes per row, bi_hl rows.\n"
      "typedef struct {\n"
      "    u32 bi_pdata;\n"
      "    i16 bi_wb; i16 bi_hl; i16 bi_x; i16 bi_y; i16 bi_color;\n"
      "} BITBLK;\n\n"
      "typedef struct {\n"
      "    i16 ob_next; i16 ob_head; i16 ob_tail;\n"
      "    u16 ob_type; u16 ob_flags; u16 ob_state;\n"
      "    u32 ob_spec;                 // an inline box word, else set by the fixup\n"
      "    i16 ob_x; i16 ob_y; i16 ob_w; i16 ob_h;\n"
      "} OBJECT;\n\n"];

    if (p.strings.count) {
        [s appendString:@"// ---- strings ---------------------------------------------------------\n"];
        for (int i = 0; i < (int)p.strings.count; i++) {
            NSString *txt = p.strings[i];
            [s appendFormat:@"u8 rs_str%d[] = %@;%@\n", i, xtBytes(txt),
                            txt.length ? [NSString stringWithFormat:@"   // %@", cQuote(txt)] : @""];
        }
        [s appendString:@"\n"];
    }
    if (p.blobs.count) {
        [s appendString:@"// ---- bitmaps (icon bitplanes / PAM payloads) -------------------------\n"];
        for (int i = 0; i < (int)p.blobs.count; i++) {
            NSData *d = p.blobs[i];
            [s appendFormat:@"u8 rs_blob%d[%lu] = {\n%@\n};\n",
                            i, (unsigned long)d.length, byteList(d, YES, @"    ")];
        }
        [s appendString:@"\n"];
    }

    NSMutableDictionary<NSValue *, NSNumber *> *tedOf = [NSMutableDictionary dictionary];
    if (p.teds.count) {
        [s appendString:@"// ---- TEDINFO (te_p* filled in by the fixup) --------------------------\n"];
        [s appendFormat:@"TEDINFO rs_ted[%d] = {\n", (int)p.teds.count];
        for (int i = 0; i < (int)p.teds.count; i++) {
            GObject *o = p.teds[i];
            tedOf[[NSValue valueWithNonretainedObject:o]] = @(i);
            GTedinfo *t = o.ted ?: [GTedinfo new];
            [s appendFormat:@"    { 0, 0, 0, %d, %d, %d, $%04X, %d, %d, %d, %d }%@\n",
                t.font, t.fontId, t.just, gcw_pack(t.color), t.fontsize, t.thickness,
                lenWithNul(t.text), lenWithNul(t.tmplt),
                (i + 1 < (int)p.teds.count) ? @"," : @""];
        }
        [s appendString:@"};\n\n"];
    }
    NSMutableDictionary<NSValue *, NSNumber *> *iconOf = [NSMutableDictionary dictionary];
    if (p.icons.count) {
        [s appendString:@"// ---- ICONBLK (ib_p* filled in by the fixup) --------------------------\n"];
        [s appendFormat:@"ICONBLK rs_ib[%d] = {\n", (int)p.icons.count];
        for (int i = 0; i < (int)p.icons.count; i++) {
            GObject *o = p.icons[i];
            iconOf[[NSValue valueWithNonretainedObject:o]] = @(i);
            GIcon *g = o.icon ?: [GIcon new];
            [s appendFormat:@"    { 0, 0, 0, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d }%@\n",
                g.iconChar, g.charX, g.charY, g.iconX, g.iconY, g.iconW, g.iconH,
                g.textX, g.textY, g.textW, g.textH,
                (i + 1 < (int)p.icons.count) ? @"," : @""];
        }
        [s appendString:@"};\n\n"];
    }
    NSMutableDictionary<NSValue *, NSNumber *> *bbOf = [NSMutableDictionary dictionary];
    if (p.bitblks.count) {
        [s appendString:@"// ---- BITBLK (bi_pdata filled in by the fixup) ------------------------\n"];
        [s appendFormat:@"BITBLK rs_bb[%d] = {\n", (int)p.bitblks.count];
        for (int i = 0; i < (int)p.bitblks.count; i++) {
            GBitblk *bb = p.bitblks[i];
            bbOf[[NSValue valueWithNonretainedObject:bb]] = @(i);
            [s appendFormat:@"    { 0, %d, %d, %d, %d, %d }%@\n",
                bb.wb, bb.hl, bb.x, bb.y, bb.color,
                (i + 1 < (int)p.bitblks.count) ? @"," : @""];
        }
        [s appendString:@"};\n\n"];
    }

    NSMutableDictionary<NSValue *, NSNumber *> *cicoOf = [NSMutableDictionary dictionary];
    if (p.cicons.count) {
        [s appendString:@"// ---- CICON (pam/text filled in by the fixup) -------------------------\n"];
        [s appendFormat:@"CICON rs_ci[%d] = {\n", (int)p.cicons.count];
        for (int i = 0; i < (int)p.cicons.count; i++) {
            GObject *o = p.cicons[i];
            cicoOf[[NSValue valueWithNonretainedObject:o]] = @(i);
            NSData *pam = cicoPAM(o);
            [s appendFormat:@"    { 0, %lu, 0 }%@\n", (unsigned long)pam.length,
                            (i + 1 < (int)p.cicons.count) ? @"," : @""];
        }
        [s appendString:@"};\n\n"];
    }

    [s appendString:@"// ---- object trees (ob_spec filled in by the fixup) -------------------\n"];
    for (GXTree *xt in p.trees) {
        [s appendFormat:@"OBJECT %@[%d] = {\n", xt.var, (int)xt.objects.count];
        for (int i = 0; i < (int)xt.objects.count; i++) {
            GObject *o = xt.objects[i];
            int nx, hd, tl; linksFor(xt, i, &nx, &hd, &tl);
            // A box word is a plain integer, so it folds here — no fixup needed.
            NSString *spec = specIsBox(o) ? [NSString stringWithFormat:@"$%08X", boxWord(o)] : @"0";
            [s appendFormat:@"    { %4d, %4d, %4d, $%04X, $%04X, $%04X, %@ %4d, %4d, %4d, %4d }%@  // %@\n",
                nx, hd, tl, obTypeWord(o),
                (uint16_t)o.flags, (uint16_t)o.state,
                padTo([spec stringByAppendingString:@","], 10),
                o.x, o.y, o.w, o.h,
                (i + 1 < (int)xt.objects.count) ? @"," : @"",
                xt.syms[i]];
        }
        [s appendString:@"};\n\n"];
    }

    [s appendFormat:@"OBJECT@ rs_trees[%d];\n", (int)p.trees.count];
    if (p.freeStrings.count)
        [s appendFormat:@"u32 rs_free_strings[%d];    // filled in by the fixup\n",
                        (int)p.freeStrings.count];
    if (res.freeImages.count)
        [s appendFormat:@"u32 rs_free_images[%d];     // filled in by the fixup\n",
                        (int)res.freeImages.count];
    [s appendString:@"\n"];

    [s appendString:@"// ---- fixup: resolve every address once, at start-up ------------------\n"];
    [s appendFormat:@"void %@_fixup(void)\n{\n", ident];
    for (int i = 0; i < (int)p.teds.count; i++) {
        GTedinfo *t = p.teds[i].ted ?: [GTedinfo new];
        [s appendFormat:@"    rs_ted[%d].te_ptext  = (u32)rs_str%d;\n", i, internStr(p, t.text)];
        [s appendFormat:@"    rs_ted[%d].te_ptmplt = (u32)rs_str%d;\n", i, internStr(p, t.tmplt)];
        [s appendFormat:@"    rs_ted[%d].te_pvalid = (u32)rs_str%d;\n", i, internStr(p, t.valid)];
    }
    for (int i = 0; i < (int)p.icons.count; i++) {
        GIcon *g = p.icons[i].icon ?: [GIcon new];
        int mk = internBlob(p, g.monoMask), dt = internBlob(p, g.monoData);
        if (mk >= 0) [s appendFormat:@"    rs_ib[%d].ib_pmask = (u32)rs_blob%d;\n", i, mk];
        if (dt >= 0) [s appendFormat:@"    rs_ib[%d].ib_pdata = (u32)rs_blob%d;\n", i, dt];
        [s appendFormat:@"    rs_ib[%d].ib_ptext = (u32)rs_str%d;\n", i, internStr(p, g.label)];
    }
    for (int i = 0; i < (int)p.cicons.count; i++) {
        GObject *o = p.cicons[i];
        GIcon *g = o.icon ?: [GIcon new];
        int bi = internBlob(p, cicoPAM(o));
        if (bi >= 0) [s appendFormat:@"    rs_ci[%d].pam  = (u32)rs_blob%d;\n", i, bi];
        [s appendFormat:@"    rs_ci[%d].text = (u32)rs_str%d;\n", i, internStr(p, g.label)];
    }
    for (int i = 0; i < (int)p.bitblks.count; i++) {
        int bi = internBlob(p, p.bitblks[i].data);
        [s appendFormat:@"    rs_bb[%d].bi_pdata = %@;\n", i,
            bi < 0 ? @"0" : [NSString stringWithFormat:@"(u32)rs_blob%d", bi]];
    }
    if (p.teds.count || p.icons.count || p.cicons.count || p.bitblks.count) [s appendString:@"\n"];

    for (GXTree *xt in p.trees) {
        for (int i = 0; i < (int)xt.objects.count; i++) {
            GObject *o = xt.objects[i];
            NSString *rhs = nil;
            if (specIsString(o))
                rhs = [NSString stringWithFormat:@"(u32)rs_str%d", internStr(p, o.text)];
            else if (specIsTed(o))
                rhs = [NSString stringWithFormat:@"(u32)&rs_ted[%@]",
                                tedOf[[NSValue valueWithNonretainedObject:o]]];
            else if (specIsIcon(o))
                rhs = [NSString stringWithFormat:@"(u32)&rs_ib[%@]",
                                iconOf[[NSValue valueWithNonretainedObject:o]]];
            else if (specIsCicon(o))
                rhs = [NSString stringWithFormat:@"(u32)&rs_ci[%@]",
                                cicoOf[[NSValue valueWithNonretainedObject:o]]];
            else if (specIsBitblk(o))
                rhs = [NSString stringWithFormat:@"(u32)&rs_bb[%@]",
                                bbOf[[NSValue valueWithNonretainedObject:o.bitblk]]];
            if (rhs) [s appendFormat:@"    %@[%s].ob_spec = %@;\n",
                                     xt.var, xt.syms[i].UTF8String, rhs];
        }
    }
    [s appendString:@"\n"];
    for (int i = 0; i < (int)p.freeStrings.count; i++)
        [s appendFormat:@"    rs_free_strings[%s] = (u32)rs_str%d;\n",
                        p.freeSyms[i].UTF8String, internStr(p, p.freeStrings[i])];
    for (int i = 0; i < (int)res.freeImages.count; i++)
        [s appendFormat:@"    rs_free_images[%d] = (u32)&rs_bb[%@];\n", i,
                        bbOf[[NSValue valueWithNonretainedObject:res.freeImages[i]]]];
    if (p.freeStrings.count || res.freeImages.count) [s appendString:@"\n"];

    for (int ti = 0; ti < (int)p.trees.count; ti++)
        [s appendFormat:@"    rs_trees[%@] = &%@[0];\n", p.trees[ti].sym, p.trees[ti].var];
    [s appendString:@"}\n"];
    return s;
}
