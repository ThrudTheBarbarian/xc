// UXGem.xc — GEM's constants.
//
// These SHOULD come from #import <GEM> along with the structs and functions, but
// aes.h declares them all in ANONYMOUS enums:
//
//     enum { G_BOX=20, G_TEXT=21, ..., G_USERDEF=24, ... };
//     enum { OF_NONE=0x00, OF_SELECTABLE=0x01, ... };
//
// and xtc's DWARF importer does not surface the enumerators of an unnamed enum.
// So every G_*, OF_*, OS_* and W_* constant is invisible to xtc, and we mirror
// them here.  This is duplication that can drift — the real fixes are either
//   (a) xtc imports anonymous enum constants, or
//   (b) GEM names its enums (enum ObType { ... }).
// (a) is better: it costs GEM nothing and helps every future binding.

// object types
#define G_BOX 20
#define G_TEXT 21
#define G_BOXTEXT 22
#define G_IMAGE 23
#define G_USERDEF 24
#define G_IBOX 25
#define G_BUTTON 26
#define G_BOXCHAR 27
#define G_STRING 28
#define G_FTEXT 29
#define G_FBOXTEXT 30
#define G_ICON 31
#define G_TITLE 32
#define G_CICON 33
// XT GEM themed extensions
#define G_CHECKBOX 40
#define G_RADIO 41
#define G_POPUP 42
#define G_FIELD 43

// ob_flags
#define OF_NONE $0000
#define OF_SELECTABLE $0001
#define OF_DEFAULT $0002
#define OF_EXIT $0004
#define OF_EDITABLE $0008
#define OF_RBUTTON $0010
#define OF_LASTOB $0020
#define OF_TOUCHEXIT $0040
#define OF_HIDETREE $0080
#define OF_CLIPCHILDREN $1000 // a child is cut at its parent's edge (what makes a table scroll)

// TEDINFO te_just — text justification.
#define TE_LEFT 0
#define TE_RIGHT 1
#define TE_CNTR 2

// ob_state
#define OS_NORMAL $0000
#define OS_SELECTED $0001
#define OS_CROSSED $0002
#define OS_CHECKED $0004
#define OS_DISABLED $0008
#define OS_OUTLINED $0010
#define OS_SHADOWED $0020

// How deep objc_draw / objc_find will descend.
//
// Classic GEM used 8, because a GEM dialog is a box with widgets in it.  A VIEW
// HIERARCHY IS NOT: window -> content -> scroll -> clip -> table -> row -> cell ->
// field is ALREADY eight, and AppKit-shaped trees routinely go deeper.  At depth 8 the
// AES silently stops descending — those views are never drawn and never hit-tested,
// with no error and no clue.  Measured: test_scale.xc saw exactly 8 of 16 levels draw.
//
// It is only a recursion bound in draw_rec / find_rec, so raising it costs nothing but
// stack, and 64 frames of a handful of words is noise.
#define UX_DEPTH 64

// The selected-row background.  Pen 8 is light grey, so a cell's black text stays
// readable on it.  A themed "list.row.selected" slice would be better and would move
// this out of Xtg entirely — there is not one yet.
#define UX_PEN_SELECT 250 // PEN_SEL: the theme's selection/accent colour (aes.h), so a selected
                          // table row reads clearly instead of the near-invisible pen-8 grey
