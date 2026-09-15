// GHelp.h — contextual help text for the selected object.

#import <AppKit/AppKit.h>
#import "GModel.h"

// A formatted help blurb describing the object's type and what each inspector
// option means for it (plus type-specific notes, e.g. popup wiring).
NSAttributedString* GHelpForObject(GObject* _Nullable o);
