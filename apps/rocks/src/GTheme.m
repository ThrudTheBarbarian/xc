// GTheme.m — see GTheme.h.

#import "GTheme.h"

typedef struct
    {
    char name[40];
    int sx, sy, sw, sh; // source rect in the atlas (top-down)
    int l, t, r, b;     // 9-slice insets
    int fill;           // 0 stretch, 1 tile, 2 none
    } GSlice;

@implementation GTheme
    {
    NSBitmapImageRep* _atlas; // top-down RGBA
    int _atlasW, _atlasH;
    GSlice _slices[256];
    int _nslices;
    }

// Where to look for the theme, in order.  The bundled copy comes first and is
// the only one that matters for a built .app — `make` copies it in and fails if
// it cannot.  For running out of a source tree, set ROCKS_GEM_DIR to a GEM
// desktop checkout.  No absolute path is built in: one would only mask a broken
// bundle on the machine that built it.
+ (NSArray<NSString*>*)candidateDirs
    {
    NSMutableArray* c = [NSMutableArray array];
    NSString* bundled = [[NSBundle mainBundle] pathForResource:@"1x"
                                                        ofType:nil
                                                   inDirectory:@"themes/Aristo2"];
    if (bundled)
        [c addObject:bundled];
    NSString* gem = NSProcessInfo.processInfo.environment[@"ROCKS_GEM_DIR"];
    if (gem.length)
        [c addObject:[gem stringByAppendingPathComponent:@"themes/Aristo2/1x"]];
    return c;
    }

// Which one we actually loaded (or nil) — see Rocks --resources.
+ (NSString*)loadedFrom
    {
    NSFileManager* fm = [NSFileManager defaultManager];
    for (NSString* dir in [self candidateDirs])
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"theme.ini"]])
            return dir;
    return nil;
    }

+ (GTheme*)defaultTheme
    {
    static GTheme* shared;
    static BOOL tried;
    if (tried)
        return shared;
    tried = YES;
    NSFileManager* fm = [NSFileManager defaultManager];
    for (NSString* dir in [self candidateDirs])
        {
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"artwork.tex"]])
            {
            shared = [[GTheme alloc] initWithDir:dir];
            if (shared)
                break;
            }
        }
    return shared;
    }

- (instancetype)initWithDir:(NSString*)dir
    {
    if (!(self = [super init]))
        return nil;
    _name = dir.lastPathComponent;
    _fg = [NSColor colorWithSRGBRed:0x28 / 255.0 green:0x28 / 255.0 blue:0x28 / 255.0 alpha:1];
    if (![self loadAtlas:[dir stringByAppendingPathComponent:@"artwork.tex"]])
        return nil;
    [self loadLocations:[dir stringByAppendingPathComponent:@"locations.txt"]];
    [self loadIni:[dir stringByAppendingPathComponent:@"theme.ini"]];
    return _nslices ? self : nil;
    }

// GTEX: "GTEX" + uint32 LE width + uint32 LE height + width*height*4 RGBA (top-down)
- (BOOL)loadAtlas:(NSString*)path
    {
    NSData* d = [NSData dataWithContentsOfFile:path];
    if (d.length < 12)
        return NO;
    const uint8_t* p = d.bytes;
    if (memcmp(p, "GTEX", 4) != 0)
        return NO;
    int w = p[4] | p[5] << 8 | p[6] << 16 | p[7] << 24;
    int h = p[8] | p[9] << 8 | p[10] << 16 | p[11] << 24;
    if (w <= 0 || h <= 0 || d.length < 12 + (NSUInteger)w * h * 4)
        return NO;
    _atlasW = w;
    _atlasH = h;
    // NON-premultiplied: our RGBA are straight (gray/alpha from the source PNGs).
    _atlas = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                     pixelsWide:w
                                                     pixelsHigh:h
                                                  bitsPerSample:8
                                                samplesPerPixel:4
                                                       hasAlpha:YES
                                                       isPlanar:NO
                                                 colorSpaceName:NSDeviceRGBColorSpace
                                                   bitmapFormat:NSBitmapFormatAlphaNonpremultiplied
                                                    bytesPerRow:w * 4
                                                   bitsPerPixel:32];
    // The atlas stores each pixel as a native 0xRRGGBBAA uint32 (little-endian),
    // i.e. file bytes are A,B,G,R.  Reorder to the R,G,B,A the bitmap expects.
    const uint8_t* src = p + 12;
    uint8_t* dst = _atlas.bitmapData;
    for (NSUInteger i = 0; i < (NSUInteger)w * h; i++)
        {
        uint8_t a = src[i * 4 + 0], b = src[i * 4 + 1], g = src[i * 4 + 2], r = src[i * 4 + 3];
        dst[i * 4 + 0] = r;
        dst[i * 4 + 1] = g;
        dst[i * 4 + 2] = b;
        dst[i * 4 + 3] = a;
        }
    return YES;
    }

- (void)loadLocations:(NSString*)path
    {
    NSString* s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    for (NSString* raw in [s componentsSeparatedByString:@"\n"])
        {
        NSString* line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0 || [line hasPrefix:@"#"])
            continue;
        NSMutableArray* tok = [NSMutableArray array];
        for (NSString* t in [line componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]])
            if (t.length)
                [tok addObject:t];
        if (tok.count < 10 || _nslices >= 256)
            continue;
        GSlice sl;
        memset(&sl, 0, sizeof sl);
        strncpy(sl.name, [tok[0] UTF8String], sizeof(sl.name) - 1);
        sl.sx = [tok[1] intValue];
        sl.sy = [tok[2] intValue];
        sl.sw = [tok[3] intValue];
        sl.sh = [tok[4] intValue];
        sl.l = [tok[5] intValue];
        sl.t = [tok[6] intValue];
        sl.r = [tok[7] intValue];
        sl.b = [tok[8] intValue];
        NSString* f = tok[9];
        sl.fill = [f isEqualToString:@"tile"] ? 1 : [f isEqualToString:@"none"] ? 2
                                                                                : 0;
        _slices[_nslices++] = sl;
        }
    }

- (void)loadIni:(NSString*)path
    {
    NSString* s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    for (NSString* raw in [s componentsSeparatedByString:@"\n"])
        {
        NSArray* kv = [raw componentsSeparatedByString:@"="];
        if (kv.count != 2)
            continue;
        NSString* k = [kv[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        unsigned hex = 0;
        [[NSScanner scannerWithString:kv[1]] scanHexInt:&hex];
        NSColor* c = [NSColor colorWithSRGBRed:((hex >> 16) & 0xFF) / 255.0
                                         green:((hex >> 8) & 0xFF) / 255.0
                                          blue:(hex & 0xFF) / 255.0
                                         alpha:1];
        if ([k isEqualToString:@"fg"])
            _fg = c;
        }
    }

- (const GSlice*)find:(NSString*)name
    {
    const char* n = name.UTF8String;
    for (int i = 0; i < _nslices; i++)
        if (strcmp(_slices[i].name, n) == 0)
            return &_slices[i];
    return NULL;
    }
- (BOOL)hasSlice:(NSString*)name
    {
    return [self find:name] != NULL;
    }
- (NSSize)sliceSize:(NSString*)name
    {
    const GSlice* s = [self find:name];
    return s ? NSMakeSize(s->sw, s->sh) : NSZeroSize;
    }

// draw a top-down source rect from the atlas into dst (flipped-view coords)
- (void)blitSrcX:(int)sx y:(int)sy w:(int)sw h:(int)sh toDst:(NSRect)dst
    {
    if (sw <= 0 || sh <= 0 || dst.size.width <= 0 || dst.size.height <= 0)
        return;
    // NSImage coord origin is bottom-left; our atlas is top-down.
    NSRect from = NSMakeRect(sx, _atlasH - sy - sh, sw, sh);
    static NSImage* img;
    if (!img)
        {
        img = [[NSImage alloc] initWithSize:NSMakeSize(_atlasW, _atlasH)];
        [img addRepresentation:_atlas];
        }
    [img drawInRect:dst
              fromRect:from
             operation:NSCompositingOperationSourceOver
              fraction:1.0
        respectFlipped:YES
                 hints:nil];
    }

- (void)draw:(NSString*)name inRect:(NSRect)dst
    {
    const GSlice* s = [self find:name];
    if (!s)
        return;
    // 3x3 grid; a zero inset on an axis collapses that axis to a single cell.
    int lx = s->l, rx = s->r, ty = s->t, by = s->b;
    BOOL hSlice = (lx > 0 || rx > 0), vSlice = (ty > 0 || by > 0);

    int sxs[4] = {s->sx, s->sx + lx, s->sx + s->sw - rx, s->sx + s->sw};
    int sys[4] = {s->sy, s->sy + ty, s->sy + s->sh - by, s->sy + s->sh};
    CGFloat dxs[4] = {dst.origin.x, dst.origin.x + lx, NSMaxX(dst) - rx, NSMaxX(dst)};
    CGFloat dys[4] = {dst.origin.y, dst.origin.y + ty, NSMaxY(dst) - by, NSMaxY(dst)};

    int cStart = hSlice ? 0 : 0, cEnd = hSlice ? 3 : 1;
    int rStart = vSlice ? 0 : 0, rEnd = vSlice ? 3 : 1;
    for (int r = rStart; r < rEnd; r++)
        {
        for (int c = cStart; c < cEnd; c++)
            {
            int sX = hSlice ? sxs[c] : s->sx;
            int sW = hSlice ? sxs[c + 1] - sxs[c] : s->sw;
            int sY = vSlice ? sys[r] : s->sy;
            int sH = vSlice ? sys[r + 1] - sys[r] : s->sh;
            CGFloat dX = hSlice ? dxs[c] : dst.origin.x;
            CGFloat dW = hSlice ? dxs[c + 1] - dxs[c] : dst.size.width;
            CGFloat dY = vSlice ? dys[r] : dst.origin.y;
            CGFloat dH = vSlice ? dys[r + 1] - dys[r] : dst.size.height;
            [self blitSrcX:sX y:sY w:sW h:sH toDst:NSMakeRect(dX, dY, dW, dH)];
            }
        }
    }
@end
