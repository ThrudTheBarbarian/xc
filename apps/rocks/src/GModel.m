// GModel.m — model implementation.

#import "GModel.h"
#import "GImage.h"
#import <AppKit/AppKit.h>

NSString* GObTypeName(GObType t)
    {
    switch (t)
        {
    case GT_BOX:
        return @"Box";
    case GT_TEXT:
        return @"Text";
    case GT_BOXTEXT:
        return @"BoxText";
    case GT_IMAGE:
        return @"Image";
    case GT_USERDEF:
        return @"UserDef";
    case GT_IBOX:
        return @"IBox";
    case GT_BUTTON:
        return @"Button";
    case GT_BOXCHAR:
        return @"BoxChar";
    case GT_STRING:
        return @"String";
    case GT_FTEXT:
        return @"FText";
    case GT_FBOXTEXT:
        return @"FBoxText";
    case GT_ICON:
        return @"Icon";
    case GT_TITLE:
        return @"Title";
    case GT_CHECKBOX:
        return @"Checkbox";
    case GT_CICONBLK:
        return @"Colour Icon (CICONBLK)";
    case GT_RADIO:
        return @"Radio";
    case GT_POPUP:
        return @"Popup";
    case GT_FIELD:
        return @"Field";
    case GT_CICON:
        return @"Color Icon";
        }
    return @"?";
    }

@implementation GTedinfo
- (instancetype)init
    {
    if ((self = [super init]))
        {
        _text = @"";
        _tmplt = @"";
        _valid = @"";
        _font = 3;
        _just = 0;
        _color = gcw_default();
        }
    return self;
    }
@end

@implementation GBox
- (instancetype)init
    {
    if ((self = [super init]))
        {
        _character = 0;
        _thickness = 1;
        _color = gcw_default();
        }
    return self;
    }
@end

@implementation GBitblk
- (BOOL)isMform
    {
    return GBitblkIsMform(_data, _wb, _hl);
    }

- (NSImage*)image
    {
    if (_cachedImage)
        return _cachedImage;
    if (!_data || _wb <= 0 || _hl <= 0)
        return nil;
    // A cursor bank stores each MFORM inside a BITBLK; draw it as the 16x16
    // cursor it is, not as a 16x37 strip of raw words.
    _cachedImage = [self isMform] ? GImageFromMform(_data, NULL, NULL)
                                  : GImageFromBitblk(_data, _wb, _hl, _color);
    return _cachedImage;
    }
@end

@implementation GIcon
- (instancetype)init
    {
    if ((self = [super init]))
        {
        _isColor = YES;
        _label = @"";
        }
    return self;
    }

- (NSImage*)image
    {
    if (_cachedImage)
        return _cachedImage;
    if (_isColor)
        {
        NSData* d = _pam;
        if (!d && _externalPath)
            d = [NSData dataWithContentsOfFile:_externalPath];
        if (d)
            _cachedImage = GImageFromPAM(d);
        }
    else if (_monoData && _iconW > 0 && _iconH > 0)
        {
        _cachedImage = GImageFromMono(_monoData, _monoMask, _iconW, _iconH);
        }
    return _cachedImage;
    }
@end

@implementation GObject

+ (instancetype)objectOfType:(GObType)type frame:(NSRect)f
    {
    GObject* o = [GObject new];
    o.type = type;
    o.flags = OF_NONE;
    o.state = OS_NORMAL;
    o.x = (int)f.origin.x;
    o.y = (int)f.origin.y;
    o.w = (int)f.size.width;
    o.h = (int)f.size.height;
    o.children = [NSMutableArray array];
    [o seedPayload];
    // Editable field types default to OF_EDITABLE so they render their bezel.
    if (type == GT_FTEXT || type == GT_FBOXTEXT || type == GT_FIELD)
        o.flags |= OF_EDITABLE;
    return o;
    }

- (instancetype)init
    {
    if ((self = [super init]))
        {
        _children = [NSMutableArray array];
        }
    return self;
    }

- (BOOL)hasStringSpec
    {
    switch (_type)
        {
    case GT_STRING:
    case GT_BUTTON:
    case GT_TITLE:
    case GT_CHECKBOX:
    case GT_RADIO:
    case GT_POPUP:
        return YES; // G_BOXCHAR uses an inline box spec
    default:
        return NO;
        }
    }
- (BOOL)hasTedinfo
    {
    switch (_type)
        {
    case GT_TEXT:
    case GT_BOXTEXT:
    case GT_FTEXT:
    case GT_FBOXTEXT:
    case GT_FIELD:
        return YES;
    default:
        return NO;
        }
    }
- (BOOL)hasBox
    {
    switch (_type)
        {
    case GT_BOX:
    case GT_IBOX:
    case GT_BOXCHAR:
        return YES;
    default:
        return NO;
        }
    }
- (BOOL)hasIcon
    {
    return _type == GT_ICON || _type == GT_CICON || _type == GT_CICONBLK || _type == GT_IMAGE;
    }
- (BOOL)hasBitblk
    {
    return _type == GT_IMAGE;
    }
- (BOOL)canHaveChildren
    {
    switch (_type)
        {
    case GT_BOX:
    case GT_IBOX:
    case GT_BOXTEXT:
    case GT_IMAGE:
        return YES;
    default:
        return NO;
        }
    }

- (NSString*)defaultText
    {
    switch (_type)
        {
    case GT_BUTTON:
        return @"Button";
    case GT_CHECKBOX:
        return @"Checkbox";
    case GT_RADIO:
        return @"Option";
    case GT_TITLE:
        return @"Title";
    case GT_POPUP:
        return @"Popup";
    default:
        return @"Text";
        }
    }

- (void)seedPayload
    {
    if ([self hasStringSpec] && !_text)
        _text = [self defaultText];
    if ([self hasTedinfo] && !_ted)
        {
        _ted = [GTedinfo new];
        switch (_type)
            {
        case GT_TEXT:
            _ted.tmplt = @"Text";
            break; // static label
        case GT_BOXTEXT:
            _ted.tmplt = @"BoxText";
            _ted.thickness = 1;
            break; // boxed label
        default:
            _ted.tmplt = @"____________";
            break; // FTEXT/FBOXTEXT/FIELD slots
            }
        }
    if ([self hasBox] && !_box)
        _box = [GBox new];
    if ([self hasIcon] && !_icon)
        {
        _icon = [GIcon new];
        _icon.isColor = (_type == GT_CICON || _type == GT_CICONBLK || _type == GT_IMAGE);
        }
    }

- (GObject*)deepCopy
    {
    GObject* n = [GObject new];
    n.type = _type;
    n.extType = _extType;
    n.legacyExtType = _legacyExtType;
    n.flags = _flags;
    n.state = _state;
    n.x = _x;
    n.y = _y;
    n.w = _w;
    n.h = _h;
    n.text = _text;
    n.name = _name;
    if (_ted)
        {
        GTedinfo* t = [GTedinfo new];
        t.text = _ted.text;
        t.tmplt = _ted.tmplt;
        t.valid = _ted.valid;
        t.font = _ted.font;
        t.fontId = _ted.fontId;
        t.just = _ted.just;
        t.color = _ted.color;
        t.fontsize = _ted.fontsize;
        t.thickness = _ted.thickness;
        n.ted = t;
        }
    if (_box)
        {
        GBox* b = [GBox new];
        b.character = _box.character;
        b.thickness = _box.thickness;
        b.color = _box.color;
        n.box = b;
        }
    if (_bitblk)
        {
        GBitblk* bb = [GBitblk new];
        bb.data = _bitblk.data;
        bb.wb = _bitblk.wb;
        bb.hl = _bitblk.hl;
        bb.x = _bitblk.x;
        bb.y = _bitblk.y;
        bb.color = _bitblk.color;
        n.bitblk = bb;
        }
    if (_icon)
        {
        GIcon* ic = [GIcon new];
        ic.isColor = _icon.isColor;
        ic.label = _icon.label;
        ic.pam = _icon.pam;
        ic.externalPath = _icon.externalPath;
        ic.ciconRaw = _icon.ciconRaw;
        ic.selPam = _icon.selPam;
        ic.monoData = _icon.monoData;
        ic.monoMask = _icon.monoMask;
        ic.iconChar = _icon.iconChar;
        ic.charX = _icon.charX;
        ic.charY = _icon.charY;
        ic.textX = _icon.textX;
        ic.textY = _icon.textY;
        ic.textW = _icon.textW;
        ic.textH = _icon.textH;
        ic.iconX = _icon.iconX;
        ic.iconY = _icon.iconY;
        ic.iconW = _icon.iconW;
        ic.iconH = _icon.iconH;
        n.icon = ic;
        }
    NSMutableArray* kids = [NSMutableArray array];
    for (GObject* c in _children)
        [kids addObject:[c deepCopy]];
    n.children = kids;
    return n;
    }

- (void)preorder:(void (^)(GObject*))block
    {
    block(self);
    for (GObject* c in _children)
        [c preorder:block];
    }

- (GObject*)parentOf:(GObject*)target
    {
    for (GObject* c in _children)
        {
        if (c == target)
            return self;
        GObject* p = [c parentOf:target];
        if (p)
            return p;
        }
    return nil;
    }
@end

@implementation GTree
- (GObject*)parentOf:(GObject*)node
    {
    if (node == _root)
        return nil;
    return [_root parentOf:node];
    }
- (NSPoint)absoluteOriginOf:(GObject*)node
    {
    __block NSPoint found = NSMakePoint(NAN, NAN);
    void (^walk)(GObject*, int, int) = nil;
    __block __weak void (^weakWalk)(GObject*, int, int);
    weakWalk = walk = ^(GObject* o, int ax, int ay) {
      int bx = ax + o.x, by = ay + o.y;
      if (o == node)
          {
          found = NSMakePoint(bx, by);
          return;
          }
      for (GObject* c in o.children)
          weakWalk(c, bx, by);
    };
    walk(_root, 0, 0);
    return found;
    }
- (GObject*)hitTest:(NSPoint)p
    {
    __block GObject* best = nil;
    int px = (int)p.x, py = (int)p.y;
    void (^walk)(GObject*, int, int) = nil;
    __block __weak void (^weakWalk)(GObject*, int, int);
    weakWalk = walk = ^(GObject* o, int ax, int ay) {
      if (o.flags & OF_HIDETREE)
          return;
      int bx = ax + o.x, by = ay + o.y;
      if (px >= bx && py >= by && px < bx + o.w && py < by + o.h)
          best = o;
      for (GObject* c in o.children)
          weakWalk(c, bx, by);
    };
    walk(_root, 0, 0);
    return best;
    }
- (NSArray<GObject*>*)allObjects
    {
    NSMutableArray* out = [NSMutableArray array];
    [_root preorder:^(GObject* o) {
      [out addObject:o];
    }];
    return out;
    }

- (NSArray<GObject*>*)menuTitles
    {
    NSMutableArray* a = [NSMutableArray array];
    [_root preorder:^(GObject* o) {
      if (o.type == GT_TITLE)
          [a addObject:o];
    }];
    return a;
    }
- (BOOL)isMenu
    {
    return [self menuTitles].count > 0;
    }
- (GObject*)menuBar
    {
    NSArray* t = [self menuTitles];
    return t.count ? [self parentOf:t.firstObject] : nil;
    }
- (NSArray<GObject*>*)menuDropdowns
    {
    GObject* bar = [self menuBar];
    NSMutableArray* a = [NSMutableArray array];
    // A pulldown is a box that directly contains menu-item strings.
    [_root preorder:^(GObject* o) {
      if (o.type != GT_BOX || o == bar)
          return;
      for (GObject* c in o.children)
          if (c.type == GT_STRING || c.type == GT_FTEXT || c.type == GT_BOXTEXT)
              {
              [a addObject:o];
              break;
              }
    }];
    return a;
    }

- (GObject*)dropdownUnderTitle:(GObject*)title
    {
    if (!title)
        return nil;
    CGFloat tx = [self absoluteOriginOf:title].x;
    GObject* best = nil;
    CGFloat bestD = 1e9;
    for (GObject* dd in [self menuDropdowns])
        {
        CGFloat d = fabs([self absoluteOriginOf:dd].x - tx);
        if (d < bestD)
            {
            bestD = d;
            best = dd;
            }
        }
    return best;
    }
@end

@implementation GResource

+ (instancetype)emptyDialog
    {
    GResource* r = [GResource new];
    r.trees = [NSMutableArray array];
    r.freeStrings = [NSMutableArray array];
    r.freeImages = [NSMutableArray array];
    r.bigEndian = YES;
    r.packedCoords = YES;
    r.embedIcons = YES;
    r.charWidth = 8;
    r.charHeight = 16;
    GObject* root = [GObject objectOfType:GT_BOX frame:NSMakeRect(0, 0, 320, 200)];
    root.box.thickness = 2;
    root.flags = OF_LASTOB;
    GTree* t = [GTree new];
    t.name = @"TREE0";
    t.kind = GK_DIALOG;
    t.root = root;
    [r.trees addObject:t];
    return r;
    }

- (instancetype)init
    {
    if ((self = [super init]))
        {
        _trees = [NSMutableArray array];
        _freeStrings = [NSMutableArray array];
        _freeImages = [NSMutableArray array];
        _bigEndian = YES;
        _packedCoords = YES;
        _embedIcons = YES;
        _charWidth = 8;
        _charHeight = 16;
        }
    return self;
    }

- (int)flatten:(GTree*)tree into:(GFlatNode**)outNodes
    {
    NSMutableArray<GObject*>* order = [NSMutableArray array];
    [tree.root preorder:^(GObject* o) {
      [order addObject:o];
    }];
    int n = (int)order.count;
    NSMapTable* index = [NSMapTable strongToStrongObjectsMapTable];
    for (int i = 0; i < n; i++)
        [index setObject:@(i) forKey:order[i]];

    GFlatNode* flat = calloc(n, sizeof(GFlatNode));
    for (int i = 0; i < n; i++)
        {
        GObject* o = order[i];
        flat[i].obj = o;
        flat[i].next = -1;
        flat[i].head = o.children.count ? [[index objectForKey:o.children.firstObject] intValue] : -1;
        flat[i].tail = o.children.count ? [[index objectForKey:o.children.lastObject] intValue] : -1;
        }
    // sibling links: within each parent, next = following sibling; last -> parent
    void (^link)(GObject*) = nil;
    __block __weak void (^weakLink)(GObject*);
    weakLink = link = ^(GObject* parent) {
      NSArray* kids = parent.children;
      for (NSUInteger i = 0; i < kids.count; i++)
          {
          GObject* c = kids[i];
          int ci = [[index objectForKey:c] intValue];
          if (i + 1 < kids.count)
              flat[ci].next = [[index objectForKey:kids[i + 1]] intValue];
          else
              flat[ci].next = [[index objectForKey:parent] intValue];
          weakLink(c);
          }
    };
    link(tree.root);
    flat[0].next = -1;
    *outNodes = flat;
    return n;
    }
@end
