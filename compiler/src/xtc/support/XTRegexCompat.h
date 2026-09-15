/****************************************************************************\
|* XTRegexCompat.h — one behavioural difference between Apple's Foundation and
|* GNUstep's, in the one place it bites.
|*
|* -[NSRegularExpression stringByReplacingMatchesInString:options:range:
|*  withTemplate:] returns @"" for a zero-length range on Apple, and **nil** on
|* GNUstep.
|*
|* That matters because this tree rewrites assembly line by line, and assembly
|* is full of blank lines — 215 in a 3000-line fixture. Every one of them came
|* back nil on Linux, and then either
|*
|*   [out addObject:nil]   ->  "Tried to add nil to array", or
|*   l = <nil>             ->  silently swallowed the rest of that line's work
|*
|* The first is how `-A android` failed on the CI box; the second is worse,
|* because it does not announce itself.
|*
|* Header-only and static inline ON PURPOSE: xcc, xcc-cg-* and xcc-ln-* are
|* separate binaries with separate hand-picked object lists, so a .m here would
|* mean editing five link lines to fix a three-line function.
\****************************************************************************/

#ifndef XTREGEXCOMPAT_H
#define XTREGEXCOMPAT_H

#import <Foundation/Foundation.h>

/// Replace every match of `re` in `s` with `tmpl`, portably.
/// Returns `s` unchanged when there is nothing to do — never nil for non-nil `s`.
static inline NSString* XTRegexReplace(NSRegularExpression* re,
                                       NSString* s, NSString* tmpl)
    {
    if (!re || s.length == 0)
        return s;
    NSString* r = [re stringByReplacingMatchesInString:s
                                               options:0
                                                 range:NSMakeRange(0, s.length)
                                          withTemplate:tmpl];
    return r ?: s;
    }

#endif /* XTREGEXCOMPAT_H */
