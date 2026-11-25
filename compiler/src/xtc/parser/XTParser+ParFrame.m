/****************************************************************************\
|* XTParser+ParFrame.m
|*
|* The par frame walk (#338): a par body's frame, computed from its tree once
|* it is parsed: the captures, their types and bases in first-use order
|* (which sets the block's field layout), the globals the body names, the
|* names it assigns, and its uses of each name, as subscript bases and as
|* array updates, whether it can leave an iteration early, and which `par.x`
|* names a grid body reads. The walk visits the tree in the order the parser
|* read it, and binds the body's declarations as the parser did, in scopes
|* pushed on blkScopes above the frame's depth, so a name resolves as it did
|* where it was used. A block literal or a nested par block in the body is
|* read through the site the parser registered for it (pfwRegister): its
|* body counts toward the uses, and the names its site passes in are uses at
|* the site. What cannot be captured is still said where it is used
|* (blkNoteIdentifierUse, blkNoteBareCall), among the parse's other errors.
|*
|* A lifted loop's block is built from a copy of the loop as parsed
|* (parAutoFor), not from a second parse in the block's frame, so the walk of
|* that copy (pfwAuto) does what the frame did to the parse: it says what the
|* block cannot capture, in the order the parse said it, and reads `self.f` as
|* the ivar f (pfwSelfIvar).
|* Mirrored in the port (Parser.xc, parFrameWalk).
\****************************************************************************/
#import <objc/runtime.h>
#import "XTParser+Private.h"
#import "XTArrayType.h"

// Store an object into an ivar, retaining it as a strong reference. Apple's
// runtime needs the StrongDefault form for ivars without ownership metadata;
// the GNUstep runtime's object_setIvar already honours each ivar's ownership.
#if defined(__APPLE__)
#define pfwSetIvar(o, iv, v) object_setIvarWithStrongDefault((o), (iv), (v))
#else
#define pfwSetIvar(o, iv, v) object_setIvar((o), (iv), (v))
#endif

NS_ASSUME_NONNULL_BEGIN

/****************************************************************************\
|* A lifted loop's copy: every node and the case, label and catch records in
|* it copied ivar by ivar, the arrays that hold them copied (mutable), and
|* everything else (names, types, locations) shared. The port's
|* Node.deepCopy.
\****************************************************************************/
static BOOL pfwTreeObject(id v)
    {
    return [v isKindOfClass:[XTASTNode class]] || [v isKindOfClass:[XTSwitchCase class]] ||
           [v isKindOfClass:[XTCaseLabel class]] || [v isKindOfClass:[XTCatchClause class]];
    }

static id _Nullable pfwCopyValue(id _Nullable v);

static id pfwCopyObject(id src)
    {
    Class cls = object_getClass(src);
    id dst = [cls alloc];
    for (Class c = cls; c && c != [NSObject class]; c = class_getSuperclass(c))
        {
        unsigned int count = 0;
        Ivar* ivars = class_copyIvarList(c, &count);
        for (unsigned int i = 0; i < count; i++)
            {
            const char* enc = ivar_getTypeEncoding(ivars[i]);
            if (enc && enc[0] == '@')
                pfwSetIvar(dst, ivars[i], pfwCopyValue(object_getIvar(src, ivars[i])));
            else if (enc)
                {
                NSUInteger size = 0;
                NSGetSizeAndAlignment(enc, &size, NULL);
                ptrdiff_t off = ivar_getOffset(ivars[i]);
                memcpy((char*)(__bridge void*)dst + off, (const char*)(__bridge void*)src + off, size);
                }
            }
        free(ivars);
        }
    return dst;
    }

static id _Nullable pfwCopyValue(id _Nullable v)
    {
    if (!v)
        return nil;
    if (pfwTreeObject(v))
        return pfwCopyObject(v);
    if ([v isKindOfClass:[NSArray class]])
        {
        NSMutableArray* a = [NSMutableArray arrayWithCapacity:((NSArray*)v).count];
        for (id e in (NSArray*)v)
            [a addObject:pfwCopyValue(e)];
        return a;
        }
    return v;
    }

XTASTNode* XTASTDeepCopy(XTASTNode* n)
    {
    return pfwCopyValue(n);
    }

// Each node, record or array an object's ivars hold, for `f`.
static void pfwEachIvar(id obj, void (^f)(Ivar iv, id val))
    {
    for (Class c = object_getClass(obj); c && c != [NSObject class]; c = class_getSuperclass(c))
        {
        unsigned int count = 0;
        Ivar* ivars = class_copyIvarList(c, &count);
        for (unsigned int i = 0; i < count; i++)
            {
            const char* enc = ivar_getTypeEncoding(ivars[i]);
            if (!enc || enc[0] != '@')
                continue;
            id val = object_getIvar(obj, ivars[i]);
            if (val && (pfwTreeObject(val) || [val isKindOfClass:[NSArray class]]))
                f(ivars[i], val);
            }
        free(ivars);
        }
    }

// Each name `from` in the tree under `obj` made `to`.
static void pfwRename(id obj, NSString* from, NSString* to)
    {
    if ([obj isKindOfClass:[XTIdentifierNode class]] && [((XTIdentifierNode*)obj).identName isEqualToString:from])
        pfwSetIvar(obj, class_getInstanceVariable([XTIdentifierNode class], "_identName"), to);
    pfwEachIvar(obj, ^(Ivar iv, id val) {
      (void)iv;
      if (pfwTreeObject(val))
          pfwRename(val, from, to);
      else
          for (id e in (NSArray*)val)
              if (pfwTreeObject(e))
                  pfwRename(e, from, to);
    });
    }

void XTASTRename(XTASTNode* n, NSString* from, NSString* to)
    {
    pfwRename(n, [from copy], [to copy]);
    }

/****************************************************************************\
|* Adjacent par blocks fused (#147): what one body touches, read from its
|* tree, as the port's parFuseScan. "acc" name -> bits (1 read, 2 written, 4
|* at another index or through a pointer), "names" every name it reads or
|* writes, "decls" its own names and "dtypes" their types, "scalars" the
|* names it assigns, "bad" set when it holds what fusing cannot carry.
\****************************************************************************/
static NSString* _Nullable pfuRoot(XTASTNode* n)
    {
    while (n)
        {
        if ([n isKindOfClass:[XTIdentifierNode class]])
            return ((XTIdentifierNode*)n).identName;
        if ([n isKindOfClass:[XTSubscriptExprNode class]])
            n = ((XTSubscriptExprNode*)n).base;
        else if ([n isKindOfClass:[XTMemberAccessNode class]] && !((XTMemberAccessNode*)n).isArrow)
            n = ((XTMemberAccessNode*)n).base;
        else
            return nil;
        }
    return nil;
    }

static void pfuNote(NSMutableDictionary* st, NSString* n, NSUInteger bits)
    {
    NSMutableDictionary* acc = st[@"acc"];
    acc[n] = @([acc[n] unsignedIntegerValue] | bits);
    }

static void pfuWalk(id _Nullable n, NSMutableDictionary* st, NSString* iv, NSUInteger loops);

static void pfuAccess(NSMutableDictionary* st, XTSubscriptExprNode* sub, NSString* iv, NSUInteger bits, NSUInteger loops)
    {
    XTASTNode* base = sub.base;
    XTASTNode* idx = sub.index;
    if ([base isKindOfClass:[XTIdentifierNode class]])
        {
        NSString* name = ((XTIdentifierNode*)base).identName;
        BOOL atIv = [idx isKindOfClass:[XTIdentifierNode class]] && [((XTIdentifierNode*)idx).identName isEqualToString:iv];
        pfuNote(st, name, atIv ? bits : bits | 4);
        [st[@"names"] addObject:name];
        }
    else
        {
        NSString* root = pfuRoot(base);
        if (!root)
            {
            st[@"bad"] = @YES;
            return;
            }
        pfuNote(st, root, bits | 4);
        [st[@"names"] addObject:root];
        pfuWalk(base, st, iv, loops);
        }
    if (idx)
        pfuWalk(idx, st, iv, loops);
    }

static void pfuTarget(NSMutableDictionary* st, XTASTNode* t, NSString* iv, NSUInteger bits, NSUInteger loops)
    {
    if ([t isKindOfClass:[XTSubscriptExprNode class]])
        {
        pfuAccess(st, (XTSubscriptExprNode*)t, iv, bits, loops);
        return;
        }
    if ([t isKindOfClass:[XTIdentifierNode class]])
        {
        [st[@"names"] addObject:((XTIdentifierNode*)t).identName];
        [st[@"scalars"] addObject:((XTIdentifierNode*)t).identName];
        return;
        }
    st[@"bad"] = @YES;
    }

static void pfuWalk(id _Nullable n, NSMutableDictionary* st, NSString* iv, NSUInteger loops)
    {
    if (!n)
        return;
    if ([n isKindOfClass:[XTReturnNode class]] || [n isKindOfClass:[XTGotoNode class]] || [n isKindOfClass:[XTThrowNode class]] ||
        [n isKindOfClass:[XTTryNode class]] || [n isKindOfClass:[XTDeferNode class]] || [n isKindOfClass:[XTAsmBlockNode class]] ||
        [n isKindOfClass:[XTDeleteNode class]] || [n isKindOfClass:[XTLabelNode class]] || [n isKindOfClass:[XTTupleAssignNode class]])
        {
        st[@"bad"] = @YES;
        return;
        }
    if (([n isKindOfClass:[XTBreakNode class]] || [n isKindOfClass:[XTContinueNode class]]) && loops == 0)
        {
        st[@"bad"] = @YES;
        return;
        }
    if ([n isKindOfClass:[XTForCStyleNode class]] || [n isKindOfClass:[XTForInNode class]] || [n isKindOfClass:[XTWhileNode class]] ||
        [n isKindOfClass:[XTSwitchNode class]])
        {
        pfwEachIvar(n, ^(Ivar ivar, id val) {
          (void)ivar;
          if (pfwTreeObject(val))
              pfuWalk(val, st, iv, loops + 1);
          else
              for (id e in (NSArray*)val)
                  pfuWalk(e, st, iv, loops + 1);
        });
        return;
        }
    if ([n isKindOfClass:[XTCallExprNode class]])
        {
        XTCallExprNode* c = n;
        if (c.isIndirectCall || !XTParFuseMath(c.calleeName))
            {
            st[@"bad"] = @YES;
            return;
            }
        for (XTASTNode* a in c.arguments)
            pfuWalk(a, st, iv, loops);
        return;
        }
    if ([n isKindOfClass:[XTMethodCallExprNode class]])
        {
        XTMethodCallExprNode* c = n;
        if (![c.receiver isKindOfClass:[XTIdentifierNode class]] || ![((XTIdentifierNode*)c.receiver).identName isEqualToString:@"Math"] ||
            !XTParFuseMath(c.methodName))
            {
            st[@"bad"] = @YES;
            return;
            }
        for (XTASTNode* a in c.arguments)
            pfuWalk(a, st, iv, loops);
        return;
        }
    if ([n isKindOfClass:[XTVariableDeclNode class]])
        {
        XTVariableDeclNode* d = n;
        [st[@"decls"] addObject:d.varName];
        if ([d.declaredType isKindOfClass:[XTArrayType class]])
            [st[@"arrays"] addObject:d.varName];
        pfuWalk(d.initialiser, st, iv, loops);
        for (XTASTNode* a in d.constructorArgs)
            pfuWalk(a, st, iv, loops);
        return;
        }
    if ([n isKindOfClass:[XTAssignExprNode class]])
        {
        XTAssignExprNode* a = n;
        pfuTarget(st, a.lhs, iv, a.assignOp == XTAssignOpAssign ? 2 : 3, loops);
        pfuWalk(a.rhs, st, iv, loops);
        return;
        }
    if ([n isKindOfClass:[XTPostfixExprNode class]])
        {
        pfuTarget(st, ((XTPostfixExprNode*)n).operand, iv, 3, loops);
        return;
        }
    if ([n isKindOfClass:[XTUnaryExprNode class]])
        {
        XTUnaryExprNode* u = n;
        if (u.op == XTUnaryOpPreInc || u.op == XTUnaryOpPreDec)
            {
            pfuTarget(st, u.operand, iv, 3, loops);
            return;
            }
        if (u.op == XTUnaryOpAddrOf || u.op == XTUnaryOpDeref)
            {
            // An address taken, or a pointer read: what it reaches is not
            // known, so its array is touched everywhere.
            NSString* root = pfuRoot(u.operand);
            if (!root)
                {
                st[@"bad"] = @YES;
                return;
                }
            pfuNote(st, root, 7);
            [st[@"names"] addObject:root];
            pfuWalk(u.operand, st, iv, loops);
            return;
            }
        }
    if ([n isKindOfClass:[XTSubscriptExprNode class]])
        {
        pfuAccess(st, n, iv, 1, loops);
        return;
        }
    if ([n isKindOfClass:[XTIdentifierNode class]])
        {
        [st[@"names"] addObject:((XTIdentifierNode*)n).identName];
        [st[@"bare"] addObject:((XTIdentifierNode*)n).identName];
        return;
        }
    if ([n isKindOfClass:[XTMemberAccessNode class]] && ((XTMemberAccessNode*)n).isArrow)
        {
        st[@"bad"] = @YES;
        return;
        }
    pfwEachIvar(n, ^(Ivar ivar, id val) {
      (void)ivar;
      if (pfwTreeObject(val))
          pfuWalk(val, st, iv, loops);
      else
          for (id e in (NSArray*)val)
              pfuWalk(e, st, iv, loops);
    });
    }

NSMutableDictionary* XTParFuseScan(XTASTNode* body, NSString* iv)
    {
    NSMutableDictionary* st = [@{
        @"acc" : [NSMutableDictionary dictionary],
        @"names" : [NSMutableSet set],
        @"bare" : [NSMutableSet set],
        @"scalars" : [NSMutableSet set],
        @"decls" : [NSMutableSet set],
        @"arrays" : [NSMutableSet set],
    } mutableCopy];
    pfuWalk(body, st, iv, 0);
    // A name read whole (passed on, copied into a pointer) is touched at
    // every index.
    NSMutableDictionary* acc = st[@"acc"];
    for (NSString* b in st[@"bare"])
        if (acc[b])
            pfuNote(st, b, 4);
    // An element access through a name the body declares that is not an
    // array of its own: what it reaches is not known.
    for (NSString* a in acc)
        if ([st[@"decls"] containsObject:a] && ![st[@"arrays"] containsObject:a])
            st[@"bad"] = @YES;
    return st;
    }

// The same bound: numbers, names and arithmetic on them, alike.
BOOL XTParFuseSame(XTASTNode* _Nullable a, XTASTNode* _Nullable b)
    {
    if (!a || !b)
        return a == b;
    if ([a class] != [b class])
        return NO;
    if ([a isKindOfClass:[XTLiteralIntNode class]])
        return ((XTLiteralIntNode*)a).intValue == ((XTLiteralIntNode*)b).intValue;
    if ([a isKindOfClass:[XTIdentifierNode class]])
        return [((XTIdentifierNode*)a).identName isEqualToString:((XTIdentifierNode*)b).identName];
    if ([a isKindOfClass:[XTBinaryExprNode class]])
        return ((XTBinaryExprNode*)a).op == ((XTBinaryExprNode*)b).op &&
               XTParFuseSame(((XTBinaryExprNode*)a).left, ((XTBinaryExprNode*)b).left) &&
               XTParFuseSame(((XTBinaryExprNode*)a).right, ((XTBinaryExprNode*)b).right);
    if ([a isKindOfClass:[XTCastExprNode class]])
        return [((XTCastExprNode*)a).castType.description isEqualToString:((XTCastExprNode*)b).castType.description] &&
               XTParFuseSame(((XTCastExprNode*)a).operand, ((XTCastExprNode*)b).operand);
    if ([a isKindOfClass:[XTUnaryExprNode class]])
        return ((XTUnaryExprNode*)a).op == ((XTUnaryExprNode*)b).op &&
               XTParFuseSame(((XTUnaryExprNode*)a).operand, ((XTUnaryExprNode*)b).operand);
    return NO;
    }

// A bound both loops may share: numbers, names neither body writes, and
// arithmetic on them.
BOOL XTParFuseBound(XTASTNode* _Nullable e, NSSet* written)
    {
    if ([e isKindOfClass:[XTLiteralIntNode class]])
        return YES;
    if ([e isKindOfClass:[XTIdentifierNode class]])
        return ![written containsObject:((XTIdentifierNode*)e).identName];
    if ([e isKindOfClass:[XTBinaryExprNode class]])
        return XTParFuseBound(((XTBinaryExprNode*)e).left, written) && XTParFuseBound(((XTBinaryExprNode*)e).right, written);
    if ([e isKindOfClass:[XTCastExprNode class]])
        return XTParFuseBound(((XTCastExprNode*)e).operand, written);
    if ([e isKindOfClass:[XTUnaryExprNode class]] && ((XTUnaryExprNode*)e).op == XTUnaryOpNeg)
        return XTParFuseBound(((XTUnaryExprNode*)e).operand, written);
    return NO;
    }

// A maths function a block may call on any device.
BOOL XTParFuseMath(NSString* _Nullable n)
    {
    static NSSet* ok;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      ok = [NSSet setWithArray:[@"sqrt sqrtf sin sinf cos cosf tan tanf exp expf exp2 exp2f log logf log2 log2f log10 log10f "
                                @"pow powf fabs fabsf floor floorf ceil ceilf round roundf trunc truncf fmin fminf fmax fmaxf "
                                @"fmod fmodf atan atanf atan2 atan2f asin asinf acos acosf tanh tanhf sinh sinhf cosh coshf "
                                @"abs min max rsqrt rsqrtf fma fmaf" componentsSeparatedByString:@" "]];
    });
    return n && [ok containsObject:n];
    }

// The loop's body replaced (the fused body).
void XTParFuseSetBody(XTForCStyleNode* loop, XTASTNode* body)
    {
    pfwSetIvar(loop, class_getInstanceVariable([XTForCStyleNode class], "_body"), body);
    }

// `old` replaced by `rep` where the tree under `obj` holds it. Whether it was.
static BOOL pfwReplace(id obj, id old, id rep)
    {
    __block BOOL done = NO;
    pfwEachIvar(obj, ^(Ivar iv, id val) {
        if (done)
            return;
        if (val == old)
            {
            pfwSetIvar(obj, iv, rep);
            done = YES;
            return;
            }
        if ([val isKindOfClass:[NSArray class]])
            {
            NSMutableArray* a = (NSMutableArray*)val;
            for (NSUInteger k = 0; k < a.count && !done; k++)
                {
                if (a[k] == old)
                    {
                    a[k] = rep;
                    done = YES;
                    }
                else if (pfwTreeObject(a[k]))
                    done = pfwReplace(a[k], old, rep);
                }
            return;
            }
        done = pfwReplace(val, old, rep);
    });
    return done;
    }

/****************************************************************************\
|* The goals of a lifted loop's copy, as a parse in the block's frame read
|* them: a loop without a goal of its own takes `g`, the goal around it, the
|* block's for the lifted loop, and a C-style loop with one of its own passes
|* that on to its body (parseFor, parseWhile). As the port.
\****************************************************************************/
void parAutoGoals(XTASTNode* n, NSInteger g)
    {
    if ([n isKindOfClass:[XTForCStyleNode class]])
        {
        XTForCStyleNode* f = (XTForCStyleNode*)n;
        if ((f.srcFacts & XTSrcGoal) && f.goal != 0)
            g = f.goal;
        else
            f.goal = g;
        }
    else if ([n isKindOfClass:[XTWhileNode class]])
        ((XTWhileNode*)n).goal = g;
    else if ([n isKindOfClass:[XTForInNode class]])
        ((XTForInNode*)n).goal = g;
    pfwEachIvar(n, ^(Ivar iv, id val) {
        if ([val isKindOfClass:[NSArray class]])
            {
            for (id e in (NSArray*)val)
                if (pfwTreeObject(e))
                    parAutoGoals(e, g);
            }
        else
            parAutoGoals(val, g);
    });
    }

@implementation XTParser (ParFrame)

/****************************************************************************\
|* A literal's mk call (kind 0), or a nested written (1) or automatic (2) par
|* block's site, with the body the parser read for it, the literal's
|* parameters, the names the site noted, and for an automatic block the loop
|* as written. Only inside a par body, whose walk reads it.
\****************************************************************************/
- (void)pfwRegister:(nullable XTASTNode*)site
               body:(nullable XTASTNode*)body
             params:(nullable NSArray<XTParamNode*>*)params
              noted:(nullable NSArray<NSString*>*)noted
               kind:(NSUInteger)kind
              plain:(nullable XTASTNode*)plain
    {
    if (!site || !body)
        return;
    if (kind == 0)
        [self plRegister:site entry:@{ @"kind" : @(kind), @"body" : body, @"params" : params ?: @[] }];
    BOOL inPar = NO;
    for (NSDictionary* f in [self blkFrames])
        if ([f[@"par"] boolValue])
            inPar = YES;
    if (!inPar)
        return;
    if (!self.pfwSites)
        self.pfwSites = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
                                              valueOptions:NSPointerFunctionsStrongMemory];
    NSMutableDictionary* e = [NSMutableDictionary dictionary];
    e[@"body"] = body;
    e[@"params"] = params ?: @[];
    e[@"noted"] = noted ? [noted copy] : @[];
    e[@"kind"] = @(kind);
    if (plain)
        e[@"plain"] = plain;
    [self.pfwSites setObject:e forKey:site];
    }

/****************************************************************************\
|* The frame of `body`, a par body (a block) or a lifted loop, parsed in
|* `frame`: names, types, bases, wb, outer, written, refs, subBase,
|* memWritten, updates, exits and gridUsed.
\****************************************************************************/
- (NSMutableDictionary*)parFrameWalk:(XTASTNode*)body frame:(NSDictionary*)frame
    {
    NSMutableDictionary* w = [NSMutableDictionary dictionary];
    w[@"depth"] = frame[@"depth"];
    w[@"names"] = [NSMutableArray array];
    w[@"types"] = [NSMutableDictionary dictionary];
    w[@"bases"] = [NSMutableDictionary dictionary];
    w[@"wb"] = [NSMutableSet set];
    w[@"written"] = [NSMutableSet set];
    if (frame[@"grid"])
        w[@"gridUsed"] = [NSMutableSet set];
    NSMutableDictionary* savedW = self.pfw;
    BOOL savedTop = self.pfwTop;
    self.pfw = w;
    self.pfwTop = YES;
    [self blkPushScope];
    [self pfwNode:body];
    [self blkPopScope];
    self.pfw = savedW;
    self.pfwTop = savedTop;
    return w;
    }

- (void)pfwNodes:(nullable NSArray<XTASTNode*>*)nodes
    {
    for (XTASTNode* n in nodes)
        [self pfwNode:n];
    }

- (void)pfwNode:(nullable XTASTNode*)n
    {
    if (!n)
        return;
    if ([n isKindOfClass:[XTIdentifierNode class]])
        {
        NSString* name = ((XTIdentifierNode*)n).identName;
        if (n.srcFacts & XTSrcSynth)
            [self pfwGridName:name];
        else
            [self pfwUse:name];
        return;
        }
    if (n.srcFacts & XTSrcSynth)
        return;
    if (self.pfwAuto && [n isKindOfClass:[XTMemberAccessNode class]])
        {
        XTIdentifierNode* f = [self pfwSelfIvar:(XTMemberAccessNode*)n];
        if (f)
            {
            pfwReplace(self.pfwRoot, n, f);
            [self pfwUse:f.identName];
            return;
            }
        }
    NSDictionary* site = self.pfwSites ? [self.pfwSites objectForKey:n] : nil;
    if (site)
        {
        [self pfwSite:n entry:site];
        return;
        }
    if ([n isKindOfClass:[XTBlockNode class]])
        {
        XTBlockNode* b = (XTBlockNode*)n;
        if (b.isDeclList)
            {
            [self pfwNodes:b.statements];
            return;
            }
        [self blkPushScope];
        [self pfwNodes:b.statements];
        [self blkPopScope];
        return;
        }
    if ([n isKindOfClass:[XTVariableDeclNode class]])
        {
        // Bound once its initialiser (or constructor arguments) is read.
        XTVariableDeclNode* d = (XTVariableDeclNode*)n;
        [self pfwNode:d.initialiser];
        [self pfwNodes:d.constructorArgs];
        [self blkBind:d.varName type:d.declaredType];
        if (!d.declaredType || d.declaredType.kind == XTTypeKindAuto)
            [self blkBindAuto:d.varName fromInit:d.initialiser];
        return;
        }
    if ([n isKindOfClass:[XTForCStyleNode class]])
        {
        XTForCStyleNode* f = (XTForCStyleNode*)n;
        XTVariableDeclNode* d = [f.loopInit isKindOfClass:[XTVariableDeclNode class]] ? (XTVariableDeclNode*)f.loopInit : nil;
        if (f.srcFacts & XTSrcRange)
            {
            // A range: its bounds, then the body with the variable bound; the
            // condition's and the step's use of the variable are the parser's.
            [self pfwNode:d.initialiser];
            if ([f.condition isKindOfClass:[XTBinaryExprNode class]])
                [self pfwNode:((XTBinaryExprNode*)f.condition).right];
            [self blkPushScope];
            if (d)
                [self blkBind:d.varName type:d.declaredType];
            [self pfwNode:f.body];
            [self blkPopScope];
            return;
            }
        // The variable is bound from the condition on (parseFor).
        if (d)
            [self pfwNode:d.initialiser];
        else
            [self pfwNode:f.loopInit];
        [self blkPushScope];
        if (d)
            [self blkBind:d.varName type:d.declaredType];
        [self pfwNode:f.condition];
        [self pfwNode:f.increment];
        [self pfwNode:f.body];
        [self blkPopScope];
        return;
        }
    if ([n isKindOfClass:[XTForInNode class]])
        {
        XTForInNode* f = (XTForInNode*)n;
        [self pfwNode:f.collection];
        [self blkPushScope];
        if ([f.loopVar isKindOfClass:[XTVariableDeclNode class]])
            {
            XTVariableDeclNode* v = (XTVariableDeclNode*)f.loopVar;
            [self blkBind:v.varName type:v.declaredType];
            }
        [self pfwNode:f.body];
        [self blkPopScope];
        return;
        }
    if ([n isKindOfClass:[XTTupleAssignNode class]])
        {
        // The value, then the declared targets are bound; a bare target is
        // read as a token, not as a name.
        XTTupleAssignNode* t = (XTTupleAssignNode*)n;
        [self pfwNode:t.sourceExpr];
        for (XTASTNode* d in t.targets)
            if ([d isKindOfClass:[XTVariableDeclNode class]])
                [self blkBind:((XTVariableDeclNode*)d).varName type:((XTVariableDeclNode*)d).declaredType];
        return;
        }
    if ([n isKindOfClass:[XTAssignExprNode class]])
        {
        XTAssignExprNode* a = (XTAssignExprNode*)n;
        [self pfwNode:a.lhs];
        [self pfwNode:a.rhs];
        [self pfwWrite:a.lhs];
        [self pfwUpdate:a.lhs op:a.assignOp rhs:a.rhs];
        return;
        }
    if ([n isKindOfClass:[XTUnaryExprNode class]])
        {
        XTUnaryExprNode* u = (XTUnaryExprNode*)n;
        [self pfwNode:u.operand];
        if (u.op == XTUnaryOpAddrOf)
            [self pfwMemWrite:u.operand];
        if (u.op == XTUnaryOpPreInc || u.op == XTUnaryOpPreDec)
            [self pfwWrite:u.operand];
        return;
        }
    if ([n isKindOfClass:[XTPostfixExprNode class]])
        {
        XTPostfixExprNode* p = (XTPostfixExprNode*)n;
        [self pfwNode:p.operand];
        [self pfwWrite:p.operand];
        if (p.postfixOp == XTPostfixOpInc)
            [self pfwUpdate:p.operand op:XTAssignOpAdd rhs:nil];
        return;
        }
    if ([n isKindOfClass:[XTSubscriptExprNode class]])
        {
        XTSubscriptExprNode* s = (XTSubscriptExprNode*)n;
        [self pfwNode:s.base];
        [self pfwNode:s.index];
        if ([s.base isKindOfClass:[XTIdentifierNode class]])
            [self pfwCount:@"subBase" name:((XTIdentifierNode*)s.base).identName by:1];
        return;
        }
    if ([n isKindOfClass:[XTSliceExprNode class]])
        {
        XTSliceExprNode* s = (XTSliceExprNode*)n;
        [self pfwNode:s.base];
        [self pfwNode:s.startExpr];
        [self pfwNode:s.endExpr];
        return;
        }
    if ([n isKindOfClass:[XTCallExprNode class]])
        {
        // A callee that is not a name, read first. A name read as a name
        // (`(f)(x)`, or `delete(…)`) is a use before the arguments; a name
        // called as it is written is a use after them when it is a local or
        // a parameter (#437).
        XTCallExprNode* c = (XTCallExprNode*)n;
        if (c.calleeExpr)
            {
            [self pfwNode:c.calleeExpr];
            [self pfwNodes:c.arguments];
            return;
            }
        NSString* callee = c.calleeName;
        BOOL asName = (c.srcFacts & XTSrcParenCallee) || [callee isEqualToString:@"delete"] ||
                      [callee isEqualToString:@"retain"] || [callee isEqualToString:@"release"];
        if (asName)
            [self pfwUse:callee];
        [self pfwNodes:c.arguments];
        NSUInteger depth = 0;
        if (!asName && [self blkLookup:callee depth:&depth])
            [self pfwUse:callee];
        else if (!asName && self.pfwAuto && self.pfwTop)
            [self blkBareCallCheck:callee at:c.location];
        return;
        }
    if ([n isKindOfClass:[XTMethodCallExprNode class]])
        {
        XTMethodCallExprNode* m = (XTMethodCallExprNode*)n;
        if (m.srcFacts & XTSrcCalled)
            {
            // `b(…)` through a block binding: a use of b after the arguments.
            // A named literal calling itself is `self.invoke(…)`, no use.
            [self pfwNodes:m.arguments];
            if ([m.receiver isKindOfClass:[XTIdentifierNode class]] &&
                ![((XTIdentifierNode*)m.receiver).identName isEqualToString:@"self"])
                [self pfwUse:((XTIdentifierNode*)m.receiver).identName];
            return;
            }
        [self pfwNode:m.receiver];
        [self pfwNodes:m.arguments];
        return;
        }
    if ([n isKindOfClass:[XTMemberAccessNode class]])
        {
        [self pfwNode:((XTMemberAccessNode*)n).base];
        return;
        }
    if ([n isKindOfClass:[XTBinaryExprNode class]])
        {
        [self pfwNode:((XTBinaryExprNode*)n).left];
        [self pfwNode:((XTBinaryExprNode*)n).right];
        return;
        }
    if ([n isKindOfClass:[XTTernaryExprNode class]])
        {
        XTTernaryExprNode* t = (XTTernaryExprNode*)n;
        [self pfwNode:t.condition];
        [self pfwNode:t.thenExpr];
        [self pfwNode:t.elseExpr];
        return;
        }
    if ([n isKindOfClass:[XTCastExprNode class]])
        {
        [self pfwNode:((XTCastExprNode*)n).operand];
        return;
        }
    if ([n isKindOfClass:[XTRangeExprNode class]])
        {
        [self pfwNode:((XTRangeExprNode*)n).startExpr];
        [self pfwNode:((XTRangeExprNode*)n).endExpr];
        return;
        }
    if ([n isKindOfClass:[XTNewExprNode class]])
        {
        XTNewExprNode* e = (XTNewExprNode*)n;
        [self pfwNode:e.countExpr];
        [self pfwNodes:e.arguments];
        return;
        }
    if ([n isKindOfClass:[XTSizeofExprNode class]])
        {
        id o = ((XTSizeofExprNode*)n).operand;
        if ([o isKindOfClass:[XTASTNode class]])
            [self pfwNode:o];
        return;
        }
    if ([n isKindOfClass:[XTIfNode class]])
        {
        XTIfNode* i = (XTIfNode*)n;
        [self pfwNode:i.condition];
        [self pfwNode:i.thenBlock];
        [self pfwNode:i.elseBlock];
        return;
        }
    if ([n isKindOfClass:[XTWhileNode class]])
        {
        [self pfwNode:((XTWhileNode*)n).condition];
        [self pfwNode:((XTWhileNode*)n).body];
        return;
        }
    if ([n isKindOfClass:[XTReturnNode class]])
        {
        self.pfw[@"exits"] = @YES;
        [self pfwNodes:((XTReturnNode*)n).values];
        return;
        }
    if ([n isKindOfClass:[XTBreakNode class]] || [n isKindOfClass:[XTContinueNode class]])
        {
        self.pfw[@"exits"] = @YES;
        return;
        }
    if ([n isKindOfClass:[XTExpressionStatementNode class]])
        {
        [self pfwNode:((XTExpressionStatementNode*)n).expression];
        return;
        }
    if ([n isKindOfClass:[XTSwitchNode class]])
        {
        XTSwitchNode* s = (XTSwitchNode*)n;
        [self pfwNode:s.subject];
        for (XTSwitchCase* c in s.cases)
            {
            for (XTCaseLabel* l in c.labels)
                {
                [self pfwNode:l.singleValue];
                [self pfwNode:l.rangeLo];
                [self pfwNode:l.rangeHi];
                }
            [self pfwNodes:c.body];
            }
        return;
        }
    if ([n isKindOfClass:[XTDeferNode class]])
        {
        [self pfwNode:((XTDeferNode*)n).body];
        return;
        }
    if ([n isKindOfClass:[XTThrowNode class]])
        {
        [self pfwNode:((XTThrowNode*)n).operand];
        return;
        }
    if ([n isKindOfClass:[XTTryNode class]])
        {
        XTTryNode* t = (XTTryNode*)n;
        [self pfwNode:t.tryBlock];
        for (XTCatchClause* c in t.catchClauses)
            [self pfwNode:c.block];
        return;
        }
    if ([n isKindOfClass:[XTDeleteNode class]])
        {
        [self pfwNode:((XTDeleteNode*)n).operand];
        return;
        }
    }

/****************************************************************************\
|* A literal or a nested block, read as the parser read it: an automatic
|* block's loop as written first (parsed before the block), the body in its
|* own frame, then the names its site passes in.
\****************************************************************************/
- (void)pfwSite:(XTASTNode*)n entry:(NSDictionary*)e
    {
    NSUInteger kind = [e[@"kind"] unsignedIntegerValue];
    if (kind == 2)
        [self pfwNode:e[@"plain"]];
    BOOL savedTop = self.pfwTop;
    self.pfwTop = NO;
    [self blkPushScope];
    for (XTParamNode* p in e[@"params"])
        [self blkBind:p.paramName type:p.paramType];
    [self pfwNode:e[@"body"]];
    [self blkPopScope];
    self.pfwTop = savedTop;
    if (kind == 0)
        {
        // The mk call: its class reference and write-back slots are the
        // parser's, its capture arguments uses.
        [self pfwNodes:((XTMethodCallExprNode*)n).arguments];
        return;
        }
    for (NSString* name in e[@"noted"])
        [self pfwUse:name];
    }

- (void)pfwCount:(NSString*)key name:(NSString*)name by:(NSUInteger)by
    {
    NSMutableDictionary* m = self.pfw[key];
    if (!m)
        self.pfw[key] = m = [NSMutableDictionary dictionary];
    m[name] = @([m[name] unsignedIntegerValue] + by);
    }

/****************************************************************************\
|* A use of a name: counted, and at the body's own level a capture when it
|* resolves outside the body, or a global when it resolves nowhere.
\****************************************************************************/
- (void)pfwUse:(NSString*)name
    {
    [self pfwCount:@"refs" name:name by:1];
    if (!self.pfwTop)
        return;
    NSUInteger foundDepth = 0;
    NSDictionary* info = [self blkLookup:name depth:&foundDepth];
    if (!info)
        {
        if (self.pfwAuto && ([name isEqualToString:@"self"] || [self blkIsIvar:name]))
            [self blkCaptureError:0 name:name at:[self currentLocation]];
        else if (self.pfwAuto && [self blkIsLaterIvar:name])
            [self blkCaptureError:3 name:name at:[self currentLocation]];
        // A written block captures an ivar the class declares further down
        // as one declared above, with the type its declaration gives it
        // (#513). A lifted loop stays a loop instead (above).
        XTType* later = self.pfwAuto ? nil : [self blkLaterIvarType:name];
        if (later)
            {
            NSMutableArray* names = self.pfw[@"names"];
            if (![names containsObject:name])
                {
                [names addObject:name];
                self.pfw[@"types"][name] = later;
                }
            return;
            }
        NSMutableArray* outer = self.pfw[@"outer"];
        if (!outer)
            self.pfw[@"outer"] = outer = [NSMutableArray array];
        if (![outer containsObject:name])
            [outer addObject:name];
        return;
        }
    if (foundDepth >= [self.pfw[@"depth"] unsignedIntegerValue])
        return;
    id ty = info[@"type"];
    if (self.pfwAuto && ty == [NSNull null])
        {
        [self blkCaptureError:1 name:name at:[self currentLocation]];
        return;
        }
    // The frame is not on the stack: any frame there is one the loop sits in.
    if (self.pfwAuto && [info[@"wb"] boolValue] && [self blkFrames].count > 0)
        {
        [self blkCaptureError:2 name:name at:[self currentLocation]];
        return;
        }
    NSMutableArray* names = self.pfw[@"names"];
    if ([names containsObject:name])
        return;
    if (ty == [NSNull null])
        return;
    if ([info[@"wb"] boolValue])
        {
        // The frame itself is off the stack by now: any frame left is one
        // the block sits in.
        if ([self blkFrames].count > 0)
            return;
        [self.pfw[@"wb"] addObject:name];
        }
    [names addObject:name];
    self.pfw[@"types"][name] = ty;
    if (info[@"base"])
        self.pfw[@"bases"][name] = info[@"base"];
    }

/****************************************************************************\
|* `self.f` in a lifted loop's copy, `f` this class's own ivar binding where
|* it is read: the name f at the `self`, as the parse in the block's frame
|* read it (parSelfIvar), else nil.
\****************************************************************************/
- (nullable XTIdentifierNode*)pfwSelfIvar:(XTMemberAccessNode*)m
    {
    if (m.isArrow || ![m.base isKindOfClass:[XTIdentifierNode class]] || (m.base.srcFacts & XTSrcParen))
        return nil;
    if (![((XTIdentifierNode*)m.base).identName isEqualToString:@"self"])
        return nil;
    NSString* f = m.memberName;
    if ([f isEqualToString:@"release"] || [f isEqualToString:@"retain"] || [f isEqualToString:@"delete"])
        return nil;
    NSDictionary* info = [self blkLookup:f depth:NULL];
    if (![info[@"ivar"] boolValue])
        return nil;
    return [[XTIdentifierNode alloc] initWithName:f location:m.base.location];
    }

// `par.x` … in a `par :grid` body, which the parser reads as these names.
- (void)pfwGridName:(NSString*)name
    {
    NSMutableSet* used = self.pfw[@"gridUsed"];
    if (!self.pfwTop || !used)
        return;
    if ([@[ @"par$x", @"par$y", @"par$z", @"par$w", @"par$h", @"par$d" ] containsObject:name])
        [used addObject:name];
    }

// An assignment's target: a name the body writes, or an element or field of
// the array or struct it is rooted at (memWritten).
- (void)pfwWrite:(nullable XTASTNode*)t
    {
    [self pfwMemWrite:t];
    if (self.pfwTop && [t isKindOfClass:[XTIdentifierNode class]])
        [self.pfw[@"written"] addObject:((XTIdentifierNode*)t).identName];
    }

- (void)pfwMemWrite:(nullable XTASTNode*)t
    {
    if (!t || [t isKindOfClass:[XTIdentifierNode class]])
        return;
    NSString* root = parRootName(t);
    if (!root)
        return;
    NSMutableSet* mw = self.pfw[@"memWritten"];
    if (!mw)
        self.pfw[@"memWritten"] = mw = [NSMutableSet set];
    [mw addObject:root];
    }

- (void)pfwUpdate:(nullable XTASTNode*)t op:(XTAssignOp)aop rhs:(nullable XTASTNode*)rhs
    {
    NSUInteger uses = 0;
    NSString* key = parUpdateKey(t, aop, rhs, &uses);
    if (key)
        [self pfwCount:@"updates" name:key by:uses];
    }

/****************************************************************************\
|* The frame of a par body or a lifted loop parsed in `frame`, from its tree,
|* into `frame`, which parDesugarBody then reads.
\****************************************************************************/
- (void)parFrameFill:(NSMutableDictionary*)frame body:(nullable XTASTNode*)body
    {
    if (!body)
        return;
    NSDictionary* w = [self parFrameWalk:body frame:frame];
    for (NSString* k in w)
        if (![k isEqualToString:@"depth"])
            frame[k] = w[k];
    }

@end

NS_ASSUME_NONNULL_END
