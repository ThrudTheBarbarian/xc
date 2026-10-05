#import "XTIRParMSL.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRLayout.h"
#import "XTIRSymbol.h"
#import "XTIRSupport.h"

#import "XTIRParMSL_Private.h"


static NSString* scalarName(XTIRType* t)
    {
    switch (t.kind)
        {
        case XTIRTypeKindI8: return @"char";
        case XTIRTypeKindU8: return @"uchar";
        case XTIRTypeKindI16: return @"short";
        case XTIRTypeKindU16: return @"ushort";
        case XTIRTypeKindI32: return @"int";
        case XTIRTypeKindU32: return @"uint";
        case XTIRTypeKindI64: return @"long";
        case XTIRTypeKindU64: return @"ulong";
        case XTIRTypeKindF32: return @"float";
        case XTIRTypeKindBool: return @"bool";
        default: return nil; // f64 (refused on Metal, §7), aggregates, vectors
        }
    }

static NSString* signedName(XTIRType* t)
    {
    switch (t.kind)
        {
        case XTIRTypeKindI8: case XTIRTypeKindU8: return @"char";
        case XTIRTypeKindI16: case XTIRTypeKindU16: return @"short";
        case XTIRTypeKindI32: case XTIRTypeKindU32: return @"int";
        case XTIRTypeKindI64: case XTIRTypeKindU64: return @"long";
        default: return scalarName(t);
        }
    }

static NSString* unsignedName(XTIRType* t)
    {
    switch (t.kind)
        {
        case XTIRTypeKindI8: case XTIRTypeKindU8: return @"uchar";
        case XTIRTypeKindI16: case XTIRTypeKindU16: return @"ushort";
        case XTIRTypeKindI32: case XTIRTypeKindU32: return @"uint";
        case XTIRTypeKindI64: case XTIRTypeKindU64: return @"ulong";
        default: return scalarName(t);
        }
    }

@implementation XTIRParMSL

+ (nullable NSString*)sourceForKernel:(XTIRFunction*)run module:(XTIRModule*)module fast:(BOOL)fast
                                   why:(NSString* _Nullable* _Nullable)why
    {
    XTIRParMSL* p = [XTIRParMSL new];
    p.module = module;
    p.fn = run;
    p.fast = fast;
    NSString* out = [p print];
    if (!out && why)
        *why = p.why;
    return out;
    }

// `Stdio$printf` reads as `Stdio.printf`, and an overload's `__double` tail goes.
static NSString* shownName(NSString* irName)
    {
    NSRange r = [irName rangeOfString:@"__"];
    NSString* s = (r.location != NSNotFound && r.location > 0) ? [irName substringToIndex:r.location] : irName;
    return [s stringByReplacingOccurrencesOfString:@"$" withString:@"."];
    }

// The maths a GPU has only approximately (NVIDIA), by its bare name.
static BOOL isTranscendental(NSString* callee)
    {
    NSString* m = callee;
    if ([m hasPrefix:@"Math$"])
        m = [m substringFromIndex:5];
    NSRange r = [m rangeOfString:@"__"];
    if (r.location != NSNotFound)
        m = [m substringToIndex:r.location];
    if ([m hasPrefix:@"_xm_"])
        m = [m substringFromIndex:4];
    if ([m hasSuffix:@"f"] && m.length > 3)
        m = [m substringToIndex:m.length - 1];
    return [@[ @"sin", @"cos", @"exp", @"ln", @"log", @"pow" ] containsObject:m];
    }

- (void)because:(NSString*)why
    {
    if (!self.why)
        self.why = why;
    }

// The reason an instruction could not be printed.
- (NSString*)whyFor:(XTIRInsn*)i ptx:(BOOL)ptx
    {
    if (i.opcode == XTIROpCall && i.operands.count && i.operands[0].kind == XTIROperandKindSym)
        {
        NSString* callee = [self.module symbolForId:i.operands[0].symbolId].name;
        if (ptx && isTranscendental(callee))
            return self.fast
                ? [NSString stringWithFormat:@"it calls %@ on a double, which this GPU has in a fast form only for float",
                                             shownName(callee)]
                : [NSString stringWithFormat:@"it calls %@, which this GPU has only in an approximate form, and the "
                                             @"block's goal is accuracy",
                                             shownName(callee)];
        return [self callFailed:callee helper:nil];
        }
    if (!ptx && i.result.type.kind == XTIRTypeKindF64)
        return @"it uses double, which Apple GPUs do not have";
    return @"it uses an operation its GPU version cannot express yet";
    }

// A call that could not be printed: the helper's own reason, when there is one.
- (NSString*)callFailed:(NSString*)callee helper:(nullable XTIRParMSL*)h
    {
    if (h.why)
        return [NSString stringWithFormat:@"it calls %@, which cannot run on the GPU (%@)", shownName(callee), h.why];
    return [NSString stringWithFormat:@"it calls %@, which cannot run on the GPU", shownName(callee)];
    }

@synthesize sinitOf = _sinitOf;

- (NSMutableDictionary<NSNumber*, NSNumber*>*)sinitOf
    {
    if (!_sinitOf)
        _sinitOf = [NSMutableDictionary dictionary];
    return _sinitOf;
    }

- (nullable XTIRType*)typeOf:(XTIRValueId)v
    {
    return [self.fn valueForId:v].type;
    }

// Values are named by their order in the walk (each block's phis, then its
// instructions), not by id: the port numbers its values differently, and both
// compilers must print the same kernel.
- (NSString*)name:(XTIRValueId)v
    {
    // A helper's parameters: parameter n is value n (the memory token last).
    if (self.helperMode && v + 1 < self.fn.paramTypes.count)
        return [NSString stringWithFormat:@"p%llu", (unsigned long long)v];
    return [NSString stringWithFormat:@"v%lu", (unsigned long)[self.ordinal[@(v)] unsignedIntegerValue]];
    }

// An operand as an MSL expression.
- (nullable NSString*)expr:(XTIROperand*)op type:(nullable XTIRType*)want
    {
    switch (op.kind)
        {
        case XTIROperandKindUse:
            return [self name:op.valueId];
        case XTIROperandKindImmI:
            {
            NSString* t = want ? scalarName(want) : @"long";
            if (!t)
                return nil;
            if (want.kind == XTIRTypeKindBool)
                return op.intValue ? @"true" : @"false";
            return [NSString stringWithFormat:@"%@(%lldL)", t, (long long)op.intValue];
            }
        case XTIROperandKindImmF:
            {
            if (want.kind != XTIRTypeKindF32)
                return nil;
            uint64_t raw = op.floatRawBytes;
            double d;
            memcpy(&d, &raw, sizeof d);
            float f = (float)d;
            uint32_t bits;
            memcpy(&bits, &f, sizeof bits);
            return [NSString stringWithFormat:@"as_type<float>(0x%08xu)", bits];
            }
        default:
            return nil;
        }
    }

- (nullable NSString*)pointerType:(XTIRType*)t space:(XTParSpace)s
    {
    if (t.kind != XTIRTypeKindPtr)
        return nil;
    NSString* inner = scalarName(t.pointeeType);
    if (!inner)
        return nil;
    return [NSString stringWithFormat:@"%@ %@*", s == XTParSpaceDevice ? @"device" : @"thread", inner];
    }

// The field of the block object an address names, when it is `FieldAddr self, #k`.
- (NSInteger)selfFieldOf:(XTIROperand*)op
    {
    if (self.helperMode || op.kind != XTIROperandKindUse)
        return -1;
    XTIRInsn* d = self.def[@(op.valueId)];
    if (d.opcode != XTIROpFieldAddr || d.operands.count < 2 || d.operands[0].kind != XTIROperandKindUse ||
        d.operands[0].valueId != 0 || d.operands[1].kind != XTIROperandKindImmI)
        return -1;
    return (NSInteger)d.operands[1].intValue;
    }

// Classify every pointer value, and find the buffers and the reductions.
- (BOOL)analyse
    {
    for (XTIRBlock* b in self.fn.blocks)
        {
        for (XTIRInsn* i in b.phiNodes)
            if (i.result)
                self.def[@(i.result.valueId)] = i;
        for (XTIRInsn* i in b.instructions)
            if (i.result)
                self.def[@(i.result.valueId)] = i;
        }
    NSArray<XTIRLayoutField*>* fields = self.objLayout.fields;
    for (XTIRBlock* b in self.fn.blocks)
        {
        for (XTIRInsn* i in b.instructions)
            {
            XTIRValueId r = i.result ? i.result.valueId : 0;
            switch (i.opcode)
                {
                case XTIROpFieldAddr:
                    {
                    NSInteger k = [self selfFieldOf:[XTIROperand useWithValueId:r]];
                    if (k >= 0)
                        {
                        if ((NSUInteger)k >= fields.count)
                            {
                            [self because:@"it uses an operation its GPU version cannot express yet"];
                            return NO;
                            }
                        self.space[@(r)] = @(XTParSpaceThread);
                        }
                    else if (i.operands.count && i.operands[0].kind == XTIROperandKindUse)
                        self.space[@(r)] = self.space[@(i.operands[0].valueId)] ?: @(XTParSpaceNone);
                    break;
                    }
                case XTIROpLoad:
                    {
                    if (i.result.type.kind != XTIRTypeKindPtr)
                        break;
                    // A pointer ivar of the block object: a captured array.
                    NSInteger k = [self selfFieldOf:i.operands[0]];
                    if (k <= 0)
                        {
                        // a pointer read from anywhere else
                        [self because:@"it reads a pointer from memory, which its GPU version cannot follow"];
                        return NO;
                        }
                    [self.bufferFields addIndex:(NSUInteger)k];
                    self.space[@(r)] = @(XTParSpaceDevice);
                    self.bufferOf[@(r)] = @(k);
                    break;
                    }
                case XTIROpElementAddr:
                case XTIROpBitcast:
                    if (i.result.type.kind == XTIRTypeKindPtr && i.operands.count &&
                        i.operands[0].kind == XTIROperandKindUse)
                        self.space[@(r)] = self.space[@(i.operands[0].valueId)] ?: @(XTParSpaceNone);
                    break;
                case XTIROpStore:
                    {
                    NSInteger k = [self selfFieldOf:i.operands[0]];
                    if (k > 2) // a write to the block object past lo/hi: a reduction
                        [self.reductionFields addIndex:(NSUInteger)k];
                    break;
                    }
                case XTIROpAddrOf:
                    {
                    // A static-init guard's parts (see sinitOf).
                    XTIRSymbol* g = (i.operands.count && i.operands[0].kind == XTIROperandKindSym)
                                        ? [self.module symbolForId:i.operands[0].symbolId]
                                        : nil;
                    if ([g.name hasPrefix:@"__sinit_"] || [g.name hasPrefix:@"__sdata_"] || [g.name hasSuffix:@"$init"])
                        {
                        self.sinitOf[@(r)] = @([g.name hasPrefix:@"__sinit_"]);
                        self.space[@(r)] = @(XTParSpaceThread);
                        break;
                        }
                    // A data global of scalars (an array, or one value): a
                    // device buffer. Anything else stays on the CPU.
                    if (!g)
                        {
                        [self because:@"it uses an operation its GPU version cannot express yet"];
                        return NO;
                        }
                    if (self.helperMode)
                        {
                        [self because:[NSString stringWithFormat:@"it uses the global %@", shownName(g.name)]];
                        return NO;
                        }
                    if (g.kind != XTIRSymbolKindDataGlobal || i.result.type.kind != XTIRTypeKindPtr ||
                        !scalarName(i.result.type.pointeeType))
                        {
                        XTIRType* pt = i.result.type.kind == XTIRTypeKindPtr ? i.result.type.pointeeType : nil;
                        [self because:[NSString stringWithFormat:pt.kind == XTIRTypeKindF64
                                           ? @"it uses %@, an array of double; the GPU holds arrays of float and integers"
                                           : @"it uses %@, which is not a global array of numbers",
                                           shownName(g.name)]];
                        return NO;
                        }
                    if (![self.globals containsObject:g.name])
                        [self.globals addObject:g.name];
                    self.space[@(r)] = @(XTParSpaceDevice);
                    self.globalOf[@(r)] = g.name;
                    break;
                    }
                default:
                    break;
                }
            }
        }
    // Every pointer value needs a known space.
    for (NSNumber* v in self.def)
        {
        XTIRInsn* d = self.def[v];
        if (d.result.type.kind == XTIRTypeKindPtr && d.opcode != XTIROpPhi &&
            [self.space[v] unsignedIntegerValue] == XTParSpaceNone)
            {
            [self because:@"it uses a pointer its GPU version cannot place"];
            return NO;
            }
        }
    return YES;
    }

- (nullable NSString*)declOf:(XTIRValue*)v
    {
    XTIRType* t = v.type;
    if (t.kind == XTIRTypeKindMemory)
        return nil;
    if (t.kind == XTIRTypeKindPtr)
        {
        XTParSpace s = (XTParSpace)[self.space[@(v.valueId)] unsignedIntegerValue];
        NSString* pt = [self pointerType:t space:s == XTParSpaceNone ? XTParSpaceThread : s];
        return pt ? [NSString stringWithFormat:@"    %@ %@ = 0;\n", pt, [self name:v.valueId]] : @"";
        }
    NSString* n = scalarName(t);
    if (!n)
        {
        [self because:t.kind == XTIRTypeKindF64 ? @"it uses double, which Apple GPUs do not have"
                                                : @"it uses a value its GPU version cannot hold yet"];
        self.failed = YES;
        return @"";
        }
    return [NSString stringWithFormat:@"    %@ %@ = %@(0);\n", n, [self name:v.valueId], n];
    }

// Assign the phis of `target` for the edge from `from`, as a parallel copy.
- (NSString*)edgeFrom:(XTIRBlock*)from to:(XTIRBlock*)target indent:(NSString*)ind
    {
    NSMutableString* s = [NSMutableString stringWithString:[self copiesFrom:from to:target indent:ind]];
    [s appendFormat:@"%@pc = %lu; continue;\n", ind,
                    (unsigned long)[self.blockIndex[target.name] unsignedIntegerValue]];
    return s;
    }

// The phi copies for the edge from -> target, as a parallel copy in its own
// braces (so two edges' temporaries never share a scope); "" when target has
// no phis.
- (NSString*)copiesFrom:(XTIRBlock*)from to:(XTIRBlock*)target indent:(NSString*)ind
    {
    NSMutableString* s = [NSMutableString string];
    NSMutableArray<NSString*>* tmps = [NSMutableArray array];
    NSUInteger n = 0;
    for (XTIRInsn* phi in target.phiNodes)
        {
        if (!phi.result || phi.result.type.kind == XTIRTypeKindMemory)
            continue;
        XTIROperand* in = nil;
        for (NSUInteger k = 0; k + 1 < phi.operands.count; k += 2)
            if (phi.operands[k].blockRef == from)
                in = phi.operands[k + 1];
        if (!in)
            {
            self.failed = YES;
            return @"";
            }
        NSString* e = [self expr:in type:phi.result.type];
        NSString* d = [self declOf:phi.result];
        if (!e || !d.length)
            {
            self.failed = YES;
            return @"";
            }
        // `    T vN = T(0);` -> `T t<n> = <e>;`
        NSString* ty = [[d stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
            componentsSeparatedByString:@" v"][0];
        [s appendFormat:@"%@%@ t%lu = %@;\n", ind, ty, (unsigned long)n, e];
        [tmps addObject:[NSString stringWithFormat:@"%@%@ = t%lu;\n", ind, [self name:phi.result.valueId],
                                                   (unsigned long)n]];
        n++;
        }
    for (NSString* t in tmps)
        [s appendString:t];
    if (n == 0)
        return @"";
    return [NSString stringWithFormat:@"%@{\n%@%@}\n", ind, s, ind];
    }


// ── structured control flow ─────────────────────────────────────────────────
// The dispatch loop is correct for any CFG, but on a GPU the threads of a
// SIMD group that take different arms never reconverge inside it, and the
// cases run one after another. So a kernel whose CFG is structured — loops
// with one exit, ifs that rejoin — is printed as while/if/else instead:
// a back edge is `continue`, the loop's exit `break`, the join of an if the
// fall-through after it, and any other target is printed in place when this
// edge is its only way in. A CFG that does not fit returns nil and keeps the
// dispatch loop. Every walk here is over arrays in block order, so the port
// reproduces it.

- (NSUInteger)indexOf:(XTIRBlock*)b
    {
    return [self.blockIndex[b.name] unsignedIntegerValue];
    }

- (NSArray<NSNumber*>*)succsOf:(NSUInteger)u
    {
    XTIRInsn* t = self.fn.blocks[u].terminator;
    NSMutableArray<NSNumber*>* out = [NSMutableArray array];
    if (t.opcode == XTIROpBranch)
        [out addObject:@([self indexOf:t.operands[0].blockRef])];
    else if (t.opcode == XTIROpCondBranch)
        {
        [out addObject:@([self indexOf:t.operands[1].blockRef])];
        [out addObject:@([self indexOf:t.operands[2].blockRef])];
        }
    return out;
    }

// Reverse postorder, loops (header -> its blocks, and its single exit),
// forward-predecessor counts and immediate post-dominators. NO when the CFG
// is not one this printer structures.
- (BOOL)planStructure
    {
    NSUInteger n = self.fn.blocks.count;
    NSMutableArray<NSArray<NSNumber*>*>* succ = [NSMutableArray array];
    for (NSUInteger u = 0; u < n; u++)
        {
        XTIRInsn* t = self.fn.blocks[u].terminator;
        if (t.opcode != XTIROpBranch && t.opcode != XTIROpCondBranch && t.opcode != XTIROpReturn)
            return NO;
        [succ addObject:[self succsOf:u]];
        }
    self.succ = succ;
    // RPO by an explicit DFS in successor order.
    NSMutableArray<NSNumber*>* rpo = [NSMutableArray array];
    NSMutableArray<NSNumber*>* state = [NSMutableArray array]; // 0 new, 1 on stack, 2 done
    for (NSUInteger u = 0; u < n; u++)
        [state addObject:@0];
    NSMutableArray<NSArray<NSNumber*>*>* stack = [NSMutableArray arrayWithObject:@[ @0, @0 ]];
    state[0] = @1;
    while (stack.count)
        {
        NSUInteger u = [stack.lastObject[0] unsignedIntegerValue];
        NSUInteger k = [stack.lastObject[1] unsignedIntegerValue];
        if (k < succ[u].count)
            {
            stack[stack.count - 1] = @[ @(u), @(k + 1) ];
            NSUInteger v = [succ[u][k] unsignedIntegerValue];
            if ([state[v] integerValue] == 0)
                {
                state[v] = @1;
                [stack addObject:@[ @(v), @0 ]];
                }
            continue;
            }
        state[u] = @2;
        [rpo insertObject:@(u) atIndex:0];
        [stack removeLastObject];
        }
    NSMutableArray<NSNumber*>* rpoIndex = [NSMutableArray array];
    for (NSUInteger u = 0; u < n; u++)
        [rpoIndex addObject:@(-1)];
    for (NSUInteger i = 0; i < rpo.count; i++)
        rpoIndex[[rpo[i] unsignedIntegerValue]] = @(i);
    self.rpoIndex = rpoIndex;
    // Back edges (u -> v with v no later in RPO) name the loop headers; a
    // header's loop is every block that reaches a back-edge source without
    // passing the header.
    NSMutableArray<NSNumber*>* fwdPreds = [NSMutableArray array];
    for (NSUInteger u = 0; u < n; u++)
        [fwdPreds addObject:@0];
    self.loopOf = [NSMutableDictionary dictionary];
    self.loopExit = [NSMutableDictionary dictionary];
    for (NSUInteger u = 0; u < n; u++)
        {
        if ([rpoIndex[u] integerValue] < 0)
            continue;
        for (NSNumber* vn in succ[u])
            {
            NSUInteger v = vn.unsignedIntegerValue;
            if ([rpoIndex[v] integerValue] > [rpoIndex[u] integerValue])
                {
                fwdPreds[v] = @([fwdPreds[v] unsignedIntegerValue] + 1);
                continue;
                }
            // a back edge u -> v
            NSMutableIndexSet* body = self.loopOf[@(v)];
            if (!body)
                self.loopOf[@(v)] = body = [NSMutableIndexSet indexSetWithIndex:v];
            NSMutableArray<NSNumber*>* work = [NSMutableArray arrayWithObject:@(u)];
            while (work.count)
                {
                NSUInteger w = [work.lastObject unsignedIntegerValue];
                [work removeLastObject];
                if ([body containsIndex:w])
                    continue;
                [body addIndex:w];
                for (NSUInteger p = 0; p < n; p++)
                    for (NSNumber* q in succ[p])
                        if (q.unsignedIntegerValue == w && [rpoIndex[p] integerValue] >= 0)
                            [work addObject:@(p)];
                }
            }
        }
    self.fwdPreds = fwdPreds;
    // Each loop leaves to exactly one block.
    for (NSNumber* h in [self.loopOf.allKeys sortedArrayUsingSelector:@selector(compare:)])
        {
        NSIndexSet* body = self.loopOf[h];
        __block NSInteger exitTo = -1;
        __block BOOL bad = NO;
        [body enumerateIndexesUsingBlock:^(NSUInteger w, BOOL* stop) {
            for (NSNumber* q in succ[w])
                if (![body containsIndex:q.unsignedIntegerValue])
                    {
                    if (exitTo >= 0 && exitTo != (NSInteger)q.unsignedIntegerValue)
                        bad = YES;
                    exitTo = (NSInteger)q.unsignedIntegerValue;
                    }
        }];
        if (bad || exitTo < 0)
            return NO;
        self.loopExit[h] = @(exitTo);
        }
    // Immediate post-dominators over the CFG, to a virtual exit after every
    // Return (Cooper-Harvey-Kennedy on the reverse graph, in postorder of
    // the reverse graph = the order blocks' RPO indices fall).
    NSMutableArray<NSNumber*>* ipdom = [NSMutableArray array];
    for (NSUInteger u = 0; u <= n; u++)
        [ipdom addObject:@(-1)];
    ipdom[n] = @(n);
    // Process in reverse RPO (a good order for a post-dominator problem).
    BOOL changed = YES;
    while (changed)
        {
        changed = NO;
        for (NSInteger i = (NSInteger)rpo.count - 1; i >= 0; i--)
            {
            NSUInteger u = [rpo[(NSUInteger)i] unsignedIntegerValue];
            NSArray<NSNumber*>* ss = succ[u].count ? succ[u] : @[ @(n) ];
            NSInteger best = -1;
            for (NSNumber* sn in ss)
                {
                NSUInteger sv = sn.unsignedIntegerValue;
                if ([ipdom[sv] integerValue] < 0)
                    continue;
                if (best < 0)
                    best = (NSInteger)sv;
                else
                    best = [self pdomMeet:(NSUInteger)best with:sv ipdom:ipdom count:n];
                }
            if (best >= 0 && [ipdom[u] integerValue] != best)
                {
                ipdom[u] = @(best);
                changed = YES;
                }
            }
        }
    self.ipdom = ipdom;
    return YES;
    }

// The nearest common post-dominator of a and b (n is the virtual exit),
// walking up by "post-order rank": the exit ranks highest.
- (NSUInteger)pdomMeet:(NSUInteger)a with:(NSUInteger)b ipdom:(NSArray<NSNumber*>*)ipdom count:(NSUInteger)n
    {
    NSMutableIndexSet* up = [NSMutableIndexSet indexSet];
    NSUInteger x = a;
    for (NSUInteger guard = 0; guard <= n + 1; guard++)
        {
        [up addIndex:x];
        if (x == n || [ipdom[x] integerValue] < 0)
            break;
        x = [ipdom[x] unsignedIntegerValue];
        }
    x = b;
    for (NSUInteger guard = 0; guard <= n + 1; guard++)
        {
        if ([up containsIndex:x])
            return x;
        if (x == n || [ipdom[x] integerValue] < 0)
            break;
        x = [ipdom[x] unsignedIntegerValue];
        }
    return n;
    }

// One edge, structured: the phi copies, then continue / break / nothing /
// the target in place. NO when the target cannot be reached this way.
- (BOOL)jumpFrom:(NSUInteger)u to:(NSUInteger)v loop:(NSInteger)h exit:(NSInteger)e follow:(NSInteger)f
          indent:(NSString*)ind out:(NSMutableString*)out
    {
    [out appendString:[self copiesFrom:self.fn.blocks[u] to:self.fn.blocks[v] indent:ind]];
    if ((NSInteger)v == h)
        {
        [out appendFormat:@"%@continue;\n", ind];
        return YES;
        }
    if ((NSInteger)v == e)
        {
        [out appendFormat:@"%@break;\n", ind];
        return YES;
        }
    if ((NSInteger)v == f)
        return YES;
    if (self.loopOf[@(v)])
        return [self emitLoop:v exit:e follow:f outerLoop:h indent:ind out:out];
    if ([self.fwdPreds[v] unsignedIntegerValue] != 1)
        return NO; // a join this edge does not own
    return [self emitBlock:v loop:h exit:e follow:f indent:ind out:out];
    }

- (BOOL)emitLoop:(NSUInteger)x exit:(NSInteger)oe follow:(NSInteger)of outerLoop:(NSInteger)oh
          indent:(NSString*)ind out:(NSMutableString*)out
    {
    if ([self.fwdPreds[x] unsignedIntegerValue] != 1)
        return NO;
    NSUInteger ex = [self.loopExit[@(x)] unsignedIntegerValue];
    // The loop's exit must stay inside the enclosing loop (or be its exit or
    // the follow), or leaving it would need a multi-level break.
    if (oh >= 0 && ![self.loopOf[@(oh)] containsIndex:ex] && (NSInteger)ex != oe && (NSInteger)ex != of)
        return NO;
    [out appendFormat:@"%@while (true) {\n", ind];
    if (![self emitBlock:x loop:(NSInteger)x exit:(NSInteger)ex follow:-1
                  indent:[ind stringByAppendingString:@"    "] out:out])
        return NO;
    [out appendFormat:@"%@}\n", ind];
    // After the loop: its exit, reached by `break`.
    if ((NSInteger)ex == of)
        return YES;
    if ((NSInteger)ex == oh)
        {
        [out appendFormat:@"%@continue;\n", ind];
        return YES;
        }
    if ((NSInteger)ex == oe)
        {
        [out appendFormat:@"%@break;\n", ind];
        return YES;
        }
    if (self.loopOf[@(ex)])
        return NO;
    return [self emitBlock:ex loop:oh exit:oe follow:of indent:ind out:out];
    }

- (BOOL)emitBlock:(NSUInteger)x loop:(NSInteger)h exit:(NSInteger)e follow:(NSInteger)f
           indent:(NSString*)ind out:(NSMutableString*)out
    {
    XTIRBlock* b = self.fn.blocks[x];
    for (XTIRInsn* i in b.instructions)
        {
        NSString* st = [self statement:i];
        if (!st)
            {
            [self because:[self whyFor:i ptx:NO]];
            return NO;
            }
        if (st.length)
            [out appendFormat:@"%@%@\n", ind, st];
        }
    XTIRInsn* t = b.terminator;
    if (t.opcode == XTIROpReturn)
        {
        if (self.helperMode)
            {
            XTIROperand* rv = t.operands.count ? t.operands[0] : nil;
            XTIRType* rvt = (rv && rv.kind == XTIROperandKindUse) ? [self typeOf:rv.valueId] : nil;
            if (rvt && rvt.kind != XTIRTypeKindMemory)
                {
                NSString* ex = [self expr:rv type:rvt];
                if (!ex)
                    return NO;
                [out appendFormat:@"%@return %@;\n", ind, ex];
                }
            else
                [out appendFormat:@"%@return;\n", ind];
            return YES;
            }
        // The kernel's work ends: leave the do/while(false) around the body,
        // which only works from outside any loop.
        if (h >= 0)
            return NO;
        [out appendFormat:@"%@break;\n", ind];
        return YES;
        }
    if (t.opcode == XTIROpBranch)
        return [self jumpFrom:x to:[self indexOf:t.operands[0].blockRef] loop:h exit:e follow:f indent:ind out:out];
    // CondBranch: if/else that rejoin at x's immediate post-dominator.
    NSUInteger n = self.fn.blocks.count;
    NSInteger j = [self.ipdom[x] integerValue];
    if (j < 0)
        return NO;
    NSInteger join = (j == (NSInteger)n) ? f : j; // the virtual exit: nothing after
    if (join >= 0 && join != h && join != e && join != f)
        {
        // The join is printed after the if: it must lie in this loop.
        if (h >= 0 && ![self.loopOf[@(h)] containsIndex:(NSUInteger)join])
            return NO;
        }
    NSString* c = [self expr:t.operands[0] type:nil];
    if (!c)
        return NO;
    NSString* in2 = [ind stringByAppendingString:@"    "];
    [out appendFormat:@"%@if (%@) {\n", ind, c];
    if (![self jumpFrom:x to:[self indexOf:t.operands[1].blockRef] loop:h exit:e follow:join indent:in2 out:out])
        return NO;
    [out appendFormat:@"%@} else {\n", ind];
    if (![self jumpFrom:x to:[self indexOf:t.operands[2].blockRef] loop:h exit:e follow:join indent:in2 out:out])
        return NO;
    [out appendFormat:@"%@}\n", ind];
    if (join < 0 || join == f)
        return YES;
    if (join == h)
        {
        [out appendFormat:@"%@continue;\n", ind];
        return YES;
        }
    if (join == e)
        {
        [out appendFormat:@"%@break;\n", ind];
        return YES;
        }
    if (self.loopOf[@(join)])
        return [self emitLoop:(NSUInteger)join exit:e follow:f outerLoop:h indent:ind out:out];
    return [self emitBlock:(NSUInteger)join loop:h exit:e follow:f indent:ind out:out];
    }

// The structured body, or nil (then the dispatch loop prints it).
- (nullable NSString*)structuredBodyIndent:(NSString*)ind
    {
    if (![self planStructure])
        return nil;
    NSMutableString* out = [NSMutableString string];
    BOOL ok = self.loopOf[@0] ? [self emitLoop:0 exit:-1 follow:-1 outerLoop:-1 indent:ind out:out]
                              : [self emitBlock:0 loop:-1 exit:-1 follow:-1 indent:ind out:out];
    return (ok && !self.failed) ? out : nil;
    }

- (nullable NSString*)binary:(XTIRInsn*)i
    {
    XTIRType* t = i.result.type;
    NSString* a = [self expr:i.operands[0] type:t];
    NSString* b = [self expr:i.operands[1] type:t];
    if (!a || !b)
        return nil;
    NSString* n = scalarName(t);
    switch (i.opcode)
        {
        case XTIROpAdd: case XTIROpFAdd: return [NSString stringWithFormat:@"%@(%@ + %@)", n, a, b];
        case XTIROpSub: case XTIROpFSub: return [NSString stringWithFormat:@"%@(%@ - %@)", n, a, b];
        case XTIROpMul: case XTIROpFMul: return [NSString stringWithFormat:@"%@(%@ * %@)", n, a, b];
        case XTIROpFDiv: return [NSString stringWithFormat:@"%@(%@ / %@)", n, a, b];
        case XTIROpUDiv: return [NSString stringWithFormat:@"%@(%@(%@) / %@(%@))", n, unsignedName(t), a, unsignedName(t), b];
        case XTIROpURem: return [NSString stringWithFormat:@"%@(%@(%@) %% %@(%@))", n, unsignedName(t), a, unsignedName(t), b];
        case XTIROpSDiv: return [NSString stringWithFormat:@"%@(%@(%@) / %@(%@))", n, signedName(t), a, signedName(t), b];
        case XTIROpSRem: return [NSString stringWithFormat:@"%@(%@(%@) %% %@(%@))", n, signedName(t), a, signedName(t), b];
        case XTIROpAnd: return [NSString stringWithFormat:@"%@(%@ & %@)", n, a, b];
        case XTIROpOr: return [NSString stringWithFormat:@"%@(%@ | %@)", n, a, b];
        case XTIROpXor: return [NSString stringWithFormat:@"%@(%@ ^ %@)", n, a, b];
        case XTIROpShl: return [NSString stringWithFormat:@"%@(%@ << %@)", n, a, b];
        case XTIROpLShr: return [NSString stringWithFormat:@"%@(%@(%@) >> %@)", n, unsignedName(t), a, b];
        case XTIROpAShr: return [NSString stringWithFormat:@"%@(%@(%@) >> %@)", n, signedName(t), a, b];
        default: return nil;
        }
    }

- (nullable NSString*)comparisonOf:(XTIRInsn*)i
    {
    XTIRType* t = [self typeOf:i.operands[0].kind == XTIROperandKindUse ? i.operands[0].valueId
                                                                        : i.operands[1].valueId];
    if (!t)
        return nil;
    NSString* a = [self expr:i.operands[0] type:t];
    NSString* b = [self expr:i.operands[1] type:t];
    if (!a || !b)
        return nil;
    if (i.opcode == XTIROpFCmp)
        {
        static NSString* fops[] = { @"==", @"!=", @"<", @">", @"<=", @">=" };
        if (i.predicate > XTIRFCmpOGE)
            return nil;
        return [NSString stringWithFormat:@"(%@ %@ %@)", a, fops[i.predicate], b];
        }
    static NSString* iops[] = { @"==", @"!=", @"<", @">", @"<=", @">=", @"<", @">", @"<=", @">=" };
    if (i.predicate > XTIRICmpUGE)
        return nil;
    BOOL isSigned = (i.predicate >= XTIRICmpSLT && i.predicate <= XTIRICmpSGE);
    BOOL isUnsigned = (i.predicate >= XTIRICmpULT);
    NSString* cast = isSigned ? signedName(t) : isUnsigned ? unsignedName(t) : nil;
    if (cast && t.kind != XTIRTypeKindBool)
        return [NSString stringWithFormat:@"(%@(%@) %@ %@(%@))", cast, a, iops[i.predicate], cast, b];
    return [NSString stringWithFormat:@"(%@ %@ %@)", a, iops[i.predicate], b];
    }

// The maths intrinsics, by the callee's name, as precise Metal functions (§7).
static NSString* intrinsicFor(NSString* callee)
    {
    NSString* m = callee;
    if ([m hasPrefix:@"Math$"])
        m = [m substringFromIndex:5];
    NSRange r = [m rangeOfString:@"__"];
    if (r.location != NSNotFound)
        m = [m substringToIndex:r.location];
    if ([m hasPrefix:@"_xm_"])
        m = [m substringFromIndex:4];
    if ([m hasSuffix:@"f"] && m.length > 3)
        m = [m substringToIndex:m.length - 1];
    NSDictionary<NSString*, NSString*>* map = @{
        @"sqrt" : @"precise::sqrt", @"sin" : @"precise::sin", @"cos" : @"precise::cos",
        @"exp" : @"precise::exp", @"ln" : @"precise::log", @"log" : @"precise::log",
        @"pow" : @"precise::pow", @"floor" : @"floor", @"fma" : @"fma", @"abs" : @"abs",
        @"fabs" : @"abs", @"min" : @"min", @"max" : @"max"
    };
    return map[m];
    }

- (nullable NSString*)statement:(XTIRInsn*)i
    {
    XTIRType* rt = i.result.type;
    NSString* r = i.result ? [self name:i.result.valueId] : nil;
    switch (i.opcode)
        {
        case XTIROpConst:
            {
            NSString* e = [self expr:i.operands[0] type:rt];
            return e ? [NSString stringWithFormat:@"%@ = %@;", r, e] : nil;
            }
        case XTIROpAdd: case XTIROpSub: case XTIROpMul: case XTIROpUDiv: case XTIROpSDiv:
        case XTIROpURem: case XTIROpSRem: case XTIROpAnd: case XTIROpOr: case XTIROpXor:
        case XTIROpShl: case XTIROpLShr: case XTIROpAShr:
        case XTIROpFAdd: case XTIROpFSub: case XTIROpFMul: case XTIROpFDiv:
            {
            NSString* e = [self binary:i];
            return e ? [NSString stringWithFormat:@"%@ = %@;", r, e] : nil;
            }
        case XTIROpNot:
            {
            NSString* a = [self expr:i.operands[0] type:rt];
            if (!a)
                return nil;
            return rt.kind == XTIRTypeKindBool ? [NSString stringWithFormat:@"%@ = !%@;", r, a]
                                               : [NSString stringWithFormat:@"%@ = %@(~%@);", r, scalarName(rt), a];
            }
        case XTIROpNeg:
        case XTIROpFNeg:
            {
            NSString* a = [self expr:i.operands[0] type:rt];
            return a ? [NSString stringWithFormat:@"%@ = %@(-%@);", r, scalarName(rt), a] : nil;
            }
        case XTIROpFSqrt:
            {
            NSString* a = [self expr:i.operands[0] type:rt];
            return a ? [NSString stringWithFormat:@"%@ = %@::sqrt(%@);", r, self.fast ? @"fast" : @"precise", a] : nil;
            }
        case XTIROpICmp:
        case XTIROpFCmp:
            {
            NSString* e = [self comparisonOf:i];
            return e ? [NSString stringWithFormat:@"%@ = %@;", r, e] : nil;
            }
        case XTIROpZExt:
        case XTIROpSExt:
        case XTIROpTrunc:
        case XTIROpSIToFp:
        case XTIROpUIToFp:
        case XTIROpFpToSI:
        case XTIROpFpToUI:
        case XTIROpCopy:
            {
            XTIRType* st = i.operands[0].kind == XTIROperandKindUse ? [self typeOf:i.operands[0].valueId] : rt;
            NSString* a = [self expr:i.operands[0] type:st];
            if (!a || !scalarName(rt))
                return nil;
            // Widen through the source's own signedness, as the CPU does.
            if (i.opcode == XTIROpZExt)
                a = [NSString stringWithFormat:@"%@(%@)", unsignedName(st), a];
            else if (i.opcode == XTIROpSExt)
                a = [NSString stringWithFormat:@"%@(%@)", signedName(st), a];
            return [NSString stringWithFormat:@"%@ = %@(%@);", r, scalarName(rt), a];
            }
        case XTIROpSelect:
            {
            NSString* c = [self expr:i.operands[0] type:nil];
            NSString* a = [self expr:i.operands[1] type:rt];
            NSString* b = [self expr:i.operands[2] type:rt];
            return (c && a && b) ? [NSString stringWithFormat:@"%@ = %@ ? %@ : %@;", r, c, a, b] : nil;
            }
        case XTIROpFieldAddr:
            {
            NSInteger k = [self selfFieldOf:[XTIROperand useWithValueId:i.result.valueId]];
            // The slot of a captured array: only ever loaded, and that load is
            // the buffer itself, so the slot's address needs no code.
            if (k >= 0 && self.objLayout.fields[(NSUInteger)k].type.kind == XTIRTypeKindPtr)
                return @"";
            XTParSpace s = (XTParSpace)[self.space[@(i.result.valueId)] unsignedIntegerValue];
            NSString* pt = [self pointerType:rt space:s];
            if (!pt)
                return nil;
            if (k >= 0)
                return [NSString stringWithFormat:@"%@ = (%@)(st + %u);", r, pt,
                                                  self.objLayout.fields[(NSUInteger)k].byteOffset];
            // A field of a struct element in a buffer: by its byte offset.
            XTIRType* bt = [self typeOf:i.operands[0].valueId];
            XTIRLayout* l = bt.pointeeType.layout;
            NSInteger f = (NSInteger)i.operands[1].intValue;
            if (!l || f < 0 || (NSUInteger)f >= l.fields.count)
                return nil;
            return [NSString stringWithFormat:@"%@ = (%@)((%@ uchar*)%@ + %u);", r, pt,
                                              s == XTParSpaceDevice ? @"device" : @"thread",
                                              [self name:i.operands[0].valueId], l.fields[(NSUInteger)f].byteOffset];
            }
        case XTIROpElementAddr:
            {
            NSString* idx = [self expr:i.operands[1] type:nil];
            return idx ? [NSString stringWithFormat:@"%@ = %@ + %@;", r, [self name:i.operands[0].valueId], idx] : nil;
            }
        case XTIROpBitcast:
            {
            XTParSpace s = (XTParSpace)[self.space[@(i.result.valueId)] unsignedIntegerValue];
            NSString* pt = rt.kind == XTIRTypeKindPtr ? [self pointerType:rt space:s] : scalarName(rt);
            return pt ? [NSString stringWithFormat:@"%@ = as_type<%@>(%@);", r, pt,
                                                   [self expr:i.operands[0] type:nil]] : nil;
            }
        case XTIROpLoad:
            {
            NSNumber* buf = self.bufferOf[@(i.result.valueId)];
            if (buf)
                return [NSString stringWithFormat:@"%@ = buf_%@;", r, buf];
            if (!scalarName(rt))
                return nil;
            if ([self.sinitOf[@(i.operands[0].valueId)] boolValue])
                return [NSString stringWithFormat:@"%@ = %@(2);", r, scalarName(rt)];
            return [NSString stringWithFormat:@"%@ = *%@;", r, [self name:i.operands[0].valueId]];
            }
        case XTIROpStore:
            {
            if (i.operands[0].kind != XTIROperandKindUse)
                return nil;
            XTIRType* pt = [self typeOf:i.operands[0].valueId];
            NSString* v = [self expr:i.operands[1] type:pt.pointeeType];
            return v ? [NSString stringWithFormat:@"*%@ = %@;", [self name:i.operands[0].valueId], v] : nil;
            }
        case XTIROpCall:
            {
            XTIRSymbol* sym = [self.module symbolForId:i.operands[0].symbolId];
            NSString* callee = sym.name;
            // The static-init machinery: the host has run it.
            if ([callee isEqualToString:@"_xtc_sinit_run"] || [callee hasSuffix:@"$init"])
                return @"";
            NSString* fn = intrinsicFor(callee);
            // The speed goal: Metal's fast versions, in place of the precise ones.
            if (self.fast && [fn hasPrefix:@"precise::"])
                fn = [@"fast::" stringByAppendingString:[fn substringFromIndex:9]];
            BOOL isVoid = !rt || rt.kind == XTIRTypeKindMemory;
            if (!fn)
                {
                // A function of the program (the subset check has walked it):
                // printed once, before the kernel.
                XTIRFunction* target = nil;
                for (XTIRFunction* g in self.module.functions)
                    if ([g.name isEqualToString:callee])
                        target = g;
                if (!target)
                    return nil;
                fn = [@"h_" stringByAppendingString:[callee stringByReplacingOccurrencesOfString:@"$" withString:@"_"]];
                if (![self.helperNames containsObject:callee])
                    {
                    [self.helperNames addObject:callee];
                    XTIRParMSL* h = [XTIRParMSL new];
                    h.module = self.module;
                    h.fn = target;
                    h.helperMode = YES;
                    h.fast = self.fast;
                    h.helperText = self.helperText;
                    h.helperNames = self.helperNames;
                    NSString* text = [h printHelper:fn];
                    if (!text)
                        {
                        [self because:[self callFailed:callee helper:h]];
                        return nil;
                        }
                    [self.helperText addObject:text];
                    }
                }
            else if (isVoid)
                return nil;
            NSMutableArray<NSString*>* args = [NSMutableArray array];
            for (NSUInteger k = 1; k < i.operands.count; k++)
                {
                XTIROperand* o = i.operands[k];
                if (o.kind == XTIROperandKindUse && [self typeOf:o.valueId].kind == XTIRTypeKindMemory)
                    continue;
                NSString* e = [self expr:o type:(o.kind == XTIROperandKindUse ? [self typeOf:o.valueId] : rt)];
                if (!e)
                    return nil;
                [args addObject:e];
                }
            if (isVoid)
                return [NSString stringWithFormat:@"%@(%@);", fn, [args componentsJoinedByString:@", "]];
            return [NSString stringWithFormat:@"%@ = %@(%@);", r, fn, [args componentsJoinedByString:@", "]];
            }
        case XTIROpAddrOf:
            {
            if (self.sinitOf[@(i.result.valueId)])
                return @"";
            NSString* g = self.globalOf[@(i.result.valueId)];
            if (!g)
                return nil;
            return [NSString stringWithFormat:@"%@ = glob_%lu;", r, (unsigned long)[self.globals indexOfObject:g]];
            }
        case XTIROpDbgValue:
            return @"";
        default:
            return nil;
        }
    }

// The declarations and the dispatch-loop body of self.fn (a kernel or a
// helper): YES when every instruction printed.
- (BOOL)declarations:(NSMutableString*)decls body:(NSMutableString*)body
    {
    NSUInteger bi = 0;
    for (XTIRBlock* b in self.fn.blocks)
        self.blockIndex[b.name] = @(bi++);
    self.ordinal = [NSMutableDictionary dictionary];
    NSUInteger ord = 0;
    for (XTIRBlock* b in self.fn.blocks)
        {
        for (XTIRInsn* i in b.phiNodes)
            if (i.result && i.result.type.kind != XTIRTypeKindMemory)
                self.ordinal[@(i.result.valueId)] = @(ord++);
        for (XTIRInsn* i in b.instructions)
            if (i.result && i.result.type.kind != XTIRTypeKindMemory)
                self.ordinal[@(i.result.valueId)] = @(ord++);
        }

    for (XTIRBlock* b in self.fn.blocks)
        {
        for (XTIRInsn* phi in b.phiNodes)
            if (phi.result && phi.result.type.kind != XTIRTypeKindMemory)
                {
                // A phi of pointers takes its incomings' space.
                if (phi.result.type.kind == XTIRTypeKindPtr)
                    for (NSUInteger k = 1; k < phi.operands.count; k += 2)
                        if (phi.operands[k].kind == XTIROperandKindUse && self.space[@(phi.operands[k].valueId)])
                            self.space[@(phi.result.valueId)] = self.space[@(phi.operands[k].valueId)];
                [decls appendString:[self declOf:phi.result]];
                }
        for (XTIRInsn* i in b.instructions)
            if (i.result && i.result.type.kind != XTIRTypeKindMemory)
                [decls appendString:[self declOf:i.result]];
        }
    if (self.failed)
        return NO;

    for (XTIRBlock* b in self.fn.blocks)
        {
        [body appendFormat:@"        case %lu: {\n", (unsigned long)[self.blockIndex[b.name] unsignedIntegerValue]];
        for (XTIRInsn* i in b.instructions)
            {
            NSString* s = [self statement:i];
            if (!s)
                {
                [self because:[self whyFor:i ptx:NO]];
                return NO;
                }
            if (s.length)
                [body appendFormat:@"            %@\n", s];
            }
        XTIRInsn* t = b.terminator;
        switch (t.opcode)
            {
            case XTIROpBranch:
                [body appendString:[self edgeFrom:b to:t.operands[0].blockRef indent:@"            "]];
                break;
            case XTIROpCondBranch:
                {
                NSString* c = [self expr:t.operands[0] type:nil];
                if (!c)
                    return NO;
                [body appendFormat:@"            if (%@) {\n", c];
                [body appendString:[self edgeFrom:b to:t.operands[1].blockRef indent:@"                "]];
                [body appendString:@"            }\n"];
                [body appendString:[self edgeFrom:b to:t.operands[2].blockRef indent:@"            "]];
                break;
                }
            case XTIROpReturn:
                {
                // A helper returns its value; the kernel just stops.
                XTIROperand* rv = t.operands.count ? t.operands[0] : nil;
                XTIRType* rvt = (rv && rv.kind == XTIROperandKindUse) ? [self typeOf:rv.valueId] : nil;
                if (self.helperMode && rvt && rvt.kind != XTIRTypeKindMemory)
                    {
                    NSString* e = [self expr:rv type:rvt];
                    if (!e)
                        return NO;
                    [body appendFormat:@"            return %@;\n", e];
                    }
                else if (self.helperMode)
                    [body appendString:@"            return;\n"];
                else
                    [body appendString:@"            pc = 0xffffffffu; continue;\n"];
                break;
                }
            default:
                return NO;
            }
        [body appendString:@"        }\n"];
        }
    return !self.failed;
    }

// A helper the kernel calls: `static <ret> <name>(<params>)`, its body the
// same dispatch loop. Scalars only, in and out.
- (nullable NSString*)printHelper:(NSString*)name
    {
    self.def = [NSMutableDictionary dictionary];
    self.space = [NSMutableDictionary dictionary];
    self.bufferOf = [NSMutableDictionary dictionary];
    self.bufferFields = [NSMutableIndexSet indexSet];
    self.reductionFields = [NSMutableIndexSet indexSet];
    self.blockIndex = [NSMutableDictionary dictionary];
    if (![self analyse])
        return nil;
    NSMutableArray<NSString*>* params = [NSMutableArray array];
    for (NSUInteger k = 0; k + 1 < self.fn.paramTypes.count; k++)
        {
        NSString* t = scalarName(self.fn.paramTypes[k]);
        if (!t)
            return nil;
        [params addObject:[NSString stringWithFormat:@"%@ p%lu", t, (unsigned long)k]];
        }
    XTIRType* rt = self.fn.returnType;
    NSString* ret = (!rt || rt.kind == XTIRTypeKindVoid || rt.kind == XTIRTypeKindMemory) ? @"void" : scalarName(rt);
    if (!ret)
        return nil;
    NSMutableString* decls = [NSMutableString string];
    NSMutableString* body = [NSMutableString string];
    if (![self declarations:decls body:body])
        return nil;
    NSMutableString* out = [NSMutableString string];
    [out appendFormat:@"static %@ %@(%@)\n{\n", ret, name, [params componentsJoinedByString:@", "]];
    [out appendString:decls];
    NSString* structured = [self structuredBodyIndent:@"    "];
    if (structured)
        [out appendString:structured];
    else
        {
        [out appendString:@"    uint pc = 0;\n    while (pc != 0xffffffffu) {\n        switch (pc) {\n"];
        [out appendString:body];
        [out appendString:@"        default: pc = 0xffffffffu; continue;\n        }\n    }\n"];
        }
    if (![ret isEqualToString:@"void"])
        [out appendFormat:@"    return %@(0);\n", ret];
    [out appendString:@"}\n"];
    return out;
    }

- (nullable NSString*)print
    {
    self.def = [NSMutableDictionary dictionary];
    self.space = [NSMutableDictionary dictionary];
    self.bufferOf = [NSMutableDictionary dictionary];
    self.bufferFields = [NSMutableIndexSet indexSet];
    self.reductionFields = [NSMutableIndexSet indexSet];
    self.blockIndex = [NSMutableDictionary dictionary];

    XTIRType* selfT = self.fn.paramTypes.count ? self.fn.paramTypes[0] : nil;
    self.objLayout = selfT.kind == XTIRTypeKindPtr ? selfT.pointeeType.layout : nil;
    // lo and hi are ParChunk's two i64 ivars, fields 1 and 2 (field 0 is the vtable).
    self.globals = [NSMutableArray array];
    self.globalOf = [NSMutableDictionary dictionary];
    if (!self.objLayout || self.objLayout.fields.count < 3 ||
        self.objLayout.fields[1].type.kind != XTIRTypeKindI64 || self.objLayout.fields[2].type.kind != XTIRTypeKindI64)
        return nil;
    if (![self analyse])
        return nil;

    NSMutableString* decls = [NSMutableString string];
    NSMutableString* body = [NSMutableString string];
    self.helperText = [NSMutableArray array];
    self.helperNames = [NSMutableSet set];
    if (![self declarations:decls body:body])
        return nil;
    if (self.failed)
        return nil;

    // The header line the runtime reads, and the kernel's parameters.
    NSArray<XTIRLayoutField*>* fl = self.objLayout.fields;
    NSMutableString* meta = [NSMutableString stringWithFormat:@"// xcpar size=%u lo=%u hi=%u", self.objLayout.size,
                                                              fl[1].byteOffset, fl[2].byteOffset];
    NSMutableString* params = [NSMutableString stringWithString:
        @"constant uchar* args [[buffer(0)]], constant long* span [[buffer(1)]]"];
    __block NSUInteger slot = 2;
    __block BOOL bad = NO;
    [self.bufferFields enumerateIndexesUsingBlock:^(NSUInteger k, BOOL* stop) {
        NSString* et = scalarName(fl[k].type.pointeeType);
        if (!et)
            {
            bad = YES;
            *stop = YES;
            return;
            }
        [meta appendFormat:@" buf=%u:%lu:%u", fl[k].byteOffset, (unsigned long)(k - 3), fl[k].type.pointeeType.byteWidth];
        [params appendFormat:@", device %@* buf_%lu [[buffer(%lu)]]", et, (unsigned long)k, (unsigned long)slot++];
    }];
    for (NSUInteger gi = 0; gi < self.globals.count; gi++)
        {
        XTIRSymbol* g = [self.module symbolForName:self.globals[gi]];
        XTIRType* gt = g.globalType;
        XTIRType* et = gt.kind == XTIRTypeKindAgg ? gt.layout.fields.firstObject.type : gt;
        NSString* en = scalarName(et);
        if (!en)
            return nil;
        [meta appendFormat:@" glob=%@:%u", self.globals[gi], et.byteWidth];
        [params appendFormat:@", device %@* glob_%lu [[buffer(%lu)]]", en, (unsigned long)gi, (unsigned long)slot++];
        }
    NSMutableString* tail = [NSMutableString string];
    [self.reductionFields enumerateIndexesUsingBlock:^(NSUInteger k, BOOL* stop) {
        NSString* et = scalarName(fl[k].type);
        if (!et)
            {
            bad = YES;
            *stop = YES;
            return;
            }
        [meta appendFormat:@" red=%u:%u", fl[k].byteOffset, fl[k].type.byteWidth];
        [params appendFormat:@", device %@* red_%lu [[buffer(%lu)]]", et, (unsigned long)k, (unsigned long)slot++];
        [tail appendFormat:@"    red_%lu[tid] = *(thread %@*)(st + %u);\n", (unsigned long)k, et, fl[k].byteOffset];
    }];
    if (bad)
        return nil;

    NSMutableString* out = [NSMutableString string];
    // A speed-goal block's runtime compiles it with fast maths (MTLMathModeFast).
    if (self.fast)
        [meta appendString:@" fast"];
    [out appendFormat:@"%@\n", meta];
    [out appendString:@"#include <metal_stdlib>\nusing namespace metal;\n"];
    for (NSString* h in self.helperText)
        [out appendString:h];
    [out appendFormat:@"kernel void par_kernel(%@, uint tid [[thread_position_in_grid]])\n{\n", params];
    [out appendFormat:@"    thread uchar st[%u];\n", self.objLayout.size];
    [out appendFormat:@"    for (uint q = 0; q < %uu; q++) st[q] = args[q];\n", self.objLayout.size];
    [out appendString:@"    long lo = span[0] + long(tid) * span[2];\n"];
    [out appendString:@"    long hi = min(lo + span[2], span[1]);\n"];
    [out appendFormat:@"    *(thread long*)(st + %u) = lo;\n    *(thread long*)(st + %u) = hi;\n",
                      fl[1].byteOffset, fl[2].byteOffset];
    [out appendString:decls];
    NSString* structured = [self structuredBodyIndent:@"        "];
    if (structured)
        {
        [out appendString:@"    if (lo < hi) do {\n"];
        [out appendString:structured];
        [out appendString:@"    } while (false);\n"];
        }
    else
        {
        [out appendString:@"    uint pc = 0;\n    while (lo < hi && pc != 0xffffffffu) {\n        switch (pc) {\n"];
        [out appendString:body];
        [out appendString:@"        default: pc = 0xffffffffu; continue;\n        }\n    }\n"];
        }
    [out appendString:@"    if (lo >= span[1]) return;\n"];
    [out appendString:tail];
    [out appendString:@"}\n"];
    return out;
    }

@end
