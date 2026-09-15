// AlertWizard.m — see AlertWizard.h.

#import "AlertWizard.h"
#import "GAlert.h"

// The live preview: draws the alert exactly as GAlert would on the canvas.
@interface GAlertPreview : NSView
@property(strong) GAlert* alert;
@end

@implementation GAlertPreview
// GTheme slices assume a flipped view
- (BOOL)isFlipped
    {
    return YES;
    }
- (void)drawRect:(NSRect)dirty
    {
    [[NSColor colorWithWhite:0.28 alpha:1] set];
    NSRectFill(self.bounds);
    if (!_alert)
        return;

    NSSize want = [_alert preferredSize];
    NSRect r = NSMakeRect(round((NSWidth(self.bounds) - want.width) / 2),
                          round((NSHeight(self.bounds) - want.height) / 2),
                          want.width, want.height);
    [[NSColor colorWithWhite:0 alpha:0.35] set];
    NSRectFill(NSOffsetRect(r, 3, 3)); // a little drop shadow
    [_alert drawInRect:r];
    }
@end

@implementation AlertWizard
    {
    Document* _doc;
    int _editIndex; // free-string index being edited, or -1
    GAlert* _alert;
    GAlertPreview* _preview;
    NSPopUpButton* _iconPopup;
    NSTextField* _lines[5];
    NSTextField* _buttons[3];
    NSPopUpButton* _defaultPopup;
    NSTextField* _stringField; // the literal form_alert string
    NSTextField* _warning;
    }

- (instancetype)initWithDocument:(Document*)doc editingIndex:(int)index
    {
    NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 720, 430)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.title = index >= 0 ? @"Edit Alert" : @"New Alert";
    if ((self = [super initWithWindow:w]))
        {
        _doc = doc;
        _editIndex = index;
        _alert = nil;
        if (index >= 0 && index < (int)doc.resource.freeStrings.count)
            _alert = [GAlert alertFromString:doc.resource.freeStrings[index]];
        if (!_alert)
            _alert = [GAlert new];
        [self buildUI];
        [self syncFromModel];
        }
    return self;
    }

// MARK: layout

- (NSTextField*)labelAt:(NSPoint)p text:(NSString*)t
    {
    NSTextField* l = [NSTextField labelWithString:t];
    l.font = [NSFont systemFontOfSize:11];
    l.textColor = [NSColor secondaryLabelColor];
    l.frame = NSMakeRect(p.x, p.y, 120, 16);
    [self.window.contentView addSubview:l];
    return l;
    }

- (NSTextField*)fieldAt:(NSRect)f placeholder:(NSString*)ph
    {
    NSTextField* tf = [[NSTextField alloc] initWithFrame:f];
    tf.placeholderString = ph;
    tf.font = [NSFont systemFontOfSize:12];
    tf.target = self;
    tf.action = @selector(edited:);
    tf.delegate = (id)self;
    [self.window.contentView addSubview:tf];
    return tf;
    }

- (void)buildUI
    {
    NSView* c = self.window.contentView;
    CGFloat x = 20, y = 380;

    [self labelAt:NSMakePoint(x, y + 2) text:@"Icon"];
    _iconPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x + 60, y - 2, 120, 24)];
    [_iconPopup addItemsWithTitles:@[ @"None", @"Note", @"Wait", @"Stop" ]];
    _iconPopup.target = self;
    _iconPopup.action = @selector(edited:);
    [c addSubview:_iconPopup];

    y -= 36;
    [self labelAt:NSMakePoint(x, y + 2) text:@"Message"];
    for (int i = 0; i < 5; i++)
        {
        _lines[i] = [self fieldAt:NSMakeRect(x + 60, y - (i * 28), 260, 22)
                      placeholder:i == 0 ? @"first line" : @"…"];
        }

    y -= 5 * 28 + 12;
    [self labelAt:NSMakePoint(x, y + 2) text:@"Buttons"];
    for (int i = 0; i < 3; i++)
        {
        _buttons[i] = [self fieldAt:NSMakeRect(x + 60 + i * 90, y - 2, 84, 22)
                        placeholder:i == 0 ? @"OK" : @"—"];
        }

    y -= 34;
    [self labelAt:NSMakePoint(x, y + 2) text:@"Default"];
    _defaultPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x + 60, y - 2, 120, 24)];
    _defaultPopup.target = self;
    _defaultPopup.action = @selector(edited:);
    [c addSubview:_defaultPopup];

    // the literal string — this is what actually gets stored
    y -= 40;
    [self labelAt:NSMakePoint(x, y + 2) text:@"form_alert"];
    _stringField = [[NSTextField alloc] initWithFrame:NSMakeRect(x + 60, y - 2, 260, 22)];
    _stringField.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _stringField.editable = YES;
    _stringField.target = self;
    _stringField.action = @selector(stringEdited:);
    [c addSubview:_stringField];

    _warning = [NSTextField labelWithString:@""];
    _warning.font = [NSFont systemFontOfSize:11];
    _warning.textColor = [NSColor systemOrangeColor];
    _warning.frame = NSMakeRect(x, y - 30, 340, 16);
    [c addSubview:_warning];

    // preview on the right
    _preview = [[GAlertPreview alloc] initWithFrame:NSMakeRect(360, 60, 340, 340)];
    _preview.wantsLayer = YES;
    [c addSubview:_preview];

    NSButton* cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    cancel.frame = NSMakeRect(480, 16, 90, 30);
    [c addSubview:cancel];
    NSButton* ok = [NSButton buttonWithTitle:_editIndex >= 0 ? @"Save" : @"Add to Resource"
                                      target:self
                                      action:@selector(save:)];
    ok.frame = NSMakeRect(575, 16, 130, 30);
    ok.keyEquivalent = @"\r";
    [c addSubview:ok];
    }

// MARK: model <-> fields

- (void)syncFromModel
    {
    [_iconPopup selectItemAtIndex:_alert.icon];
    for (int i = 0; i < 5; i++)
        _lines[i].stringValue = (i < (int)_alert.lines.count) ? _alert.lines[i] : @"";
    for (int i = 0; i < 3; i++)
        _buttons[i].stringValue = (i < (int)_alert.buttons.count) ? _alert.buttons[i] : @"";
    [self rebuildDefaultPopup];
    _stringField.stringValue = [_alert stringValue];
    _preview.alert = _alert;
    _preview.needsDisplay = YES;
    [self checkLimits];
    }

- (void)rebuildDefaultPopup
    {
    [_defaultPopup removeAllItems];
    for (int i = 0; i < (int)_alert.buttons.count; i++)
        [_defaultPopup addItemWithTitle:_alert.buttons[i].length ? _alert.buttons[i]
                                                                 : [NSString stringWithFormat:@"Button %d", i + 1]];
    int sel = MAX(1, MIN(_alert.defaultButton, (int)_alert.buttons.count));
    if (_defaultPopup.numberOfItems)
        [_defaultPopup selectItemAtIndex:sel - 1];
    }

// Pull the fields into the model.  Trailing blank lines/buttons just drop out.
- (void)readFields
    {
    _alert.icon = (GAlertIcon)_iconPopup.indexOfSelectedItem;

    NSMutableArray* ls = [NSMutableArray array];
    for (int i = 0; i < 5; i++)
        {
        NSString* v = _lines[i].stringValue;
        if (v.length)
            [ls addObject:v];
        else if (ls.count)
            [ls addObject:@""]; // keep an interior blank line
        }
    while (ls.count && [ls.lastObject length] == 0)
        [ls removeLastObject];
    _alert.lines = ls.count ? ls : @[ @"" ];

    NSMutableArray* bs = [NSMutableArray array];
    for (int i = 0; i < 3; i++)
        {
        NSString* v = _buttons[i].stringValue;
        if (v.length)
            [bs addObject:v];
        }
    _alert.buttons = bs.count ? bs : @[ @"OK" ];

    int def = (int)_defaultPopup.indexOfSelectedItem + 1;
    _alert.defaultButton = MAX(1, MIN(def, (int)_alert.buttons.count));
    }

- (void)edited:(id)sender
    {
    [self readFields];
    [self rebuildDefaultPopup];
    _stringField.stringValue = [_alert stringValue];
    _preview.alert = _alert;
    _preview.needsDisplay = YES;
    [self checkLimits];
    }

// Typing the raw string is allowed too — it is the thing being stored, after all.
- (void)stringEdited:(id)sender
    {
    GAlert* a = [GAlert alertFromString:_stringField.stringValue];
    if (!a)
        {
        NSBeep();
        _stringField.stringValue = [_alert stringValue];
        return;
        }
    a.defaultButton = _alert.defaultButton;
    _alert = a;
    [self syncFromModel];
    }

- (void)controlTextDidChange:(NSNotification*)n
    {
    if (n.object == _stringField)
        return; // only on Enter, or it fights the caret
    [self edited:n.object];
    }

// GEM clips an alert that is too big; say so rather than letting it surprise later.
- (void)checkLimits
    {
    NSMutableArray* w = [NSMutableArray array];
    for (NSString* l in _alert.lines)
        if (l.length > 30)
            {
            [w addObject:@"a line is over 30 characters"];
            break;
            }
    for (NSString* b in _alert.buttons)
        if (b.length > 10)
            {
            [w addObject:@"a button is over 10 characters"];
            break;
            }
    if (_alert.lines.count > 5)
        [w addObject:@"more than 5 lines"];
    if (_alert.buttons.count > 3)
        [w addObject:@"more than 3 buttons"];
    for (NSString* s in _alert.lines)
        if ([s containsString:@"["] || [s containsString:@"]"] || [s containsString:@"|"])
            {
            [w addObject:@"[ ] and | cannot appear in the text"];
            break;
            }
    _warning.stringValue = w.count
                               ? [@"GEM will clip this — " stringByAppendingString:[w componentsJoinedByString:@", "]]
                               : @"";
    }

// MARK: actions

- (void)cancel:(id)sender
    {
    [self close];
    }

- (void)save:(id)sender
    {
    [self readFields];
    NSString* s = [_alert stringValue];
    Document* doc = _doc;
    int idx = _editIndex;
    [doc perform:(idx >= 0 ? @"Edit Alert" : @"Add Alert")
           block:^{
             NSMutableArray* fs = doc.resource.freeStrings;
             if (idx >= 0 && idx < (int)fs.count)
                 fs[idx] = s;
             else
                 [fs addObject:s];
           }];
    [self close];
    }

@end
