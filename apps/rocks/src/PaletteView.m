// PaletteView.m — see PaletteView.h.

#import "PaletteView.h"
#import "CanvasView.h"
#import "GModel.h"

@interface PaletteView () <NSDraggingSource>
@end

@implementation PaletteView
    {
    NSArray<NSNumber*>* _types;
    CGFloat _rowH;
    NSInteger _pressed;
    }

- (instancetype)initWithFrame:(NSRect)f
    {
    if ((self = [super initWithFrame:f]))
        {
        _rowH = 30;
        _pressed = -1;
        _types = @[ @(GT_BOX), @(GT_IBOX), @(GT_BOXTEXT), @(GT_STRING), @(GT_TEXT),
                    @(GT_TITLE), @(GT_BUTTON), @(GT_CHECKBOX), @(GT_RADIO),
                    @(GT_FIELD), @(GT_FTEXT), @(GT_POPUP), @(GT_BOXCHAR),
                    @(GT_ICON), @(GT_CICON), @(GT_IMAGE) ];
        }
    return self;
    }

- (BOOL)isFlipped
    {
    return YES;
    }

- (NSInteger)rowAt:(NSPoint)p
    {
    NSInteger r = (NSInteger)(p.y / _rowH);
    return (r >= 0 && r < (NSInteger)_types.count) ? r : -1;
    }

- (void)drawRect:(NSRect)dirty
    {
    [[NSColor colorWithWhite:0.16 alpha:1] set];
    NSRectFill(self.bounds);
    NSDictionary* attr = @{NSFontAttributeName : [NSFont systemFontOfSize:12],
                           NSForegroundColorAttributeName : [NSColor colorWithWhite:0.9 alpha:1]};
    for (NSInteger i = 0; i < (NSInteger)_types.count; i++)
        {
        NSRect row = NSMakeRect(0, i * _rowH, self.bounds.size.width, _rowH);
        if (i == _pressed)
            {
            [[NSColor colorWithSRGBRed:0.15 green:0.4 blue:0.8 alpha:1] set];
            NSRectFill(row);
            }
        // swatch
        NSRect sw = NSMakeRect(8, i * _rowH + 7, 16, 16);
        [[NSColor colorWithWhite:0.4 alpha:1] set];
        NSRectFill(sw);
        [[NSColor colorWithWhite:0.7 alpha:1] set];
        NSFrameRect(sw);
        NSString* name = GObTypeName((GObType)[_types[i] intValue]);
        [name drawAtPoint:NSMakePoint(34, i * _rowH + 8) withAttributes:attr];
        [[NSColor colorWithWhite:0 alpha:0.3] set];
        NSRectFill(NSMakeRect(0, (i + 1) * _rowH - 1, self.bounds.size.width, 1));
        }
    }

- (void)mouseDown:(NSEvent*)e
    {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    _pressed = [self rowAt:p];
    self.needsDisplay = YES;
    }

- (void)mouseDragged:(NSEvent*)e
    {
    if (_pressed < 0)
        return;
    GObType type = (GObType)[_types[_pressed] intValue];

    NSPasteboardItem* item = [[NSPasteboardItem alloc] init];
    [item setString:[NSString stringWithFormat:@"%d", type] forType:GPaletteDragType];
    NSDraggingItem* di = [[NSDraggingItem alloc] initWithPasteboardWriter:item];

    NSString* name = GObTypeName(type);
    NSDictionary* attr = @{NSFontAttributeName : [NSFont systemFontOfSize:12],
                           NSForegroundColorAttributeName : [NSColor whiteColor]};
    NSSize sz = [name sizeWithAttributes:attr];
    NSImage* img = [[NSImage alloc] initWithSize:NSMakeSize(sz.width + 16, sz.height + 8)];
    [img lockFocus];
    [[NSColor colorWithSRGBRed:0.15 green:0.4 blue:0.8 alpha:0.9] set];
    NSRectFill(NSMakeRect(0, 0, sz.width + 16, sz.height + 8));
    [name drawAtPoint:NSMakePoint(8, 4) withAttributes:attr];
    [img unlockFocus];

    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    di.draggingFrame = NSMakeRect(p.x - 8, p.y - 4, img.size.width, img.size.height);
    [di setDraggingFrame:di.draggingFrame contents:img];

    [self beginDraggingSessionWithItems:@[ di ] event:e source:self];
    _pressed = -1;
    self.needsDisplay = YES;
    }

- (void)mouseUp:(NSEvent*)e
    {
    _pressed = -1;
    self.needsDisplay = YES;
    }

// NSDraggingSource
- (NSDragOperation)draggingSession:(NSDraggingSession*)s
    sourceOperationMaskForDraggingContext:(NSDraggingContext)ctx
    {
    return NSDragOperationCopy;
    }
@end
