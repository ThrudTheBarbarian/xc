/* rsc.c — see rsc.h.  Portable C GEM .rsc reader/writer. */

#include "rsc.h"
#include <stdlib.h>
#include <string.h>

enum { SZ_OBJ = 24, SZ_TED = 28, SZ_IB = 34, SZ_BB = 14, SZ_HDR = 36 };

/* ---- arena (block list; pointers stay valid for the resource's lifetime) -- */
typedef struct ArenaBlock { struct ArenaBlock *next; size_t used, cap; } ArenaBlock;

struct RSC {
    RSC_OBJECT *obj;   int nobj, obj_cap;
    int32_t    *trees; int ntree, tree_cap;
    ArenaBlock *arena;
    int cell_w, cell_h;
    /* extended format (rsh_vrsn & RSC_VRSN_EXTENDED) */
    int            extended;
    int            rocks;      /* rsh_vrsn & RSC_VRSN_ROCKS: our own ob_type high byte */
    RSC_CICONBLK **cib;     int ncib;       /* indexed by a G_CICON's ob_spec */
    RSC_RGB       *palette;                 /* 256 entries, or NULL */
    /* free strings: rsrc_gaddr(R_STRING, i) */
    char         **strings; int nstring, string_cap;
    /* free images: rsrc_gaddr(R_IMAGE, i) */
    RSC_BITBLK   **freeimg; int nfreeimg, freeimg_cap;
};

static void *arena_alloc(RSC *r, size_t n) {
    n = (n + 7) & ~(size_t)7;
    ArenaBlock *b = r->arena;
    if (!b || b->used + n > b->cap) {
        size_t cap = n > 65536 ? n : 65536;
        b = (ArenaBlock *)malloc(sizeof(ArenaBlock) + cap);
        if (!b) return NULL;
        b->next = r->arena; b->used = 0; b->cap = cap;
        r->arena = b;
    }
    void *p = (uint8_t *)(b + 1) + b->used;
    b->used += n;
    memset(p, 0, n);
    return p;
}

/* ---- byte order (files are big-endian) ----------------------------------- */
static uint16_t rd16(const uint8_t *p, int be) {
    return be ? (uint16_t)((p[0] << 8) | p[1]) : (uint16_t)((p[1] << 8) | p[0]);
}
static uint32_t rd32(const uint8_t *p, int be) {
    return be ? ((uint32_t)p[0]<<24 | (uint32_t)p[1]<<16 | (uint32_t)p[2]<<8 | p[3])
              : ((uint32_t)p[3]<<24 | (uint32_t)p[2]<<16 | (uint32_t)p[1]<<8 | p[0]);
}
static void wr16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }
static void wr32(uint8_t *p, uint32_t v) {
    p[0]=(uint8_t)(v>>24); p[1]=(uint8_t)(v>>16); p[2]=(uint8_t)(v>>8); p[3]=(uint8_t)v;
}

static int unpack_coord(uint16_t raw, int cell) {
    int lo = raw & 0xff; int hi = (int8_t)((raw >> 8) & 0xff);
    return lo * cell + hi;
}
static uint16_t pack_coord(int px, int cell) {
    if (cell <= 0) cell = 8;
    int chars = px / cell, extra = px - chars * cell;
    return (uint16_t)(((extra & 0xff) << 8) | (chars & 0xff));
}

/* exact byte length of a P7 PAM at offset (header + WIDTH*HEIGHT*DEPTH) */
static uint32_t pam_len(const uint8_t *p, size_t len, uint32_t off) {
    if (off + 2 >= len || p[off] != 'P' || p[off+1] != '7') return 0;
    size_t i = off + 2; int w = 0, h = 0, depth = 0;
    while (i < len) {
        size_t s = i; while (i < len && p[i] != '\n') i++;
        size_t n = i - s; const char *ln = (const char *)(p + s);
        if (i < len) i++;
        if      (n >= 6 && !memcmp(ln, "ENDHDR", 6)) break;
        else if (n >= 6 && !memcmp(ln, "WIDTH ",  6)) w     = atoi(ln + 6);
        else if (n >= 7 && !memcmp(ln, "HEIGHT ", 7)) h     = atoi(ln + 7);
        else if (n >= 6 && !memcmp(ln, "DEPTH ",  6)) depth = atoi(ln + 6);
    }
    if (w <= 0 || h <= 0 || depth <= 0) return 0;
    return (uint32_t)((i - off) + (size_t)w * h * depth);
}

/* type categories (low byte of ob_type) */
static int is_box(int t)    { return t==G_BOX || t==G_IBOX || t==G_BOXCHAR; }
static int is_string(int t) { return t==G_STRING||t==G_BUTTON||t==G_TITLE||t==G_CHECKBOX||t==G_RADIO||t==G_POPUP; }
static int is_ted(int t)    { return t==G_TEXT||t==G_BOXTEXT||t==G_FTEXT||t==G_FBOXTEXT||t==G_FIELD; }
static int is_pam(int t)    { return t==G_PAMICON; }   /* G_IMAGE is handled separately */

static char *dup_cstr(RSC *r, const uint8_t *p, size_t len, uint32_t off) {
    if (off == 0 || off >= len) return arena_alloc(r, 1);   /* "" */
    uint32_t e = off; while (e < len && p[e]) e++;
    char *s = arena_alloc(r, e - off + 1);
    if (s) memcpy(s, p + off, e - off);
    return s;
}

/* A BITBLK: 14 bytes on disk, then bi_wb * bi_hl bytes of 1bpp data. */
static RSC_BITBLK *read_bitblk(RSC *r, const uint8_t *p, size_t len, uint32_t off, int be) {
    if (!off || off + SZ_BB > len) return NULL;
    RSC_BITBLK *bb = rsc_new_bitblk(r);
    if (!bb) return NULL;
    const uint8_t *b = p + off;
    uint32_t pdata  = rd32(b + 0, be);
    bb->bi_wb    = (int16_t)rd16(b + 4, be);
    bb->bi_hl    = (int16_t)rd16(b + 6, be);
    bb->bi_x     = (int16_t)rd16(b + 8, be);
    bb->bi_y     = (int16_t)rd16(b + 10, be);
    bb->bi_color = (int16_t)rd16(b + 12, be);
    uint32_t bytes = (uint32_t)(bb->bi_wb > 0 ? bb->bi_wb : 0) * (uint32_t)(bb->bi_hl > 0 ? bb->bi_hl : 0);
    if (pdata && bytes && pdata + bytes <= len) bb->bi_pdata = rsc_intern_bytes(r, p + pdata, bytes);
    return bb;
}

/* ---- the extended (CICONBLK) section -------------------------------------
 *
 * Past the classic image, at the word-aligned rsh_rssize, sits a 0-terminated
 * array of LONGs:
 *      [0] the true file size (rsh_rssize is only 16 bits, so it cannot say)
 *      [1] offset of the CICONBLK pointer array   (0 / -1 = none)
 *      [2] offset of an optional 256-colour palette
 *
 * The pointer array is LONGs terminated by -1, one per CICONBLK; the blocks
 * themselves follow it packed back to back:
 *
 *      ICONBLK   (34 bytes: the mono fallback, geometry and label)
 *      LONG      numRez
 *      mono data (isize)          isize = ((wicon+15)/16)*2 * hicon
 *      mono mask (isize)
 *      char[12]  unused name slot (ib_ptext points here when ib_wtext == 0)
 *      numRez x {
 *          CICON header (22 bytes; sel_data non-zero = a SELECTED form follows)
 *          col_data (isize * num_planes)
 *          col_mask (isize)
 *          [ sel_data (isize * num_planes), sel_mask (isize) ]
 *      }
 *
 * A G_CICON object's ob_spec is an INDEX into the pointer array, not an offset.
 */
static uint32_t iconblk_bytes(int w, int h) {
    if (w <= 0 || h <= 0) return 0;
    return (uint32_t)(((w + 15) / 16) * 2) * (uint32_t)h;
}

/* Read one ICONBLK's fields (34 bytes) — shared by G_ICON and a CICONBLK's mono. */
static void read_iconblk(RSC_ICONBLK *ib, const uint8_t *b, int be) {
    ib->ib_char  = (int16_t)rd16(b + 12, be);
    ib->ib_xchar = (int16_t)rd16(b + 14, be); ib->ib_ychar = (int16_t)rd16(b + 16, be);
    ib->ib_xicon = (int16_t)rd16(b + 18, be); ib->ib_yicon = (int16_t)rd16(b + 20, be);
    ib->ib_wicon = (int16_t)rd16(b + 22, be); ib->ib_hicon = (int16_t)rd16(b + 24, be);
    ib->ib_xtext = (int16_t)rd16(b + 26, be); ib->ib_ytext = (int16_t)rd16(b + 28, be);
    ib->ib_wtext = (int16_t)rd16(b + 30, be); ib->ib_htext = (int16_t)rd16(b + 32, be);
}

/* Returns 0 on success. On failure the resource is still usable, just without
 * colour icons — a broken extension must not lose the dialogs. */
static int parse_extension(RSC *r, const uint8_t *p, size_t len, uint16_t rssize, int be) {
    size_t osize = ((size_t)rssize + 1) & ~(size_t)1;
    if (osize + 8 > len) return -1;

    uint32_t cib_off = rd32(p + osize + 4, be);
    uint32_t pal_off = (osize + 12 <= len) ? rd32(p + osize + 8, be) : 0;
    r->extended = 1;

    if (pal_off && pal_off != 0xFFFFFFFFu && pal_off + 256 * 8 <= len) {
        r->palette = arena_alloc(r, 256 * sizeof(RSC_RGB));
        if (r->palette)
            for (int i = 0; i < 256; i++) {
                const uint8_t *e = p + pal_off + (size_t)i * 8;
                r->palette[i].r   = (int16_t)rd16(e + 0, be);
                r->palette[i].g   = (int16_t)rd16(e + 2, be);
                r->palette[i].b   = (int16_t)rd16(e + 4, be);
                r->palette[i].pen = (int16_t)rd16(e + 6, be);
            }
    }
    if (!cib_off || cib_off == 0xFFFFFFFFu || cib_off >= len) return 0;   /* no colour icons */

    /* the pointer array: LONGs, terminated by -1 */
    int n = 0;
    while (cib_off + (size_t)(n + 1) * 4 <= len && rd32(p + cib_off + (size_t)n * 4, be) != 0xFFFFFFFFu) {
        if (++n > 4096) return -1;                      /* runaway: not a real array */
    }
    if (n == 0) return 0;

    r->cib = arena_alloc(r, (size_t)n * sizeof(RSC_CICONBLK *));
    if (!r->cib) return -1;
    r->ncib = n;

    size_t at = cib_off + (size_t)(n + 1) * 4;          /* first block, past the -1 */
    for (int i = 0; i < n; i++) {
        if (at + 38 > len) { r->ncib = i; return -1; }
        size_t start = at;
        RSC_CICONBLK *cb = rsc_new_ciconblk(r);
        if (!cb) return -1;
        r->cib[i] = cb;

        read_iconblk(&cb->mono, p + at, be);
        uint32_t isize = iconblk_bytes(cb->mono.ib_wicon, cb->mono.ib_hicon);
        int32_t numRez = (int32_t)rd32(p + at + 34, be);
        if (isize == 0 || numRez < 0 || numRez > 32) { r->ncib = i; return -1; }
        at += 38;

        if (at + 2 * (size_t)isize + 12 > len) { r->ncib = i; return -1; }
        cb->mono.ib_pdata = rsc_intern_bytes(r, p + at, isize); at += isize;
        cb->mono.ib_pmask = rsc_intern_bytes(r, p + at, isize); at += isize;
        /* ib_ptext is a file offset when the icon has a text box, otherwise it
         * points at the 12-byte name slot that follows the mask. */
        uint32_t ptext = rd32(p + start + 8, be);
        cb->mono.ib_ptext = (cb->mono.ib_wtext && ptext && ptext < len)
                          ? dup_cstr(r, p, len, ptext)
                          : dup_cstr(r, p, len, (uint32_t)at);
        at += 12;                                        /* the unused name slot */

        cb->nrez = (int16_t)numRez;
        cb->rez  = numRez ? arena_alloc(r, (size_t)numRez * sizeof(RSC_CICON_REZ)) : NULL;
        for (int j = 0; j < numRez; j++) {
            if (at + 22 > len) { cb->nrez = (int16_t)j; r->ncib = i + 1; return -1; }
            RSC_CICON_REZ *z = &cb->rez[j];
            z->num_planes = (int16_t)rd16(p + at, be);
            int has_sel   = rd32(p + at + 10, be) != 0;  /* the sel_data slot is a flag */
            uint32_t psize = isize * (uint32_t)(z->num_planes > 0 ? z->num_planes : 0);
            at += 22;
            if (z->num_planes <= 0 || z->num_planes > 32 ||
                at + psize + isize + (has_sel ? psize + isize : 0) > len) {
                cb->nrez = (int16_t)j; r->ncib = i + 1; return -1;
            }
            z->col_data = rsc_intern_bytes(r, p + at, psize); at += psize;
            z->col_mask = rsc_intern_bytes(r, p + at, isize); at += isize;
            if (has_sel) {
                z->sel_data = rsc_intern_bytes(r, p + at, psize); at += psize;
                z->sel_mask = rsc_intern_bytes(r, p + at, isize); at += isize;
            } else {
                z->sel_data = z->sel_mask = NULL;
            }
        }
        /* keep the block verbatim so an imported file can go back out unchanged */
        cb->raw_len = (uint32_t)(at - start);
        cb->raw = rsc_intern_bytes(r, p + start, cb->raw_len);
    }
    return 0;
}

/* ---- reader -------------------------------------------------------------- */

static RSC *try_parse(const uint8_t *p, size_t len, int be) {
    if (len < SZ_HDR) return NULL;
    uint16_t h[18];
    for (int i = 0; i < 18; i++) h[i] = rd16(p + i*2, be);
    uint32_t objBase = h[1], tedBase = h[2], ibBase = h[3], trindex = h[9];
    int nobs = h[10], ntree = h[11];
    uint16_t rssize = h[17];
    int rocks = (h[0] & RSC_VRSN_ROCKS) != 0;

    /* A cursor/image bank (EmuTOS's mform.rsc, emucurs*.rsc) has NO object trees
     * at all — just a free-image table.  Accept that, as long as it carries
     * something. */
    int nstr_h = (int16_t)h[15], nimg_h = (int16_t)h[16];
    if (nobs < 0 || nobs > 8000 || ntree < 0 || ntree > 2000) return NULL;
    if (ntree == 0 && nstr_h <= 0 && nimg_h <= 0) return NULL;   /* nothing at all */
    if (nobs > 0) {
        if (objBase < SZ_HDR || objBase >= len) return NULL;
        if (objBase + (size_t)nobs * SZ_OBJ > len) return NULL;
    }
    if (ntree > 0 && trindex + (size_t)ntree * 4 > len) return NULL;
    if (rssize != 0 && rssize != len && rssize < objBase) return NULL;

    RSC *r = rsc_new();
    if (!r) return NULL;
    r->rocks = rocks;
    if (nobs > 0) {                       /* calloc(0, n) may legitimately return NULL */
        r->obj = (RSC_OBJECT *)calloc(nobs, sizeof(RSC_OBJECT));
        if (!r->obj) { rsc_free(r); return NULL; }
    }
    r->nobj = r->obj_cap = nobs;
    int cw = r->cell_w, ch = r->cell_h;

    for (int i = 0; i < nobs; i++) {
        const uint8_t *o = p + objBase + (size_t)i * SZ_OBJ;
        RSC_OBJECT *g = &r->obj[i];
        g->ob_next  = (int16_t)rd16(o + 0, be);
        g->ob_head  = (int16_t)rd16(o + 2, be);
        g->ob_tail  = (int16_t)rd16(o + 4, be);
        g->ob_type  = rd16(o + 6, be);         /* keep both bytes */
        g->ob_flags = rd16(o + 8, be);
        g->ob_state = rd16(o + 10, be);
        uint32_t spec = rd32(o + 12, be);
        g->ob_x = (int16_t)unpack_coord(rd16(o + 16, be), cw);
        g->ob_y = (int16_t)unpack_coord(rd16(o + 18, be), ch);
        g->ob_w = (int16_t)unpack_coord(rd16(o + 20, be), cw);
        g->ob_h = (int16_t)unpack_coord(rd16(o + 22, be), ch);

        int t = g->ob_type & 0xFF;
        if (is_box(t)) {
            g->ob_spec = (void *)(uintptr_t)spec;               /* inline box word */
        } else if (is_string(t)) {
            g->ob_spec = dup_cstr(r, p, len, spec);
        } else if (is_ted(t)) {
            RSC_TEDINFO *ti = rsc_new_tedinfo(r);
            if (spec + SZ_TED <= len && ti) {
                const uint8_t *b = p + spec;
                ti->te_ptext  = dup_cstr(r, p, len, rd32(b + 0, be));
                ti->te_ptmplt = dup_cstr(r, p, len, rd32(b + 4, be));
                ti->te_pvalid = dup_cstr(r, p, len, rd32(b + 8, be));
                ti->te_font=(int16_t)rd16(b+12,be); ti->te_fontid=(int16_t)rd16(b+14,be);
                ti->te_just=(int16_t)rd16(b+16,be); ti->te_color=(int16_t)rd16(b+18,be);
                ti->te_fontsize=(int16_t)rd16(b+20,be); ti->te_thickness=(int16_t)rd16(b+22,be);
                ti->te_txtlen=(int16_t)rd16(b+24,be); ti->te_tmplen=(int16_t)rd16(b+26,be);
            }
            g->ob_spec = ti;
        } else if (t == G_ICON) {
            RSC_ICONBLK *ib = rsc_new_iconblk(r);
            if (spec + SZ_IB <= len && ib) {
                const uint8_t *b = p + spec;
                uint32_t pmask=rd32(b+0,be), pdata=rd32(b+4,be), ptext=rd32(b+8,be);
                ib->ib_char=(int16_t)rd16(b+12,be);
                ib->ib_xchar=(int16_t)rd16(b+14,be); ib->ib_ychar=(int16_t)rd16(b+16,be);
                ib->ib_xicon=(int16_t)rd16(b+18,be); ib->ib_yicon=(int16_t)rd16(b+20,be);
                ib->ib_wicon=(int16_t)rd16(b+22,be); ib->ib_hicon=(int16_t)rd16(b+24,be);
                ib->ib_xtext=(int16_t)rd16(b+26,be); ib->ib_ytext=(int16_t)rd16(b+28,be);
                ib->ib_wtext=(int16_t)rd16(b+30,be); ib->ib_htext=(int16_t)rd16(b+32,be);
                ib->ib_ptext = dup_cstr(r, p, len, ptext);
                uint32_t bytes = (uint32_t)(((ib->ib_wicon + 15) / 16) * 2) * (ib->ib_hicon > 0 ? ib->ib_hicon : 0);
                if (pdata && pdata + bytes <= len) ib->ib_pdata = rsc_intern_bytes(r, p + pdata, bytes);
                if (pmask && pmask + bytes <= len) ib->ib_pmask = rsc_intern_bytes(r, p + pmask, bytes);
            }
            g->ob_spec = ib;
        } else if (t == G_IMAGE) {
            /* A classic G_IMAGE points at a BITBLK; Rocks' older files pointed it
             * at a PAM instead.  The "P7" magic tells them apart — and a PAM one
             * is RETYPED to G_PAMICON here, so from this point on G_IMAGE means
             * exactly "classic bit form" and nothing has to guess. */
            uint32_t pl = pam_len(p, len, spec);
            if (pl) {
                RSC_PAMICON *ci = rsc_new_pamicon(r);
                if (ci) { ci->pam = rsc_intern_bytes(r, p + spec, pl); ci->pam_len = pl; }
                g->ob_spec = ci;
                g->ob_type = (uint16_t)((g->ob_type & 0xFF00) | G_PAMICON);
            } else {
                g->ob_spec = read_bitblk(r, p, len, spec, be);
            }
        } else if (is_pam(t)) {
            RSC_PAMICON *ci = rsc_new_pamicon(r);
            uint32_t pl = pam_len(p, len, spec);
            if (pl && ci) { ci->pam = rsc_intern_bytes(r, p + spec, pl); ci->pam_len = pl; }
            g->ob_spec = ci;
        } else if (t == G_CICON) {
            /* Filled in below, once the extension has been located: ob_spec here
             * is an index into the file's CICONBLK array, not an offset. */
            g->ob_spec = (void *)(uintptr_t)spec;
        } else {
            g->ob_spec = NULL;
        }
        (void)tedBase; (void)ibBase;
    }

    for (int t = 0; t < ntree; t++) {
        uint32_t off = rd32(p + trindex + (size_t)t * 4, be);
        if (off < objBase || off >= objBase + (size_t)nobs * SZ_OBJ) continue;
        rsc_add_tree(r, (int)((off - objBase) / SZ_OBJ));
    }
    /* Free images: a table of LONG offsets to BITBLKs (rsrc_gaddr(R_IMAGE, i)). */
    uint32_t frimg = h[8];
    int nimages = (int16_t)h[16];
    if (nimages > 0 && frimg && frimg + (size_t)nimages * 4 <= len) {
        for (int i = 0; i < nimages; i++) {
            RSC_BITBLK *bb = read_bitblk(r, p, len, rd32(p + frimg + (size_t)i * 4, be), be);
            if (bb) rsc_add_freeimage(r, bb);
        }
    }

    /* Free strings: a table of LONG offsets, reached by rsrc_gaddr(R_STRING, i).
     * They belong to no object, so nothing above would have picked them up. */
    uint32_t frstr = h[5];
    int nstring = (int16_t)h[15];
    if (nstring > 0 && frstr && frstr + (size_t)nstring * 4 <= len) {
        for (int i = 0; i < nstring; i++)
            rsc_add_string(r, dup_cstr(r, p, len, rd32(p + frstr + (size_t)i * 4, be)));
    }

    /* The extension: colour icons and the palette. A malformed one costs us the
     * icons, not the whole resource. */
    if (h[0] & RSC_VRSN_EXTENDED) {
        parse_extension(r, p, len, rssize, be);
        /* A G_CICON's ob_spec is an index into the CICONBLK array; resolve it. */
        for (int i = 0; i < r->nobj; i++) {
            RSC_OBJECT *g = &r->obj[i];
            if ((g->ob_type & 0xFF) != G_CICON) continue;
            uint32_t idx = (uint32_t)(uintptr_t)g->ob_spec;
            g->ob_spec = ((int)idx < r->ncib) ? (void *)r->cib[idx] : NULL;
        }
    } else {
        for (int i = 0; i < r->nobj; i++)      /* a G_CICON with no extension: nothing to point at */
            if ((r->obj[i].ob_type & 0xFF) == G_CICON) r->obj[i].ob_spec = NULL;
    }
    /* Reject only if we found nothing worth having. */
    if (r->ntree == 0 && r->nstring == 0 && r->nfreeimg == 0) { rsc_free(r); return NULL; }
    return r;
}

RSC *rsc_read(const uint8_t *data, size_t len, const char **err) {
    RSC *r = try_parse(data, len, 1);          /* big-endian (Atari) */
    if (!r) r = try_parse(data, len, 0);       /* little-endian fallback */
    if (!r && err) *err = "not a recognisable GEM .rsc (or unsupported extended format)";
    return r;
}

/* ---- writer -------------------------------------------------------------- */

/* small growable index tables */
typedef struct { void **items; int n, cap; } PtrVec;
static int pv_find(PtrVec *v, void *p) { for (int i=0;i<v->n;i++) if (v->items[i]==p) return i; return -1; }
static int pv_add(PtrVec *v, void *p) {
    if (v->n == v->cap) { v->cap = v->cap ? v->cap*2 : 16; v->items = realloc(v->items, v->cap*sizeof(void*)); }
    v->items[v->n] = p; return v->n++;
}
typedef struct { char **items; uint32_t *off; int n, cap; } StrVec;
static int sv_intern(StrVec *v, const char *s) {
    if (!s) s = "";
    for (int i=0;i<v->n;i++) if (!strcmp(v->items[i], s)) return i;
    if (v->n == v->cap) { v->cap = v->cap ? v->cap*2 : 16;
        v->items = realloc(v->items, v->cap*sizeof(char*)); v->off = realloc(v->off, v->cap*sizeof(uint32_t)); }
    v->items[v->n] = (char *)s; return v->n++;
}

int rsc_write(const RSC *r, uint8_t **out_p, size_t *out_len, const char **err) {
    int nobs = r->nobj, ntree = r->ntree;
    int cw = r->cell_w, ch = r->cell_h;

    StrVec strs = {0};
    PtrVec teds = {0}, ibs = {0}, cics = {0}, bbs = {0};
    uint32_t *bb_off = NULL;
    /* image data (icon bitplanes + embedded PAMs), built up-front */
    uint8_t *imdata = NULL; uint32_t imlen = 0, imcap = 0;
    #define IM_APPEND(ptr, n) do { if (imlen + (n) > imcap) { imcap = (imlen + (n)) * 2 + 64; imdata = realloc(imdata, imcap); } \
        memcpy(imdata + imlen, (ptr), (n)); imlen += (n); } while (0)
    uint32_t *ib_data_off = NULL, *ib_mask_off = NULL, *cic_off = NULL;

    /* pass 1: collect.  Everything that ends up in the string pool must be
     * interned HERE — the layout below hands out an offset per interned string,
     * so anything interned later would get no offset at all. */
    for (int i = 0; i < r->nstring; i++) sv_intern(&strs, r->strings[i]);   /* free strings */

    for (int i = 0; i < nobs; i++) {
        RSC_OBJECT *o = &r->obj[i];
        int t = o->ob_type & 0xFF;
        if (is_string(t)) sv_intern(&strs, (const char *)o->ob_spec);
        else if (is_ted(t) && o->ob_spec) {
            RSC_TEDINFO *ti = o->ob_spec;
            sv_intern(&strs, ti->te_ptext); sv_intern(&strs, ti->te_ptmplt); sv_intern(&strs, ti->te_pvalid);
            pv_add(&teds, ti);
        } else if (t == G_ICON && o->ob_spec) {
            RSC_ICONBLK *ib = o->ob_spec;
            sv_intern(&strs, ib->ib_ptext ? ib->ib_ptext : "");
            int idx = pv_add(&ibs, ib);
            ib_data_off = realloc(ib_data_off, ibs.cap*sizeof(uint32_t));
            ib_mask_off = realloc(ib_mask_off, ibs.cap*sizeof(uint32_t));
            uint32_t bytes = (uint32_t)(((ib->ib_wicon + 15) / 16) * 2) * (ib->ib_hicon > 0 ? ib->ib_hicon : 0);
            ib_data_off[idx] = imlen; if (ib->ib_pdata && bytes) IM_APPEND(ib->ib_pdata, bytes); else if (bytes) { uint8_t z=0; for(uint32_t k=0;k<bytes;k++) IM_APPEND(&z,1);}
            ib_mask_off[idx] = imlen; if (ib->ib_pmask && bytes) IM_APPEND(ib->ib_pmask, bytes); else if (bytes) IM_APPEND(imdata + ib_data_off[idx], bytes);
        } else if (is_pam(t) && o->ob_spec) {
            RSC_PAMICON *ci = o->ob_spec;
            int idx = pv_add(&cics, ci);
            cic_off = realloc(cic_off, cics.cap*sizeof(uint32_t));
            cic_off[idx] = imlen;
            if (ci->pam && ci->pam_len) IM_APPEND(ci->pam, ci->pam_len);
        } else if (t == G_IMAGE && o->ob_spec && pv_find(&bbs, o->ob_spec) < 0) {
            RSC_BITBLK *bb = o->ob_spec;
            int idx = pv_add(&bbs, bb);
            bb_off = realloc(bb_off, bbs.cap*sizeof(uint32_t));
            bb_off[idx] = imlen;
            uint32_t bytes = (uint32_t)(bb->bi_wb > 0 ? bb->bi_wb : 0) * (uint32_t)(bb->bi_hl > 0 ? bb->bi_hl : 0);
            if (bb->bi_pdata && bytes) IM_APPEND(bb->bi_pdata, bytes);
        }
    }
    /* free images are BITBLKs too, and may not be referenced by any object */
    for (int i = 0; i < r->nfreeimg; i++) {
        RSC_BITBLK *bb = r->freeimg[i];
        if (!bb || pv_find(&bbs, bb) >= 0) continue;
        int idx = pv_add(&bbs, bb);
        bb_off = realloc(bb_off, bbs.cap*sizeof(uint32_t));
        bb_off[idx] = imlen;
        uint32_t bytes = (uint32_t)(bb->bi_wb > 0 ? bb->bi_wb : 0) * (uint32_t)(bb->bi_hl > 0 ? bb->bi_hl : 0);
        if (bb->bi_pdata && bytes) IM_APPEND(bb->bi_pdata, bytes);
    }
    int nted = teds.n, nib = ibs.n, nbb = bbs.n;
    int nstring = r->nstring, nimages = r->nfreeimg;

    /* layout */
    uint32_t objBase = SZ_HDR;
    uint32_t tedBase = objBase + (uint32_t)nobs * SZ_OBJ;
    uint32_t ibBase  = tedBase + (uint32_t)nted * SZ_TED;
    uint32_t bbBase  = ibBase + (uint32_t)nib * SZ_IB;
    uint32_t frstr   = bbBase + (uint32_t)nbb * SZ_BB;      /* free-string table  */
    uint32_t frimg   = frstr + (uint32_t)nstring * 4;       /* free-image table   */
    uint32_t trindex = frimg + (uint32_t)nimages * 4;
    uint32_t strBase = trindex + (uint32_t)ntree * 4;
    uint32_t cur = strBase;
    /* string data + offsets */
    uint32_t strbytes = 0;
    for (int i = 0; i < strs.n; i++) { strs.off[i] = cur; uint32_t l = (uint32_t)strlen(strs.items[i]) + 1; cur += l; strbytes += l; }
    uint32_t imBase = cur;
    uint32_t total = imBase + imlen;

    uint8_t *buf = (uint8_t *)calloc(total ? total : 1, 1);
    if (!buf) { if (err) *err = "out of memory"; goto fail; }

    /* header */
    uint16_t hdr[18] = {0};
    hdr[0]=RSC_VRSN_ROCKS; hdr[1]=(uint16_t)objBase; hdr[2]=(uint16_t)tedBase; hdr[3]=(uint16_t)ibBase;
    hdr[4]=(uint16_t)bbBase; hdr[5]=(uint16_t)frstr; hdr[6]=(uint16_t)strBase; hdr[7]=(uint16_t)imBase;
    hdr[8]=(uint16_t)frimg; hdr[9]=(uint16_t)trindex; hdr[10]=(uint16_t)nobs; hdr[11]=(uint16_t)ntree;
    hdr[12]=(uint16_t)nted; hdr[13]=(uint16_t)nib; hdr[14]=(uint16_t)nbb;
    hdr[15]=(uint16_t)nstring; hdr[16]=(uint16_t)nimages; hdr[17]=(uint16_t)total;
    for (int i=0;i<18;i++) wr16(buf + i*2, hdr[i]);

    /* objects */
    for (int i = 0; i < nobs; i++) {
        RSC_OBJECT *o = &r->obj[i];
        uint8_t *d = buf + objBase + (size_t)i * SZ_OBJ;
        uint16_t flags = o->ob_flags;
        if (i == nobs - 1) flags |= OF_LASTOB;
        wr16(d+0,(uint16_t)o->ob_next); wr16(d+2,(uint16_t)o->ob_head); wr16(d+4,(uint16_t)o->ob_tail);
        wr16(d+6,o->ob_type); wr16(d+8,flags); wr16(d+10,o->ob_state);
        int t = o->ob_type & 0xFF;
        uint32_t spec = 0;
        if (is_box(t)) spec = RSC_OB_BOXWORD(o);
        else if (is_string(t)) spec = strs.off[sv_intern(&strs, (const char *)o->ob_spec)];
        else if (is_ted(t)) spec = tedBase + (uint32_t)pv_find(&teds, o->ob_spec) * SZ_TED;
        else if (t == G_ICON) spec = ibBase + (uint32_t)pv_find(&ibs, o->ob_spec) * SZ_IB;
        else if (is_pam(t)) { int k = pv_find(&cics, o->ob_spec); spec = k>=0 ? imBase + cic_off[k] : 0; }
        else if (t == G_IMAGE) { int k = pv_find(&bbs, o->ob_spec); spec = k>=0 ? bbBase + (uint32_t)k * SZ_BB : 0; }
        wr32(d+12, spec);
        wr16(d+16, pack_coord(o->ob_x, cw)); wr16(d+18, pack_coord(o->ob_y, ch));
        wr16(d+20, pack_coord(o->ob_w, cw)); wr16(d+22, pack_coord(o->ob_h, ch));
    }
    /* tedinfo */
    for (int i = 0; i < nted; i++) {
        RSC_TEDINFO *ti = teds.items[i];
        uint8_t *d = buf + tedBase + (size_t)i * SZ_TED;
        wr32(d+0, strs.off[sv_intern(&strs, ti->te_ptext)]);
        wr32(d+4, strs.off[sv_intern(&strs, ti->te_ptmplt)]);
        wr32(d+8, strs.off[sv_intern(&strs, ti->te_pvalid)]);
        wr16(d+12,(uint16_t)ti->te_font); wr16(d+14,(uint16_t)ti->te_fontid);
        wr16(d+16,(uint16_t)ti->te_just); wr16(d+18,(uint16_t)ti->te_color);
        wr16(d+20,(uint16_t)ti->te_fontsize); wr16(d+22,(uint16_t)ti->te_thickness);
        wr16(d+24,(uint16_t)(ti->te_ptext?strlen(ti->te_ptext)+1:1));
        wr16(d+26,(uint16_t)(ti->te_ptmplt?strlen(ti->te_ptmplt)+1:1));
    }
    /* iconblk */
    for (int i = 0; i < nib; i++) {
        RSC_ICONBLK *ib = ibs.items[i];
        uint8_t *d = buf + ibBase + (size_t)i * SZ_IB;
        wr32(d+0, ib_mask_off ? imBase + ib_mask_off[i] : 0);
        wr32(d+4, ib_data_off ? imBase + ib_data_off[i] : 0);
        wr32(d+8, strs.off[sv_intern(&strs, ib->ib_ptext ? ib->ib_ptext : "")]);
        wr16(d+12,(uint16_t)ib->ib_char);
        wr16(d+14,(uint16_t)ib->ib_xchar); wr16(d+16,(uint16_t)ib->ib_ychar);
        wr16(d+18,(uint16_t)ib->ib_xicon); wr16(d+20,(uint16_t)ib->ib_yicon);
        wr16(d+22,(uint16_t)ib->ib_wicon); wr16(d+24,(uint16_t)ib->ib_hicon);
        wr16(d+26,(uint16_t)ib->ib_xtext); wr16(d+28,(uint16_t)ib->ib_ytext);
        wr16(d+30,(uint16_t)ib->ib_wtext); wr16(d+32,(uint16_t)ib->ib_htext);
    }
    /* bitblk */
    for (int i = 0; i < nbb; i++) {
        RSC_BITBLK *bb = bbs.items[i];
        uint8_t *d = buf + bbBase + (size_t)i * SZ_BB;
        uint32_t bytes = (uint32_t)(bb->bi_wb > 0 ? bb->bi_wb : 0) * (uint32_t)(bb->bi_hl > 0 ? bb->bi_hl : 0);
        wr32(d+0, (bb->bi_pdata && bytes) ? imBase + bb_off[i] : 0);
        wr16(d+4,(uint16_t)bb->bi_wb);  wr16(d+6,(uint16_t)bb->bi_hl);
        wr16(d+8,(uint16_t)bb->bi_x);   wr16(d+10,(uint16_t)bb->bi_y);
        wr16(d+12,(uint16_t)bb->bi_color);
    }
    /* free strings / free images: tables of offsets into what we just laid out */
    for (int i = 0; i < nstring; i++)
        wr32(buf + frstr + (size_t)i * 4, strs.off[sv_intern(&strs, r->strings[i])]);
    for (int i = 0; i < nimages; i++) {
        int k = pv_find(&bbs, r->freeimg[i]);
        wr32(buf + frimg + (size_t)i * 4, k >= 0 ? bbBase + (uint32_t)k * SZ_BB : 0);
    }
    /* tree index */
    for (int i = 0; i < ntree; i++) wr32(buf + trindex + (size_t)i * 4, objBase + (uint32_t)r->trees[i] * SZ_OBJ);
    /* string data */
    for (int i = 0; i < strs.n; i++) { size_t l = strlen(strs.items[i]) + 1; memcpy(buf + strs.off[i], strs.items[i], l); }
    /* image data */
    if (imlen) memcpy(buf + imBase, imdata, imlen);

    *out_p = buf; *out_len = total;
    free(strs.items); free(strs.off); free(teds.items); free(ibs.items); free(cics.items); free(bbs.items);
    free(imdata); free(ib_data_off); free(ib_mask_off); free(cic_off); free(bb_off);
    (void)strbytes;
    return 0;
fail:
    free(strs.items); free(strs.off); free(teds.items); free(ibs.items); free(cics.items); free(bbs.items);
    free(imdata); free(ib_data_off); free(ib_mask_off); free(cic_off); free(bb_off);
    return 1;
}

/* ---- lifecycle + builders ------------------------------------------------ */

RSC *rsc_new(void) {
    RSC *r = (RSC *)calloc(1, sizeof(RSC));
    if (r) { r->cell_w = 8; r->cell_h = 16; }
    return r;
}
void rsc_free(RSC *r) {
    if (!r) return;
    ArenaBlock *b = r->arena;
    while (b) { ArenaBlock *n = b->next; free(b); b = n; }
    free(r->obj); free(r->trees); free(r->strings); free(r->freeimg); free(r);
}
void rsc_set_cell(RSC *r, int cw, int ch) { r->cell_w = cw > 0 ? cw : 8; r->cell_h = ch > 0 ? ch : 16; }

int rsc_ntrees(const RSC *r) { return r->ntree; }
RSC_OBJECT *rsc_tree(const RSC *r, int i) {
    return (i >= 0 && i < r->ntree && r->trees[i] < r->nobj) ? &r->obj[r->trees[i]] : NULL;
}
RSC_OBJECT *rsc_objects(const RSC *r, int *count_out) { if (count_out) *count_out = r->nobj; return r->obj; }

int rsc_alloc_objects(RSC *r, int n) {
    int base = r->nobj;
    if (base + n > r->obj_cap) {
        int cap = (base + n) > r->obj_cap*2 ? (base + n) : (r->obj_cap ? r->obj_cap*2 : 16);
        r->obj = realloc(r->obj, cap * sizeof(RSC_OBJECT)); r->obj_cap = cap;
    }
    memset(r->obj + base, 0, n * sizeof(RSC_OBJECT));
    r->nobj = base + n;
    return base;
}
int rsc_add_tree(RSC *r, int root) {
    if (r->ntree == r->tree_cap) { r->tree_cap = r->tree_cap ? r->tree_cap*2 : 8;
        r->trees = realloc(r->trees, r->tree_cap * sizeof(int32_t)); }
    r->trees[r->ntree] = root;
    return r->ntree++;
}
char *rsc_intern_str(RSC *r, const char *s) {
    if (!s) s = "";
    size_t l = strlen(s) + 1; char *d = arena_alloc(r, l);
    if (d) memcpy(d, s, l);
    return d;
}
uint8_t *rsc_intern_bytes(RSC *r, const uint8_t *b, uint32_t n) {
    uint8_t *d = arena_alloc(r, n ? n : 1);
    if (d && n) memcpy(d, b, n);
    return d;
}
RSC_TEDINFO *rsc_new_tedinfo(RSC *r) { RSC_TEDINFO *t = arena_alloc(r, sizeof *t);
    if (t) { t->te_ptext = t->te_ptmplt = t->te_pvalid = arena_alloc(r, 1); } return t; }
RSC_ICONBLK *rsc_new_iconblk(RSC *r) { return arena_alloc(r, sizeof(RSC_ICONBLK)); }
RSC_PAMICON  *rsc_new_pamicon(RSC *r)  { return arena_alloc(r, sizeof(RSC_PAMICON)); }
RSC_CICONBLK *rsc_new_ciconblk(RSC *r) { return arena_alloc(r, sizeof(RSC_CICONBLK)); }

int rsc_is_extended(const RSC *r) { return r ? r->extended : 0; }
int rsc_is_rocks(const RSC *r)    { return r ? r->rocks : 0; }
const RSC_RGB *rsc_palette(const RSC *r) { return r ? r->palette : NULL; }

int rsc_nstrings(const RSC *r) { return r ? r->nstring : 0; }
const char *rsc_string(const RSC *r, int i) {
    return (r && i >= 0 && i < r->nstring) ? r->strings[i] : NULL;
}
int rsc_add_string(RSC *r, const char *s) {
    if (r->nstring == r->string_cap) {
        int cap = r->string_cap ? r->string_cap * 2 : 16;
        char **n = realloc(r->strings, (size_t)cap * sizeof(char *));
        if (!n) return -1;
        r->strings = n; r->string_cap = cap;
    }
    r->strings[r->nstring] = rsc_intern_str(r, s ? s : "");
    return r->nstring++;
}

RSC_BITBLK *rsc_new_bitblk(RSC *r) { return arena_alloc(r, sizeof(RSC_BITBLK)); }

int rsc_nfreeimages(const RSC *r) { return r ? r->nfreeimg : 0; }
RSC_BITBLK *rsc_freeimage(const RSC *r, int i) {
    return (r && i >= 0 && i < r->nfreeimg) ? r->freeimg[i] : NULL;
}
int rsc_add_freeimage(RSC *r, RSC_BITBLK *bb) {
    if (r->nfreeimg == r->freeimg_cap) {
        int cap = r->freeimg_cap ? r->freeimg_cap * 2 : 8;
        RSC_BITBLK **n = realloc(r->freeimg, (size_t)cap * sizeof(RSC_BITBLK *));
        if (!n) return -1;
        r->freeimg = n; r->freeimg_cap = cap;
    }
    r->freeimg[r->nfreeimg] = bb;
    return r->nfreeimg++;
}

int rsc_nciconblks(const RSC *r) { return r ? r->ncib : 0; }
RSC_CICONBLK *rsc_ciconblk(const RSC *r, int i) {
    return (r && i >= 0 && i < r->ncib) ? r->cib[i] : NULL;
}
