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

protocol UXGraphics
    {
    void fillRect(UXRect r, i32 pen);                         // a solid rectangle (VDI pen index)
    void fillRectRGB(UXRect r, i32 red, i32 green, i32 blue); // a solid rectangle in true 8-bit RGB
    void drawTheme(u8 * slice, UXRect r);                     // a themed 9-slice (native widget art)
    void drawText(u8 * s, i16 x, i16 y, i32 pen, i32 size);
    // Styled text: a named family at a size, optionally bold/italic (the font chooser's preview).  Win32
    // and Cocoa render the real family + traits; GEM synthesises bold/italic (vst_effects) on its single
    // loaded face and honours the size.  size 0 means the UI default; family "" or unknown falls back.
    void drawTextFont(u8 * s, i16 x, i16 y, i32 pen, u8 * family, i32 size, bool bold, bool italic);
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
    // UXPainter keeps drawing it as one.
    bool strokesNatively(void);
    void strokeNative(i32 * ops, i32 n, i32 width, i32 startCap, i32 endCap, i32 pen);
    void strokeNativeRGB(i32 * ops, i32 n, i32 width, i32 startCap, i32 endCap,
                         i32 red, i32 green, i32 blue);
    }
