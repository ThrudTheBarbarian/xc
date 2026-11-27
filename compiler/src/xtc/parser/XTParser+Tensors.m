//
//  XTParser+Tensors.m
//  xcc
//
//  Tensor types. `tensor<T, R>` is a value type: a view of an ARC-managed
//  TensorStorage (an element offset, R shapes and R strides, counted in
//  elements), with the element type T in the static type. Each (T, R) the
//  unit uses becomes a class the compiler writes, `__tensor_<T>_<R>`, held
//  by value, so copies, parameters, returns, fields and scope exits retain
//  and release the storage as for any stack instance. Its index operator
//  reads and writes elements; its methods are the members (shape, stride,
//  rank, count, isContiguous, data or, for
//  f4, bytes). Mirrored in the port's parser, text
//  for text.
//

#import "XTParser.h"
#import "XTParser+Private.h"
#import "XTLexer.h"
#import "XTToken.h"
#import "XTType.h"
#import "XTTypeTable.h"
#import "XTDiagnosticEngine.h"

@implementation XTParser (Tensors)

// The canonical element name of a tensor's element token, or nil when the
// token names no type at all.
static NSString* XTTensorElemName(XTToken* e)
    {
    if (e.isTypeKeyword)
        {
        if ([e.value isEqualToString:@"float"])
            return @"f32";
        if ([e.value isEqualToString:@"double"])
            return @"f64";
        return e.value;
        }
    if (e.type == XTTokenIdentifier)
        return e.value;
    return nil;
    }

// The size of one element in bits, or 0 for a type a tensor does not hold.
static NSUInteger XTTensorElemBits(NSString* e)
    {
    if ([e hasPrefix:@"f8$"])
        return 8;
    if ([e hasPrefix:@"f16$"])
        return 16;
    NSDictionary<NSString*, NSNumber*>* bits = @{
        @"i8" : @8, @"u8" : @8, @"bool" : @8, @"f8" : @8,
        @"i16" : @16, @"u16" : @16, @"f16" : @16, @"bf16" : @16,
        @"i32" : @32, @"u32" : @32, @"f32" : @32,
        @"i64" : @64, @"u64" : @64, @"f64" : @64,
        @"f4" : @4
    };
    return bits[e].unsignedIntegerValue;
    }

// An element type as the source writes it: a pack's canonical name
// `f8$e5m2` is `f8:pack(e5m2)`, `f8$e4m3$ieee` is `f8:pack(e4m3, ieee)`.
static NSString* XTTensorElemSource(NSString* e)
    {
    NSArray<NSString*>* parts = [e componentsSeparatedByString:@"$"];
    if (parts.count < 2)
        return e;
    if (parts.count == 2)
        return [NSString stringWithFormat:@"%@:pack(%@)", parts[0], parts[1]];
    return [NSString stringWithFormat:@"%@:pack(%@, %@)", parts[0], parts[1], parts[2]];
    }

// `tensor<T, R>` as the source writes it, from the class name.
static NSString* XTTensorSpelling(NSString* name)
    {
    NSString* body = [name substringFromIndex:9];
    NSRange us = [body rangeOfString:@"_" options:NSBackwardsSearch];
    if (us.location == NSNotFound)
        return name;
    NSString* elem = [[body substringToIndex:us.location] stringByReplacingOccurrencesOfString:@"_" withString:@"$"];
    return [NSString stringWithFormat:@"tensor<%@, %@>", XTTensorElemSource(elem), [body substringFromIndex:us.location + 1]];
    }

/****************************************************************************\
|* The views a unit takes, read from its tokens before the parse. A slice
|* `t[a..b, .., i]` is a pattern of one letter for each position: `i` an
|* index, `r` a..b, `R` a...b, `f` a.. (or a...), `t` ..b, `T` ...b and `a`
|* `..` alone; a subscript with no range is not a slice. `x.view(…)`,
|* `x.reshape(…)` and `x.broadcast(…)` give the ranks of their results, one
|* for each argument. The port reads the same.
\****************************************************************************/
static void XTTensorViewUses(NSArray<XTToken*>* t, NSMutableArray<NSString*>* patterns, NSMutableIndexSet* shapeRanks,
                             NSMutableIndexSet* bcastRanks)
    {
    NSUInteger n = t.count;
    for (NSUInteger i = 0; i < n; i++)
        {
        XTTokenType ty = t[i].type;
        if (ty == XTTokenDot && i + 2 < n && t[i + 1].type == XTTokenIdentifier && t[i + 2].type == XTTokenLParen)
            {
            NSString* m = t[i + 1].value;
            BOOL shape = [m isEqualToString:@"view"] || [m isEqualToString:@"reshape"];
            BOOL bcast = [m isEqualToString:@"broadcast"];
            if (!shape && !bcast)
                continue;
            NSInteger depth = 0;
            NSUInteger commas = 0;
            BOOL any = NO;
            for (NSUInteger j = i + 2; j < n; j++)
                {
                XTTokenType u = t[j].type;
                if (u == XTTokenLParen || u == XTTokenLBracket || u == XTTokenLBrace)
                    depth++;
                else if (u == XTTokenRParen || u == XTTokenRBracket || u == XTTokenRBrace)
                    depth--;
                if (depth == 0)
                    break;
                if (j > i + 2)
                    any = YES;
                if (depth == 1 && u == XTTokenComma)
                    commas++;
                }
            NSUInteger args = any ? commas + 1 : 0;
            if (args >= 1 && args <= 8)
                [(shape ? shapeRanks : bcastRanks) addIndex:args];
            continue;
            }
        if (ty != XTTokenLBracket)
            continue;
        NSMutableString* pat = [NSMutableString string];
        BOOL range = NO, ok = YES, dots = NO, incl = NO;
        NSUInteger before = 0, after = 0;
        NSInteger depth = 0;
        for (NSUInteger j = i + 1; j < n && ok; j++)
            {
            XTTokenType u = t[j].type;
            if (depth == 0 && (u == XTTokenComma || u == XTTokenRBracket))
                {
                if (!dots && before == 0)
                    ok = NO;
                else if (!dots)
                    [pat appendString:@"i"];
                else
                    {
                    range = YES;
                    if (before && after)
                        [pat appendString:incl ? @"R" : @"r"];
                    else if (before)
                        [pat appendString:@"f"];
                    else if (after)
                        [pat appendString:incl ? @"T" : @"t"];
                    else
                        [pat appendString:@"a"];
                    }
                dots = incl = NO;
                before = after = 0;
                if (u == XTTokenRBracket)
                    break;
                continue;
                }
            if (u == XTTokenLParen || u == XTTokenLBracket || u == XTTokenLBrace)
                depth++;
            else if (u == XTTokenRParen || u == XTTokenRBracket || u == XTTokenRBrace)
                {
                if (--depth < 0)
                    ok = NO;
                }
            else if (u == XTTokenSemicolon || u == XTTokenEOF)
                ok = NO;
            if (depth == 0 && (u == XTTokenDotDot || u == XTTokenEllipsis) && !dots)
                {
                dots = YES;
                incl = u == XTTokenEllipsis;
                continue;
                }
            if (dots)
                after++;
            else
                before++;
            }
        if (ok && range && pat.length <= 8 && ![patterns containsObject:pat])
            [patterns addObject:pat];
        }
    }

// The rank a class name ends in.
static NSUInteger XTTensorNameRank(NSString* name)
    {
    return (NSUInteger)[name substringFromIndex:name.length - 1].integerValue;
    }

// The kept dimensions of a slice pattern: its ranges.
static NSUInteger XTTensorPatternRank(NSString* p)
    {
    NSUInteger r = 0;
    for (NSUInteger k = 0; k < p.length; k++)
        if ([p characterAtIndex:k] != 'i')
            r++;
    return r;
    }

// The classes the views give: each element type's class of every rank the
// unit views, reshapes or broadcasts to, then each slice's result, until
// none is new. In order, so both compilers write the same classes.
static void XTTensorCloseNames(NSMutableArray<NSString*>* names, NSArray<NSString*>* patterns, NSIndexSet* shapeRanks,
                               NSIndexSet* bcastRanks)
    {
    NSMutableIndexSet* ranks = [shapeRanks mutableCopy];
    [ranks addIndexes:bcastRanks];
    NSMutableArray<NSString*>* prefixes = [NSMutableArray array];
    for (NSString* nm in names)
        {
        NSString* pre = [nm substringToIndex:nm.length - 1];
        if (![prefixes containsObject:pre])
            [prefixes addObject:pre];
        }
    for (NSString* pre in prefixes)
        for (NSUInteger r = 1; r <= 8; r++)
            if ([ranks containsIndex:r])
                {
                NSString* nm = [NSString stringWithFormat:@"%@%lu", pre, (unsigned long)r];
                if (![names containsObject:nm])
                    [names addObject:nm];
                }
    for (NSUInteger q = 0; q < names.count; q++)
        {
        NSString* nm = names[q];
        for (NSString* p in patterns)
            {
            NSUInteger r = XTTensorPatternRank(p);
            if (p.length != XTTensorNameRank(nm) || r == 0)
                continue;
            NSString* res = [NSString stringWithFormat:@"%@%lu", [nm substringToIndex:nm.length - 1], (unsigned long)r];
            if (![names containsObject:res])
                [names addObject:res];
            }
        }
    }

/****************************************************************************\
|* `tensor < T , R >` becomes the one identifier `__tensor_<T>_<R>` (a pack's
|* `$` written `_`), so every place that reads a type reads a class name; the
|* class is written by tensorClassSource: below. `new tensor<T, R>(d0, …)`
|* becomes `__tensor_<T>_<R>_make(d0, …)`, which gives a zero-filled,
|* contiguous tensor by value, and must have R dimensions. Runs after the
|* packs are fused, so `tensor<f8:pack(e5m2), 2>` reads its element as one
|* token. Once the driver has imported TensorStorage.xc (tensorReady), the
|* classes' tokens join the end of the unit; before that each name is a class
|* marker, so the unit still parses.
\****************************************************************************/
- (void)fuseTensorTypes
    {
    NSMutableArray<XTToken*>* t = [self.tokens mutableCopy];
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    BOOL changed = NO;
    NSUInteger n = t.count;
    for (NSUInteger i = 0; i + 2 < n; i++)
        {
        XTToken* tk = t[i];
        if (tk.type != XTTokenIdentifier || ![tk.value isEqualToString:@"tensor"] || t[i + 1].type != XTTokenLess)
            continue;
        XTToken* e = t[i + 2];
        NSString* en = XTTensorElemName(e);
        BOOL meant = (i + 3 < n && t[i + 3].type == XTTokenComma) || e.isTypeKeyword ||
                     (en && XTTensorElemBits(en) > 0);
        if (!meant)
            continue;
        if (!(i + 5 < n && t[i + 3].type == XTTokenComma && t[i + 4].type == XTTokenIntLiteral &&
              t[i + 5].type == XTTokenGreater))
            {
            [self.diagnostics emitError:@"a tensor type is written tensor<T, R>: an element type T and a rank R from 1 to 8, "
                                        @"as in tensor<f32, 2>"
                                     at:tk.location];
            continue;
            }
        NSUInteger bits = en ? XTTensorElemBits(en) : 0;
        if (bits == 0)
            {
            [self.diagnostics emitError:[NSString stringWithFormat:@"a tensor's elements are integers, bool, f64, f32, f16, bf16, "
                                                                   @"f8, f4 or a pack of these, not '%@'; hold class or "
                                                                   @"struct values in an array",
                                                                   e.value]
                                     at:e.location];
            en = @"u8";
            }
        NSString* rv = t[i + 4].value;
        BOOL digits = rv.length > 0;
        for (NSUInteger k = 0; k < rv.length; k++)
            if ([rv characterAtIndex:k] < '0' || [rv characterAtIndex:k] > '9')
                digits = NO;
        NSInteger rank = digits && rv.length < 4 ? rv.integerValue : 0;
        if (rank < 1 || rank > 8)
            {
            [self.diagnostics emitError:[NSString stringWithFormat:@"a tensor's rank is an integer from 1 to 8, not '%@'", rv]
                                     at:t[i + 4].location];
            rank = 1;
            }
        NSString* name = [NSString stringWithFormat:@"__tensor_%@_%ld",
                                                    [en stringByReplacingOccurrencesOfString:@"$" withString:@"_"], (long)rank];
        if (![names containsObject:name])
            [names addObject:name];
        XTToken* fused = [[XTToken alloc] initWithType:XTTokenIdentifier value:name location:tk.location];
        [t replaceObjectsInRange:NSMakeRange(i, 6) withObjectsFromArray:@[ fused ]];
        n = t.count;
        changed = YES;
        }
    // `new tensor<T, R>(d0, …)`: the class's _make function, with R dimensions.
    for (NSUInteger i = 0; i + 2 < n; i++)
        {
        if (t[i].type != XTTokenNew || t[i + 1].type != XTTokenIdentifier || ![t[i + 1].value hasPrefix:@"__tensor_"] ||
            t[i + 2].type != XTTokenLParen)
            continue;
        NSString* name = t[i + 1].value;
        NSInteger rank = [name substringFromIndex:name.length - 1].integerValue;
        NSInteger depth = 0;
        NSUInteger commas = 0;
        BOOL any = NO;
        for (NSUInteger j = i + 2; j < n; j++)
            {
            XTTokenType ty = t[j].type;
            if (ty == XTTokenLParen || ty == XTTokenLBracket || ty == XTTokenLBrace)
                depth++;
            else if (ty == XTTokenRParen || ty == XTTokenRBracket || ty == XTTokenRBrace)
                depth--;
            if (depth == 0)
                break;
            if (j > i + 2)
                any = YES;
            if (depth == 1 && ty == XTTokenComma)
                commas++;
            }
        NSInteger given = any ? (NSInteger)commas + 1 : 0;
        if (given != rank)
            {
            NSMutableString* dims = [NSMutableString string];
            for (NSInteger k = 0; k < rank; k++)
                [dims appendFormat:@"%@d%ld", k ? @", " : @"", (long)k];
            NSString* sp = XTTensorSpelling(name);
            [self.diagnostics emitError:[NSString stringWithFormat:@"new %@ takes %ld dimension%@, one for each index, as in "
                                                                   @"new %@(%@)",
                                                                   sp, (long)rank, rank == 1 ? @"" : @"s", sp, dims]
                                     at:t[i].location];
            }
        XTSourceLocation* loc = t[i].location;
        [t replaceObjectsInRange:NSMakeRange(i, 2)
            withObjectsFromArray:@[ [[XTToken alloc] initWithType:XTTokenIdentifier
                                                            value:[name stringByAppendingString:@"_make"]
                                                         location:loc] ]];
        n = t.count;
        changed = YES;
        }
    // A struct copies its bytes and counts no references, so it cannot hold a
    // tensor value (a pointer to one is a plain pointer).
    for (NSUInteger i = 0; i + 1 < n; i++)
        {
        if (t[i].type != XTTokenStruct)
            continue;
        NSUInteger j = i + 1;
        while (j < n && t[j].type != XTTokenLBrace && t[j].type != XTTokenSemicolon && t[j].type != XTTokenLParen &&
               t[j].type != XTTokenRBrace)
            j++;
        if (j >= n || t[j].type != XTTokenLBrace)
            continue;
        NSInteger depth = 0;
        for (; j < n; j++)
            {
            if (t[j].type == XTTokenLBrace)
                depth++;
            else if (t[j].type == XTTokenRBrace && --depth == 0)
                break;
            else if (depth == 1 && t[j].type == XTTokenIdentifier && [t[j].value hasPrefix:@"__tensor_"] &&
                     !(j + 1 < n && t[j + 1].type == XTTokenStar))
                [self.diagnostics emitError:[NSString stringWithFormat:@"a struct cannot hold a %@: a struct's copy counts no "
                                                                       @"references to the tensor's storage; hold it in a class",
                                                                       XTTensorSpelling(t[j].value)]
                                         at:t[j].location];
            }
        }
    for (NSString* nm in self.importedTensorNames ?: @[])
        if (![names containsObject:nm])
            [names addObject:nm];
    // The views the unit takes: its slice patterns, and the ranks it views,
    // reshapes and broadcasts to. Each class gets the methods for them, and
    // the classes of their results join the unit.
    NSMutableArray<NSString*>* patterns = [NSMutableArray array];
    NSMutableIndexSet* shapeRanks = [NSMutableIndexSet indexSet];
    NSMutableIndexSet* bcastRanks = [NSMutableIndexSet indexSet];
    if (names.count)
        {
        XTTensorViewUses(t, patterns, shapeRanks, bcastRanks);
        XTTensorCloseNames(names, patterns, shapeRanks, bcastRanks);
        }
    self.blkState[@"tensorNames"] = names;
    if (names.count && self.tensorReady)
        {
        NSMutableString* src = [NSMutableString string];
        for (NSString* nm in names)
            {
            NSString* c = [XTParser tensorClassSource:nm patterns:patterns shapeRanks:shapeRanks bcastRanks:bcastRanks];
            if (c)
                [src appendString:c];
            }
        XTLexer* lexer = [[XTLexer alloc] initWithSource:src filename:@"<tensor>" diagnostics:self.diagnostics];
        NSMutableArray<XTToken*>* toks = [[lexer tokenise] mutableCopy];
        if (toks.count && toks.lastObject.type == XTTokenEOF)
            [toks removeLastObject];
        NSUInteger at = (t.count && t.lastObject.type == XTTokenEOF) ? t.count - 1 : t.count;
        [t replaceObjectsInRange:NSMakeRange(at, 0) withObjectsFromArray:toks];
        self.tokens = t;
        // The classes spell their element types as the source does.
        [self fusePackSuffixes];
        return;
        }
    if (changed)
        self.tokens = t;
    for (NSString* nm in names)
        if (![self.typeTable typeForName:nm])
            [self.typeTable registerType:[[XTType alloc] initWithKind:XTTypeKindClass displayName:nm] forName:nm];
    }

/****************************************************************************\
|* A tensor class's views, each a new header over the same storage, never a
|* copy (but copy() and a reshape() the strides cannot express): a method
|* for each slice pattern of the class's rank (an index operator, so `t[a..b,
|* i]` is a call of it), transpose() for rank 2, permute(…), copy(), and
|* view(…), reshape(…) and broadcast(…) for each rank the unit asks for.
|* `elem` is the element type as an array of it is written (`f4[]` for f4);
|* `count` the product of the shapes. The port writes the same text.
\****************************************************************************/
static NSString* XTTensorViewSource(NSString* name, NSInteger rank, NSUInteger bits, NSString* elem, NSString* count,
                                    NSArray<NSString*>* patterns, NSIndexSet* shapeRanks, NSIndexSet* bcastRanks)
    {
    NSString* pre = [name substringToIndex:name.length - 1];
    BOOL f4 = [elem isEqualToString:@"f4[]"];
    NSMutableString* s = [NSMutableString string];
    for (NSString* p in patterns)
        {
        NSUInteger r = XTTensorPatternRank(p);
        if ((NSInteger)p.length != rank || r == 0)
            continue;
        NSString* res = [NSString stringWithFormat:@"%@%lu", pre, (unsigned long)r];
        NSMutableString* params = [NSMutableString string];
        NSMutableString* annot = [NSMutableString string];
        NSMutableString* off = [NSMutableString stringWithString:@"_offset"];
        NSMutableString* body = [NSMutableString string];
        NSUInteger j = 0;
        for (NSUInteger k = 0; k < p.length; k++)
            {
            unichar c = [p characterAtIndex:k];
            BOOL lo = c == 'r' || c == 'R' || c == 'f';
            BOOL hi = c == 'r' || c == 'R' || c == 't' || c == 'T';
            if (k)
                [annot appendString:@", "];
            if (c == 'i')
                {
                [params appendFormat:@"%@u64 i%lu", params.length ? @", " : @"", (unsigned long)k];
                [annot appendFormat:@"i%lu", (unsigned long)k];
                [off appendFormat:@" + i%lu * _stride[%lu]", (unsigned long)k, (unsigned long)k];
                continue;
                }
            if (lo)
                {
                [params appendFormat:@"%@u64 s%lu", params.length ? @", " : @"", (unsigned long)k];
                [off appendFormat:@" + s%lu * _stride[%lu]", (unsigned long)k, (unsigned long)k];
                }
            if (hi)
                [params appendFormat:@"%@u64 e%lu", params.length ? @", " : @"", (unsigned long)k];
            NSString* dots = (c == 'R' || c == 'T') ? @"..." : @"..";
            [annot appendFormat:@"%@%@%@", lo ? [NSString stringWithFormat:@"s%lu", (unsigned long)k] : @"", dots,
                                hi ? [NSString stringWithFormat:@"e%lu", (unsigned long)k] : @""];
            NSString* end = hi ? [NSString stringWithFormat:@"e%lu%@", (unsigned long)k, (c == 'R' || c == 'T') ? @" + 1" : @""]
                               : [NSString stringWithFormat:@"_shape[%lu]", (unsigned long)k];
            if (lo)
                [body appendFormat:@"v._shape[%lu] = %@ - s%lu;\n", (unsigned long)j, end, (unsigned long)k];
            else
                [body appendFormat:@"v._shape[%lu] = %@;\n", (unsigned long)j, end];
            [body appendFormat:@"v._stride[%lu] = _stride[%lu];\n", (unsigned long)j, (unsigned long)k];
            j++;
            }
        [s appendFormat:@"%@ __slice_%@(%@) :operator(self[%@])\n{\n%@ v;\nv._storage = _storage;\nv._offset = %@;\n%@return v;\n}\n",
                        res, p, params.length ? params : @"void", annot, res, off, body];
        }
    if (rank == 2)
        [s appendFormat:@"%@ transpose(void)\n{\n%@ v;\nv._storage = _storage;\nv._offset = _offset;\nv._shape[0] = _shape[1];\n"
                        @"v._shape[1] = _shape[0];\nv._stride[0] = _stride[1];\nv._stride[1] = _stride[0];\nreturn v;\n}\n",
                        name, name];
    NSMutableString* pp = [NSMutableString string];
    NSMutableString* pb = [NSMutableString string];
    for (NSInteger k = 0; k < rank; k++)
        {
        [pp appendFormat:@"%@u64 p%ld", k ? @", " : @"", (long)k];
        [pb appendFormat:@"v._shape[%ld] = _shape[p%ld];\nv._stride[%ld] = _stride[p%ld];\n", (long)k, (long)k, (long)k, (long)k];
        }
    [s appendFormat:@"%@ permute(%@)\n{\n%@ v;\nv._storage = _storage;\nv._offset = _offset;\n%@return v;\n}\n", name, pp, name, pb];
    // For a par block's guard (parTensorGuardFor): does the view repeat an
    // element, and has another the same layout?
    [s appendString:@"bool __repeats(void)\n{\n"];
    NSMutableString* like = [NSMutableString stringWithString:@"u._offset == _offset"];
    for (NSInteger k = 0; k < rank; k++)
        {
        [s appendFormat:@"if (_stride[%ld] == 0 && _shape[%ld] > 1)\nreturn true;\n", (long)k, (long)k];
        [like appendFormat:@" && u._stride[%ld] == _stride[%ld]", (long)k, (long)k];
        }
    [s appendFormat:@"return false;\n}\nbool __like(%@ u)\n{\nreturn %@;\n}\n", name, like];
    // copy(): a contiguous storage of its own, element by element.
    [s appendFormat:@"%@ copy(void)\n{\n%@ c;\nc._offset = 0;\n", name, name];
    for (NSInteger k = 0; k < rank; k++)
        [s appendFormat:@"c._shape[%ld] = _shape[%ld];\n", (long)k, (long)k];
    [s appendFormat:@"c._stride[%ld] = 1;\n", (long)(rank - 1)];
    for (NSInteger k = rank - 2; k >= 0; k--)
        [s appendFormat:@"c._stride[%ld] = c._stride[%ld] * _shape[%ld];\n", (long)k, (long)(k + 1), (long)(k + 1)];
    [s appendFormat:@"c._storage = TensorStorage.alloc(%@, %lu);\n", count, (unsigned long)bits];
    if (f4)
        [s appendString:@"f4[] p = (f4[])_storage.data;\nf4[] q = (f4[])c._storage.data;\n"];
    else
        [s appendFormat:@"%@* p = (%@*)_storage.data;\n%@* q = (%@*)c._storage.data;\n", elem, elem, elem, elem];
    [s appendString:@"u64 at = 0;\n"];
    NSMutableString* flat = [NSMutableString stringWithString:@"_offset"];
    for (NSInteger k = 0; k < rank; k++)
        {
        [s appendFormat:@"for (u64 i%ld = 0; i%ld < _shape[%ld]; i%ld++)\n", (long)k, (long)k, (long)k, (long)k];
        [flat appendFormat:@" + i%ld * _stride[%ld]", (long)k, (long)k];
        }
    [s appendFormat:@"{\nq[at] = p[%@];\nat++;\n}\nreturn c;\n}\n", flat];
    // broadcast(…): the shapes line up from the last; a dimension of size 1
    // and each new leading one repeat with stride 0.
    for (NSUInteger m = (NSUInteger)rank; m <= 8; m++)
        {
        if (![bcastRanks containsIndex:m])
            continue;
        NSString* res = [NSString stringWithFormat:@"%@%lu", pre, (unsigned long)m];
        NSMutableString* ps = [NSMutableString string];
        for (NSUInteger j = 0; j < m; j++)
            [ps appendFormat:@"%@u64 d%lu", j ? @", " : @"", (unsigned long)j];
        [s appendFormat:@"%@ broadcast(%@)\n{\n%@ v;\nv._storage = _storage;\nv._offset = _offset;\n", res, ps, res];
        NSUInteger lead = m - (NSUInteger)rank;
        for (NSUInteger j = 0; j < m; j++)
            [s appendFormat:@"v._shape[%lu] = d%lu;\n", (unsigned long)j, (unsigned long)j];
        for (NSUInteger j = 0; j < lead; j++)
            [s appendFormat:@"v._stride[%lu] = 0;\n", (unsigned long)j];
        for (NSInteger k = 0; k < rank; k++)
            {
            NSUInteger j = lead + (NSUInteger)k;
            [s appendFormat:@"if (_shape[%ld] == d%lu)\nv._stride[%lu] = _stride[%ld];\nelse if (_shape[%ld] == 1)\n"
                            @"v._stride[%lu] = 0;\nelse\n_xt_tensor_fail_broadcast(%ld, _shape[%ld], d%lu);\n",
                            (long)k, (unsigned long)j, (unsigned long)j, (long)k, (long)k, (unsigned long)j, (long)k, (long)k,
                            (unsigned long)j];
            }
        [s appendString:@"return v;\n}\n"];
        }
    // view(…) gives a new shape over the same elements when the strides can
    // express it (_xt_tensor_strides), and stops the program otherwise;
    // reshape(…) copies then.
    for (NSUInteger m = 1; m <= 8; m++)
        {
        if (![shapeRanks containsIndex:m])
            continue;
        NSString* res = [NSString stringWithFormat:@"%@%lu", pre, (unsigned long)m];
        NSMutableString* ps = [NSMutableString string];
        NSMutableString* args = [NSMutableString string];
        NSMutableString* prod = [NSMutableString string];
        NSMutableString* fill = [NSMutableString stringWithFormat:@"u64 ns[%lu];\nu64 nt[%lu];\n", (unsigned long)m,
                                                                  (unsigned long)m];
        for (NSUInteger j = 0; j < m; j++)
            {
            [ps appendFormat:@"%@u64 d%lu", j ? @", " : @"", (unsigned long)j];
            [args appendFormat:@"%@d%lu", j ? @", " : @"", (unsigned long)j];
            [prod appendFormat:@"%@d%lu", j ? @" * " : @"", (unsigned long)j];
            [fill appendFormat:@"ns[%lu] = d%lu;\n", (unsigned long)j, (unsigned long)j];
            }
        NSString* strides = [NSString stringWithFormat:@"_xt_tensor_strides(&_shape[0], &_stride[0], %ld, &ns[0], &nt[0], %lu)",
                                                       (long)rank, (unsigned long)m];
        [s appendFormat:@"%@ view(%@)\n{\n%@if (%@ != %@)\n_xt_tensor_fail_count(\"view\", %@, %@);\nif (!%@)\n"
                        @"_xt_tensor_fail_view();\n%@ v;\nv._storage = _storage;\nv._offset = _offset;\n",
                        res, ps, fill, prod, count, count, prod, strides, res];
        for (NSUInteger j = 0; j < m; j++)
            [s appendFormat:@"v._shape[%lu] = d%lu;\nv._stride[%lu] = nt[%lu];\n", (unsigned long)j, (unsigned long)j,
                            (unsigned long)j, (unsigned long)j];
        [s appendString:@"return v;\n}\n"];
        [s appendFormat:@"%@ reshape(%@)\n{\n%@if (%@ != %@)\n_xt_tensor_fail_count(\"reshape\", %@, %@);\nif (%@)\n"
                        @"return self.view(%@);\n%@ c = self.copy();\nreturn c.view(%@);\n}\n",
                        res, ps, fill, prod, count, count, prod, strides, args, name, args];
        }
    return s;
    }

/****************************************************************************\
|* The class a tensor type is: the storage, the element offset, the shapes
|* and the strides, the index operator's get and set, and the members; then
|* `<name>_make` (zero-filled, contiguous, row major). nil for a name that is not
|* a tensor class. The port writes the same text.
\****************************************************************************/
+ (nullable NSString*)tensorClassSource:(NSString*)name
    {
    return [self tensorClassSource:name patterns:@[] shapeRanks:[NSIndexSet indexSet] bcastRanks:[NSIndexSet indexSet]];
    }

+ (nullable NSString*)tensorClassSource:(NSString*)name
                               patterns:(NSArray<NSString*>*)patterns
                             shapeRanks:(NSIndexSet*)shapeRanks
                             bcastRanks:(NSIndexSet*)bcastRanks
    {
    if (![name hasPrefix:@"__tensor_"])
        return nil;
    NSString* body = [name substringFromIndex:9];
    NSRange us = [body rangeOfString:@"_" options:NSBackwardsSearch];
    if (us.location == NSNotFound)
        return nil;
    NSString* elem = [[body substringToIndex:us.location] stringByReplacingOccurrencesOfString:@"_" withString:@"$"];
    NSInteger rank = [body substringFromIndex:us.location + 1].integerValue;
    NSUInteger bits = XTTensorElemBits(elem);
    if (bits == 0 || rank < 1 || rank > 8)
        return nil;
    NSString* E = XTTensorElemSource(elem);
    BOOL f4 = [elem isEqualToString:@"f4"];
    NSMutableString* dims = [NSMutableString string];
    NSMutableString* idx = [NSMutableString string];
    NSMutableString* idxParams = [NSMutableString string];
    NSMutableString* flat = [NSMutableString stringWithString:@"_offset"];
    NSMutableString* count = [NSMutableString string];
    for (NSInteger k = 0; k < rank; k++)
        {
        [dims appendFormat:@"%@u64 d%ld", k ? @", " : @"", (long)k];
        [idx appendFormat:@"%@i%ld", k ? @", " : @"", (long)k];
        [idxParams appendFormat:@"%@u64 i%ld", k ? @", " : @"", (long)k];
        [flat appendFormat:@" + i%ld * _stride[%ld]", (long)k, (long)k];
        [count appendFormat:@"%@_shape[%ld]", k ? @" * " : @"", (long)k];
        }
    NSString* data = f4 ? @"f4[] p = (f4[])_storage.data;"
                        : [NSString stringWithFormat:@"%@* p = (%@*)_storage.data;", E, E];
    NSMutableString* s = [NSMutableString string];
    [s appendFormat:@"class %@\n{\nTensorStorage* _storage;\nu64 _offset;\nu64 _shape[%ld];\nu64 _stride[%ld];\n",
                    name, (long)rank, (long)rank];
    // `new tensor<T, R>(…)`: a free function beside the class, as the
    // result of a static method adopted and then returned is released one
    // time too many.
    NSMutableString* mk = [NSMutableString string];
    [mk appendFormat:@"%@ %@_make(%@)\n{\n%@ t;\n", name, name, dims, name];
    for (NSInteger k = 0; k < rank; k++)
        [mk appendFormat:@"t._shape[%ld] = d%ld;\n", (long)k, (long)k];
    [mk appendFormat:@"t._stride[%ld] = 1;\n", (long)(rank - 1)];
    for (NSInteger k = rank - 2; k >= 0; k--)
        [mk appendFormat:@"t._stride[%ld] = t._stride[%ld] * d%ld;\n", (long)k, (long)(k + 1), (long)(k + 1)];
    NSMutableString* dprod = [NSMutableString string];
    for (NSInteger k = 0; k < rank; k++)
        [dprod appendFormat:@"%@d%ld", k ? @" * " : @"", (long)k];
    [mk appendFormat:@"t._storage = TensorStorage.alloc(%@, %lu);\nreturn t;\n}\n", dprod, (unsigned long)bits];
    [s appendFormat:@"%@ _get(%@) :operator(self[%@])\n{\n%@\nreturn p[%@];\n}\n", E, idxParams, idx, data, flat];
    [s appendFormat:@"void _set(%@, %@ v) :operator(self[%@] = v)\n{\n%@\np[%@] = v;\n}\n", idxParams, E, idx, data, flat];
    [s appendString:@"u64 shape(u64 k)\n{\nreturn _shape[k];\n}\n"];
    [s appendString:@"u64 stride(u64 k)\n{\nreturn _stride[k];\n}\n"];
    [s appendString:@"u64 offset(void)\n{\nreturn _offset;\n}\n"];
    [s appendFormat:@"u64 rank(void)\n{\nreturn %ld;\n}\n", (long)rank];
    [s appendFormat:@"u64 count(void)\n{\nreturn %@;\n}\n", count];
    [s appendString:@"bool isContiguous(void)\n{\nu64 want = 1;\n"];
    for (NSInteger k = rank - 1; k >= 0; k--)
        [s appendFormat:@"if (_shape[%ld] != 1 && _stride[%ld] != want)\nreturn false;\nwant = want * _shape[%ld];\n",
                        (long)k, (long)k, (long)k];
    [s appendString:@"return true;\n}\n"];
    if (f4)
        [s appendString:@"u8* bytes(void)\n{\nreturn _storage.data + (_offset >> 1);\n}\n"];
    else
        [s appendFormat:@"%@* data(void)\n{\nreturn (%@*)_storage.data + _offset;\n}\n", E, E];
    [s appendString:XTTensorViewSource(name, rank, bits, f4 ? @"f4[]" : E, count, patterns, shapeRanks, bcastRanks)];
    [s appendString:@"}\n"];
    [s appendString:mk];
    return s;
    }

@end

@implementation XTParser (TensorViews)

// An error the tensor checks find as the unit parses: reported once the
// parse is done (tensorReportDeferred), since an error stops the parse. As
// the port.
- (void)tensorDeferError:(NSString*)msg at:(XTSourceLocation*)loc
    {
    NSMutableArray* d = self.blkState[@"tensorErrors"];
    if (!d)
        self.blkState[@"tensorErrors"] = d = [NSMutableArray array];
    [d addObject:@[ msg, loc ]];
    }

- (void)tensorReportDeferred
    {
    for (NSArray* e in self.blkState[@"tensorErrors"] ?: @[])
        [self.diagnostics emitError:e[0] at:e[1]];
    [self.blkState removeObjectForKey:@"tensorErrors"];
    }

// Does a token spell a decimal integer of at most nine digits?
static BOOL XTTensorSmallDecimal(XTToken* t)
    {
    if (t.type != XTTokenIntLiteral || t.value.length == 0 || t.value.length > 9)
        return NO;
    for (NSUInteger k = 0; k < t.value.length; k++)
        if ([t.value characterAtIndex:k] < '0' || [t.value characterAtIndex:k] > '9')
            return NO;
    return YES;
    }

/****************************************************************************\
|* How the function sets `n`: -1 when anything sets it but its declaration
|* `T n = …` (another assignment, a tuple's target, an increment, its address
|* or `.n`), else how many declarations set it (0 or 1), with the index of
|* the token after the `=` in `at`. As the port's parTensorSets.
\****************************************************************************/
- (NSInteger)parTensorSets:(NSString*)n end:(NSUInteger)end at:(NSUInteger*)at
    {
    NSArray<XTToken*>* tk = self.tokens;
    NSUInteger count = tk.count;
    NSInteger sets = 0;
    *at = NSNotFound;
    for (NSUInteger i = self.fnTok; i < end && i < count; i++)
        {
        XTToken* t = tk[i];
        if (t.type != XTTokenIdentifier || ![t.value isEqualToString:n])
            continue;
        XTTokenType before = i > 0 ? tk[i - 1].type : (XTTokenType)0;
        XTTokenType after = i + 1 < count ? tk[i + 1].type : (XTTokenType)0;
        if (before == XTTokenAmpersand || before == XTTokenPlusPlus || before == XTTokenMinusMinus || before == XTTokenDot ||
            before == XTTokenArrow)
            return -1;
        if (after == XTTokenPlusPlus || after == XTTokenMinusMinus)
            return -1;
        if (after >= XTTokenAssign && after <= XTTokenRorAssign)
            {
            // A declaration names its type first: a class (a tensor's
            // included) or a built-in type.
            BOOL typed = before == XTTokenIdentifier || (i > 0 && tk[i - 1].isTypeKeyword);
            if (after != XTTokenAssign || !typed || sets > 0)
                return -1;
            sets = 1;
            *at = i + 2;
            continue;
            }
        if (after == XTTokenComma || after == XTTokenRParen)
            {
            NSInteger depth = 0;
            for (NSUInteger j = i + 1; j < end && j < count; j++)
                {
                XTTokenType u = tk[j].type;
                if (u == XTTokenSemicolon || u == XTTokenLBrace || u == XTTokenRBrace)
                    break;
                if (u == XTTokenLParen)
                    depth++;
                else if (u == XTTokenRParen)
                    {
                    if (depth == 0)
                        {
                        if (j + 1 < count && tk[j + 1].type == XTTokenAssign)
                            return -1;
                        break;
                        }
                    depth--;
                    }
                }
            }
        }
    return sets;
    }

// `n` is set once, where the function declares it: the index of the token
// after its `=`, or NSNotFound.
- (NSUInteger)parTensorSetOnce:(NSString*)n end:(NSUInteger)end
    {
    NSUInteger at = NSNotFound;
    return [self parTensorSets:n end:end at:&at] == 1 ? at : NSNotFound;
    }

/****************************************************************************\
|* The fresh local a captured tensor's storage is: itself when it is fresh
|* (parTensorFresh), else, for a local set once from a view of another,
|* `n = x[…]`, `x.transpose()`, `x.permute(…)` or `x.view(…)`, x's; nil when
|* there is none (a broadcast, a reshape, a parameter, anything else). As the
|* port's parTensorRoot.
\****************************************************************************/
- (nullable NSString*)parTensorRoot:(NSString*)n end:(NSUInteger)end
    {
    NSArray<XTToken*>* tk = self.tokens;
    for (int depth = 0; depth < 8 && n; depth++)
        {
        if ([self parTensorFresh:n end:end])
            return n;
        NSUInteger at = [self parTensorSetOnce:n end:end];
        if (at == NSNotFound || at + 2 >= tk.count || tk[at].type != XTTokenIdentifier)
            return nil;
        BOOL view = tk[at + 1].type == XTTokenLBracket ||
                    (tk[at + 1].type == XTTokenDot && tk[at + 2].type == XTTokenIdentifier &&
                     ([tk[at + 2].value isEqualToString:@"transpose"] || [tk[at + 2].value isEqualToString:@"permute"] ||
                      [tk[at + 2].value isEqualToString:@"view"]));
        if (!view)
            return nil;
        n = tk[at].value;
        }
    return nil;
    }

// `n` keeps one value through the function: a local set once where it is
// declared, or a parameter of the function never set.
- (BOOL)parTensorUnset:(NSString*)n end:(NSUInteger)end
    {
    NSUInteger at = NSNotFound;
    NSInteger sets = [self parTensorSets:n end:end at:&at];
    if (sets == 1)
        return YES;
    if (sets != 0 || self.fnTok == 0)
        return NO;
    // A parameter: named between the parentheses before the body.
    NSArray<XTToken*>* tk = self.tokens;
    NSUInteger i = self.fnTok;
    while (i > 0 && tk[i - 1].type != XTTokenRParen)
        i--;
    NSInteger depth = 0;
    while (i > 0)
        {
        i--;
        XTTokenType u = tk[i].type;
        if (u == XTTokenRParen)
            depth++;
        else if (u == XTTokenLParen && --depth == 0)
            return NO;
        else if (u == XTTokenIdentifier && depth == 1 && [tk[i].value isEqualToString:n])
            return YES;
        else if (u == XTTokenSemicolon || u == XTTokenLBrace || u == XTTokenRBrace)
            return NO;
        }
    return NO;
    }

// The dimensions a fresh local was made with, `T n = new tensor<…>(4, 6)`,
// when each is a decimal literal; nil otherwise.
- (nullable NSArray<NSNumber*>*)tensorLiteralDims:(NSString*)n
    {
    NSUInteger end = [self parFuseFnEnd];
    NSUInteger at = [self parTensorSetOnce:n end:end];
    NSArray<XTToken*>* tk = self.tokens;
    if (at == NSNotFound || at + 1 >= tk.count || tk[at].type != XTTokenIdentifier || ![tk[at].value hasPrefix:@"__tensor_"] ||
        ![tk[at].value hasSuffix:@"_make"] || tk[at + 1].type != XTTokenLParen)
        return nil;
    NSMutableArray<NSNumber*>* dims = [NSMutableArray array];
    for (NSUInteger j = at + 2; j + 1 < tk.count; j += 2)
        {
        if (!XTTensorSmallDecimal(tk[j]))
            return nil;
        [dims addObject:@(tk[j].value.longLongValue)];
        if (tk[j + 1].type == XTTokenRParen)
            return dims;
        if (tk[j + 1].type != XTTokenComma)
            return nil;
        }
    return nil;
    }

// Do strides exist that give the shapes `ns` over a view with shapes `os`
// and strides `ot` (the element counts equal)? The test view() makes as it
// runs (_xt_tensor_strides in TensorStorage.xc). As the port.
static BOOL XTTensorStridesFit(NSArray<NSNumber*>* os, NSArray<NSNumber*>* ot, NSArray<NSNumber*>* ns)
    {
    long long n = 1;
    for (NSNumber* d in os)
        n *= d.longLongValue;
    if (n == 0)
        return YES;
    NSInteger vd = (NSInteger)ns.count - 1;
    long long base = ot.lastObject.longLongValue, tn = 1, vn = 1;
    NSInteger td = (NSInteger)os.count;
    while (td > 0)
        {
        td--;
        tn *= os[td].longLongValue;
        if (td == 0 || (os[td - 1].longLongValue != 1 && ot[td - 1].longLongValue != tn * base))
            {
            while (vd >= 0 && (vn < tn || ns[vd].longLongValue == 1))
                {
                vn *= ns[vd].longLongValue;
                vd--;
                }
            if (vn != tn)
                return NO;
            if (td > 0)
                {
                base = ot[td - 1].longLongValue;
                tn = 1;
                vn = 1;
                }
            }
        }
    return vd == -1;
    }

/****************************************************************************\
|* A view or reshape whose shapes are known as it parses: `n.view(…)` with
|* literal shapes, n a local made once with literal dimensions and never set
|* again, perhaps through transpose() and permute(…) with literals first.
|* The element counts must be equal, and view() needs strides that keep the
|* elements in place; the same tests stop the program at run time. As the
|* port's tensorCheckConstantView.
\****************************************************************************/
- (void)tensorCheckConstantView:(XTMethodCallExprNode*)call
    {
    BOOL view = [call.methodName isEqualToString:@"view"];
    if ((!view && ![call.methodName isEqualToString:@"reshape"]) || self.tensorNames.count == 0)
        return;
    NSMutableArray<NSNumber*>* want = [NSMutableArray array];
    for (XTASTNode* a in call.arguments)
        {
        if (![a isKindOfClass:[XTLiteralIntNode class]] || ((XTLiteralIntNode*)a).isNil)
            return;
        [want addObject:@(((XTLiteralIntNode*)a).intValue)];
        }
    NSMutableArray<XTMethodCallExprNode*>* chain = [NSMutableArray array];
    XTASTNode* r = call.receiver;
    while ([r isKindOfClass:[XTMethodCallExprNode class]])
        {
        XTMethodCallExprNode* m = (XTMethodCallExprNode*)r;
        BOOL ok = [m.methodName isEqualToString:@"transpose"] && m.arguments.count == 0;
        if ([m.methodName isEqualToString:@"permute"])
            {
            ok = YES;
            for (XTASTNode* a in m.arguments)
                if (![a isKindOfClass:[XTLiteralIntNode class]] || ((XTLiteralIntNode*)a).isNil)
                    ok = NO;
            }
        if (!ok)
            return;
        [chain insertObject:m atIndex:0];
        r = m.receiver;
        }
    if (![r isKindOfClass:[XTIdentifierNode class]] || want.count == 0)
        return;
    NSString* n = ((XTIdentifierNode*)r).identName;
    NSArray<NSNumber*>* dims = [self tensorLiteralDims:n];
    if (!dims)
        return;
    NSUInteger rank = dims.count;
    NSMutableArray<NSNumber*>* shape = [dims mutableCopy];
    NSMutableArray<NSNumber*>* stride = [NSMutableArray arrayWithCapacity:rank];
    long long st = 1;
    for (NSUInteger k = 0; k < rank; k++)
        [stride addObject:@0];
    for (NSInteger k = (NSInteger)rank - 1; k >= 0; k--)
        {
        stride[(NSUInteger)k] = @(st);
        st *= dims[(NSUInteger)k].longLongValue;
        }
    for (XTMethodCallExprNode* m in chain)
        {
        NSMutableArray<NSNumber*>* ps = [NSMutableArray array];
        if ([m.methodName isEqualToString:@"transpose"])
            {
            if (rank != 2)
                return;
            [ps addObjectsFromArray:@[ @1, @0 ]];
            }
        else
            {
            if (m.arguments.count != rank)
                return;
            NSMutableIndexSet* seen = [NSMutableIndexSet indexSet];
            for (XTASTNode* a in m.arguments)
                {
                int64_t v = ((XTLiteralIntNode*)a).intValue;
                if (v < 0 || v >= (int64_t)rank || [seen containsIndex:(NSUInteger)v])
                    return;
                [seen addIndex:(NSUInteger)v];
                [ps addObject:@(v)];
                }
            }
        NSArray<NSNumber*>* s0 = [shape copy];
        NSArray<NSNumber*>* t0 = [stride copy];
        for (NSUInteger k = 0; k < rank; k++)
            {
            shape[k] = s0[ps[k].unsignedIntegerValue];
            stride[k] = t0[ps[k].unsignedIntegerValue];
            }
        }
    long long have = 1, asked = 1;
    for (NSNumber* d in shape)
        have *= d.longLongValue;
    for (NSNumber* d in want)
        asked *= d.longLongValue;
    if (have != asked)
        [self tensorDeferError:[NSString stringWithFormat:@"%@() of '%@', which holds %lld element%@, as %lld: the counts must be "
                                                          @"equal",
                                                          call.methodName, n, have, have == 1 ? @"" : @"s", asked]
                            at:call.location];
    else if (view && !XTTensorStridesFit(shape, stride, want))
        [self tensorDeferError:[NSString stringWithFormat:@"view() cannot reshape this view of '%@' in place: its elements are "
                                                          @"not contiguous where the new shape merges dimensions; reshape() "
                                                          @"copies them, or copy() it first",
                                                          n]
                            at:call.location];
    }

/****************************************************************************\
|* A write through a broadcast view, where it shows as it parses: `x.broad
|* cast(…)[i, j] = v`, or through a local set once from `x.broadcast(…)` and
|* never again. A broadcast repeats elements (stride 0), so one write would
|* change every element it repeats. As the port's tensorCheckBroadcastWrite.
\****************************************************************************/
- (void)tensorCheckBroadcastWrite:(XTASTNode*)lhs at:(XTSourceLocation*)loc
    {
    if (![lhs isKindOfClass:[XTSubscriptExprNode class]] || self.tensorNames.count == 0)
        return;
    XTASTNode* b = ((XTSubscriptExprNode*)lhs).base;
    BOOL bc = [b isKindOfClass:[XTMethodCallExprNode class]] &&
              [((XTMethodCallExprNode*)b).methodName isEqualToString:@"broadcast"];
    if (!bc && [b isKindOfClass:[XTIdentifierNode class]])
        {
        NSUInteger at = [self parTensorSetOnce:((XTIdentifierNode*)b).identName end:[self parFuseFnEnd]];
        NSArray<XTToken*>* tk = self.tokens;
        bc = at != NSNotFound && at >= 2 && at + 3 < tk.count && [tk[at - 3].value hasPrefix:@"__tensor_"] &&
             tk[at].type == XTTokenIdentifier && tk[at + 1].type == XTTokenDot &&
             [tk[at + 2].value isEqualToString:@"broadcast"] && tk[at + 3].type == XTTokenLParen;
        }
    if (bc)
        [self tensorDeferError:@"a write through a broadcast view would change every element it repeats; write to the tensor "
                               @"it was taken from, or copy() it first"
                            at:loc];
    }

/****************************************************************************\
|* Two captured tensors a block may write both: slices of one tensor that
|* split its first dimension at the same place, `a = t[lo..h, …]` (or `..h`)
|* and `b = t[h.., …]` (or `h..hi`). Each of a, b and t is set once where it
|* is declared (or is a parameter never set), and h is the same tokens in
|* both, each a decimal literal, an operator or a name likewise set once (or
|* never). As the port's parTensorDisjoint.
\****************************************************************************/
- (BOOL)parTensorDisjoint:(NSString*)a with:(NSString*)b end:(NSUInteger)end
    {
    NSArray<XTToken*>* tk = self.tokens;
    NSUInteger at[2] = {[self parTensorSetOnce:a end:end], [self parTensorSetOnce:b end:end]};
    NSArray<XTToken*>* split[2] = {nil, nil};
    NSString* root = nil;
    for (int w = 0; w < 2; w++)
        {
        NSUInteger i = at[w];
        if (i == NSNotFound || i + 2 >= end || tk[i].type != XTTokenIdentifier || tk[i + 1].type != XTTokenLBracket)
            return NO;
        if (root && ![root isEqualToString:tk[i].value])
            return NO;
        root = tk[i].value;
        // The first position, up to its comma or the bracket, at depth 0.
        NSUInteger j = i + 2, dots = NSNotFound;
        NSInteger depth = 0;
        for (; j < end; j++)
            {
            XTTokenType u = tk[j].type;
            if (depth == 0 && (u == XTTokenComma || u == XTTokenRBracket))
                break;
            if (u == XTTokenLParen || u == XTTokenLBracket)
                depth++;
            else if (u == XTTokenRParen || u == XTTokenRBracket)
                depth--;
            else if (depth == 0 && u == XTTokenEllipsis)
                return NO;
            else if (depth == 0 && u == XTTokenDotDot && dots == NSNotFound)
                dots = j;
            }
        if (dots == NSNotFound || j >= end)
            return NO;
        // a ends at h, b starts at h.
        NSRange h = w == 0 ? NSMakeRange(dots + 1, j - dots - 1) : NSMakeRange(i + 2, dots - i - 2);
        if (h.length == 0)
            return NO;
        split[w] = [tk subarrayWithRange:h];
        }
    if (split[0].count != split[1].count)
        return NO;
    if (![self parTensorUnset:root end:end])
        return NO;
    for (NSUInteger k = 0; k < split[0].count; k++)
        {
        XTToken* x = split[0][k];
        XTToken* y = split[1][k];
        if (x.type != y.type || ![x.value isEqualToString:y.value])
            return NO;
        if (x.type == XTTokenIdentifier)
            {
            if (k + 1 < split[0].count && (split[0][k + 1].type == XTTokenLParen || split[0][k + 1].type == XTTokenDot ||
                                           split[0][k + 1].type == XTTokenArrow || split[0][k + 1].type == XTTokenLBracket))
                return NO;
            if (![self parTensorUnset:x.value end:end])
                return NO;
            }
        else if (!(x.type == XTTokenIntLiteral || x.type == XTTokenPlus || x.type == XTTokenMinus || x.type == XTTokenStar ||
                   x.type == XTTokenSlash || x.type == XTTokenLParen || x.type == XTTokenRParen))
            return NO;
        }
    return YES;
    }

@end
