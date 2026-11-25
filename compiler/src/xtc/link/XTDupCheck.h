// XTDupCheck.h — two objects defining one name from different sources (#663).
//
// Every in-house linker keeps the FIRST definition of a name two inputs
// define: right for the copies every -c object and split build carries (the
// standard library compiled into each module, all from one source), wrong
// when two modules each wrote a definition of their own. The bytes cannot
// tell the two apart, so each -c object records where its definitions came
// from (`<object>.xtc.origins`: `<symbol>\t<file basename>:<line>`), and a
// link refuses a name two named objects define from different origins. An
// object without the table and an archive member keep first-wins. The port's
// DupCheck.xc.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The origins table beside an object, or nil when it has none.
NSDictionary<NSString*, NSString*>* _Nullable XTDupOrigins(NSString* objPath);

// A symbol's origin; Mach-O names carry one leading underscore the table
// does not.
NSString* _Nullable XTDupOriginOf(NSDictionary<NSString*, NSString*>* _Nullable origins,
                                  NSString* sym, BOOL machO);

// The refusal, worded the same by every linker (each adds its own prefix).
NSString* XTDupMessage(NSString* name, NSString* first, NSString* firstOrigin,
                       NSString* second, NSString* secondOrigin);

NS_ASSUME_NONNULL_END
