// UXIcon.xc — icons by neutral name, as each platform has them.
//
// A toolbar item (and later anything else with an icon) names its icon from this set: "new",
// "open", "save", "delete", "cut", "copy", "paste", "undo", "redo", "add", "remove", "play",
// "pause", "stop", "back", "forward", "search", "settings", "info", "share", "print", "refresh",
// "edit", "close" and "folder".  Each backend shows the platform's own icon for it where the
// platform has one: an SF Symbol on macOS and iOS, a standard toolbar bitmap on Windows, a system
// drawable on Android.  Where UXKit draws the toolbar itself (GTK, GEM, the web) it draws the glyph
// here, 16 pixels square, in the ink it is given.  A name not in the set is no icon.
#import "UXGraphics.xc"
#import "UXGeometry.xc"

class UXIcon : Object
    {
    static bool same(u8* a, u8* b)
        {
        i32 i = (i32)0;
        while (a[i] != (u8)0 && a[i] == b[i])
            {
            i = i + (i32)1;
            }
        return a[i] == b[i];
        }

    // Where the name is in the table below, or -1.
    static i32 indexOf(u8* name)
        {
        if (name == (u8*)0 || name[0] == (u8)0)
            {
            return (i32)-1;
            }
        for (i32 k = (i32)0; k < (i32)25; k = k + (i32)1)
            {
            if (UXIcon.same(name, UXIcon.nameAt(k)))
                {
                return k;
                }
            }
        return (i32)-1;
        }

    static bool isKnown(u8* name)
        {
        return UXIcon.indexOf(name) >= (i32)0;
        }

    // The table: the neutral name, its SF Symbol, its Windows standard bitmap (STD_*, -1 for
    // none) and its Android drawable (android.R.drawable, "" for none).
    static u8* nameAt(i32 k)
        {
        u8* n[25];
        n[0] = (u8*)"new"; n[1] = (u8*)"open"; n[2] = (u8*)"save"; n[3] = (u8*)"delete"; n[4] = (u8*)"cut";
        n[5] = (u8*)"copy"; n[6] = (u8*)"paste"; n[7] = (u8*)"undo"; n[8] = (u8*)"redo"; n[9] = (u8*)"add";
        n[10] = (u8*)"remove"; n[11] = (u8*)"play"; n[12] = (u8*)"pause"; n[13] = (u8*)"stop"; n[14] = (u8*)"back";
        n[15] = (u8*)"forward"; n[16] = (u8*)"search"; n[17] = (u8*)"settings"; n[18] = (u8*)"info";
        n[19] = (u8*)"share"; n[20] = (u8*)"print"; n[21] = (u8*)"refresh"; n[22] = (u8*)"edit"; n[23] = (u8*)"close";
        n[24] = (u8*)"folder";
        return n[k];
        }

    // The SF Symbol for a name (macOS 11 and iOS 13 on), or "".
    static u8* sfSymbol(u8* name)
        {
        u8* s[25];
        s[0] = (u8*)"doc.badge.plus"; s[1] = (u8*)"folder"; s[2] = (u8*)"square.and.arrow.down"; s[3] = (u8*)"trash";
        s[4] = (u8*)"scissors"; s[5] = (u8*)"doc.on.doc"; s[6] = (u8*)"doc.on.clipboard"; s[7] = (u8*)"arrow.uturn.backward";
        s[8] = (u8*)"arrow.uturn.forward"; s[9] = (u8*)"plus"; s[10] = (u8*)"minus"; s[11] = (u8*)"play.fill";
        s[12] = (u8*)"pause.fill"; s[13] = (u8*)"stop.fill"; s[14] = (u8*)"chevron.backward"; s[15] = (u8*)"chevron.forward";
        s[16] = (u8*)"magnifyingglass"; s[17] = (u8*)"gearshape"; s[18] = (u8*)"info.circle"; s[19] = (u8*)"square.and.arrow.up";
        s[20] = (u8*)"printer"; s[21] = (u8*)"arrow.clockwise"; s[22] = (u8*)"pencil"; s[23] = (u8*)"xmark";
        s[24] = (u8*)"folder";
        i32 k = UXIcon.indexOf(name);
        return k >= (i32)0 ? s[k] : (u8*)"";
        }

    // The Windows common-control standard bitmap (IDB_STD_SMALL_COLOR's STD_* index), or -1.
    static i32 win32Std(u8* name)
        {
        i32 w[25];
        w[0] = (i32)6; w[1] = (i32)7; w[2] = (i32)8; w[3] = (i32)5; w[4] = (i32)0; w[5] = (i32)1; w[6] = (i32)2;
        w[7] = (i32)3; w[8] = (i32)4; w[9] = (i32)-1; w[10] = (i32)-1; w[11] = (i32)-1; w[12] = (i32)-1; w[13] = (i32)-1;
        w[14] = (i32)-1; w[15] = (i32)-1; w[16] = (i32)12; w[17] = (i32)10; w[18] = (i32)11; w[19] = (i32)-1;
        w[20] = (i32)14; w[21] = (i32)-1; w[22] = (i32)-1; w[23] = (i32)-1; w[24] = (i32)7;
        i32 k = UXIcon.indexOf(name);
        return k >= (i32)0 ? w[k] : (i32)-1;
        }

    // The Android system drawable (a field of android.R.drawable), or "".
    static u8* androidDrawable(u8* name)
        {
        u8* a[25];
        a[0] = (u8*)"ic_menu_add"; a[1] = (u8*)"ic_menu_upload"; a[2] = (u8*)"ic_menu_save"; a[3] = (u8*)"ic_menu_delete";
        a[4] = (u8*)""; a[5] = (u8*)""; a[6] = (u8*)""; a[7] = (u8*)"ic_menu_revert"; a[8] = (u8*)"";
        a[9] = (u8*)"ic_input_add"; a[10] = (u8*)"ic_input_delete"; a[11] = (u8*)"ic_media_play"; a[12] = (u8*)"ic_media_pause";
        a[13] = (u8*)""; a[14] = (u8*)"ic_media_previous"; a[15] = (u8*)"ic_media_next"; a[16] = (u8*)"ic_menu_search";
        a[17] = (u8*)"ic_menu_preferences"; a[18] = (u8*)"ic_menu_info_details"; a[19] = (u8*)"ic_menu_share";
        a[20] = (u8*)""; a[21] = (u8*)"ic_menu_rotate"; a[22] = (u8*)"ic_menu_edit"; a[23] = (u8*)"ic_menu_close_clear_cancel";
        a[24] = (u8*)"ic_menu_upload";
        i32 k = UXIcon.indexOf(name);
        return k >= (i32)0 ? a[k] : (u8*)"";
        }

    // ---- the drawn glyphs: 16 x 16 at (x, y), in pen `pen` ---------------------------------------
    // A stroke, drawn as filled rectangles, which every backend draws to the pixel at full strength.
    static void ln(UXGraphics* g, i32 x0, i32 y0, i32 x1, i32 y1, i32 pen)
        {
        if (x0 == x1)
            {
            i32 top = y0 < y1 ? y0 : y1;
            g.fillRect(UXGeom.make((i16)x0, (i16)top, (i16)1, (i16)((y0 < y1 ? y1 - y0 : y0 - y1) + (i32)1)), pen);
            return;
            }
        if (y0 == y1)
            {
            i32 left = x0 < x1 ? x0 : x1;
            g.fillRect(UXGeom.make((i16)left, (i16)y0, (i16)((x0 < x1 ? x1 - x0 : x0 - x1) + (i32)1), (i16)1), pen);
            return;
            }
        // A slant is whole pixels too (Bresenham), not drawLine: an anti-aliased line that is
        // nearly vertical lands half on each of two pixels and comes out a light grey (GTK did this
        // to the bin's sides).
        i32 dx = x1 > x0 ? x1 - x0 : x0 - x1;
        i32 dy = y1 > y0 ? y0 - y1 : y1 - y0;
        i32 sx = x0 < x1 ? (i32)1 : (i32)-1;
        i32 sy = y0 < y1 ? (i32)1 : (i32)-1;
        i32 err = dx + dy;
        while (true)
            {
            g.fillRect(UXGeom.make((i16)x0, (i16)y0, (i16)1, (i16)1), pen);
            if (x0 == x1 && y0 == y1)
                {
                break;
                }
            i32 e2 = err * (i32)2;
            if (e2 >= dy)
                {
                err = err + dy;
                x0 = x0 + sx;
                }
            if (e2 <= dx)
                {
                err = err + dx;
                y0 = y0 + sy;
                }
            }
        }
    static void box(UXGraphics* g, i32 x, i32 y, i32 w, i32 h, i32 pen)
        {
        UXIcon.ln(g, x, y, x + w - (i32)1, y, pen);
        UXIcon.ln(g, x, y + h - (i32)1, x + w - (i32)1, y + h - (i32)1, pen);
        UXIcon.ln(g, x, y, x, y + h - (i32)1, pen);
        UXIcon.ln(g, x + w - (i32)1, y, x + w - (i32)1, y + h - (i32)1, pen);
        }
    static void bar(UXGraphics* g, i32 x, i32 y, i32 w, i32 h, i32 pen)
        {
        g.fillRect(UXGeom.make((i16)x, (i16)y, (i16)w, (i16)h), pen);
        }
    // an octagon round (cx, cy) of radius r: a circle at this size
    static void ring(UXGraphics* g, i32 cx, i32 cy, i32 r, i32 pen)
        {
        i32 d = (r * (i32)5) / (i32)12;
        UXIcon.ln(g, cx - d, cy - r, cx + d, cy - r, pen);
        UXIcon.ln(g, cx + d, cy - r, cx + r, cy - d, pen);
        UXIcon.ln(g, cx + r, cy - d, cx + r, cy + d, pen);
        UXIcon.ln(g, cx + r, cy + d, cx + d, cy + r, pen);
        UXIcon.ln(g, cx + d, cy + r, cx - d, cy + r, pen);
        UXIcon.ln(g, cx - d, cy + r, cx - r, cy + d, pen);
        UXIcon.ln(g, cx - r, cy + d, cx - r, cy - d, pen);
        UXIcon.ln(g, cx - r, cy - d, cx - d, cy - r, pen);
        }
    static void page(UXGraphics* g, i32 x, i32 y, i32 w, i32 h, i32 pen)
        {
        UXIcon.ln(g, x, y, x + w - (i32)4, y, pen);
        UXIcon.ln(g, x + w - (i32)4, y, x + w - (i32)1, y + (i32)3, pen);
        UXIcon.ln(g, x + w - (i32)1, y + (i32)3, x + w - (i32)1, y + h - (i32)1, pen);
        UXIcon.ln(g, x, y + h - (i32)1, x + w - (i32)1, y + h - (i32)1, pen);
        UXIcon.ln(g, x, y, x, y + h - (i32)1, pen);
        }

    // Draws the named glyph; false (and nothing drawn) for a name not in the set.
    static bool draw(UXGraphics* g, u8* name, i32 x, i32 y, i32 pen)
        {
        i32 k = UXIcon.indexOf(name);
        if (k < (i32)0)
            {
            return false;
            }
        if (k == (i32)0) // new: a page with a plus
            {
            UXIcon.page(g, x + (i32)2, y + (i32)1, (i32)10, (i32)14, pen);
            UXIcon.bar(g, x + (i32)10, y + (i32)8, (i32)6, (i32)2, pen);
            UXIcon.bar(g, x + (i32)12, y + (i32)6, (i32)2, (i32)6, pen);
            }
        else if (k == (i32)1 || k == (i32)24) // open, folder: a folder
            {
            UXIcon.box(g, x + (i32)1, y + (i32)4, (i32)14, (i32)10, pen);
            UXIcon.ln(g, x + (i32)1, y + (i32)4, x + (i32)3, y + (i32)2, pen);
            UXIcon.ln(g, x + (i32)3, y + (i32)2, x + (i32)7, y + (i32)2, pen);
            UXIcon.ln(g, x + (i32)7, y + (i32)2, x + (i32)8, y + (i32)4, pen);
            }
        else if (k == (i32)2) // save: a disk
            {
            UXIcon.box(g, x + (i32)1, y + (i32)1, (i32)14, (i32)14, pen);
            UXIcon.bar(g, x + (i32)4, y + (i32)1, (i32)7, (i32)5, pen);
            UXIcon.box(g, x + (i32)4, y + (i32)9, (i32)8, (i32)6, pen);
            }
        else if (k == (i32)3) // delete: a bin
            {
            UXIcon.ln(g, x + (i32)1, y + (i32)3, x + (i32)14, y + (i32)3, pen);
            UXIcon.ln(g, x + (i32)6, y + (i32)1, x + (i32)9, y + (i32)1, pen);
            UXIcon.ln(g, x + (i32)3, y + (i32)4, x + (i32)4, y + (i32)14, pen);
            UXIcon.ln(g, x + (i32)12, y + (i32)4, x + (i32)11, y + (i32)14, pen);
            UXIcon.ln(g, x + (i32)4, y + (i32)14, x + (i32)11, y + (i32)14, pen);
            UXIcon.ln(g, x + (i32)6, y + (i32)6, x + (i32)6, y + (i32)12, pen);
            UXIcon.ln(g, x + (i32)9, y + (i32)6, x + (i32)9, y + (i32)12, pen);
            }
        else if (k == (i32)4) // cut: scissors
            {
            UXIcon.ring(g, x + (i32)4, y + (i32)12, (i32)2, pen);
            UXIcon.ring(g, x + (i32)11, y + (i32)12, (i32)2, pen);
            UXIcon.ln(g, x + (i32)5, y + (i32)10, x + (i32)11, y + (i32)1, pen);
            UXIcon.ln(g, x + (i32)10, y + (i32)10, x + (i32)4, y + (i32)1, pen);
            }
        else if (k == (i32)5) // copy: two pages
            {
            UXIcon.box(g, x + (i32)1, y + (i32)1, (i32)9, (i32)11, pen);
            UXIcon.box(g, x + (i32)6, y + (i32)4, (i32)9, (i32)11, pen);
            }
        else if (k == (i32)6) // paste: a clipboard
            {
            UXIcon.box(g, x + (i32)2, y + (i32)2, (i32)12, (i32)13, pen);
            UXIcon.bar(g, x + (i32)5, y + (i32)1, (i32)6, (i32)3, pen);
            UXIcon.ln(g, x + (i32)5, y + (i32)8, x + (i32)10, y + (i32)8, pen);
            UXIcon.ln(g, x + (i32)5, y + (i32)11, x + (i32)10, y + (i32)11, pen);
            }
        else if (k == (i32)7 || k == (i32)8) // undo, redo: a hooked arrow
            {
            bool left = k == (i32)7;
            i32 tip = left ? x + (i32)2 : x + (i32)13;
            i32 back = left ? x + (i32)12 : x + (i32)3;
            UXIcon.ln(g, tip, y + (i32)6, back, y + (i32)6, pen);
            UXIcon.ln(g, back, y + (i32)6, left ? back + (i32)2 : back - (i32)2, y + (i32)9, pen);
            UXIcon.ln(g, left ? back + (i32)2 : back - (i32)2, y + (i32)9, back, y + (i32)13, pen);
            UXIcon.ln(g, tip, y + (i32)6, left ? tip + (i32)4 : tip - (i32)4, y + (i32)2, pen);
            UXIcon.ln(g, tip, y + (i32)6, left ? tip + (i32)4 : tip - (i32)4, y + (i32)10, pen);
            }
        else if (k == (i32)9) // add
            {
            UXIcon.bar(g, x + (i32)2, y + (i32)7, (i32)12, (i32)2, pen);
            UXIcon.bar(g, x + (i32)7, y + (i32)2, (i32)2, (i32)12, pen);
            }
        else if (k == (i32)10) // remove
            {
            UXIcon.bar(g, x + (i32)2, y + (i32)7, (i32)12, (i32)2, pen);
            }
        else if (k == (i32)11) // play
            {
            g.fillTriangle((i16)(x + (i32)4), (i16)(y + (i32)2), (i16)(x + (i32)4), (i16)(y + (i32)14), (i16)(x + (i32)14),
                           (i16)(y + (i32)8), pen);
            }
        else if (k == (i32)12) // pause
            {
            UXIcon.bar(g, x + (i32)4, y + (i32)2, (i32)3, (i32)12, pen);
            UXIcon.bar(g, x + (i32)9, y + (i32)2, (i32)3, (i32)12, pen);
            }
        else if (k == (i32)13) // stop
            {
            UXIcon.bar(g, x + (i32)3, y + (i32)3, (i32)10, (i32)10, pen);
            }
        else if (k == (i32)14 || k == (i32)15) // back, forward: a chevron
            {
            i32 tip = k == (i32)14 ? x + (i32)4 : x + (i32)11;
            i32 tail = k == (i32)14 ? x + (i32)10 : x + (i32)5;
            UXIcon.ln(g, tail, y + (i32)2, tip, y + (i32)8, pen);
            UXIcon.ln(g, tip, y + (i32)8, tail, y + (i32)14, pen);
            }
        else if (k == (i32)16) // search: a lens
            {
            UXIcon.ring(g, x + (i32)6, y + (i32)6, (i32)5, pen);
            UXIcon.ln(g, x + (i32)10, y + (i32)10, x + (i32)14, y + (i32)14, pen);
            UXIcon.ln(g, x + (i32)11, y + (i32)10, x + (i32)15, y + (i32)14, pen);
            }
        else if (k == (i32)17) // settings: a gear
            {
            UXIcon.ring(g, x + (i32)8, y + (i32)8, (i32)5, pen);
            UXIcon.ring(g, x + (i32)8, y + (i32)8, (i32)2, pen);
            UXIcon.bar(g, x + (i32)7, y + (i32)1, (i32)2, (i32)2, pen);
            UXIcon.bar(g, x + (i32)7, y + (i32)13, (i32)2, (i32)2, pen);
            UXIcon.bar(g, x + (i32)1, y + (i32)7, (i32)2, (i32)2, pen);
            UXIcon.bar(g, x + (i32)13, y + (i32)7, (i32)2, (i32)2, pen);
            }
        else if (k == (i32)18) // info: a ringed i
            {
            UXIcon.ring(g, x + (i32)8, y + (i32)8, (i32)7, pen);
            UXIcon.bar(g, x + (i32)7, y + (i32)4, (i32)2, (i32)2, pen);
            UXIcon.bar(g, x + (i32)7, y + (i32)7, (i32)2, (i32)5, pen);
            }
        else if (k == (i32)19) // share: a tray with an arrow up out of it
            {
            UXIcon.ln(g, x + (i32)3, y + (i32)7, x + (i32)3, y + (i32)14, pen);
            UXIcon.ln(g, x + (i32)3, y + (i32)14, x + (i32)12, y + (i32)14, pen);
            UXIcon.ln(g, x + (i32)12, y + (i32)14, x + (i32)12, y + (i32)7, pen);
            UXIcon.ln(g, x + (i32)8, y + (i32)1, x + (i32)8, y + (i32)10, pen);
            UXIcon.ln(g, x + (i32)8, y + (i32)1, x + (i32)5, y + (i32)4, pen);
            UXIcon.ln(g, x + (i32)8, y + (i32)1, x + (i32)11, y + (i32)4, pen);
            }
        else if (k == (i32)20) // print: a printer
            {
            UXIcon.box(g, x + (i32)1, y + (i32)6, (i32)14, (i32)6, pen);
            UXIcon.box(g, x + (i32)4, y + (i32)1, (i32)8, (i32)5, pen);
            UXIcon.box(g, x + (i32)4, y + (i32)10, (i32)8, (i32)5, pen);
            }
        else if (k == (i32)21) // refresh: an open ring with an arrowhead
            {
            UXIcon.ln(g, x + (i32)13, y + (i32)8, x + (i32)11, y + (i32)12, pen);
            UXIcon.ln(g, x + (i32)11, y + (i32)12, x + (i32)8, y + (i32)14, pen);
            UXIcon.ln(g, x + (i32)8, y + (i32)14, x + (i32)4, y + (i32)12, pen);
            UXIcon.ln(g, x + (i32)4, y + (i32)12, x + (i32)2, y + (i32)8, pen);
            UXIcon.ln(g, x + (i32)2, y + (i32)8, x + (i32)4, y + (i32)4, pen);
            UXIcon.ln(g, x + (i32)4, y + (i32)4, x + (i32)8, y + (i32)2, pen);
            UXIcon.ln(g, x + (i32)8, y + (i32)2, x + (i32)11, y + (i32)3, pen);
            g.fillTriangle((i16)(x + (i32)10), (i16)(y + (i32)0), (i16)(x + (i32)14), (i16)(y + (i32)4),
                           (i16)(x + (i32)9), (i16)(y + (i32)6), pen);
            }
        else if (k == (i32)22) // edit: a pencil
            {
            UXIcon.ln(g, x + (i32)2, y + (i32)14, x + (i32)12, y + (i32)4, pen);
            UXIcon.ln(g, x + (i32)4, y + (i32)14, x + (i32)14, y + (i32)4, pen);
            UXIcon.ln(g, x + (i32)12, y + (i32)4, x + (i32)14, y + (i32)2, pen);
            UXIcon.ln(g, x + (i32)2, y + (i32)14, x + (i32)4, y + (i32)14, pen);
            }
        else // close: a cross
            {
            UXIcon.ln(g, x + (i32)3, y + (i32)3, x + (i32)13, y + (i32)13, pen);
            UXIcon.ln(g, x + (i32)4, y + (i32)3, x + (i32)13, y + (i32)12, pen);
            UXIcon.ln(g, x + (i32)13, y + (i32)3, x + (i32)3, y + (i32)13, pen);
            UXIcon.ln(g, x + (i32)12, y + (i32)3, x + (i32)3, y + (i32)12, pen);
            }
        return true;
        }
    }
