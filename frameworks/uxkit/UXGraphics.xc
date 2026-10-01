// UXGraphics.xc — the drawing context handed to every drawRect, as a swappable protocol.
//
// Each backend provides its own realization — UXGemGraphics over the AES's VDI on GEM, a
// GDI one on Win32, a CoreGraphics one on macOS — and a drawRect override calls these
// primitives without ever knowing which backend it is drawing through.  That is the whole
// point: one drawRect, native pixels on every host.
//
// Coordinates are BOUNDS-relative (0,0 = the view's top-left); the backend adds the view's
// origin, so a drawRect never has to know where it sits on screen.
#import "UXGeometry.xc"

// The op run strokeNative takes: an opcode followed by its coordinates, in whole pixels.
//   UXSTROKE_MOVE  x y                      start a subpath
//   UXSTROKE_LINE  x y                      straight to
//   UXSTROKE_CURVE c1x c1y c2x c2y x y      a cubic from the current point
//   UXSTROKE_CLOSE                          close the subpath
#define UXSTROKE_MOVE 0
#define UXSTROKE_LINE 1
#define UXSTROKE_CURVE 2
#define UXSTROKE_CLOSE 3

// The line join a native stroke uses at every interior vertex: UXJOIN_MITER / UXJOIN_ROUND /
// UXJOIN_BEVEL, defined with the caps in UXShapePath.xc (the vector pass owns the vocabulary).
// GEM ignores it because it keeps the neutral stroker, which is round.

// A font weight for drawTextFontRGBA, on the CSS scale (100 thin .. 900 black, 400 normal).  A number
// rather than a bool because a map's labels are 600 and a semibold is neither bold nor not.
#define UXWEIGHT_THIN 100
#define UXWEIGHT_LIGHT 300
#define UXWEIGHT_NORMAL 400
#define UXWEIGHT_MEDIUM 500
#define UXWEIGHT_SEMIBOLD 600
#define UXWEIGHT_BOLD 700
#define UXWEIGHT_BLACK 900

// The byte layouts drawPixels reads.  Both are STRAIGHT (not premultiplied) alpha, row-major, top row
// first, with no padding between rows.
#define UXPIX_RGBA 0   // bytes R,G,B,A -- a decoded PNG, the map's atlas
#define UXPIX_ARGB32 1 // u32 words 0xAARRGGBB in native order -- a UXImage

protocol UXGraphics
    {
    void fillRect(UXRect r, i32 pen);                         // a solid rectangle (VDI pen index)
    void fillRectRGB(UXRect r, i32 red, i32 green, i32 blue); // a solid rectangle in true 8-bit RGB
    void fillRectRGBA(UXRect r, i32 red, i32 green, i32 blue, i32 alpha); // ... and with an alpha
    // Make a rectangle carry NOTHING.  A layer that composites over a map has to start empty each frame,
    // and there is no other call that empties: fillRectRGBA(r,0,0,0,0) is a source-over fill, so alpha 0
    // paints nothing at all rather than erasing.  Where the surface has an alpha this clears to
    // transparent; where it does not (GEM, GDI — the same two that answer blendsAlpha false) it is the
    // window background, which is the closest a surface with no transparency can come to empty.
    void clearRect(UXRect r);
    // A region of a bitmap, scaled into a rect, with an extra overall alpha (255 = as stored).  `data`
    // is w x h pixels in `format` (UXPIX_*); `src` is the region in the bitmap's pixels and `dst` where
    // it lands, in view coordinates; the scaling is smooth.  The bitmap is NOT copied: a backend may
    // cache what it builds from `data` by its address, so the bytes must not change once drawn (draw
    // changed pixels from a new buffer).  The canvas drawImage(img, sx, sy, sw, sh, dx, dy, dw, dh).
    void drawPixels(u8* data, i32 w, i32 h, i32 format, UXRect src, UXRect dst, i32 alpha);
    void drawTheme(u8 * slice, UXRect r);                     // a themed 9-slice (native widget art)
    void drawText(u8 * s, i16 x, i16 y, i32 pen, i32 size);
    void drawTextRGBA(u8 * s, i16 x, i16 y, i32 red, i32 green, i32 blue, i32 alpha, i32 size);
    // Styled text: a named family at a size, optionally bold/italic (the font chooser's preview).  Win32
    // and Cocoa render the real family + traits; GEM synthesises bold/italic (vst_effects) on its single
    // loaded face and honours the size.  size 0 means the UI default; family "" or unknown falls back.
    void drawTextFont(u8 * s, i16 x, i16 y, i32 pen, u8 * family, i32 size, bool bold, bool italic);
    // Text with a family AND weight AND colour AND alpha at once: drawTextFont has the face and a pen
    // index, drawTextRGBA has the colour and alpha and no face, and a map's labels need all four.
    // `weight` is UXWEIGHT_* (a family with no such weight resolves to the nearest it has); `italic`
    // selects the italic face.  alpha is the same straight 0..255 as the RGBA family above.
    void drawTextFontRGBA(u8 * s, i16 x, i16 y, u8 * family, i32 size, i32 weight, bool italic,
                          i32 red, i32 green, i32 blue, i32 alpha);
    void fillTriangle(i16 x0, i16 y0, i16 x1, i16 y1, i16 x2, i16 y2, i32 pen);
    void fillCircle(i16 cx, i16 cy, i16 r, i32 pen);        // a filled disc (GEM radio; native art elsewhere)
    bool hasThemeArt(void);                                 // TRUE where drawTheme renders real atlas art (GEM, web);
                                                            // false where it is the flat stand-in — a widget picks
                                                            // sprite art or geometry accordingly
    void drawLine(i16 x0, i16 y0, i16 x1, i16 y1, i32 pen); // a stroked segment (checkmark, rules)
    // A filled CONVEX polygon: xy is x,y,x,y... in view coordinates, n is the point count.  This is
    // the primitive everything vector-shaped is built from — a stroked curve is a run of quads and
    // joins, a cap is a polygon, a radial gradient is a stack of shrinking polygons — so one call
    // buys the lot rather than each shape needing a seam of its own.  A flat i16 array because that
    // is literally VDI's v_fillarea signature, and the shortest path to GDI's Polygon and to
    // NSBezierPath.  CONVEX: the fill rule differs between backends for self-crossing outlines, and
    // UXPainter only ever hands over convex pieces, so the difference never shows.
    void fillPolygon(i16 * xy, i32 n, i32 pen);
    void fillPolygonRGB(i16 * xy, i32 n, i32 red, i32 green, i32 blue);
    void fillPolygonRGBA(i16 * xy, i32 n, i32 red, i32 green, i32 blue, i32 alpha);

    // ---- alpha --------------------------------------------------------------------------------
    // The RGBA family above is the RGB family with a fourth component: alpha, 0..255, straight (not
    // premultiplied), where 255 is what the RGB form draws.  It is what the map's ink needs — a
    // coastline at 0.92, a border glow at 0.12, 0.28 and 0.75 — and it keeps the two-dimensional
    // layer able to draw it without moving the ink into the GL layer as geometry.
    //
    // NOT EVERY BACKEND BLENDS, and this says which.  GEM draws hard VDI pixels into a palette and
    // has no compositing; GDI fills and strokes opaque and would need an offscreen DIB per shape to
    // do better.  Those two answer false and DRAW THE COLOUR OPAQUE — a shape that is meant to be
    // 12% still covers what is under it.  Ask before relying on alpha: a layer that cannot blend
    // should be told so rather than quietly draw at 1.0.
    bool blendsAlpha(void);

    // ---- native stroking ------------------------------------------------------------------------
    // True where the BACKEND can stroke a path itself: AppKit (NSBezierPath + setLineWidth:) and GDI
    // (a geometric pen + PolyBezierTo).  Those two draw the CURVE, at sub-pixel precision, with their
    // own joins and caps — the only way to get a smooth silhouette, because the toolkit's own stroker
    // offsets a polyline whose vertices are whole pixels and so wobbles by up to half a pixel.
    // GEM answers false and keeps the neutral stroker: the VDI has no wide-curve stroke, and on hard
    // pixels the wobble is invisible anyway.
    //
    // The path is handed over as a flat OP RUN rather than an object, because the AppKit half of this
    // lives in Objective-C and the Win32 half in GDI calls — neither can walk an xt class.  See
    // UXSTROKE_* for the encoding.  Caps are NONE/ROUND/SQUARE only: an ARROW is a shape, and
    // UXPainter keeps drawing it as one.  `join` (UXJOIN_*) is the interior-vertex join — the map's
    // borders set round and miter, and it is the cap's sibling rather than a new kind of thing.
    bool strokesNatively(void);
    // True where the backend's stroker can take a DASH as well: an on/off run in device pixels plus a
    // phase into it, both passed per call.  AppKit, cairo, Skia (Android), CoreGraphics and Canvas2D
    // all have one; GDI does not (its only phase-less dash is a cosmetic pen's, and a cosmetic pen is
    // one pixel wide with no join) and the VDI has neither, so those two answer false and the caller
    // dashes the flattened polyline itself — coarser, but at least the right picture.
    //
    // `ndash` 0 means solid, so a caller need not build an empty pattern.  The phase is in DEVICE
    // pixels and may be negative: a negative offset starts the run before its beginning, which is a
    // stroke beginning part-way through an off run rather than a different pattern.
    //
    // THE PHASE RESTARTS AT EVERY SUBPATH of the op run.  That is the browser's rule, and all five
    // dashers already keep it — AppKit, cairo, Skia, CoreGraphics and Canvas2D each measured with a
    // two-subpath run (make mac-dash / gtk-real / android-real / ios-real), so a run goes to the
    // backend whole and no shim splits anything.  See UXShapePath's dash comment.
    bool dashesNatively(void);
    // The stroke width is in DEVICE PIXELS and is a FRACTION: a pen of 1.536 is a pen of 1.536.  The
    // backends that stroke through a real stroker (AppKit, cairo, Skia, CoreGraphics, Canvas2D) draw
    // it exactly; GDI's pen width and the VDI's line width are whole numbers, so those two round to
    // the nearest pixel — a coarse hairline beats a wrong one.  The dash run and phase stay whole
    // pixels: a paint's dashes are its solid rhythm, and no caller has wanted a fraction of one yet.
    void strokeNative(i32 * ops, i32 n, double width, i32 startCap, i32 endCap, i32 join,
                      i32 * dash, i32 ndash, i32 phase, i32 pen);
    void strokeNativeRGB(i32 * ops, i32 n, double width, i32 startCap, i32 endCap, i32 join,
                         i32 * dash, i32 ndash, i32 phase, i32 red, i32 green, i32 blue);
    void strokeNativeRGBA(i32 * ops, i32 n, double width, i32 startCap, i32 endCap, i32 join,
                          i32 * dash, i32 ndash, i32 phase, i32 red, i32 green, i32 blue, i32 alpha);
    }
