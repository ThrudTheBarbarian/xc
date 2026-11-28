//
//  XTParser+TensorKernels.m
//  xcc
//
//  The kernels of tensor expressions. Sema reads an element-wise tensor
//  expression (`a * b + c`, `Math.sqrt(t)`, a cast, `t[.., ..] = x`, `t +=
//  u`) as one tree and writes it as a signature; the driver starts again
//  with the signatures, and the parse writes each one's kernel here, after
//  the tensor classes, in the file `<tensor>`:
//
//    new <tree>            a new tensor of the broadcast shape
//    set:<E>:<R> <tree>    written into a tensor<E, R> (a view, or the
//                          target of a compound assignment, read as `d`)
//
//  The tree is in prefix order, one token for each node:
//
//    t:<E>:<R>             an operand tensor<E, R>
//    s:<E>                 a scalar operand of type E
//    d                     the destination's own element
//    + - * / % :<E>        arithmetic in E
//    < <= > >= == != :<E>  a comparison in E, giving bool
//    neg:<E>  cast:<E>     unary minus in E, a conversion to E
//    fn:<name>:<E>         a Math function in E (pow takes two)
//
//  A kernel is a function `__tk_<hash>` and the block class `__tkc_<hash>`
//  it runs, a ParChunk as a CPU par block's is: its run() computes elements
//  [lo, hi) of the result (or rows of it), each from the operands' elements
//  at its position, once. A contiguous result whose operands are all
//  contiguous with its shape is one flat loop; any other is a loop nest over
//  base, offset and strides, a broadcast dimension having stride 0. The
//  names hash the signature (FNV-1a, 64 bits), so a kernel two modules both
//  write is the same function. Mirrored in the port's parser, text for text.
//

#import "XTParser.h"
#import "XTParser+Private.h"

@implementation XTParser (TensorKernels)

// An element type as the source writes it: `f8$e5m2` is `f8:pack(e5m2)`.
static NSString* XTKSource(NSString* e)
    {
    NSArray<NSString*>* parts = [e componentsSeparatedByString:@"$"];
    if (parts.count < 2)
        return e;
    if (parts.count == 2)
        return [NSString stringWithFormat:@"%@:pack(%@)", parts[0], parts[1]];
    return [NSString stringWithFormat:@"%@:pack(%@, %@)", parts[0], parts[1], parts[2]];
    }

// A pointer to elements of e, as a field or local is declared.
static NSString* XTKPtr(NSString* e)
    {
    return [e isEqualToString:@"f4"] ? @"f4[]" : [XTKSource(e) stringByAppendingString:@"*"];
    }

static NSString* XTKClass(NSString* e, NSInteger r)
    {
    return [NSString stringWithFormat:@"__tensor_%@_%ld", [e stringByReplacingOccurrencesOfString:@"$" withString:@"_"],
                                      (long)r];
    }

// The part of a token after its first `:`, and the part after that.
static NSString* XTKAfter(NSString* tok, NSUInteger n)
    {
    NSArray<NSString*>* parts = [tok componentsSeparatedByString:@":"];
    return n < parts.count ? parts[n] : @"";
    }

+ (NSString*)tensorKernelName:(NSString*)sig
    {
    uint64_t h = 14695981039346656037ULL;
    const char* s = sig.UTF8String;
    for (; *s; s++)
        {
        h ^= (uint8_t)*s;
        h *= 1099511628211ULL;
        }
    return [NSString stringWithFormat:@"%016llx", (unsigned long long)h];
    }

// The operands: kind ('t', 's'), element type and rank, in order.
static void XTKLeaves(NSArray<NSString*>* tk, NSMutableArray<NSString*>* kind, NSMutableArray<NSString*>* elem,
                      NSMutableArray<NSNumber*>* rank)
    {
    for (NSUInteger i = 1; i < tk.count; i++)
        {
        NSString* t = tk[i];
        if ([t hasPrefix:@"t:"])
            {
            [kind addObject:@"t"];
            [elem addObject:XTKAfter(t, 1)];
            [rank addObject:@(XTKAfter(t, 2).integerValue)];
            }
        else if ([t hasPrefix:@"s:"])
            {
            [kind addObject:@"s"];
            [elem addObject:XTKAfter(t, 1)];
            [rank addObject:@0];
            }
        }
    }

+ (NSArray<NSString*>*)tensorKernelClasses:(NSString*)sig
    {
    NSArray<NSString*>* tk = [sig componentsSeparatedByString:@" "];
    NSMutableArray<NSString*>* kind = [NSMutableArray array];
    NSMutableArray<NSString*>* elem = [NSMutableArray array];
    NSMutableArray<NSNumber*>* rank = [NSMutableArray array];
    XTKLeaves(tk, kind, elem, rank);
    NSMutableArray<NSString*>* out = [NSMutableArray array];
    NSInteger R = 0;
    for (NSNumber* r in rank)
        R = MAX(R, r.integerValue);
    NSString* er = nil;
    if ([tk[0] hasPrefix:@"set:"])
        {
        er = XTKAfter(tk[0], 1);
        R = XTKAfter(tk[0], 2).integerValue;
        }
    else
        {
        // The root's type: a comparison gives bool, any other node its own.
        NSString* root = tk.count > 1 ? tk[1] : @"";
        NSString* op = XTKAfter(root, 0);
        BOOL cmp = [@[ @"<", @"<=", @">", @">=", @"==", @"!=" ] containsObject:op];
        er = cmp ? @"bool" : [op isEqualToString:@"fn"] ? XTKAfter(root, 2) : XTKAfter(root, 1);
        }
    [out addObject:XTKClass(er, R)];
    for (NSUInteger i = 0; i < kind.count; i++)
        if ([kind[i] isEqualToString:@"t"])
            {
            NSString* c = XTKClass(elem[i], rank[i].integerValue);
            if (![out containsObject:c])
                [out addObject:c];
            }
    return out;
    }

/****************************************************************************\
|* The generator's state: the tokens, the operand count so far, R, the
|* destination's element type, and the mode: 0 the flat loop (index `i`), 1
|* the innermost level of the loop nest (indices `j<k>`).
\****************************************************************************/
typedef struct
    {
    __unsafe_unretained NSArray<NSString*>* tk;
    __unsafe_unretained NSArray<NSString*>* kind;
    __unsafe_unretained NSArray<NSString*>* elem;
    __unsafe_unretained NSArray<NSNumber*>* rank;
    NSUInteger pos;
    NSUInteger leaf;
    NSInteger R;
    __unsafe_unretained NSString* er;
    int mode;
    } XTKGen;

// `text`, of type `from`, as a value of type `to`.
static NSString* XTKAs(NSString* text, NSString* from, NSString* to)
    {
    if ([from isEqualToString:to])
        return text;
    return [NSString stringWithFormat:@"((%@)(%@))", XTKSource(to), text];
    }

static BOOL XTKWide(NSString* e)
    {
    return [e isEqualToString:@"f32"] || [e isEqualToString:@"f64"];
    }

// The index of an operand's (or the destination's) element at the innermost
// level: `base` its index at the level outside, or its offset at rank 1.
static NSString* XTKInner(NSString* outer, NSString* stride, NSInteger R)
    {
    return [NSString stringWithFormat:@"%@ + j%ld * %@", outer, (long)(R - 1), stride];
    }

static NSString* XTKExpr(XTKGen* g, NSString** type)
    {
    NSString* t = g->pos < g->tk.count ? g->tk[g->pos] : @"";
    g->pos++;
    NSInteger R = g->R;
    if ([t hasPrefix:@"t:"] || [t hasPrefix:@"s:"])
        {
        NSUInteger i = g->leaf++;
        NSString* e = g->elem[i];
        *type = e;
        if ([t hasPrefix:@"s:"])
            return [NSString stringWithFormat:@"v%lu", (unsigned long)i];
        BOOL f4 = [e isEqualToString:@"f4"];
        if (g->mode == 0)
            return f4 ? [NSString stringWithFormat:@"b%lu[o%lu + (u64)i]", (unsigned long)i, (unsigned long)i]
                      : [NSString stringWithFormat:@"q%lu[i]", (unsigned long)i];
        NSString* outer = R == 1 ? [NSString stringWithFormat:@"o%lu", (unsigned long)i]
                                 : [NSString stringWithFormat:@"a%lu_%ld", (unsigned long)i, (long)(R - 2)];
        NSString* st = [NSString stringWithFormat:@"s%lu_%ld", (unsigned long)i, (long)(R - 1)];
        return [NSString stringWithFormat:@"b%lu[%@]", (unsigned long)i, XTKInner(outer, st, R)];
        }
    if ([t isEqualToString:@"d"])
        {
        *type = g->er;
        BOOL f4 = [g->er isEqualToString:@"f4"];
        if (g->mode == 0)
            return f4 ? @"eb[eo + (u64)i]" : @"pe[i]";
        NSString* outer = R == 1 ? @"eo" : [NSString stringWithFormat:@"e%ld", (long)(R - 2)];
        return [NSString stringWithFormat:@"eb[%@]", XTKInner(outer, [NSString stringWithFormat:@"es%ld", (long)(R - 1)], R)];
        }
    NSString* op = XTKAfter(t, 0);
    if ([op isEqualToString:@"neg"])
        {
        NSString* E = XTKAfter(t, 1);
        NSString* xt = nil;
        NSString* x = XTKExpr(g, &xt);
        *type = E;
        return [NSString stringWithFormat:@"(-%@)", XTKAs(x, xt, E)];
        }
    if ([op isEqualToString:@"cast"])
        {
        NSString* E = XTKAfter(t, 1);
        NSString* xt = nil;
        NSString* x = XTKExpr(g, &xt);
        *type = E;
        return [NSString stringWithFormat:@"((%@)(%@))", XTKSource(E), x];
        }
    if ([op isEqualToString:@"fn"])
        {
        NSString* name = XTKAfter(t, 1);
        NSString* E = XTKAfter(t, 2);
        NSString* xt = nil;
        NSString* x = XTKExpr(g, &xt);
        NSString* y = nil;
        NSString* yt = nil;
        if ([name isEqualToString:@"pow"])
            y = XTKExpr(g, &yt);
        *type = E;
        BOOL direct = XTKWide(E) || [E hasPrefix:@"i"];
        NSString* via = direct ? E : @"f32";
        NSString* call = y ? [NSString stringWithFormat:@"Math.%@(%@, %@)", name, XTKAs(x, xt, via), XTKAs(y, yt, via)]
                           : [NSString stringWithFormat:@"Math.%@(%@)", name, XTKAs(x, xt, via)];
        return direct ? call : [NSString stringWithFormat:@"((%@)%@)", XTKSource(E), call];
        }
    // A binary operator: arithmetic in E, or a comparison in E giving bool.
    NSString* E = XTKAfter(t, 1);
    NSString* lt = nil;
    NSString* rt = nil;
    NSString* l = XTKExpr(g, &lt);
    NSString* r = XTKExpr(g, &rt);
    BOOL cmp = [@[ @"<", @"<=", @">", @">=", @"==", @"!=" ] containsObject:op];
    *type = cmp ? @"bool" : E;
    return [NSString stringWithFormat:@"(%@ %@ %@)", XTKAs(l, lt, E), op, XTKAs(r, rt, E)];
    }

+ (NSString*)tensorKernelSource:(NSString*)sig
    {
    NSArray<NSString*>* tk = [sig componentsSeparatedByString:@" "];
    NSMutableArray<NSString*>* kind = [NSMutableArray array];
    NSMutableArray<NSString*>* elem = [NSMutableArray array];
    NSMutableArray<NSNumber*>* rank = [NSMutableArray array];
    XTKLeaves(tk, kind, elem, rank);
    NSString* h = [self tensorKernelName:sig];
    NSString* cls = [@"__tkc_" stringByAppendingString:h];
    BOOL set = [tk[0] hasPrefix:@"set:"];
    BOOL reads = [tk containsObject:@"d"];
    NSString* dc = [self tensorKernelClasses:sig][0];
    NSInteger R = [dc substringFromIndex:dc.length - 1].integerValue;
    NSString* er = set ? XTKAfter(tk[0], 1) : nil;
    // The value's type, from a first walk of the tree.
    XTKGen g = { tk, kind, elem, rank, 1, 0, R, er ?: @"", 0 };
    NSString* vt = nil;
    (void)XTKExpr(&g, &vt);
    if (!er)
        er = vt;
    BOOL f4 = [er isEqualToString:@"f4"];
    NSUInteger n = kind.count;
    NSMutableString* s = [NSMutableString string];

    // The block: what run() reads, then run(), copyChunk() and its name.
    [s appendFormat:@"class %@ : ParChunk\n{\n", cls];
    [s appendFormat:@"%@ rb_;\nu64 ro_;\n%@ eb_;\nu64 eo_;\n%@ tb_;\n", XTKPtr(er), XTKPtr(er), XTKPtr(er)];
    for (NSInteger k = 0; k < R; k++)
        [s appendFormat:@"u64 n%ld_;\nu64 rs%ld_;\nu64 es%ld_;\n", (long)k, (long)k, (long)k];
    for (NSUInteger i = 0; i < n; i++)
        {
        if ([kind[i] isEqualToString:@"s"])
            {
            [s appendFormat:@"%@ v%lu_;\n", XTKSource(elem[i]), (unsigned long)i];
            continue;
            }
        [s appendFormat:@"%@ b%lu_;\nu64 o%lu_;\n", XTKPtr(elem[i]), (unsigned long)i, (unsigned long)i];
        for (NSInteger k = 0; k < R; k++)
            [s appendFormat:@"u64 s%lu_%ld_;\n", (unsigned long)i, (long)k];
        }
    [s appendString:@"bool flat_;\nbool copying_;\nu8 parity_;\n"];

    // run(): locals first, so the loops read no field.
    [s appendString:@"void run(void)\n{\n"];
    [s appendFormat:@"%@ rb = rb_;\nu64 ro = ro_;\n%@ eb = eb_;\nu64 eo = eo_;\n%@ tb = tb_;\n", XTKPtr(er), XTKPtr(er),
                    XTKPtr(er)];
    for (NSInteger k = 0; k < R; k++)
        [s appendFormat:@"u64 n%ld = n%ld_;\nu64 rs%ld = rs%ld_;\nu64 es%ld = es%ld_;\n", (long)k, (long)k, (long)k, (long)k,
                        (long)k, (long)k];
    for (NSUInteger i = 0; i < n; i++)
        {
        if ([kind[i] isEqualToString:@"s"])
            {
            [s appendFormat:@"%@ v%lu = v%lu_;\n", XTKSource(elem[i]), (unsigned long)i, (unsigned long)i];
            continue;
            }
        [s appendFormat:@"%@ b%lu = b%lu_;\nu64 o%lu = o%lu_;\n", XTKPtr(elem[i]), (unsigned long)i, (unsigned long)i,
                        (unsigned long)i, (unsigned long)i];
        for (NSInteger k = 0; k < R; k++)
            [s appendFormat:@"u64 s%lu_%ld = s%lu_%ld_;\n", (unsigned long)i, (long)k, (unsigned long)i, (long)k];
        }
    // The value at the flat index, and at the innermost level of the nest.
    g.pos = 1;
    g.leaf = 0;
    g.mode = 0;
    NSString* flatValue = XTKAs(XTKExpr(&g, &vt), vt, er);
    g.pos = 1;
    g.leaf = 0;
    g.mode = 1;
    NSString* nestValue = XTKAs(XTKExpr(&g, &vt), vt, er);
    NSString* rIdx = XTKInner(R == 1 ? @"ro" : [NSString stringWithFormat:@"r%ld", (long)(R - 2)],
                              [NSString stringWithFormat:@"rs%ld", (long)(R - 1)], R);
    NSString* tIdx = R == 1 ? @"j0" : [NSString stringWithFormat:@"t%ld * n%ld + j%ld", (long)(R - 2), (long)(R - 1), (long)(R - 1)];
    // The copy out of a temporary (an in-place write through one).
    [s appendString:@"if (copying_)\n{\nif (flat_)\n{\n"];
    if (f4)
        [s appendString:@"for (i64 i = lo; i < hi; i++)\nrb[ro + (u64)i] = tb[(u64)i];\nreturn;\n}\n"];
    else
        [s appendFormat:@"%@ p = rb + ro;\nfor (i64 i = lo; i < hi; i++)\np[i] = tb[i];\nreturn;\n}\n", XTKPtr(er)];
    for (NSInteger k = 0; k < R; k++)
        {
        if (k == 0)
            [s appendString:@"for (u64 j0 = (u64)lo; j0 < (u64)hi; j0++)\n{\n"];
        else
            [s appendFormat:@"for (u64 j%ld = 0; j%ld < n%ld; j%ld++)\n{\n", (long)k, (long)k, (long)k, (long)k];
        if (k < R - 1)
            {
            [s appendFormat:@"u64 r%ld = %@ + j%ld * rs%ld;\n", (long)k, k == 0 ? @"ro" : [NSString stringWithFormat:@"r%ld", (long)(k - 1)],
                            (long)k, (long)k];
            [s appendFormat:@"u64 t%ld = %@j%ld;\n", (long)k,
                            k == 0 ? @"" : [NSString stringWithFormat:@"t%ld * n%ld + ", (long)(k - 1), (long)k], (long)k];
            }
        }
    [s appendFormat:@"rb[%@] = tb[%@];\n", rIdx, tIdx];
    for (NSInteger k = 0; k < R; k++)
        [s appendString:@"}\n"];
    [s appendString:@"return;\n}\n"];
    // The flat loop.
    [s appendString:@"if (flat_)\n{\n"];
    if (!f4)
        {
        [s appendFormat:@"%@ p = rb + ro;\n", XTKPtr(er)];
        if (reads)
            [s appendFormat:@"%@ pe = eb + eo;\n", XTKPtr(er)];
        }
    for (NSUInteger i = 0; i < n; i++)
        if ([kind[i] isEqualToString:@"t"] && ![elem[i] isEqualToString:@"f4"])
            [s appendFormat:@"%@ q%lu = b%lu + o%lu;\n", XTKPtr(elem[i]), (unsigned long)i, (unsigned long)i, (unsigned long)i];
    [s appendFormat:@"for (i64 i = lo; i < hi; i++)\n%@ = %@;\nreturn;\n}\n", f4 ? @"rb[ro + (u64)i]" : @"p[i]", flatValue];
    // The nest: the outermost dimension split, each level's indices advanced.
    for (NSInteger k = 0; k < R; k++)
        {
        if (k == 0)
            [s appendString:@"for (u64 j0 = (u64)lo; j0 < (u64)hi; j0++)\n{\n"];
        else
            [s appendFormat:@"for (u64 j%ld = 0; j%ld < n%ld; j%ld++)\n{\n", (long)k, (long)k, (long)k, (long)k];
        if (k == R - 1)
            continue;
        NSString* (^outer)(NSString*, NSString*) = ^NSString*(NSString* p, NSString* base) {
          return k == 0 ? base : [NSString stringWithFormat:@"%@%ld", p, (long)(k - 1)];
        };
        [s appendFormat:@"u64 r%ld = %@ + j%ld * rs%ld;\n", (long)k, outer(@"r", @"ro"), (long)k, (long)k];
        if (reads)
            [s appendFormat:@"u64 e%ld = %@ + j%ld * es%ld;\n", (long)k, outer(@"e", @"eo"), (long)k, (long)k];
        for (NSUInteger i = 0; i < n; i++)
            if ([kind[i] isEqualToString:@"t"])
                [s appendFormat:@"u64 a%lu_%ld = %@ + j%ld * s%lu_%ld;\n", (unsigned long)i, (long)k,
                                k == 0 ? [NSString stringWithFormat:@"o%lu", (unsigned long)i]
                                       : [NSString stringWithFormat:@"a%lu_%ld", (unsigned long)i, (long)(k - 1)],
                                (long)k, (unsigned long)i, (long)k];
        }
    [s appendFormat:@"rb[%@] = %@;\n", rIdx, nestValue];
    for (NSInteger k = 0; k < R; k++)
        [s appendString:@"}\n"];
    [s appendString:@"}\n"];
    // copyChunk(): every field, for the other threads' pieces.
    [s appendFormat:@"ParChunk* copyChunk(void)\n{\n%@* c = new %@();\n", cls, cls];
    [s appendString:@"c.rb_ = rb_;\nc.ro_ = ro_;\nc.eb_ = eb_;\nc.eo_ = eo_;\nc.tb_ = tb_;\n"];
    for (NSInteger k = 0; k < R; k++)
        [s appendFormat:@"c.n%ld_ = n%ld_;\nc.rs%ld_ = rs%ld_;\nc.es%ld_ = es%ld_;\n", (long)k, (long)k, (long)k, (long)k, (long)k,
                        (long)k];
    for (NSUInteger i = 0; i < n; i++)
        {
        if ([kind[i] isEqualToString:@"s"])
            {
            [s appendFormat:@"c.v%lu_ = v%lu_;\n", (unsigned long)i, (unsigned long)i];
            continue;
            }
        [s appendFormat:@"c.b%lu_ = b%lu_;\nc.o%lu_ = o%lu_;\n", (unsigned long)i, (unsigned long)i, (unsigned long)i,
                        (unsigned long)i];
        for (NSInteger k = 0; k < R; k++)
            [s appendFormat:@"c.s%lu_%ld_ = s%lu_%ld_;\n", (unsigned long)i, (long)k, (unsigned long)i, (long)k];
        }
    [s appendString:@"c.flat_ = flat_;\nc.copying_ = copying_;\nc.parity_ = parity_;\nreturn (ParChunk*)c;\n}\n"];
    [s appendString:@"u8* parName(void)\n{\nreturn \"tensor\";\n}\n"];
    // f4 elements, two to a byte: each thread's piece starts on a byte.
    if (f4)
        [s appendString:@"u8* gpuSource(void)\n{\nreturn parity_ == 0 ? \"// xcpar cpu pairs=0\" : \"// xcpar cpu pairs=1\";\n}\n"];
    [s appendString:@"}\n"];

    // The function: the shape, the destination, the block's fields, the run.
    NSMutableString* params = [NSMutableString string];
    if (set)
        [params appendFormat:@"%@ d", dc];
    for (NSUInteger i = 0; i < n; i++)
        {
        if (params.length)
            [params appendString:@", "];
        if ([kind[i] isEqualToString:@"s"])
            [params appendFormat:@"%@ x%lu", XTKSource(elem[i]), (unsigned long)i];
        else
            [params appendFormat:@"%@ x%lu", XTKClass(elem[i], rank[i].integerValue), (unsigned long)i];
        }
    [s appendFormat:@"%@ __tk_%@(%@)\n{\n", set ? @"void" : dc, h, params];
    for (NSInteger k = 0; k < R; k++)
        [s appendFormat:@"u64 n%ld = %@;\n", (long)k, set ? [NSString stringWithFormat:@"d._shape[%ld]", (long)k] : @"1"];
    for (NSUInteger i = 0; i < n; i++)
        {
        if (![kind[i] isEqualToString:@"t"])
            continue;
        NSInteger r = rank[i].integerValue;
        for (NSInteger j = 0; j < r; j++)
            {
            NSInteger k = R - r + j;
            if (set)
                [s appendFormat:@"_xt_tensor_bset(n%ld, x%lu._shape[%ld], %ld);\n", (long)k, (unsigned long)i, (long)j, (long)k];
            else
                [s appendFormat:@"n%ld = _xt_tensor_bdim(n%ld, x%lu._shape[%ld], %ld);\n", (long)k, (long)k, (unsigned long)i,
                                (long)j, (long)k];
            }
        }
    NSMutableString* dims = [NSMutableString string];
    NSMutableString* total = [NSMutableString string];
    for (NSInteger k = 0; k < R; k++)
        {
        [dims appendFormat:@"%@n%ld", k ? @", " : @"", (long)k];
        [total appendFormat:@"%@n%ld", k ? @" * " : @"", (long)k];
        }
    if (!set)
        [s appendFormat:@"%@ d = %@_make(%@);\n", dc, dc, dims];
    NSString* cast = f4 ? @"(f4[])" : [NSString stringWithFormat:@"(%@)", XTKPtr(er)];
    [s appendFormat:@"%@* c = new %@();\n", cls, cls];
    [s appendFormat:@"c.rb_ = %@d._storage.data;\nc.ro_ = d._offset;\nc.eb_ = c.rb_;\nc.eo_ = d._offset;\n", cast];
    for (NSInteger k = 0; k < R; k++)
        [s appendFormat:@"c.n%ld_ = n%ld;\nc.rs%ld_ = d._stride[%ld];\nc.es%ld_ = d._stride[%ld];\n", (long)k, (long)k, (long)k,
                        (long)k, (long)k, (long)k];
    // Each operand's base, offset and strides against the result's
    // dimensions: a dimension it lacks, or one of size 1, repeats (stride 0).
    // The flat loop needs every operand contiguous, with the result's shape.
    NSMutableString* flat = [NSMutableString stringWithString:set || reads ? @"d.isContiguous()" : @"true"];
    for (NSUInteger i = 0; i < n; i++)
        {
        if ([kind[i] isEqualToString:@"s"])
            {
            [s appendFormat:@"c.v%lu_ = x%lu;\n", (unsigned long)i, (unsigned long)i];
            continue;
            }
        NSInteger r = rank[i].integerValue;
        NSString* ic = [elem[i] isEqualToString:@"f4"] ? @"(f4[])" : [NSString stringWithFormat:@"(%@)", XTKPtr(elem[i])];
        [s appendFormat:@"c.b%lu_ = %@x%lu._storage.data;\nc.o%lu_ = x%lu._offset;\n", (unsigned long)i, ic, (unsigned long)i,
                        (unsigned long)i, (unsigned long)i];
        for (NSInteger k = 0; k < R; k++)
            {
            NSInteger j = k - (R - r);
            if (j < 0)
                [s appendFormat:@"c.s%lu_%ld_ = 0;\n", (unsigned long)i, (long)k];
            else
                [s appendFormat:@"c.s%lu_%ld_ = x%lu._shape[%ld] == 1 ? 0 : x%lu._stride[%ld];\n", (unsigned long)i, (long)k,
                                (unsigned long)i, (long)j, (unsigned long)i, (long)j];
            }
        if (r < R)
            [flat setString:@"false"];
        else if (![flat isEqualToString:@"false"])
            {
            [flat appendFormat:@" && x%lu.isContiguous()", (unsigned long)i];
            for (NSInteger k = 0; k < R; k++)
                [flat appendFormat:@" && x%lu._shape[%ld] == n%ld", (unsigned long)i, (long)k, (long)k];
            }
        }
    [s appendFormat:@"bool flat = %@;\nu64 total = %@;\n", flat, total];
    [s appendFormat:@"if (total == 0)\nreturn%@;\n", set ? @"" : @" d"];
    // A destination that repeats an element (a broadcast view) is written in
    // order. An f4 destination is cut on bytes: its elements must lie in
    // rows that start on a byte, or it is written in order.
    [s appendFormat:@"bool serial = %@;\n", set ? @"d.__repeats()" : @"false"];
    if (f4)
        {
        if (set)
            [s appendString:@"if (!d.isContiguous() || (!flat && (d._offset & 1) == 1 && (n0 == 1 || (d._stride[0] & 1) == 0)))\n"
                            @"serial = true;\n"];
        [s appendString:@"c.parity_ = (u8)(d._offset & 1);\n"];
        }
    if (set)
        {
        // An operand over the destination's storage at another offset or
        // with other strides would read elements this write has changed:
        // the value goes through a temporary, then into the destination.
        BOOL any = NO;
        for (NSUInteger i = 0; i < n; i++)
            if ([kind[i] isEqualToString:@"t"] && [elem[i] isEqualToString:er])
                {
                if (!any)
                    [s appendString:@"bool alias = false;\n"];
                any = YES;
                [s appendFormat:@"if (x%lu._storage == d._storage && !(c.o%lu_ == d._offset", (unsigned long)i, (unsigned long)i];
                for (NSInteger k = 0; k < R; k++)
                    [s appendFormat:@" && (n%ld == 1 || c.s%lu_%ld_ == d._stride[%ld])", (long)k, (unsigned long)i, (long)k, (long)k];
                [s appendString:@"))\nalias = true;\n"];
                }
        if (any)
            {
            [s appendFormat:@"if (alias)\n{\n%@ t = %@_make(%@);\n", dc, dc, dims];
            [s appendFormat:@"c.rb_ = %@t._storage.data;\nc.ro_ = 0;\n", cast];
            for (NSInteger k = 0; k < R; k++)
                [s appendFormat:@"c.rs%ld_ = t._stride[%ld];\n", (long)k, (long)k];
            [s appendFormat:@"c.flat_ = flat;\nc.parity_ = 0;\n_xt_tensor_run((ParChunk*)c, flat ? (i64)total : (i64)n0, total, false);\n"];
            [s appendFormat:@"c.tb_ = c.rb_;\nc.copying_ = true;\nc.rb_ = %@d._storage.data;\nc.ro_ = d._offset;\n", cast];
            for (NSInteger k = 0; k < R; k++)
                [s appendFormat:@"c.rs%ld_ = d._stride[%ld];\n", (long)k, (long)k];
            [s appendString:@"c.flat_ = d.isContiguous();\n"];
            if (f4)
                [s appendString:@"c.parity_ = (u8)(d._offset & 1);\n"];
            [s appendString:@"_xt_tensor_run((ParChunk*)c, c.flat_ ? (i64)total : (i64)n0, total, serial);\nreturn;\n}\n"];
            }
        }
    [s appendFormat:@"c.flat_ = flat;\n_xt_tensor_run((ParChunk*)c, flat ? (i64)total : (i64)n0, total, serial);\nreturn%@;\n}\n",
                    set ? @"" : @" d"];
    return s;
    }

@end
