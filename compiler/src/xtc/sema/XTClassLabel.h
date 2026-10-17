/****************************************************************************\
|* XTClassLabel.h
|*
|* A vtable root label is `_cls_<Class>_<method key>`, and a class name may
|* itself hold underscores (`_HttpJob`, `My_Thing`), so the first underscore
|* is not the separator. The split is the first one at which `ok` accepts the
|* class and the key (a class that exists and has that method); with none
|* accepted, the first underscore, as before. The port's Sema.labelSplit is
|* the same rule.
\****************************************************************************/
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static inline BOOL XTSplitClassLabel(NSString* label, BOOL (^ok)(NSString* cls, NSString* key),
                                     NSString* _Nullable* _Nonnull clsOut, NSString* _Nullable* _Nonnull keyOut)
    {
    if (![label hasPrefix:@"_cls_"])
        return NO;
    NSString* tail = [label substringFromIndex:5];
    NSUInteger first = NSNotFound;
    for (NSUInteger i = 0; i < tail.length; i++)
        {
        if ([tail characterAtIndex:i] != '_')
            continue;
        if (first == NSNotFound)
            first = i;
        if (i == 0)
            continue;
        NSString* c = [tail substringToIndex:i];
        NSString* k = [tail substringFromIndex:i + 1];
        if (ok(c, k))
            {
            *clsOut = c;
            *keyOut = k;
            return YES;
            }
        }
    if (first == NSNotFound)
        return NO;
    *clsOut = [tail substringToIndex:first];
    *keyOut = [tail substringFromIndex:first + 1];
    return YES;
    }

NS_ASSUME_NONNULL_END
