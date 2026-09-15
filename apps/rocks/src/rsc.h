/* rsc.h — portable GEM .rsc reader/writer (pure C, no dependencies).
 *
 * One implementation shared by the Rocks editor (Objective-C wraps this) and
 * the XT GEM C desktop, so both read and write byte-identical files.
 *
 * On disk the format is classic big-endian GEM (RSHDR + OBJECT + TEDINFO +
 * ICONBLK + strings + tree index) with a few documented extensions (see
 * RSC-FORMAT.md): extended widget types (G_CHECKBOX..G_CICON), colour icons /
 * images as embedded P7 PAM, and use of the ob_type high byte.
 *
 * In memory the OBJECT trees are "loaded" the way the AES expects: ob_spec is a
 * resolved pointer (char* / TEDINFO* / ICONBLK* / CICON*, or an inline box word),
 * ob_head/ob_tail/ob_next are indices relative to each tree's root, and
 * coordinates are in pixels. rsc_read owns all memory; rsc_free releases it.
 *
 * Only <stdint.h>/<stddef.h>/<stdlib.h>/<string.h> are used, so this compiles on
 * the host and the target unchanged. It does NOT decode/encode PAM pixels or
 * draw anything — it only moves bytes between disk and OBJECT trees.
 *
 * ---- Integration ---------------------------------------------------------
 *   Add rsc.c + rsc.h to your build.  If you already have an AES header that
 *   defines OF_/OS_/BOX_ROUND_ and the G_ object types, #define
 *   RSC_NO_STATE_FLAGS (and provide a `G_BOX` macro) before including rsc.h so
 *   the duplicates are skipped; then treat RSC_OBJECT as your OBJECT (its field
 *   layout matches AES aes.h: ob_w/ob_h, void* ob_spec).
 *
 * ---- Reading -------------------------------------------------------------
 *   const char *err = NULL;
 *   RSC *r = rsc_read(file_bytes, file_len, &err);   // NULL + err on failure
 *   if (r) {
 *       RSC_OBJECT *tree = rsc_tree(r, 0);           // root of tree 0
 *       // Walk it like the AES: indices are relative to the tree root, so
 *       // children are tree[tree[obj].ob_head], siblings via .ob_next, until
 *       // .ob_tail.  ob_spec is already a pointer (char* / RSC_TEDINFO* / ...).
 *       for (int c = tree->ob_head; c != RSC_NIL; c = tree[c].ob_next) {
 *           RSC_OBJECT *o = &tree[c];
 *           if ((o->ob_type & 0xFF) == G_STRING) puts((char *)o->ob_spec);
 *           if (c == tree->ob_tail) break;
 *       }
 *       rsc_free(r);                                 // frees everything
 *   }
 *
 * ---- Writing (building a resource) ---------------------------------------
 *   RSC *r = rsc_new();
 *   int base = rsc_alloc_objects(r, 2);              // root + one child
 *   rsc_add_tree(r, base);                           // tree 0 roots at `base`
 *   RSC_OBJECT *o = rsc_objects(r, NULL);            // re-fetch after any alloc
 *   o[base+0] = (RSC_OBJECT){ RSC_NIL, 1, 1, G_BOX, 0, OS_NORMAL,
 *                             (void*)(uintptr_t)RSC_BOXWORD(0,2,0x1100), 0,0,320,200 };
 *   o[base+1] = (RSC_OBJECT){ 0, RSC_NIL, RSC_NIL, G_STRING, OF_LASTOB, OS_NORMAL,
 *                             rsc_intern_str(r,"Hello"), 16,10,120,16 };
 *   uint8_t *bytes; size_t len; const char *err;
 *   if (rsc_write(r, &bytes, &len, &err) == 0) { fwrite(bytes,1,len,f); free(bytes); }
 *   rsc_free(r);
 *
 * Notes: ob_head/ob_tail/ob_next are indices RELATIVE to the tree root (0-based
 * within the tree, contiguous).  rsc_alloc_objects may realloc the object array,
 * so fetch the pointer with rsc_objects() AFTER the last allocation.  Strings and
 * sub-structures must come from the rsc_intern_ and rsc_new_ helpers (arena-
 * owned) so they outlive the call.  Coordinates are pixels; packing uses an 8x16 cell by
 * default (rsc_set_cell to change).
 */
#ifndef RSC_H
#define RSC_H

#include <stdint.h>
#include <stddef.h>

/* ---- object types / flags / states (classic + XT GEM extensions) -------- */
#ifndef G_BOX
enum
    {
    G_BOX = 20,
    G_TEXT = 21,
    G_BOXTEXT = 22,
    G_IMAGE = 23,
    G_USERDEF = 24,
    G_IBOX = 25,
    G_BUTTON = 26,
    G_BOXCHAR = 27,
    G_STRING = 28,
    G_FTEXT = 29,
    G_FBOXTEXT = 30,
    G_ICON = 31,
    G_TITLE = 32,
    /* The standard Atari colour icon: a CICONBLK (see below).  Only present in
        * "new format" files (rsh_vrsn & RSC_VRSN_EXTENDED). */
    G_CICON = 33,
    /* XT GEM extensions.  G_PAMICON is Rocks' own colour icon: a straight
        * RGBA P7 PAM, which unlike a CICONBLK keeps alpha and true colour. */
    G_CHECKBOX = 40,
    G_RADIO = 41,
    G_POPUP = 42,
    G_FIELD = 43,
    G_PAMICON = 44
    };
#endif

/* rsh_vrsn bit 2: the file has an extension appended past the classic image,
 * holding CICONBLKs and a 32-bit true file size (EmuTOS calls this
 * NEW_FORMAT_RSC).  Note this does NOT lift the 64KB limit on the classic
 * tables — every RSHDR offset is a 16-bit word — it only lets the icon data,
 * which is reached through 32-bit offsets, live beyond it. */
#define RSC_VRSN_EXTENDED 0x0004

/* rsh_vrsn bit 3: WE wrote this file.
 *
 * Rocks reuses the ob_type HIGH byte for its own meaning (corner rounding, the
 * "rounded field" / group-box flag, a G_POPUP's linked-tree index — see
 * RSC-FORMAT.md §5).  But the classic AES masks ob_type & 0xFF and ignores the
 * high byte, so other editors have long used it as a free "extended type" field:
 * a scan of 112 real resources finds it non-zero on G_BOX, G_IBOX, G_BUTTON,
 * G_BOXTEXT and G_STRING, with values 0x02..0x13.  Reading those as Rocks flags
 * turns 75 of them into spuriously rounded boxes and fields.
 *
 * So the high byte only carries Rocks' meaning when this bit says so.  In a file
 * without it the byte is preserved verbatim (and written back unchanged) but is
 * not allowed to mean anything. */
#define RSC_VRSN_ROCKS 0x0008
/* Flag/state constants.  Define RSC_NO_STATE_FLAGS before including this header
 * if your project already provides the OF_, OS_ and BOX_ROUND_ constants (e.g.
 * from an AES header), to avoid a redefinition. */
#ifndef RSC_NO_STATE_FLAGS
enum
    {
    OF_NONE = 0x00,
    OF_SELECTABLE = 0x01,
    OF_DEFAULT = 0x02,
    OF_EXIT = 0x04,
    OF_EDITABLE = 0x08,
    OF_RBUTTON = 0x10,
    OF_LASTOB = 0x20,
    OF_TOUCHEXIT = 0x40,
    OF_HIDETREE = 0x80,
    /* XT GEM runtime extensions (reuse freed 3D-flag bit positions): */
    OF_CANCEL = 0x200, /* Esc fires this object (Cancel affordance)      */
    OF_MOVEABLE = 0x400
    }; /* on the tree ROOT: the dialog is movable        */
enum
    {
    OS_NORMAL = 0x00,
    OS_SELECTED = 0x01,
    OS_CROSSED = 0x02,
    OS_CHECKED = 0x04,
    OS_DISABLED = 0x08,
    OS_OUTLINED = 0x10,
    OS_SHADOWED = 0x20,
    OS_WHITEBAK = 0x40
    }; /* mnemonic present; bits 8-14 = shortcut char idx */
/* ob_type high byte (extended byte): per-corner box rounding */
enum
    {
    BOX_ROUND_TL = 0x10,
    BOX_ROUND_TR = 0x20,
    BOX_ROUND_BR = 0x40,
    BOX_ROUND_BL = 0x80
    };
#endif
/* mnemonic index accessor (valid when OS_WHITEBAK is set) */
#define RSC_WB_INDEX(state) (((state) >> 8) & 0x7F)

#define RSC_NIL (-1)

/* ---- resource sub-structures (in memory; pointers resolved) --------------- */

typedef struct
    {
    char *te_ptext, *te_ptmplt, *te_pvalid;
    int16_t te_font, te_fontid, te_just, te_color, te_fontsize, te_thickness;
    int16_t te_txtlen, te_tmplen;
    } RSC_TEDINFO;

typedef struct
    {
    uint8_t *ib_pmask, *ib_pdata; /* bitplane data (may be NULL) */
    char* ib_ptext;
    int16_t ib_char, ib_xchar, ib_ychar;
    int16_t ib_xicon, ib_yicon, ib_wicon, ib_hicon;
    int16_t ib_xtext, ib_ytext, ib_wtext, ib_htext;
    } RSC_ICONBLK;

/* Rocks extension: a colour icon/image stored as a self-delimiting P7 PAM. */
typedef struct
    {
    uint8_t* pam; /* embedded PAM bytes (NULL if none) */
    uint32_t pam_len;
    char* text; /* optional label */
    } RSC_PAMICON;

/* A classic monochrome bitmap: 1 bit per pixel, bi_wb bytes per row, bi_hl rows,
 * so the data is bi_wb * bi_hl bytes.  Set bits are drawn in VDI pen bi_color;
 * clear bits are left alone (a BITBLK has no mask — it is a bit *form*).
 *
 * Reached two ways: a G_IMAGE object's ob_spec, and the free-image table
 * (rsrc_gaddr(R_IMAGE, i)).  Note Rocks also uses G_IMAGE for its own embedded
 * PAM; the two are told apart on read by the PAM's "P7" magic. */
typedef struct
    {
    uint8_t* bi_pdata;
    int16_t bi_wb, bi_hl, bi_x, bi_y, bi_color;
    } RSC_BITBLK;

/* ---- the standard Atari colour icon (G_CICON) ---------------------------- */
/* One colour version of an icon, at one screen depth.  The data is PLANAR and
 * palette-indexed and the mask is 1 bit per pixel — a CICONBLK cannot carry
 * alpha or true colour, which is why Rocks keeps its own RGBA PAM alongside. */
typedef struct
    {
    int16_t num_planes;
    uint8_t* col_data; /* planar: plane_bytes * num_planes */
    uint8_t* col_mask; /* plane_bytes, 1bpp                */
    uint8_t* sel_data; /* optional SELECTED form (NULL if absent) */
    uint8_t* sel_mask;
    } RSC_CICON_REZ;

/* A CICONBLK: the mono fallback (which also carries the geometry and label),
 * plus one RSC_CICON_REZ per screen depth. */
typedef struct
    {
    RSC_ICONBLK mono;
    int16_t nrez;
    RSC_CICON_REZ* rez;
    /* The block's bytes exactly as they were read, so a file that came in can go
     * back out unchanged even though we only render the deepest version. */
    uint8_t* raw;
    uint32_t raw_len;
    } RSC_CICONBLK;

/* An entry of the optional 256-colour palette an extended file may carry.
 * r/g/b are VDI thousandths (0..1000); `pen` is the VDI pen this index maps to. */
typedef struct
    {
    int16_t r, g, b, pen;
    } RSC_RGB;

/* ---- the AES OBJECT (in-memory layout) ----------------------------------- */
/* Field names match XT GEM aes.h so the desktop can use these directly. */
typedef struct
    {
    int16_t ob_next, ob_head, ob_tail; /* indices relative to the tree root */
    uint16_t ob_type;                  /* low byte = G_*, high byte = extended */
    uint16_t ob_flags;
    uint16_t ob_state;
    void* ob_spec;                  /* char* | RSC_TEDINFO* | RSC_ICONBLK* |
                                             RSC_PAMICON* | inline box word (see below) */
    int16_t ob_x, ob_y, ob_w, ob_h; /* pixels */
    } RSC_OBJECT;

/* For G_BOX / G_IBOX / G_BOXCHAR, ob_spec is an inline 32-bit "box word":
 * (character<<24) | (thickness<<16) | colour_word. Use these to pack/unpack. */
#define RSC_BOXWORD(ch, thick, colour) \
    (((uint32_t)((ch) & 0xFF) << 24) | ((uint32_t)((thick) & 0xFF) << 16) | ((colour) & 0xFFFF))
#define RSC_BOX_CHAR(w) (((uint32_t)(w) >> 24) & 0xFF)
#define RSC_BOX_THICK(w) ((int8_t)(((uint32_t)(w) >> 16) & 0xFF))
#define RSC_BOX_COLOUR(w) ((uint16_t)((uint32_t)(w) & 0xFFFF))
#define RSC_OB_BOXWORD(o) ((uint32_t)(uintptr_t)(o)->ob_spec)

/* ---- the loaded resource ------------------------------------------------- */
typedef struct RSC RSC; /* opaque; owns all memory */

/* Parse a big-endian classic-or-extended .rsc image (little-endian tolerated on
 * read). Returns a handle, or NULL with *err set (err may be NULL). */
RSC* rsc_read(const uint8_t* data, size_t len, const char** err);

int rsc_ntrees(const RSC* r);
RSC_OBJECT* rsc_tree(const RSC* r, int index);         /* root OBJECT of tree `index` */
RSC_OBJECT* rsc_objects(const RSC* r, int* count_out); /* the flat array */

/* Free strings (rsrc_gaddr(R_STRING, i)) — a plain indexed table of text that
 * belongs to the resource but hangs off no object. */
int rsc_nstrings(const RSC* r);
const char* rsc_string(const RSC* r, int index);
int rsc_add_string(RSC* r, const char* s); /* returns its index */

/* The optional 256-entry palette an extended file may carry (NULL if absent). */
const RSC_RGB* rsc_palette(const RSC* r);

/* Was this file in the extended (CICONBLK-bearing) format? */
int rsc_is_extended(const RSC* r);
/* Did WE write it?  If not, the ob_type high byte is a legacy extended-type value
 * and must not be read as Rocks' rounding / popup-link flags. */
int rsc_is_rocks(const RSC* r);

/* Free images: rsrc_gaddr(R_IMAGE, i) — a table of monochrome bitmaps that
 * belongs to the resource but hangs off no object. */
int rsc_nfreeimages(const RSC* r);
RSC_BITBLK* rsc_freeimage(const RSC* r, int index);
int rsc_add_freeimage(RSC* r, RSC_BITBLK* bb); /* returns its index */

/* The colour icons an extended file carried.  A G_CICON object's ob_spec points
 * straight at one of these once rsc_read has resolved it. */
int rsc_nciconblks(const RSC* r);
RSC_CICONBLK* rsc_ciconblk(const RSC* r, int index);

/* Serialize to a big-endian .rsc image (classic layout + extensions). Allocates
 * *out (caller free()s it). Returns 0 on success, non-zero on error. */
int rsc_write(const RSC* r, uint8_t** out, size_t* len, const char** err);

void rsc_free(RSC* r);

/* ---- building a resource programmatically (used by the editor bridge) ----- */
/* Create an empty resource. */
RSC* rsc_new(void);
/* Allocate `n` zeroed OBJECTs owned by the resource; returns the base index. */
int rsc_alloc_objects(RSC* r, int n);
/* Register object index `root` as tree number returned. */
int rsc_add_tree(RSC* r, int root);
/* Copy a string / bytes into the resource's arena (returns an owned pointer). */
char* rsc_intern_str(RSC* r, const char* s);
uint8_t* rsc_intern_bytes(RSC* r, const uint8_t* b, uint32_t n);
/* Allocate a zeroed sub-structure in the arena. */
RSC_TEDINFO* rsc_new_tedinfo(RSC* r);
RSC_ICONBLK* rsc_new_iconblk(RSC* r);
RSC_PAMICON* rsc_new_pamicon(RSC* r);
RSC_CICONBLK* rsc_new_ciconblk(RSC* r);
RSC_BITBLK* rsc_new_bitblk(RSC* r);

/* Coordinate cell used when packing/unpacking (default 8×16). */
void rsc_set_cell(RSC* r, int cw, int ch);

#endif /* RSC_H */
