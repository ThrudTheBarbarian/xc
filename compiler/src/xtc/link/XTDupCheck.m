// XTDupCheck.m — see the header.

#import "XTDupCheck.h"

NSDictionary<NSString*, NSString*>* XTDupOrigins(NSString* objPath)
    {
    NSString* p = [[objPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"xtc.origins"];
    NSString* t = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL];
    if (!t)
        return nil;
    NSMutableDictionary<NSString*, NSString*>* m = [NSMutableDictionary dictionary];
    for (NSString* l in [t componentsSeparatedByString:@"\n"])
        {
        NSRange tab = [l rangeOfString:@"\t"];
        if (tab.location == NSNotFound)
            continue;
        m[[l substringToIndex:tab.location]] = [l substringFromIndex:tab.location + 1];
        }
    return m;
    }

NSString* XTDupOriginOf(NSDictionary<NSString*, NSString*>* origins, NSString* sym, BOOL machO)
    {
    if (!origins)
        return nil;
    NSString* k = (machO && [sym hasPrefix:@"_"]) ? [sym substringFromIndex:1] : sym;
    return origins[k];
    }

NSString* XTDupMessage(NSString* name, NSString* first, NSString* firstOrigin,
                       NSString* second, NSString* secondOrigin)
    {
    return [NSString stringWithFormat:@"'%@' is defined in both '%@' (%@) and '%@' (%@), from "
                                      @"different sources. A name may be defined in several objects "
                                      @"only when every copy comes from the same source; rename one, "
                                      @"or keep one definition and declare it in the other module",
                                      name, first, firstOrigin, second, secondOrigin];
    }
