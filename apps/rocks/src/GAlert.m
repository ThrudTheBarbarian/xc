// GAlert.m — see GAlert.h.

#import "GAlert.h"
#import "GTheme.h"

static GTheme* theme(void)
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

// The AES's own limits.  Longer text is not rejected — it is what the resource
// says — but the wizard warns, because GEM will clip it.
static const int kMaxLines = 5, kMaxButtons = 3;

@implementation GAlert

- (instancetype)init
    {
    if ((self = [super init]))
        {
        _icon = GAlertNote;
        _lines = @[ @"Something happened." ];
        _buttons = @[ @"OK" ];
        _defaultButton = 1;
        }
    return self;
    }

// ---- the form_alert string -------------------------------------------------

+ (BOOL)looksLikeAlert:(NSString*)s
    {
    return [s hasPrefix:@"["] && [s componentsSeparatedByString:@"]"].count >= 3;
    }

// Pull out the three [..] sections.  Deliberately forgiving: real resources have
// stray spaces, missing buttons, and empty icon sections.
+ (GAlert*)alertFromString:(NSString*)s
    {
    if (!s.length || ![s hasPrefix:@"["])
        return nil;

    NSMutableArray<NSString*>* parts = [NSMutableArray array];
    NSScanner* sc = [NSScanner scannerWithString:s];
    sc.charactersToBeSkipped = nil;
    while (parts.count < 3)
        {
        if (![sc scanString:@"[" intoString:NULL])
            break;
        NSString* body = @"";
        [sc scanUpToString:@"]" intoString:&body];
        if (![sc scanString:@"]" intoString:NULL])
            break;
        [parts addObject:body ?: @""];
        }
    if (parts.count < 2)
        return nil; // need at least [icon][text]

    GAlert* a = [GAlert new];
    a.icon = (GAlertIcon)MIN(3, MAX(0, parts[0].intValue));
    a.lines = [parts[1] componentsSeparatedByString:@"|"];
    NSString* btns = parts.count > 2 ? parts[2] : @"";
    a.buttons = btns.length ? [btns componentsSeparatedByString:@"|"] : @[ @"OK" ];
    a.defaultButton = 1;
    return a;
    }

- (NSString*)stringValue
    {
    NSArray* ls = _lines.count ? _lines : @[ @"" ];
    NSArray* bs = _buttons.count ? _buttons : @[ @"OK" ];
    return [NSString stringWithFormat:@"[%d][%@][%@]", (int)_icon,
                                      [ls componentsJoinedByString:@"|"],
                                      [bs componentsJoinedByString:@"|"]];
    }

// ---- drawing ---------------------------------------------------------------

static NSString* iconSlice(GAlertIcon i)
    {
    switch (i)
        {
    case GAlertNote:
        return @"alert.note";
    case GAlertWait:
        return @"alert.wait";
    case GAlertStop:
        return @"alert.stop";
    default:
        return nil;
        }
    }

enum
    {
    kPad = 14,
    kIconGap = 14,
    kBtnH = 26,
    kBtnGap = 10,
    kLineH = 18,
    kBtnMinW = 72
    };

- (NSSize)preferredSize
    {
    NSFont* f = [NSFont systemFontOfSize:12];
    NSDictionary* attrs = @{NSFontAttributeName : f};

    CGFloat textW = 0;
    for (NSString* l in _lines)
        textW = MAX(textW, [l sizeWithAttributes:attrs].width);
    CGFloat textH = MAX(1, (CGFloat)_lines.count) * kLineH;

    GTheme* th = theme();
    NSString* slice = iconSlice(_icon);
    NSSize is = (slice && th && [th hasSlice:slice]) ? [th sliceSize:slice] : NSZeroSize;
    CGFloat iconW = is.width ? is.width + kIconGap : 0;

    CGFloat btnW = 0;
    for (NSString* b in _buttons)
        btnW += MAX(kBtnMinW, [b sizeWithAttributes:attrs].width + 24) + kBtnGap;
    if (btnW > 0)
        btnW -= kBtnGap;

    CGFloat w = MAX(iconW + textW, btnW) + kPad * 2;
    CGFloat h = MAX(textH, is.height) + kBtnH + kPad * 2 + kBtnGap;
    return NSMakeSize(MAX(w, 220), MAX(h, 96));
    }

- (void)drawInRect:(NSRect)r
    {
    GTheme* th = theme();
    NSColor* ink = th ? th.fg : [NSColor blackColor];

    // the alert panel itself
    if (th && [th hasSlice:@"dialog"])
        {
        [th draw:@"dialog" inRect:r];
        }
    else
        {
        [[NSColor colorWithWhite:0.93 alpha:1] set];
        NSRectFill(r);
        [[NSColor blackColor] set];
        NSFrameRect(r);
        }

    // icon, left, vertically centred in the text band
    CGFloat textLeft = NSMinX(r) + kPad;
    NSString* slice = iconSlice(_icon);
    if (slice && th && [th hasSlice:slice])
        {
        NSSize is = [th sliceSize:slice];
        NSRect ir = NSMakeRect(NSMinX(r) + kPad,
                               NSMinY(r) + kPad,
                               is.width, is.height);
        [th draw:slice inRect:ir];
        textLeft = NSMaxX(ir) + kIconGap;
        }

    // message lines
    NSDictionary* ta = @{NSFontAttributeName : [NSFont systemFontOfSize:12],
                         NSForegroundColorAttributeName : ink};
    CGFloat y = NSMinY(r) + kPad;
    for (NSString* l in _lines)
        {
        [l drawAtPoint:NSMakePoint(textLeft, y) withAttributes:ta];
        y += kLineH;
        }

    // buttons along the bottom, right-aligned
    NSDictionary* ba = @{NSFontAttributeName : [NSFont systemFontOfSize:12],
                         NSForegroundColorAttributeName : ink};
    CGFloat totalW = 0;
    NSMutableArray<NSNumber*>* widths = [NSMutableArray array];
    for (NSString* b in _buttons)
        {
        CGFloat w = MAX(kBtnMinW, [b sizeWithAttributes:ba].width + 24);
        [widths addObject:@(w)];
        totalW += w + kBtnGap;
        }
    if (totalW > 0)
        totalW -= kBtnGap;

    CGFloat bx = NSMaxX(r) - kPad - totalW;
    CGFloat by = NSMaxY(r) - kPad - kBtnH;
    for (int i = 0; i < (int)_buttons.count; i++)
        {
        CGFloat w = widths[i].doubleValue;
        NSRect br = NSMakeRect(bx, by, w, kBtnH);
        BOOL isDefault = (i + 1 == _defaultButton);
        NSString* bslice = isDefault ? @"button.default" : @"button";
        if (th && [th hasSlice:bslice])
            {
            [th draw:bslice inRect:br];
            }
        else
            {
            [[NSColor whiteColor] set];
            NSRectFill(br);
            [[NSColor blackColor] set];
            NSFrameRectWithWidth(br, isDefault ? 2 : 1);
            }
        NSSize ts = [_buttons[i] sizeWithAttributes:ba];
        [_buttons[i] drawAtPoint:NSMakePoint(br.origin.x + (w - ts.width) / 2,
                                             br.origin.y + (kBtnH - ts.height) / 2)
                  withAttributes:ba];
        bx += w + kBtnGap;
        }
    }

@end
