// GRender.m — see GRender.h.  Uses the XT GEM theme (Aristo2) when available,
// falling back to a pragmatic hand-drawn GEM look.

#import "GRender.h"
#import "GTheme.h"
#import <CoreText/CoreText.h>

static GTheme* gTheme(void)
    {
    static GTheme* t;
    static BOOL tried;
    if (!tried)
        {
        tried = YES;
        t = [GTheme defaultTheme];
        }
    return t;
    }

// The XTOS/GEM UI font (fonts/AovelSansRounded.ttf), loaded without registering.
NSString* GRenderFontPath(void); // which font file we actually loaded
void GRenderFontProbe(void);     // force the font load (Rocks --resources)
static NSString* gFontPath = nil;
NSString* GRenderFontPath(void)
    {
    return gFontPath;
    }

void GRenderFontProbe(void);
static NSFont* gUIFont(CGFloat size);
void GRenderFontProbe(void)
    {
    (void)gUIFont(12);
    }

static NSFont* gUIFont(CGFloat size)
    {
    static CGFontRef cg;
    static BOOL tried;
    if (!tried)
        {
        tried = YES;
        // Bundled first (see GTheme +candidateDirs — no absolute path is baked in).
        NSMutableArray* cands = [NSMutableArray array];
        NSString* b = [[NSBundle mainBundle] pathForResource:@"AovelSansRounded" ofType:@"ttf" inDirectory:@"fonts"];
        if (b)
            [cands addObject:b];
        NSString* gem = NSProcessInfo.processInfo.environment[@"ROCKS_GEM_DIR"];
        if (gem.length)
            [cands addObject:[gem stringByAppendingPathComponent:@"fonts/AovelSansRounded.ttf"]];
        for (NSString* p in cands)
            {
            NSData* dat = [NSData dataWithContentsOfFile:p];
            if (!dat)
                continue;
            CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)dat);
            cg = CGFontCreateWithDataProvider(dp);
            CGDataProviderRelease(dp);
            if (cg)
                {
                gFontPath = p;
                break;
                }
            }
        }
    if (cg)
        return (__bridge_transfer NSFont*)CTFontCreateWithGraphicsFont(cg, size, NULL, NULL);
    return [NSFont systemFontOfSize:size];
    }

// Test-drive mode parks a caret on one object; everything else draws without one.
static __weak GObject* gCaretObj = nil;
static int gCaretSlot = 0;
static int caretFor(GObject* o)
    {
    return (o && o == gCaretObj) ? gCaretSlot : -1;
    }

@implementation GRender

+ (void)setEditCaretObject:(GObject*)o slot:(int)slot
    {
    gCaretObj = o;
    gCaretSlot = slot;
    }

+ (NSColor*)penColor:(int)i
    {
    // Classic GEM/VDI 16-colour palette (index 0 = white background, 1 = black).
    static const int rgb[16][3] = {
        {255, 255, 255}, {0, 0, 0}, {255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {0, 255, 255}, {255, 255, 0}, {255, 0, 255}, {192, 192, 192}, {128, 128, 128}, {128, 0, 0}, {0, 128, 0}, {0, 0, 128}, {0, 128, 128}, {128, 128, 0}, {128, 0, 128}};
    if (i < 0 || i > 15)
        i = 1;
    return [NSColor colorWithSRGBRed:rgb[i][0] / 255.0
                               green:rgb[i][1] / 255.0
                                blue:rgb[i][2] / 255.0
                               alpha:1.0];
    }

static NSDictionary* textAttrs(int pen, CGFloat size, BOOL bold)
    {
    return @{NSFontAttributeName : gUIFont(size),
             NSForegroundColorAttributeName : [GRender penColor:pen]};
    }

static void drawCenteredText(NSString* s, NSRect r, int pen, CGFloat size, BOOL bold)
    {
    if (s.length == 0)
        return;
    NSDictionary* a = textAttrs(pen, size, bold);
    NSSize sz = [s sizeWithAttributes:a];
    NSPoint p = NSMakePoint(r.origin.x + (r.size.width - sz.width) / 2,
                            r.origin.y + (r.size.height - sz.height) / 2);
    [s drawAtPoint:p withAttributes:a];
    }

// text at a colour (themed widgets), centred vertically; align 0 left/1 right/2 centre
static void drawTextC(NSString* s, NSRect r, NSColor* col, CGFloat size, BOOL bold, int align)
    {
    if (s.length == 0)
        return;
    NSDictionary* a = @{NSFontAttributeName : gUIFont(size), NSForegroundColorAttributeName : col};
    NSSize sz = [s sizeWithAttributes:a];
    CGFloat x = r.origin.x + 6;
    if (align == 2)
        x = r.origin.x + (r.size.width - sz.width) / 2;
    else if (align == 1)
        x = NSMaxX(r) - sz.width - 6;
    [s drawAtPoint:NSMakePoint(x, r.origin.y + (r.size.height - sz.height) / 2) withAttributes:a];
    }

static void drawLeftText(NSString* s, NSRect r, int pen, CGFloat size, int just)
    {
    if (s.length == 0)
        return;
    NSDictionary* a = textAttrs(pen, size, NO);
    NSSize sz = [s sizeWithAttributes:a];
    CGFloat x = r.origin.x + 2;
    if (just == 1)
        x = r.origin.x + r.size.width - sz.width - 2; // right
    else if (just == 2)
        x = r.origin.x + (r.size.width - sz.width) / 2; // centre
    NSPoint p = NSMakePoint(x, r.origin.y + (r.size.height - sz.height) / 2);
    [s drawAtPoint:p withAttributes:a];
    }

// Draw a TEDINFO field left-aligned at its rect.  The fixed template text (label,
// punctuation) stays put; the value (te_ptext) fills the '_' slots, justified
// within the slot run per te_just (0 left / 1 right / 2 centre).  A leading '@' in
// te_ptext is GEM's "empty field" marker: we strip it and dim ONLY the value
// characters so the labels read at full strength.
// Theme slice for an editable field: rounded (ob_type high-byte bit 0) or square,
// plus the disabled state variant.
static NSString* tfSlice(GObject* o)
    {
    NSString* base = (o.extType & 0x01) ? @"textfield.rounded" : @"textfield";
    return (o.state & OS_DISABLED) ? [base stringByAppendingString:@".disabled"] : base;
    }

// `caret` is an index into the VALUE (0..length), or -1 for no caret.  It is
// drawn at the left edge of the template slot that value position occupies, so
// it lands where the next typed character will appear.
static void drawTed(GTedinfo* t, NSRect r, NSColor* normal, CGFloat size, int caret)
    {
    if (!t)
        return;
    if (t.font == 5)
        size = roundf(size * 0.72f); // te_font 5 = small system font
    NSFont* f = gUIFont(size);
    NSColor* dim = [NSColor colorWithWhite:0.62 alpha:1];
    NSString* txt = t.text ?: @"";
    BOOL empty = (txt.length == 0) || [txt hasPrefix:@"@"];
    NSString* val = (empty && txt.length > 0) ? [txt substringFromIndex:1] : txt;
    NSColor* valColor = empty ? dim : normal;
    NSDictionary* na = @{NSFontAttributeName : f, NSForegroundColorAttributeName : normal};
    NSDictionary* va = @{NSFontAttributeName : f, NSForegroundColorAttributeName : valColor};

    NSMutableAttributedString* out = [[NSMutableAttributedString alloc] init];
    NSString* tmpl = t.tmplt ?: @"";
    int nslots = 0;
    for (NSUInteger i = 0; i < tmpl.length; i++)
        if ([tmpl characterAtIndex:i] == '_')
            nslots++;
    NSInteger caretAt = -1; // index into `out` where the caret goes
    if (tmpl.length == 0)
        {
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:val attributes:va]];
        if (caret >= 0)
            caretAt = MIN((NSInteger)caret, (NSInteger)out.length);
        }
    else
        {
        int L = (int)val.length, off = 0;
        if (t.just == 1)
            off = MAX(0, nslots - L); // right
        else if (t.just == 2)
            off = MAX(0, (nslots - L) / 2); // centre
        int wantSlot = (caret >= 0) ? caret + off : -1;
        int slot = 0;
        for (NSUInteger i = 0; i < tmpl.length; i++)
            {
            unichar c = [tmpl characterAtIndex:i];
            if (c == '_')
                {
                if (slot == wantSlot)
                    caretAt = (NSInteger)out.length;
                int vi = slot - off;
                BOOL isVal = (vi >= 0 && vi < L);
                unichar ch = isVal ? [val characterAtIndex:vi] : ' ';
                [out appendAttributedString:[[NSAttributedString alloc]
                                                initWithString:[NSString stringWithCharacters:&ch length:1]
                                                    attributes:isVal ? va : na]];
                slot++;
                }
            else
                {
                [out appendAttributedString:[[NSAttributedString alloc]
                                                initWithString:[NSString stringWithCharacters:&c length:1]
                                                    attributes:na]];
                }
            }
        // caret past the last slot (a full field): sit at the end of the value
        if (caret >= 0 && caretAt < 0 && wantSlot >= nslots)
            caretAt = (NSInteger)out.length;
        }
    NSSize sz = [out size];
    // With editable slots, te_just already positioned the value inside them (label
    // stays left).  With no slots, justify the whole string within the rect.
    CGFloat x = r.origin.x + 3;
    if (nslots == 0)
        {
        if (t.just == 1)
            x = NSMaxX(r) - sz.width - 3; // right
        else if (t.just == 2)
            x = r.origin.x + (r.size.width - sz.width) / 2; // centre
        }
    CGFloat y = r.origin.y + (r.size.height - sz.height) / 2;
    [out drawAtPoint:NSMakePoint(x, y)];

    if (caretAt >= 0)
        {
        CGFloat cx = x;
        if (caretAt > 0)
            cx += [[out attributedSubstringFromRange:NSMakeRange(0, caretAt)] size].width;
        [[GRender penColor:1] set];
        NSRectFill(NSMakeRect(roundf(cx), y + 1, 1, sz.height - 2));
        }
    }

// A labelled group box (fieldset): a frame whose top border is broken by the
// TEDINFO text, e.g.  ┌─ Text ─────┐ .  Respects the fill pattern/colour (so it
// can highlight a group of options) and per-corner rounding (extType bits 4-7).
static void drawGroupBox(NSRect r, GTedinfo* t, GColorWord cw, uint8_t ext)
    {
    // 1. optional fill (same rounding as the frame)
    if (cw.pattern != 0 || cw.replace)
        {
        NSColor* c = [GRender penColor:cw.inside];
        if (cw.pattern > 0 && cw.pattern < 7)
            c = [c colorWithAlphaComponent:0.25 + 0.1 * cw.pattern];
        [c set];
        [boxPath(r, ext) fill];
        }

    NSString* label = t.text ?: @"";
    NSFont* f = gUIFont(8); // small caption text (about half the normal height)
    NSDictionary* ta = @{NSFontAttributeName : f,
                         NSForegroundColorAttributeName : [GRender penColor:cw.text]};
    NSSize ls = label.length ? [label sizeWithAttributes:ta] : NSZeroSize;
    NSRect fr = NSInsetRect(r, 0.5, 0.5);
    CGFloat x0 = fr.origin.x, y0 = fr.origin.y, x1 = NSMaxX(fr), y1 = NSMaxY(fr);
    CGFloat rad = (ext & BOX_ROUND_ALL) ? MIN(8.0, MIN(fr.size.width, fr.size.height) / 2) : 0;
    CGFloat rtl = (ext & BOX_ROUND_TL) ? rad : 0, rtr = (ext & BOX_ROUND_TR) ? rad : 0,
            rbr = (ext & BOX_ROUND_BR) ? rad : 0, rbl = (ext & BOX_ROUND_BL) ? rad : 0;
    CGFloat labX = x0 + 10 + rtl;
    CGFloat gapS = label.length ? labX - 4 : x0 + rtl;
    CGFloat gapE = label.length ? labX + ls.width + 4 : x0 + rtl;

    [[GRender penColor:cw.border] set];
    NSBezierPath* p = [NSBezierPath bezierPath];
    p.lineWidth = 1;
    [p moveToPoint:NSMakePoint(x0 + rtl, y0)]; // top-left dash (after any TL round)
    [p lineToPoint:NSMakePoint(gapS, y0)];
    [p moveToPoint:NSMakePoint(gapE, y0)]; // rest of the frame, clockwise
    [p lineToPoint:NSMakePoint(x1 - rtr, y0)];
    if (rtr)
        [p appendBezierPathWithArcFromPoint:NSMakePoint(x1, y0) toPoint:NSMakePoint(x1, y0 + rtr) radius:rtr];
    [p lineToPoint:NSMakePoint(x1, y1 - rbr)];
    if (rbr)
        [p appendBezierPathWithArcFromPoint:NSMakePoint(x1, y1) toPoint:NSMakePoint(x1 - rbr, y1) radius:rbr];
    [p lineToPoint:NSMakePoint(x0 + rbl, y1)];
    if (rbl)
        [p appendBezierPathWithArcFromPoint:NSMakePoint(x0, y1) toPoint:NSMakePoint(x0, y1 - rbl) radius:rbl];
    [p lineToPoint:NSMakePoint(x0, y0 + rtl)];
    if (rtl)
        [p appendBezierPathWithArcFromPoint:NSMakePoint(x0, y0) toPoint:NSMakePoint(x0 + rtl, y0) radius:rtl];
    [p stroke];
    if (label.length) // centred on the top border line
        [label drawAtPoint:NSMakePoint(labX, y0 - ls.height / 2) withAttributes:ta];
    }

// A rectangle path with any subset of its four corners rounded (extType bits
// 4-7).  Model coords: TL=(minX,minY) TR=(maxX,minY) BR=(maxX,maxY) BL=(minX,maxY).
static NSBezierPath* boxPath(NSRect r, uint8_t ext)
    {
    if (!(ext & BOX_ROUND_ALL))
        return [NSBezierPath bezierPathWithRect:r];
    CGFloat rad = MIN(8.0, MIN(r.size.width, r.size.height) / 2);
    BOOL tl = ext & BOX_ROUND_TL, tr = ext & BOX_ROUND_TR,
         br = ext & BOX_ROUND_BR, bl = ext & BOX_ROUND_BL;
    CGFloat x0 = r.origin.x, y0 = r.origin.y, x1 = NSMaxX(r), y1 = NSMaxY(r);
    NSBezierPath* p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(x0 + (tl ? rad : 0), y0)];
    [p lineToPoint:NSMakePoint(x1 - (tr ? rad : 0), y0)];
    if (tr)
        [p appendBezierPathWithArcFromPoint:NSMakePoint(x1, y0) toPoint:NSMakePoint(x1, y0 + rad) radius:rad];
    [p lineToPoint:NSMakePoint(x1, y1 - (br ? rad : 0))];
    if (br)
        [p appendBezierPathWithArcFromPoint:NSMakePoint(x1, y1) toPoint:NSMakePoint(x1 - rad, y1) radius:rad];
    [p lineToPoint:NSMakePoint(x0 + (bl ? rad : 0), y1)];
    if (bl)
        [p appendBezierPathWithArcFromPoint:NSMakePoint(x0, y1) toPoint:NSMakePoint(x0, y1 - rad) radius:rad];
    [p lineToPoint:NSMakePoint(x0, y0 + (tl ? rad : 0))];
    if (tl)
        [p appendBezierPathWithArcFromPoint:NSMakePoint(x0, y0) toPoint:NSMakePoint(x0 + rad, y0) radius:rad];
    [p closePath];
    return p;
    }

static void fillBoxRounded(NSRect r, GColorWord cw, uint8_t ext)
    {
    if (cw.pattern == 0 && !cw.replace)
        return; // hollow
    NSColor* c = [GRender penColor:cw.inside];
    if (cw.pattern > 0 && cw.pattern < 7)
        c = [c colorWithAlphaComponent:0.25 + 0.1 * cw.pattern];
    [c set];
    [boxPath(r, ext) fill];
    }
static void strokeBoxRounded(NSRect r, int thickness, int pen, uint8_t ext)
    {
    if (thickness == 0)
        return;
    CGFloat t = ABS(thickness);
    [[GRender penColor:pen] set];
    NSBezierPath* p = boxPath(NSInsetRect(r, t / 2, t / 2), ext);
    p.lineWidth = t;
    [p stroke];
    }

static void fillBox(NSRect r, GColorWord cw)
    {
    if (cw.pattern == 0 && !cw.replace)
        {
        // hollow: no fill
        }
    else
        {
        NSColor* c = [GRender penColor:cw.inside];
        if (cw.pattern > 0 && cw.pattern < 7)
            c = [c colorWithAlphaComponent:0.25 + 0.1 * cw.pattern];
        [c set];
        NSRectFill(r);
        }
    }

static void strokeBox(NSRect r, int thickness, int pen)
    {
    if (thickness == 0)
        return;
    CGFloat t = ABS(thickness);
    [[GRender penColor:pen] set];
    NSBezierPath* p = [NSBezierPath bezierPathWithRect:NSInsetRect(r, t / 2, t / 2)];
    p.lineWidth = t;
    [p stroke];
    }

+ (void)drawObject:(GObject*)o at:(NSPoint)origin
    {
    NSRect r = NSMakeRect(origin.x, origin.y, o.w, o.h);
    CGFloat fontSize = 11;

    switch (o.type)
        {
    case GT_BOX:
    case GT_IBOX:
    case GT_BOXCHAR:
        {
        GBox* b = o.box ?: [GBox new];
        if (o.type != GT_IBOX)
            fillBoxRounded(r, b.color, o.extType);
        strokeBoxRounded(r, o.type == GT_IBOX ? (b.thickness ?: 1) : b.thickness, b.color.border, o.extType);
        if (o.type == GT_BOXCHAR && b.character)
            {
            NSString* s = [NSString stringWithFormat:@"%c", b.character];
            drawCenteredText(s, r, b.color.text, fontSize, NO);
            }
        break;
        }
    case GT_STRING:
    case GT_TITLE:
        drawLeftText(o.text ?: @"", r, (o.state & OS_DISABLED) ? 9 : 1, fontSize, 0);
        break;
    case GT_TEXT:
    case GT_FTEXT:
        {
        GTheme* th = gTheme();
        BOOL editable = (o.type == GT_FTEXT) && (o.flags & OF_EDITABLE);
        BOOL themed = editable && th && [th hasSlice:@"textfield"];
        if (themed)
            [th draw:tfSlice(o) inRect:r];
        // Real resources routinely leave te_color at 0, which is VDI pen 0 =
        // white — invisible on the theme's white field.  Drawn on the theme,
        // take its foreground, exactly as G_FIELD does.
        NSColor* ink = themed ? th.fg : [GRender penColor:o.ted ? o.ted.color.text : 1];
        drawTed(o.ted, r, ink, fontSize, caretFor(o));
        break;
        }
    case GT_BOXTEXT:
    case GT_FBOXTEXT:
        {
        GColorWord cw = o.ted ? o.ted.color : gcw_default();
        GTheme* th = gTheme();
        // labelled group box
        if (o.type == GT_BOXTEXT && (o.extType & 0x01))
            {
            drawGroupBox(r, o.ted, cw, o.extType);
            break;
            }
        BOOL editable = (o.type == GT_FBOXTEXT) && (o.flags & OF_EDITABLE);
        BOOL themed = editable && th && [th hasSlice:@"textfield"];
        if (themed)
            {
            [th draw:tfSlice(o) inRect:r];
            }
        else
            {
            fillBoxRounded(r, cw, o.extType);
            strokeBoxRounded(r, o.ted ? o.ted.thickness : 1, cw.border, o.extType);
            }
        // as G_FTEXT: te_color 0 is pen 0 (white) and would vanish on the theme
        drawTed(o.ted, r, themed ? th.fg : [GRender penColor:cw.text], fontSize, caretFor(o));
        break;
        }
    case GT_FIELD:
        {
        GTheme* th = gTheme();
        if (th)
            {
            [th draw:tfSlice(o) inRect:r];
            drawTed(o.ted, r, th.fg, fontSize, caretFor(o));
            }
        else
            {
            [[NSColor whiteColor] set];
            NSRectFill(r);
            [[GRender penColor:1] set];
            NSFrameRect(r);
            drawTed(o.ted, r, [GRender penColor:1], fontSize, caretFor(o));
            }
        break;
        }
    case GT_BUTTON:
        {
        GTheme* th = gTheme();
        BOOL def = (o.flags & OF_DEFAULT) != 0, sel = (o.state & OS_SELECTED) != 0;
        BOOL dis = (o.state & OS_DISABLED) != 0;
        if (th)
            {
            NSString* slice = dis            ? @"button.disabled"
                              : (def && sel) ? @"button.default.pressed"
                              : def          ? @"button.default"
                              : sel          ? @"button.selected"
                                             : @"button";
            [th draw:slice inRect:r];
            NSColor* tc = def ? [NSColor whiteColor] : dis ? [GRender penColor:9]
                                                           : th.fg;
            drawTextC(o.text ?: @"", r, tc, fontSize, def, 2);
            }
        else
            {
            NSColor* fill = sel ? [GRender penColor:1] : [NSColor colorWithWhite:0.93 alpha:1];
            [fill set];
            NSBezierPath* bp = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 0.5, 0.5) xRadius:3 yRadius:3];
            [bp fill];
            [[GRender penColor:1] set];
            bp.lineWidth = def ? 2 : 1;
            [bp stroke];
            drawCenteredText(o.text ?: @"", r, sel ? 0 : 1, fontSize, def);
            }
        break;
        }
    case GT_CHECKBOX:
    case GT_RADIO:
        {
        GTheme* th = gTheme();
        BOOL on = (o.state & OS_SELECTED) != 0; // the ticked state is OS_SELECTED
        NSString* base = o.type == GT_RADIO ? @"radio" : @"check";
        if (th && [th hasSlice:base])
            {
            NSSize ss = [th sliceSize:base];
            CGFloat bs = ss.height > 0 ? ss.height : 16;
            NSRect bx = NSMakeRect(r.origin.x, r.origin.y + (r.size.height - bs) / 2, ss.width, bs);
            [th draw:(on ? [base stringByAppendingString:@".selected"] : base) inRect:bx];
            NSRect tr = NSMakeRect(NSMaxX(bx) + 6, r.origin.y, NSMaxX(r) - NSMaxX(bx) - 6, r.size.height);
            drawTextC(o.text ?: @"", tr, th.fg, fontSize, NO, 0);
            break;
            }
        // fallback
        NSRect bx = NSMakeRect(r.origin.x, r.origin.y + (r.size.height - 14) / 2, 14, 14);
        [[NSColor whiteColor] set];
        if (o.type == GT_RADIO)
            {
            [[NSBezierPath bezierPathWithOvalInRect:bx] fill];
            [[GRender penColor:1] set];
            [[NSBezierPath bezierPathWithOvalInRect:bx] stroke];
            }
        else
            {
            NSRectFill(bx);
            [[GRender penColor:1] set];
            NSFrameRect(bx);
            }
        if (on)
            {
            [[GRender penColor:1] set];
            if (o.type == GT_RADIO)
                [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(bx, 4, 4)] fill];
            else
                {
                NSBezierPath* c = [NSBezierPath bezierPath];
                [c moveToPoint:NSMakePoint(bx.origin.x + 3, bx.origin.y + 7)];
                [c lineToPoint:NSMakePoint(bx.origin.x + 6, bx.origin.y + 11)];
                [c lineToPoint:NSMakePoint(bx.origin.x + 11, bx.origin.y + 3)];
                c.lineWidth = 2;
                [c stroke];
                }
            }
        drawLeftText(o.text ?: @"", NSMakeRect(r.origin.x + 20, r.origin.y, r.size.width - 20, r.size.height), 1, fontSize, 0);
        break;
        }
    case GT_POPUP:
        {
        GTheme* th = gTheme();
        if (th && [th hasSlice:@"popup"])
            {
            [th draw:@"popup" inRect:r];
            drawTextC(o.text ?: @"", NSMakeRect(r.origin.x, r.origin.y, r.size.width - 20, r.size.height), th.fg, fontSize, NO, 0);
            }
        else
            {
            [[NSColor colorWithWhite:0.95 alpha:1] set];
            NSRectFill(r);
            [[GRender penColor:1] set];
            NSFrameRect(r);
            drawLeftText(o.text ?: @"", NSMakeRect(r.origin.x, r.origin.y, r.size.width - 16, r.size.height), 1, fontSize, 0);
            NSBezierPath* ch = [NSBezierPath bezierPath];
            CGFloat ax = r.origin.x + r.size.width - 12, ay = r.origin.y + r.size.height / 2 - 2;
            [ch moveToPoint:NSMakePoint(ax, ay)];
            [ch lineToPoint:NSMakePoint(ax + 8, ay)];
            [ch lineToPoint:NSMakePoint(ax + 4, ay + 5)];
            [ch closePath];
            [ch fill];
            }
        break;
        }
    case GT_ICON:
    case GT_CICON:
        {
        NSImage* img = [o.icon image];
        if (img)
            {
            CGFloat iw = MIN(o.w, img.size.width), ih = MIN(o.h - 12, img.size.height);
            if (o.icon.iconW > 0)
                {
                iw = o.icon.iconW;
                ih = o.icon.iconH;
                }
            NSRect ir = NSMakeRect(r.origin.x + (r.size.width - iw) / 2, r.origin.y, iw, ih);
            [img drawInRect:ir
                      fromRect:NSZeroRect
                     operation:NSCompositingOperationSourceOver
                      fraction:1
                respectFlipped:YES
                         hints:nil]; // flipped canvas
            }
        else
            {
            [[NSColor colorWithWhite:0.85 alpha:1] set];
            NSRectFill(NSMakeRect(r.origin.x, r.origin.y, r.size.width, r.size.height - 12));
            [[GRender penColor:9] set];
            NSFrameRect(NSMakeRect(r.origin.x, r.origin.y, r.size.width, r.size.height - 12));
            }
        NSString* lab = o.icon.label.length ? o.icon.label : (o.text ?: @"");
        NSRect lr = NSMakeRect(r.origin.x, r.origin.y + r.size.height - 12, r.size.width, 12);
        drawCenteredText(lab, lr, 1, 10, NO);
        break;
        }
    case GT_IMAGE:
        {
        // A classic G_IMAGE is a BITBLK bit form; Rocks' own is a PAM icon.
        NSImage* img = o.bitblk ? [o.bitblk image] : [o.icon image];
        if (img)
            {
            [img drawInRect:r
                      fromRect:NSZeroRect
                     operation:NSCompositingOperationSourceOver
                      fraction:1
                respectFlipped:YES
                         hints:nil];
            }
        else
            {
            [[NSColor colorWithWhite:0.85 alpha:1] set];
            NSRectFill(r);
            [[GRender penColor:9] set];
            NSFrameRect(r);
            drawCenteredText(@"IMAGE", r, 9, 9, NO);
            }
        break;
        }
    default:
        [[GRender penColor:9] set];
        NSFrameRect(r);
        drawCenteredText(GObTypeName(o.type), r, 9, 9, NO);
        break;
        }
    }

+ (void)drawTreeNode:(GObject*)o origin:(NSPoint)origin hidden:(NSSet<GObject*>*)hidden
    {
    if (o.flags & OF_HIDETREE)
        return;
    if (hidden && [hidden containsObject:o])
        return;
    NSPoint abs = NSMakePoint(origin.x + o.x, origin.y + o.y);
    [self drawObject:o at:abs];
    for (GObject* c in o.children)
        [self drawTreeNode:c origin:abs hidden:hidden];
    }

+ (void)drawTree:(GTree*)tree
    {
    [self drawTree:tree hidden:nil];
    }
+ (void)drawTree:(GTree*)tree hidden:(NSSet<GObject*>*)hidden
    {
    [self drawTreeNode:tree.root origin:NSZeroPoint hidden:hidden];
    }

+ (void)drawMenuTree:(GTree*)tree activeIndex:(int)active
    {
    GTheme* th = gTheme();
    NSArray<GObject*>* titles = [tree menuTitles];
    if (titles.count == 0)
        {
        [self drawTree:tree];
        return;
        }

    // 1. the menu bar: a light strip across the top, with the title labels.
    NSPoint t0 = [tree absoluteOriginOf:titles.firstObject];
    CGFloat barH = titles.firstObject.h;
    NSRect barR = NSMakeRect(0, t0.y, tree.root.w, barH);
    [[NSColor colorWithSRGBRed:244 / 255.0 green:245 / 255.0 blue:247 / 255.0 alpha:1] set];
    NSRectFill(barR);
    [(th ? [NSColor colorWithSRGBRed:0xD9 / 255.0 green:0xD9 / 255.0 blue:0xD3 / 255.0 alpha:1]
         : [GRender penColor:1]) set];
    NSRectFill(NSMakeRect(barR.origin.x, NSMaxY(barR) - 1, barR.size.width, 1));
    for (int i = 0; i < (int)titles.count; i++)
        {
        GObject* t = titles[i];
        NSPoint to = [tree absoluteOriginOf:t];
        NSRect tr = NSMakeRect(to.x, to.y, t.w, t.h);
        BOOL on = (i == active);
        if (on)
            {
            [[NSColor colorWithSRGBRed:0x38 / 255.0 green:0x75 / 255.0 blue:0xD6 / 255.0 alpha:1] set];
            NSRectFill(NSMakeRect(tr.origin.x, tr.origin.y, tr.size.width, tr.size.height - 1));
            }
        drawTextC(t.text ?: @"", tr, on ? [NSColor whiteColor] : (th ? th.fg : [GRender penColor:1]),
                  12, NO, 2);
        }

    // 2. the active dropdown — the box sitting under the active title (by X)
    GObject* activeTitle = (active >= 0 && active < (int)titles.count) ? titles[active] : nil;
    GObject* dd = [tree dropdownUnderTitle:activeTitle];
    if (dd)
        {
        NSPoint ddo = [tree absoluteOriginOf:dd];
        NSRect ddR = NSMakeRect(ddo.x, ddo.y, dd.w, dd.h);
        if (th && [th hasSlice:@"menu"])
            [th draw:@"menu" inRect:ddR];
        else
            {
            [[NSColor whiteColor] set];
            NSRectFill(ddR);
            [[GRender penColor:1] set];
            NSFrameRect(ddR);
            }
        for (GObject* item in dd.children)
            {
            NSRect ir = NSMakeRect(ddo.x + item.x, ddo.y + item.y, item.w, item.h);
            BOOL disabled = (item.state & OS_DISABLED) != 0;
            if (item.state & OS_SELECTED)
                {
                [[NSColor colorWithSRGBRed:0x38 / 255.0 green:0x75 / 255.0 blue:0xD6 / 255.0 alpha:1] set];
                NSRectFill(ir);
                }
            if ((item.state & OS_CHECKED) && th && [th hasSlice:@"menu.tick"])
                {
                NSSize ts = [th sliceSize:@"menu.tick"];
                [th draw:@"menu.tick" inRect:NSMakeRect(ir.origin.x + 2, ir.origin.y + (ir.size.height - ts.height) / 2, ts.width, ts.height)];
                }
            NSColor* tc = (item.state & OS_SELECTED) ? [NSColor whiteColor]
                          : disabled                 ? [GRender penColor:9]
                                                     : (th ? th.fg : [GRender penColor:1]);
            // menu-item strings carry their own leading spaces for the tick; draw
            // left-aligned at the item's own rect (no extra indent).
            drawTextC(item.text ?: (item.ted.text ?: @""), ir, tc, 13, NO, 0);
            }
        }
    }
@end
