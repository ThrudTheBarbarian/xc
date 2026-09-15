// InspectorView.m — see InspectorView.h.  Controls are rebuilt on each selection
// change; each control carries an identifier read back in -ctlChanged:.

#import "InspectorView.h"
#import "GImage.h"

@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped
    {
    return YES;
    }
@end

@interface InspectorView () <NSTextFieldDelegate>
@end

@implementation InspectorView
    {
    NSScrollView* _scroll;
    NSView* _form; // flipped document view holding controls
    CGFloat _y;    // layout cursor (from top)
    NSMutableDictionary<NSString*, NSControl*>* _ctl;
    GObject* _obj; // the object being edited (anchor)
    }

- (instancetype)initWithFrame:(NSRect)f
    {
    if ((self = [super initWithFrame:f]))
        {
        _ctl = [NSMutableDictionary dictionary];
        _scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
        _scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _scroll.hasVerticalScroller = YES;
        _scroll.drawsBackground = YES;
        _scroll.backgroundColor = [NSColor colorWithWhite:0.2 alpha:1];
        [self addSubview:_scroll];
        }
    return self;
    }

- (BOOL)isFlipped
    {
    return YES;
    }

// MARK: layout helpers

- (NSTextField*)label:(NSString*)s
    {
    NSTextField* t = [NSTextField labelWithString:s];
    t.textColor = [NSColor colorWithWhite:0.65 alpha:1];
    t.font = [NSFont systemFontOfSize:10];
    t.frame = NSMakeRect(10, _y, 240, 14);
    [_form addSubview:t];
    _y += 15;
    return t;
    }

- (void)section:(NSString*)s
    {
    _y += 6;
    NSTextField* t = [NSTextField labelWithString:s.uppercaseString];
    t.textColor = [NSColor colorWithWhite:0.9 alpha:1];
    t.font = [NSFont boldSystemFontOfSize:11];
    t.frame = NSMakeRect(10, _y, 240, 16);
    [_form addSubview:t];
    _y += 20;
    }

- (NSTextField*)field:(NSString*)ident value:(NSString*)v x:(CGFloat)x width:(CGFloat)w
    {
    NSTextField* tf = [[NSTextField alloc] initWithFrame:NSMakeRect(x, _y, w, 20)];
    tf.stringValue = v ?: @"";
    tf.identifier = ident;
    tf.delegate = self;
    tf.target = self;
    tf.action = @selector(ctlChanged:);
    tf.font = [NSFont systemFontOfSize:11];
    [_form addSubview:tf];
    _ctl[ident] = tf;
    return tf;
    }

- (NSPopUpButton*)popup:(NSString*)ident items:(NSArray<NSString*>*)items
               selected:(NSInteger)sel
                      x:(CGFloat)x
                  width:(CGFloat)w
    {
    NSPopUpButton* pb = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x, _y, w, 22)];
    [pb addItemsWithTitles:items];
    if (sel >= 0 && sel < (NSInteger)items.count)
        [pb selectItemAtIndex:sel];
    pb.identifier = ident;
    pb.target = self;
    pb.action = @selector(ctlChanged:);
    pb.font = [NSFont systemFontOfSize:11];
    [_form addSubview:pb];
    _ctl[ident] = pb;
    return pb;
    }

- (NSButton*)check:(NSString*)ident title:(NSString*)title on:(BOOL)on x:(CGFloat)x
    {
    NSButton* b = [[NSButton alloc] initWithFrame:NSMakeRect(x, _y, 150, 18)];
    [b setButtonType:NSButtonTypeSwitch];
    b.title = title;
    b.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    b.identifier = ident;
    b.target = self;
    b.action = @selector(ctlChanged:);
    b.font = [NSFont systemFontOfSize:11];
    b.contentTintColor = [NSColor whiteColor];
    NSMutableAttributedString* at = [[NSMutableAttributedString alloc] initWithString:title];
    [at addAttribute:NSForegroundColorAttributeName value:[NSColor colorWithWhite:0.85 alpha:1] range:NSMakeRange(0, title.length)];
    b.attributedTitle = at;
    [_form addSubview:b];
    _ctl[ident] = b;
    return b;
    }

- (NSArray<NSString*>*)colorItems
    {
    return @[ @"0 white", @"1 black", @"2 red", @"3 green", @"4 blue", @"5 cyan", @"6 yellow",
              @"7 magenta", @"8 ltgray", @"9 gray", @"10 dkred", @"11 dkgreen", @"12 dkblue",
              @"13 dkcyan", @"14 dkyellow", @"15 dkmagenta" ];
    }

// MARK: rebuild

- (void)rebuild
    {
    _obj = self.doc.anchor;
    _form = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, self.bounds.size.width, 10)];
    _scroll.documentView = _form;
    [_ctl removeAllObjects];
    _y = 12;

    if (!_obj)
        {
        NSTextField* t = [NSTextField labelWithString:@"No selection"];
        t.textColor = [NSColor colorWithWhite:0.6 alpha:1];
        t.frame = NSMakeRect(12, 12, 200, 18);
        [_form addSubview:t];
        [self finishLayout];
        return;
        }

    NSUInteger count = self.doc.selection.count;
    [self section:count > 1 ? [NSString stringWithFormat:@"%lu objects", (unsigned long)count] : GObTypeName(_obj.type)];

    // type
    [self label:@"Type"];
    NSArray* typeNames = @[ @"Box", @"IBox", @"BoxText", @"BoxChar", @"String", @"Text",
                            @"FText", @"FBoxText", @"Field", @"Title", @"Button", @"Checkbox",
                            @"Radio", @"Popup", @"Icon", @"Color Icon", @"Image" ];
    NSArray* typeVals = @[ @(GT_BOX), @(GT_IBOX), @(GT_BOXTEXT), @(GT_BOXCHAR), @(GT_STRING),
                           @(GT_TEXT), @(GT_FTEXT), @(GT_FBOXTEXT), @(GT_FIELD), @(GT_TITLE),
                           @(GT_BUTTON), @(GT_CHECKBOX), @(GT_RADIO), @(GT_POPUP), @(GT_ICON),
                           @(GT_CICON), @(GT_IMAGE) ];
    NSInteger tsel = [typeVals indexOfObject:@(_obj.type)];
    [self popup:@"type" items:typeNames selected:tsel x:10 width:230];
    _y += 28;

    // symbolic name for the .h/.c/.xt export; blank means "derive one"
    [self label:@"Name"];
    NSTextField* nf = [self field:@"name" value:_obj.name ?: @"" x:10 width:230];
    nf.placeholderString = @"auto — from the text, else the type";
    _y += 28;

    // geometry — a small label sits directly above each field box
    [self section:@"Geometry"];
    CGFloat gx[4] = {10, 68, 126, 184};
    NSString* gn[4] = {@"X", @"Y", @"W", @"H"};
    for (int i = 0; i < 4; i++)
        {
        NSTextField* l = [NSTextField labelWithString:gn[i]];
        l.textColor = [NSColor colorWithWhite:0.65 alpha:1];
        l.font = [NSFont systemFontOfSize:10];
        l.frame = NSMakeRect(gx[i], _y, 52, 12);
        [_form addSubview:l];
        }
    _y += 14;
    [self field:@"x" value:@(_obj.x).stringValue x:gx[0] width:52];
    [self field:@"y" value:@(_obj.y).stringValue x:gx[1] width:52];
    [self field:@"w" value:@(_obj.w).stringValue x:gx[2] width:52];
    [self field:@"h" value:@(_obj.h).stringValue x:gx[3] width:52];
    _y += 28;

    // flags
    [self section:@"Flags"];
    [self flagCheck:@"f_sel" title:@"Selectable" flag:OF_SELECTABLE col:0];
    [self flagCheck:@"f_def" title:@"Default" flag:OF_DEFAULT col:1];
    _y += 18;
    [self flagCheck:@"f_exit" title:@"Exit" flag:OF_EXIT col:0];
    [self flagCheck:@"f_edit" title:@"Editable" flag:OF_EDITABLE col:1];
    _y += 18;
    [self flagCheck:@"f_rbtn" title:@"Radio Btn" flag:OF_RBUTTON col:0];
    [self flagCheck:@"f_touch" title:@"Touch Exit" flag:OF_TOUCHEXIT col:1];
    _y += 18;
    [self flagCheck:@"f_hide" title:@"Hide Tree" flag:OF_HIDETREE col:0];
    [self flagCheck:@"f_last" title:@"Last Object" flag:OF_LASTOB col:1];
    _y += 18;
    [self flagCheck:@"f_cancel" title:@"Cancel (Esc)" flag:OF_CANCEL col:0];
    [self flagCheck:@"f_move" title:@"Moveable (root)" flag:OF_MOVEABLE col:1];
    _y += 24;

    // state
    [self section:@"State"];
    [self stateCheck:@"s_sel" title:@"Selected" st:OS_SELECTED col:0];
    [self stateCheck:@"s_chk" title:@"Checked" st:OS_CHECKED col:1];
    _y += 18;
    [self stateCheck:@"s_dis" title:@"Disabled" st:OS_DISABLED col:0];
    [self stateCheck:@"s_out" title:@"Outlined" st:OS_OUTLINED col:1];
    _y += 18;
    [self stateCheck:@"s_cross" title:@"Crossed" st:OS_CROSSED col:0];
    [self stateCheck:@"s_shad" title:@"Shadowed" st:OS_SHADOWED col:1];
    _y += 22;
    [self label:@"Mnemonic — underlined shortcut char index (blank = none)"];
    int mi = (_obj.state & OS_WHITEBAK) ? GS_MNEMONIC_INDEX(_obj.state) : -1;
    [self field:@"mnemonic" value:(mi >= 0 ? @(mi).stringValue : @"") x:10 width:70];
    _y += 28;

    // type-specific
    if ([_obj hasStringSpec])
        {
        [self section:@"Text"];
        [self field:@"text" value:_obj.text x:10 width:230];
        _y += 28;
        }
    if ([_obj hasTedinfo])
        {
        [self section:@"TEDINFO"];
        [self label:@"Text"];
        [self field:@"ted_text" value:_obj.ted.text x:10 width:230];
        _y += 26;
        [self label:@"Template"];
        [self field:@"ted_tmpl" value:_obj.ted.tmplt x:10 width:230];
        _y += 26;
        [self label:@"Valid"];
        [self field:@"ted_valid" value:_obj.ted.valid x:10 width:230];
        _y += 26;
        [self label:@"Font / Justify"];
        [self popup:@"ted_font" items:@[ @"Large (3)", @"Small (5)" ] selected:(_obj.ted.font == 5 ? 1 : 0) x:10 width:112];
        [self popup:@"ted_just" items:@[ @"Left", @"Right", @"Center" ] selected:_obj.ted.just x:128 width:112];
        _y += 30;
        [self colorRowPrefix:@"ted" color:_obj.ted.color];
        if (_obj.type == GT_FTEXT || _obj.type == GT_FBOXTEXT || _obj.type == GT_FIELD)
            {
            [self check:@"fld_rounded" title:@"Rounded field (themed)" on:(_obj.extType & 0x01) x:10];
            _y += 24;
            }
        if (_obj.type == GT_BOXTEXT)
            {
            [self check:@"boxtext_group" title:@"Group box (label in border)" on:(_obj.extType & 0x01) x:10];
            _y += 24;
            [self cornerRoundingChecks];
            }
        }
    if ([_obj hasBox])
        {
        [self section:@"Box"];
        [self label:@"Thickness"];
        [self field:@"box_thick" value:@(_obj.box.thickness).stringValue x:10 width:70];
        if (_obj.type == GT_BOXCHAR)
            {
            [self label:@""];
            }
        _y += 26;
        if (_obj.type == GT_BOXCHAR)
            {
            [self label:@"Character"];
            NSString* ch = _obj.box.character ? [NSString stringWithFormat:@"%c", _obj.box.character] : @"";
            [self field:@"box_char" value:ch x:10 width:40];
            _y += 26;
            }
        [self colorRowPrefix:@"box" color:_obj.box.color];
        [self cornerRoundingChecks];
        }
    if ([_obj hasIcon])
        {
        [self section:_obj.type == GT_IMAGE ? @"Image" : @"Icon"];
        [self label:@"Label"];
        [self field:@"ic_label" value:_obj.icon.label x:10 width:230];
        _y += 26;
        [self check:@"ic_color" title:@"Colour icon (PAM)" on:_obj.icon.isColor x:10];
        _y += 24;
        NSButton* b = [[NSButton alloc] initWithFrame:NSMakeRect(10, _y, 160, 24)];
        b.title = @"Import image…";
        b.bezelStyle = NSBezelStyleRounded;
        b.target = self;
        b.action = @selector(importIcon:);
        [_form addSubview:b];
        _y += 30;
        NSImage* img = [_obj.icon image];
        if (img)
            {
            NSImageView* iv = [[NSImageView alloc] initWithFrame:NSMakeRect(10, _y, 64, 64)];
            iv.image = img;
            iv.imageScaling = NSImageScaleProportionallyUpOrDown;
            [_form addSubview:iv];
            _y += 70;
            }
        }

    if (_obj.type == GT_POPUP)
        {
        [self section:@"Popup menu"];
        [self label:@"Tree shown when clicked (written as the index)"];
        NSMutableArray* items = [NSMutableArray array];
        NSArray<GTree*>* trees = self.doc.resource.trees;
        for (int i = 0; i < (int)trees.count; i++)
            [items addObject:[NSString stringWithFormat:@"%d: %@", i, trees[i].name.length ? trees[i].name : @"(tree)"]];
        NSInteger sel = (_obj.extType < trees.count) ? _obj.extType : 0;
        [self popup:@"popup_tree" items:items selected:sel x:10 width:230];
        _y += 30;
        }

    [self finishLayout];
    }

- (void)cornerRoundingChecks
    {
    [self label:@"Rounded corners"];
    [self check:@"rnd_tl" title:@"Top-left" on:(_obj.extType & BOX_ROUND_TL) x:10];
    [self check:@"rnd_tr" title:@"Top-right" on:(_obj.extType & BOX_ROUND_TR) x:128];
    _y += 18;
    [self check:@"rnd_bl" title:@"Bottom-left" on:(_obj.extType & BOX_ROUND_BL) x:10];
    [self check:@"rnd_br" title:@"Bottom-right" on:(_obj.extType & BOX_ROUND_BR) x:128];
    _y += 24;
    }

- (void)flagCheck:(NSString*)ident title:(NSString*)title flag:(GFlags)flag col:(int)col
    {
    [self check:ident title:title on:(_obj.flags & flag) != 0 x:(col == 0 ? 10 : 128)];
    }
- (void)stateCheck:(NSString*)ident title:(NSString*)title st:(GState)st col:(int)col
    {
    [self check:ident title:title on:(_obj.state & st) != 0 x:(col == 0 ? 10 : 128)];
    }

- (void)colorRowPrefix:(NSString*)pfx color:(GColorWord)c
    {
    [self label:@"Border / Text colour"];
    [self popup:[pfx stringByAppendingString:@"_border"] items:[self colorItems] selected:c.border x:10 width:112];
    [self popup:[pfx stringByAppendingString:@"_text"] items:[self colorItems] selected:c.text x:128 width:112];
    _y += 30;
    [self label:@"Fill pattern / Inside colour"];
    [self popup:[pfx stringByAppendingString:@"_pat"] items:@[ @"0 hollow", @"1", @"2", @"3", @"4", @"5", @"6", @"7 solid" ] selected:c.pattern x:10 width:112];
    [self popup:[pfx stringByAppendingString:@"_inside"] items:[self colorItems] selected:c.inside x:128 width:112];
    _y += 30;
    [self check:[pfx stringByAppendingString:@"_replace"] title:@"Opaque text (replace)" on:c.replace x:10];
    _y += 24;
    }

- (void)finishLayout
    {
    NSRect f = _form.frame;
    f.size.height = MAX(_y + 20, self.bounds.size.height);
    f.size.width = self.bounds.size.width;
    _form.frame = f;
    }

// MARK: control readback

- (GColorWord)readColorPrefix:(NSString*)pfx fallback:(GColorWord)c
    {
    NSPopUpButton* b = (id)_ctl[[pfx stringByAppendingString:@"_border"]];
    NSPopUpButton* t = (id)_ctl[[pfx stringByAppendingString:@"_text"]];
    NSPopUpButton* p = (id)_ctl[[pfx stringByAppendingString:@"_pat"]];
    NSPopUpButton* in = (id)_ctl[[pfx stringByAppendingString:@"_inside"]];
    NSButton* rep = (id)_ctl[[pfx stringByAppendingString:@"_replace"]];
    if (b)
        c.border = (int)b.indexOfSelectedItem;
    if (t)
        c.text = (int)t.indexOfSelectedItem;
    if (p)
        c.pattern = (int)p.indexOfSelectedItem;
    if (in)
        c.inside = (int)in.indexOfSelectedItem;
    if (rep)
        c.replace = rep.state == NSControlStateValueOn;
    return c;
    }

- (void)ctlChanged:(NSControl*)sender
    {
    if (!_obj)
        return;
    NSString* id_ = sender.identifier;
    GObject* obj = _obj;
    [self.doc perform:@"Edit Property"
                block:^{
                  [self applyControl:id_ sender:sender to:obj];
                }];
    // some changes (type) restructure payloads: rebuild the inspector
    if ([id_ isEqualToString:@"type"] || [id_ hasPrefix:@"ic_color"])
        [self rebuild];
    }

- (void)applyControl:(NSString*)id_ sender:(NSControl*)sender to:(GObject*)o
    {
    int iv = sender.intValue;
    NSString* sv = sender.stringValue;
    NSInteger sel = [sender isKindOfClass:[NSPopUpButton class]] ? [(NSPopUpButton*)sender indexOfSelectedItem] : 0;
    BOOL on = [sender isKindOfClass:[NSButton class]] ? ((NSButton*)sender).state == NSControlStateValueOn : NO;

    if ([id_ isEqualToString:@"type"])
        {
        NSArray* typeVals = @[ @(GT_BOX), @(GT_IBOX), @(GT_BOXTEXT), @(GT_BOXCHAR), @(GT_STRING),
                               @(GT_TEXT), @(GT_FTEXT), @(GT_FBOXTEXT), @(GT_FIELD), @(GT_TITLE),
                               @(GT_BUTTON), @(GT_CHECKBOX), @(GT_RADIO), @(GT_POPUP), @(GT_ICON),
                               @(GT_CICON), @(GT_IMAGE) ];
        if (sel >= 0 && sel < (NSInteger)typeVals.count)
            {
            o.type = (GObType)[typeVals[sel] intValue];
            [o seedPayload];
            }
        }
    else if ([id_ isEqualToString:@"x"])
        o.x = iv;
    else if ([id_ isEqualToString:@"y"])
        o.y = iv;
    else if ([id_ isEqualToString:@"w"])
        o.w = MAX(iv, 1);
    else if ([id_ isEqualToString:@"h"])
        o.h = MAX(iv, 1);
    else if ([id_ isEqualToString:@"text"])
        o.text = sv;
    else if ([id_ isEqualToString:@"name"])
        o.name = sv.length ? sv : nil;
    // flags
    else if ([id_ isEqualToString:@"f_sel"])
        [self setFlag:OF_SELECTABLE on:on o:o];
    else if ([id_ isEqualToString:@"f_def"])
        [self setFlag:OF_DEFAULT on:on o:o];
    else if ([id_ isEqualToString:@"f_exit"])
        [self setFlag:OF_EXIT on:on o:o];
    else if ([id_ isEqualToString:@"f_edit"])
        [self setFlag:OF_EDITABLE on:on o:o];
    else if ([id_ isEqualToString:@"f_rbtn"])
        [self setFlag:OF_RBUTTON on:on o:o];
    else if ([id_ isEqualToString:@"f_touch"])
        [self setFlag:OF_TOUCHEXIT on:on o:o];
    else if ([id_ isEqualToString:@"f_hide"])
        [self setFlag:OF_HIDETREE on:on o:o];
    else if ([id_ isEqualToString:@"f_last"])
        [self setFlag:OF_LASTOB on:on o:o];
    else if ([id_ isEqualToString:@"f_cancel"])
        [self setFlag:OF_CANCEL on:on o:o];
    else if ([id_ isEqualToString:@"f_move"])
        [self setFlag:OF_MOVEABLE on:on o:o];
    // state
    else if ([id_ isEqualToString:@"s_sel"])
        [self setState:OS_SELECTED on:on o:o];
    else if ([id_ isEqualToString:@"s_chk"])
        [self setState:OS_CHECKED on:on o:o];
    else if ([id_ isEqualToString:@"s_dis"])
        [self setState:OS_DISABLED on:on o:o];
    else if ([id_ isEqualToString:@"s_out"])
        [self setState:OS_OUTLINED on:on o:o];
    else if ([id_ isEqualToString:@"s_cross"])
        [self setState:OS_CROSSED on:on o:o];
    else if ([id_ isEqualToString:@"s_shad"])
        [self setState:OS_SHADOWED on:on o:o];
    else if ([id_ isEqualToString:@"mnemonic"])
        {
        NSString* v = [sv stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        uint16_t st = o.state;
        if (v.length == 0)
            {
            st &= ~(uint16_t)OS_WHITEBAK;
            st &= ~(uint16_t)(0x7F << 8);
            }
        else
            {
            int m = v.intValue;
            if (m < 0)
                m = 0;
            if (m > 126)
                m = 126;
            st |= OS_WHITEBAK;
            st = (uint16_t)((st & ~(0x7F << 8)) | ((m & 0x7F) << 8));
            }
        o.state = (GState)st;
        }
    // tedinfo
    else if ([id_ isEqualToString:@"ted_text"])
        o.ted.text = sv;
    else if ([id_ isEqualToString:@"ted_tmpl"])
        o.ted.tmplt = sv;
    else if ([id_ isEqualToString:@"ted_valid"])
        o.ted.valid = sv;
    else if ([id_ isEqualToString:@"fld_rounded"])
        o.extType = on ? (o.extType | 0x01) : (o.extType & ~0x01);
    else if ([id_ isEqualToString:@"boxtext_group"])
        o.extType = on ? (o.extType | 0x01) : (o.extType & ~0x01);
    else if ([id_ isEqualToString:@"rnd_tl"])
        o.extType = on ? (o.extType | BOX_ROUND_TL) : (o.extType & ~BOX_ROUND_TL);
    else if ([id_ isEqualToString:@"rnd_tr"])
        o.extType = on ? (o.extType | BOX_ROUND_TR) : (o.extType & ~BOX_ROUND_TR);
    else if ([id_ isEqualToString:@"rnd_br"])
        o.extType = on ? (o.extType | BOX_ROUND_BR) : (o.extType & ~BOX_ROUND_BR);
    else if ([id_ isEqualToString:@"rnd_bl"])
        o.extType = on ? (o.extType | BOX_ROUND_BL) : (o.extType & ~BOX_ROUND_BL);
    else if ([id_ isEqualToString:@"popup_tree"])
        o.extType = (uint8_t)sel;
    else if ([id_ isEqualToString:@"ted_font"])
        o.ted.font = (sel == 1 ? 5 : 3);
    else if ([id_ isEqualToString:@"ted_just"])
        o.ted.just = (int)sel;
    else if ([id_ hasPrefix:@"ted_"])
        o.ted.color = [self readColorPrefix:@"ted" fallback:o.ted.color];
    // box
    else if ([id_ isEqualToString:@"box_thick"])
        o.box.thickness = iv;
    else if ([id_ isEqualToString:@"box_char"])
        o.box.character = sv.length ? [sv characterAtIndex:0] : 0;
    else if ([id_ hasPrefix:@"box_"])
        o.box.color = [self readColorPrefix:@"box" fallback:o.box.color];
    // icon
    else if ([id_ isEqualToString:@"ic_label"])
        o.icon.label = sv;
    else if ([id_ isEqualToString:@"ic_color"])
        {
        o.icon.isColor = on;
        o.icon.cachedImage = nil;
        }
    }

- (void)setFlag:(GFlags)f on:(BOOL)on o:(GObject*)o
    {
    o.flags = on ? (o.flags | f) : (o.flags & ~f);
    }
- (void)setState:(GState)s on:(BOOL)on o:(GObject*)o
    {
    o.state = on ? (o.state | s) : (o.state & ~s);
    }

- (void)controlTextDidEndEditing:(NSNotification*)n
    {
    [self ctlChanged:n.object];
    }

// MARK: icon import

- (void)importIcon:(id)sender
    {
    if (!_obj.icon)
        return;
    NSOpenPanel* p = [NSOpenPanel openPanel];
    p.allowedFileTypes = @[ @"pam", @"png", @"gif", @"tiff", @"jpg", @"jpeg", @"bmp" ];
    if ([p runModal] != NSModalResponseOK)
        return;
    NSURL* u = p.URLs.firstObject;
    GObject* obj = _obj;
    [self.doc perform:@"Import Icon"
                block:^{
                  obj.icon.isColor = YES;
                  obj.icon.cachedImage = nil;
                  if ([u.pathExtension.lowercaseString isEqualToString:@"pam"])
                      {
                      obj.icon.pam = [NSData dataWithContentsOfURL:u];
                      }
                  else
                      {
                      NSImage* img = [[NSImage alloc] initWithContentsOfURL:u];
                      if (img)
                          obj.icon.pam = GPAMFromImage(img);
                      }
                  obj.icon.externalPath = nil;
                }];
    [self rebuild];
    }
@end
