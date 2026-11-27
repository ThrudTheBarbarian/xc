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
    self.blkState[@"tensorNames"] = names;
    if (names.count && self.tensorReady)
        {
        NSMutableString* src = [NSMutableString string];
        for (NSString* nm in names)
            {
            NSString* c = [XTParser tensorClassSource:nm];
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
|* The class a tensor type is: the storage, the element offset, the shapes
|* and the strides, the index operator's get and set, and the members; then
|* `<name>_make` (zero-filled, contiguous, row major). nil for a name that is not
|* a tensor class. The port writes the same text.
\****************************************************************************/
+ (nullable NSString*)tensorClassSource:(NSString*)name
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
    [s appendString:@"}\n"];
    [s appendString:mk];
    return s;
    }

@end
