// GHelp.m — see GHelp.h.

#import "GHelp.h"

@interface GHelpBuilder : NSObject
@property NSMutableAttributedString* s;
@end
@implementation GHelpBuilder
@end

static NSColor* headColor(void)
    {
    return [NSColor colorWithWhite:0.98 alpha:1];
    }
static NSColor* bodyColor(void)
    {
    return [NSColor colorWithWhite:0.78 alpha:1];
    }
static NSColor* dimColor(void)
    {
    return [NSColor colorWithWhite:0.58 alpha:1];
    }

static void H(NSMutableAttributedString* s, NSString* t)
    {
    NSDictionary* a = @{NSFontAttributeName : [NSFont boldSystemFontOfSize:12],
                        NSForegroundColorAttributeName : headColor()};
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:
                                                              [NSString stringWithFormat:@"%@\n", t]
                                                              attributes:a]];
    }
static void P(NSMutableAttributedString* s, NSString* t)
    {
    NSDictionary* a = @{NSFontAttributeName : [NSFont systemFontOfSize:11],
                        NSForegroundColorAttributeName : bodyColor()};
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:
                                                              [NSString stringWithFormat:@"%@\n", t]
                                                              attributes:a]];
    }
// a bullet "• name — desc" with the name emphasised
static void B(NSMutableAttributedString* s, NSString* name, NSString* desc)
    {
    NSFont* f = [NSFont systemFontOfSize:11];
    NSMutableAttributedString* line = [[NSMutableAttributedString alloc] init];
    [line appendAttributedString:[[NSAttributedString alloc] initWithString:@"   • "
                                                                 attributes:@{NSFontAttributeName : f, NSForegroundColorAttributeName : dimColor()}]];
    [line appendAttributedString:[[NSAttributedString alloc] initWithString:name
                                                                 attributes:@{NSFontAttributeName : [NSFont boldSystemFontOfSize:11], NSForegroundColorAttributeName : bodyColor()}]];
    [line appendAttributedString:[[NSAttributedString alloc] initWithString:
                                                                 [NSString stringWithFormat:@" — %@\n", desc]
                                                                 attributes:@{NSFontAttributeName : f, NSForegroundColorAttributeName : bodyColor()}]];
    [s appendAttributedString:line];
    }
static void GAP(NSMutableAttributedString* s)
    {
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                                                              attributes:@{NSFontAttributeName : [NSFont systemFontOfSize:4]}]];
    }

static void geometryHelp(NSMutableAttributedString* s)
    {
    B(s, @"X / Y", @"position relative to the parent object (0,0 = parent's top-left).");
    B(s, @"W / H", @"width and height in pixels.");
    }
static void commonFlags(NSMutableAttributedString* s)
    {
    B(s, @"Selectable", @"the object reacts to clicks.");
    B(s, @"Exit / Touch Exit", @"clicking it ends form_do (Touch fires on press, not release).");
    B(s, @"Disabled (state)", @"greyed and non-interactive.");
    }

NSAttributedString* GHelpForObject(GObject* o)
    {
    NSMutableAttributedString* s = [[NSMutableAttributedString alloc] init];
    if (!o)
        {
        P(s, @"Select an object on the canvas to see what it is and what each "
              "inspector field does. Drag a widget from the left palette to add one.");
        return s;
        }

    switch (o.type)
        {
    case GT_BOX:
    case GT_IBOX:
        H(s, o.type == GT_IBOX ? @"IBox — invisible container box" : @"Box — panel / group box");
        P(s, o.type == GT_IBOX
                 ? @"A box with no fill (border only, or fully invisible). Used purely to group children."
                 : @"A filled rectangle for panels or grouping. Drop other objects inside it to make them children (they then move and clip with the box).");
        GAP(s);
        H(s, @"Box options");
        geometryHelp(s);
        B(s, @"Thickness", @"outline weight; negative draws the border inside the rect.");
        B(s, @"Border colour", @"the outline pen (VDI palette index).");
        B(s, @"Fill pattern", @"0 = hollow (no fill); 1–7 = increasingly dense fill.");
        B(s, @"Inside colour", @"the fill colour when the pattern is not hollow.");
        break;

    case GT_BOXCHAR:
        H(s, @"BoxChar — box with a single character");
        geometryHelp(s);
        B(s, @"Character", @"the glyph drawn centred in the box.");
        B(s, @"Border / Fill", @"as for Box.");
        break;

    case GT_STRING:
        H(s, @"String — static text label");
        P(s, @"The simplest label: fixed, non-editable, no formatting or box.");
        B(s, @"Text", @"the characters shown.");
        geometryHelp(s);
        break;

    case GT_TITLE:
        H(s, @"Title — menu-bar title");
        P(s, @"A clickable title on a menu bar; its dropdown is the box of items beneath it. Only meaningful inside a Menu tree (see the tree picker).");
        B(s, @"Text", @"the title shown on the bar.");
        break;

    case GT_TEXT:
    case GT_FTEXT:
    case GT_BOXTEXT:
    case GT_FBOXTEXT:
    case GT_FIELD:
        {
        BOOL boxed = (o.type == GT_BOXTEXT || o.type == GT_FBOXTEXT);
        BOOL editable = (o.type == GT_FTEXT || o.type == GT_FBOXTEXT || o.type == GT_FIELD);
        H(s, [NSString stringWithFormat:@"%@ — %@%@ text (TEDINFO)",
                                        GObTypeName(o.type), editable ? @"editable" : @"static", boxed ? @", boxed" : @""]);
        P(s, editable
                 ? @"An input field. The Template is the visible skeleton; '_' marks each typeable slot."
                 : @"Formatted static text drawn from a template.");
        GAP(s);
        H(s, @"TEDINFO options");
        B(s, @"Template", @"fixed text + '_' slots, e.g. \"Name: ____________\" or \"__:__\".");
        B(s, @"Valid", @"one code per slot: 9=digit, f=filename, a=alphanumeric, A=UPPER, X=any.");
        B(s, @"Text", @"the value filling the slots (a leading '@' means the field starts empty).");
        B(s, @"Justify", editable ? @"positions the value inside its slots (the label stays put)." : @"positions the whole string within the object.");
        B(s, @"Font", @"Large (3) or Small (5) system font.");
        if (editable)
            {
            B(s, @"Editable flag", @"must be set for typing; it also gives the field its bezel.");
            B(s, @"Rounded field", @"picks the rounded vs square themed bezel (stored in the ob_type high byte).");
            }
        if (o.type == GT_TEXT || o.type == GT_FTEXT)
            P(s, @"(Text/FText have no box; BoxText/FBoxText add a border. Field is the themed input.)");
        if (o.type == GT_BOXTEXT)
            B(s, @"Group box", @"draws a labelled frame (label breaks the top border) — a container; drop objects inside it. (Rocks extension: ob_type high-byte bit 0.)");
        break;
        }

    case GT_BUTTON:
        H(s, @"Button — push button");
        B(s, @"Text", @"the button label.");
        geometryHelp(s);
        GAP(s);
        H(s, @"Flags that matter here");
        B(s, @"Selectable", @"required — an unselectable button can't be pressed.");
        B(s, @"Exit", @"clicking it ends form_do, which returns this object's index.");
        B(s, @"Default", @"also fires on Return/Enter; drawn with the blue default bezel.");
        B(s, @"Cancel (Esc)", @"Esc fires this object — the Cancel affordance (XT GEM extension).");
        B(s, @"Touch Exit", @"fires on press instead of release.");
        B(s, @"Disabled (state)", @"greyed and unclickable.");
        break;

    case GT_CHECKBOX:
        H(s, @"Checkbox — on/off toggle");
        B(s, @"Text", @"the label beside the box.");
        B(s, @"Selectable", @"required to toggle.");
        B(s, @"Selected (state)", @"THIS is the ticked/on state — the AES toggles OS_SELECTED on click.");
        B(s, @"Checked (state)", @"NOT the checkbox tick — that's for menu items (menu.tick). Leave it off here.");
        break;

    case GT_RADIO:
        H(s, @"Radio — exclusive option button");
        P(s, @"A group = all OF_RBUTTON buttons that share the SAME parent. Selecting one clears the others in that group.");
        B(s, @"Radio Btn flag", @"marks it as a radio (enables the exclusivity).");
        B(s, @"Selectable", @"required to select.");
        B(s, @"Selected (state)", @"the initially-chosen option — set it on exactly ONE button per group (not Checked).");
        GAP(s);
        H(s, @"Grouping");
        P(s, @"Grouping is by shared parent, not a special widget. Put each group inside its own Box/IBox so its radios are siblings; radios dropped loose on the dialog all share one group (children of the root).");
        break;

    case GT_POPUP:
        H(s, @"Popup — drop-down chooser");
        P(s, @"A button showing the current choice; clicking it drops a menu of options.");
        B(s, @"Text", @"the popup's initial / currently-shown value.");
        GAP(s);
        H(s, @"Wiring the menu");
        P(s, @"The choices live in a SEPARATE tree (a Box of String options — e.g. make one with New Menu and keep its dropdown).");
        B(s, @"Popup menu → tree", @"choose which tree is shown when clicked; it's saved as that tree's INDEX in the ob_type high byte.");
        P(s, @"At runtime the app opens that tree (menu_popup/objc_popup) and writes the chosen item's text back into Text.");
        break;

    case GT_ICON:
    case GT_CICON:
        H(s, o.type == GT_CICON ? @"Color Icon — RGBA (PAM) icon" : @"Icon — monochrome icon");
        P(s, o.type == GT_CICON
                 ? @"A full-colour icon stored as a P7 PAM bitmap, with a label beneath."
                 : @"A classic 1-bit ICONBLK icon (data + mask), with a label.");
        B(s, @"Label", @"text shown under the icon.");
        B(s, @"Import image…", @"loads a .pam / .png / … as the icon bitmap (colour icons store PAM).");
        B(s, @"Selected (state)", @"draws the icon highlighted.");
        break;

    case GT_IMAGE:
        H(s, @"Image — bitmap (BITBLK)");
        P(s, @"A raw bitmap image object. (Pixel editing not yet supported in the editor; imported ones are preserved.)");
        break;

    default:
        H(s, GObTypeName(o.type));
        geometryHelp(s);
        break;
        }

    // shared footer
    GAP(s);
    P(s, @"Geometry X/Y are relative to the parent. Arrow keys nudge; ⇧ + arrows nudge by the grid.");
    P(s, @"Cancel (Esc) & Moveable (root dialog) are in Flags; Mnemonic (State) sets the underlined shortcut char index.");
    return s;
    }
