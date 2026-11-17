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

/// `.L<rest>` becomes `.L<index>Z<rest>` in one input of a multi-file link, so
/// two files cannot collide on `.L0`. Only a LABEL is renamed (#290): a `.L`
/// inside a quoted string is left alone, and so is one that does not start a
/// token (the byte before it continues a name or a path: a letter, digit,
/// `_ $ . /`). It was a regex over every `.L`, which rewrote `dir.Logs` in a
/// -g build's file name. As the port's AsmText.namespaceLocals.
static inline BOOL XTAsmNameByte(unichar c)
    {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
        || c == '_' || c == '$' || c == '.' || c == '/';
    }
static inline NSString* XTNamespaceLocals(NSString* s, NSUInteger idx)
    {
    NSMutableString* out = [NSMutableString stringWithCapacity:s.length + 64];
    NSString* tag = [NSString stringWithFormat:@".L%luZ", (unsigned long)idx];
    NSUInteger n = s.length, i = 0;
    BOOL inStr = NO;
    while (i < n)
        {
        unichar c = [s characterAtIndex:i];
        if (inStr)
            {
            [out appendFormat:@"%C", c];
            if (c == '\\' && i + 1 < n)
                {
                [out appendFormat:@"%C", [s characterAtIndex:i + 1]];
                i += 2;
                continue;
                }
            if (c == '"' || c == '\n')
                inStr = NO;
            i++;
            continue;
            }
        if (c == '"')
            {
            inStr = YES;
            [out appendString:@"\""];
            i++;
            continue;
            }
        if (c == '.' && i + 1 < n && [s characterAtIndex:i + 1] == 'L'
            && (i == 0 || !XTAsmNameByte([s characterAtIndex:i - 1])))
            {
            [out appendString:tag];
            i += 2;
            continue;
            }
        [out appendFormat:@"%C", c];
        i++;
        }
    return out;
    }

#endif /* XTREGEXCOMPAT_H */
