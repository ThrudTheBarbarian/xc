#import "XTReachabilityAnalyzer.h"
#import "XTStmtNodes.h"
#import "XTExprNodes.h"
#import "XTType.h"
#import "XTPointerType.h"

/****************************************************************************\
|* Resolved-callee record. The label is the asm name (`_fn_foo` or
|* `_cls_Bar_method`); `body` is the statement subtree to walk when
|* this callee is first reached. Stored in a dictionary keyed on
|* label so the worklist can cheaply deduplicate.
\****************************************************************************/
@interface XTReachableDecl : NSObject
@property(nonatomic) NSString* label;
@property(nonatomic, nullable) XTASTNode* body;
// Class name for methods; nil for free functions. Used to auto-
// mark the class's init method when any other method of the class
// is reached.
@property(nonatomic, nullable) NSString* className;
@end
@implementation XTReachableDecl
@end

@interface XTReachabilityAnalyzer ()
@property(nonatomic) XTProgramNode* program;

// Name → body index. Used to look up a called function's body.
// Free functions: key is mangled name (e.g. "fpAdd__f_f").
@property(nonatomic) NSMutableDictionary<NSString*, XTFunctionDeclNode*>* funcByMangled;
// Fallback name index for calls that don't carry a resolvedMangled
// name (sema only populates it for overloaded calls; single-
// candidate calls may have just the bare `calleeName`).
@property(nonatomic) NSMutableDictionary<NSString*, NSMutableArray<XTFunctionDeclNode*>*>* funcByName;

// Class methods: key is "<Class>::<mangled>".
@property(nonatomic) NSMutableDictionary<NSString*, XTMethodDeclNode*>* methodByKey;
// Fallback "Class::methodName" → list of methods with that name.
@property(nonatomic) NSMutableDictionary<NSString*, NSMutableArray<XTMethodDeclNode*>*>* methodByClassAndName;
// Class name → class node (for looking up init when a class is touched).
@property(nonatomic) NSMutableDictionary<NSString*, XTClassDeclNode*>* classesByName;

// Smarter vtable reachability state. Populated lazily during the
// reachable walk:
//   instantiatedClasses — every class C seen in `new C` inside
//                         already-reachable code.
//   calledSlots         — every vtable slot index whose method
//                         got dispatched virtually somewhere in
//                         already-reachable code.
//
// On expansion of either set we replay the cross product against
// the other, adding only the new (slot, class) pairs to the
// worklist — the existing reachable check inside enqueueMethod
// handles the dedup.
@property(nonatomic) NSMutableSet<NSString*>* instantiatedClasses;
@property(nonatomic) NSMutableSet<NSNumber*>* calledSlots;

@property(nonatomic, nullable) NSSet<NSString*>* cachedResult;
@end

@implementation XTReachabilityAnalyzer

- (instancetype)initWithProgram:(XTProgramNode*)program
    {
    self = [super init];
    if (self)
        {
        _program = program;
        _funcByMangled = [NSMutableDictionary dictionary];
        _funcByName = [NSMutableDictionary dictionary];
        _methodByKey = [NSMutableDictionary dictionary];
        _methodByClassAndName = [NSMutableDictionary dictionary];
        _classesByName = [NSMutableDictionary dictionary];
        _instantiatedClasses = [NSMutableSet set];
        _calledSlots = [NSMutableSet set];
        [self indexDeclarations];
        }
    return self;
    }

- (void)indexDeclarations
    {
    for (XTASTNode* decl in _program.declarations)
        {
        if ([decl isKindOfClass:[XTFunctionDeclNode class]])
            {
            XTFunctionDeclNode* fn = (XTFunctionDeclNode*)decl;
            NSString* mangled = fn.mangledName ?: fn.funcName;
            _funcByMangled[mangled] = fn;
            NSMutableArray* bucket = _funcByName[fn.funcName];
            if (!bucket)
                {
                bucket = [NSMutableArray array];
                _funcByName[fn.funcName] = bucket;
                }
            [bucket addObject:fn];
            }
        else if ([decl isKindOfClass:[XTClassDeclNode class]])
            {
            XTClassDeclNode* cls = (XTClassDeclNode*)decl;
            _classesByName[cls.className] = cls;
            for (XTMethodDeclNode* m in cls.methods)
                {
                NSString* mangled = m.mangledName ?: m.methodName;
                NSString* key = [NSString stringWithFormat:@"%@::%@", cls.className, mangled];
                _methodByKey[key] = m;
                NSString* nameKey = [NSString stringWithFormat:@"%@::%@", cls.className, m.methodName];
                NSMutableArray* bucket = _methodByClassAndName[nameKey];
                if (!bucket)
                    {
                    bucket = [NSMutableArray array];
                    _methodByClassAndName[nameKey] = bucket;
                    }
                [bucket addObject:m];
                }
            }
        }
    }

- (NSString*)labelForFunction:(XTFunctionDeclNode*)fn
    {
    return [NSString stringWithFormat:@"_fn_%@", fn.mangledName ?: fn.funcName];
    }

- (NSString*)labelForMethod:(XTMethodDeclNode*)m inClass:(NSString*)className
    {
    return [NSString stringWithFormat:@"_cls_%@_%@", className, m.mangledName ?: m.methodName];
    }

- (NSSet<NSString*>*)instantiatedClassNames
    {
    // Read after `reachableLabels` populates `_instantiatedClasses`
    // as a side effect of the worklist walk. Returns a defensive
    // copy so callers can't mutate our internal state.
    return [_instantiatedClasses copy];
    }

- (NSSet<NSString*>*)reachableLabels
    {
    if (_cachedResult)
        return _cachedResult;

    NSMutableSet<NSString*>* reachable = [NSMutableSet set];
    NSMutableArray<XTReachableDecl*>* worklist = [NSMutableArray array];

    // Seed worklist with main. Every xtc program has a main (entry
    // point); if it's missing, the binary wouldn't be runnable
    // anyway so returning an empty reachable set just means
    // everything gets filtered out and the user hits a real linker
    // error they'd have seen regardless.
    XTFunctionDeclNode* mainFn = _funcByMangled[@"main"] ?: _funcByName[@"main"].firstObject;
    if (mainFn)
        {
        [self enqueueFunction:mainFn intoReachable:reachable worklist:worklist];
        }

    // :irq and :vbi handlers are entry points reached by hardware (or
    // by a runtime install routine that pokes their address into a
    // vector slot). They're not part of any static call graph from
    // main, so without seeding them as roots the reachability filter
    // strips them out.
    for (NSString* mangled in _funcByMangled)
        {
        XTFunctionDeclNode* fn = _funcByMangled[mangled];
        if (fn.isIrq || fn.isVbi)
            {
            [self enqueueFunction:fn intoReachable:reachable worklist:worklist];
            }
        }

    // Drain.
    while (worklist.count > 0)
        {
        XTReachableDecl* rd = [worklist lastObject];
        [worklist removeLastObject];
        // Walk the body collecting every callee and address-taken
        // identifier.
        [self walkNode:rd.body
                 reachable:reachable
                  worklist:worklist
            enclosingClass:rd.className];
        }

    // Auto-restore-on-exit hook. The codegen emits a `JSR
    // _cls_Gfx_atExit` after `_fn_main` returns iff Gfx is in the
    // reachable set, so the user's last-drawn frame doesn't stay
    // on screen when control returns to the loader. atExit isn't
    // called from any user code — its presence in the reachable
    // set is gated solely on Gfx.setMode being reachable. Pulling
    // it in here (after the main worklist drains) keeps the user-
    // visible reachability rules simple while making the exit
    // hook live whenever the rest of Gfx is.
    if ([reachable containsObject:@"_cls_Gfx_setMode"])
        {
        XTMethodDeclNode* atExit = _methodByKey[@"Gfx::atExit"];
        if (atExit)
            {
            [self enqueueMethod:atExit
                        inClass:@"Gfx"
                  intoReachable:reachable
                       worklist:worklist];
            // Drain again — atExit calls setMode (already in
            // reach) but might pull in additional helpers if
            // future code paths grow.
            while (worklist.count > 0)
                {
                XTReachableDecl* rd = [worklist lastObject];
                [worklist removeLastObject];
                [self walkNode:rd.body
                         reachable:reachable
                          worklist:worklist
                    enclosingClass:rd.className];
                }
            }
        }

    _cachedResult = [reachable copy];
    return _cachedResult;
    }

- (void)enqueueFunction:(XTFunctionDeclNode*)fn
          intoReachable:(NSMutableSet<NSString*>*)reachable
               worklist:(NSMutableArray<XTReachableDecl*>*)worklist
    {
    NSString* label = [self labelForFunction:fn];
    if ([reachable containsObject:label])
        return;
    [reachable addObject:label];
    XTReachableDecl* rd = [[XTReachableDecl alloc] init];
    rd.label = label;
    rd.body = fn.body;
    rd.className = nil;
    [worklist addObject:rd];
    }

/****************************************************************************\
|* For class `C` (or its nearest ancestor that fills slot S), find
|* the method body whose label is mapped to `slotIndex` in
|* `_virtualSlotByLabel` and enqueue it. Used when a previously-
|* unreached cross product (instantiated class × called slot) opens
|* up. Returns silently when no class in the chain has a method
|* in this slot — common for protocol slots dispatched through a
|* receiver of a class that doesn't conform.
\****************************************************************************/
- (void)enqueueSlot:(NSUInteger)slotIndex
            onClass:(NSString*)className
      intoReachable:(NSMutableSet<NSString*>*)reachable
           worklist:(NSMutableArray<XTReachableDecl*>*)worklist
    {
    if (!_virtualSlotByLabel)
        return;
    XTClassDeclNode* cls = _classesByName[className];
    while (cls != nil)
        {
        for (XTMethodDeclNode* m in cls.methods)
            {
            NSString* lbl = [self labelForMethod:m inClass:cls.className];
            NSNumber* s = _virtualSlotByLabel[lbl];
            if (s && s.unsignedIntegerValue == slotIndex)
                {
                [self enqueueMethod:m
                            inClass:cls.className
                      intoReachable:reachable
                           worklist:worklist];
                return;
                }
            }
        cls = cls.parentClass;
        }
    }

/****************************************************************************\
|* Record `className` as instantiated (idempotent) and replay the
|* cross product against every previously-recorded called slot.
\****************************************************************************/
- (void)markClassInstantiated:(NSString*)className
                intoReachable:(NSMutableSet<NSString*>*)reachable
                     worklist:(NSMutableArray<XTReachableDecl*>*)worklist
    {
    if ([_instantiatedClasses containsObject:className])
        return;
    [_instantiatedClasses addObject:className];
    for (NSNumber* slot in _calledSlots)
        {
        [self enqueueSlot:slot.unsignedIntegerValue
                  onClass:className
            intoReachable:reachable
                 worklist:worklist];
        }
    }

/****************************************************************************\
|* Record vtable slot `slotIndex` as virtually called (idempotent)
|* and replay the cross product against every previously-instantiated
|* class.
\****************************************************************************/
- (void)markSlotCalled:(NSUInteger)slotIndex
         intoReachable:(NSMutableSet<NSString*>*)reachable
              worklist:(NSMutableArray<XTReachableDecl*>*)worklist
    {
    NSNumber* key = @(slotIndex);
    if ([_calledSlots containsObject:key])
        return;
    [_calledSlots addObject:key];
    for (NSString* className in _instantiatedClasses)
        {
        [self enqueueSlot:slotIndex
                  onClass:className
            intoReachable:reachable
                 worklist:worklist];
        }
    }

/****************************************************************************\
|* Protocol-call dispatch fallback. The receiver's static type is a
|* protocol, not a class, so the per-class chain walk that
|* emitMethodCallExpr does for class-typed receivers can't find the
|* implementation here. Instead, scan virtualSlotByLabel for every
|* `_cls_<C>_<m>` label whose method name matches the call (by
|* mangled name when stamped, otherwise bare name) and mark each
|* found slot called. The cross-product replay then enqueues every
|* instantiated class's matching slot fill — covering every
|* conforming class without the analyser needing the protocol →
|* slot map directly.
\****************************************************************************/
- (void)markSlotsForProtocolCallNamed:(NSString*)bareName
                              mangled:(NSString* _Nullable)mangledName
                        intoReachable:(NSMutableSet<NSString*>*)reachable
                             worklist:(NSMutableArray<XTReachableDecl*>*)worklist
    {
    for (NSString* label in _virtualSlotByLabel)
        {
        // Label form: `_cls_<Class>_<mangled>`. Skip everything else.
        if (![label hasPrefix:@"_cls_"])
            continue;
        NSString* rest = [label substringFromIndex:5];
        NSRange sep = [rest rangeOfString:@"_"];
        if (sep.location == NSNotFound)
            continue;
        NSString* clsName = [rest substringToIndex:sep.location];
        NSString* methodKey = [rest substringFromIndex:sep.location + 1];
        // Match either by mangled name (preferred — overload-aware)
        // or by the underlying method name extracted by stripping
        // the trailing `__<mangle>` suffix sema appends. Fall back
        // to a bare equality with the original bareName when the
        // mangle stripper doesn't apply.
        BOOL match = NO;
        if (mangledName.length > 0 && [methodKey isEqualToString:mangledName])
            {
            match = YES;
            }
        else
            {
            NSRange mangleSep = [methodKey rangeOfString:@"__"];
            NSString* plainName = (mangleSep.location != NSNotFound)
                                      ? [methodKey substringToIndex:mangleSep.location]
                                      : methodKey;
            if ([plainName isEqualToString:bareName])
                match = YES;
            }
        if (!match)
            continue;
        NSNumber* slot = _virtualSlotByLabel[label];
        if (slot)
            {
            [self markSlotCalled:slot.unsignedIntegerValue
                   intoReachable:reachable
                        worklist:worklist];
            // Also enqueue the conforming class's method directly —
            // some programs construct the conforming class only
            // through a protocol-typed factory (no `new` site is
            // walked before the call), and the cross-product replay
            // would miss it. The class's vtable still references
            // the method label, so emit the body either way.
            NSString* clsKey = [NSString stringWithFormat:@"%@::%@", clsName, methodKey];
            XTMethodDeclNode* m = _methodByKey[clsKey];
            if (m)
                {
                [self enqueueMethod:m
                            inClass:clsName
                      intoReachable:reachable
                           worklist:worklist];
                }
            }
        }
    }

- (void)enqueueMethod:(XTMethodDeclNode*)m
              inClass:(NSString*)className
        intoReachable:(NSMutableSet<NSString*>*)reachable
             worklist:(NSMutableArray<XTReachableDecl*>*)worklist
    {
    NSString* label = [self labelForMethod:m inClass:className];
    if ([reachable containsObject:label])
        return;
    [reachable addObject:label];
    XTReachableDecl* rd = [[XTReachableDecl alloc] init];
    rd.label = label;
    rd.body = m.body;
    rd.className = className;
    [worklist addObject:rd];

    // Auto-reach the class's `init` method — first-use dispatch
    // calls it before any other method runs. If it's already in
    // the set or doesn't exist, the recursion just no-ops.
    XTClassDeclNode* cls = _classesByName[className];
    if (cls)
        {
        for (XTMethodDeclNode* other in cls.methods)
            {
            if ([other.methodName isEqualToString:@"init"])
                {
                [self enqueueMethod:other inClass:className intoReachable:reachable worklist:worklist];
                break;
                }
            }
        }

    // PR5: if the enqueued method is an init flagged for auto-
    // super.init, codegen will emit a JSR into the parent's no-arg
    // init that isn't visible as an AST call node. Walk the chain
    // so every ancestor init in the synthesised chain lands in the
    // reachable set.
    if (cls && [m.methodName isEqualToString:@"init"] && m.autoSuperInit)
        {
        for (XTClassDeclNode* p = cls.parentClass; p != nil; p = p.parentClass)
            {
            XTMethodDeclNode* parentInit = nil;
            for (XTMethodDeclNode* pm in p.methods)
                {
                if ([pm.methodName isEqualToString:@"init"] &&
                    pm.parameters.count == 0)
                    {
                    parentInit = pm;
                    break;
                    }
                }
            if (!parentInit)
                break;
            [self enqueueMethod:parentInit
                        inClass:p.className
                  intoReachable:reachable
                       worklist:worklist];
            if (!parentInit.autoSuperInit)
                break;
            }
        }

    // PR6: dealloc auto-chain. Same shape as the init walker above
    // but for the child-first dealloc chain — enqueue the nearest
    // ancestor that declares a dealloc, and if that ancestor also
    // auto-chains, walk further up so every ancestor in the chain
    // becomes reachable.
    if (cls && [m.methodName isEqualToString:@"dealloc"] && m.autoSuperDealloc)
        {
        for (XTClassDeclNode* p = cls.parentClass; p != nil; p = p.parentClass)
            {
            XTMethodDeclNode* parentDealloc = nil;
            for (XTMethodDeclNode* pm in p.methods)
                {
                if ([pm.methodName isEqualToString:@"dealloc"])
                    {
                    parentDealloc = pm;
                    break;
                    }
                }
            if (!parentDealloc)
                continue;
            [self enqueueMethod:parentDealloc
                        inClass:p.className
                  intoReachable:reachable
                       worklist:worklist];
            if (!parentDealloc.autoSuperDealloc)
                break;
            }
        }
    }

/****************************************************************************\
|* PR3 helpers: resolve a method by name through a class's inheritance
|* chain. `lookupSelfMethodInChain` mirrors the sema-side walk so the
|* reachability trim doesn't silently drop an inherited callee.
|* `ownerClassFor` reports the ancestor that declares a given method,
|* so enqueueing uses the correct `_cls_<owner>_<mangled>` label.
\****************************************************************************/
- (nullable XTMethodDeclNode*)lookupSelfMethodInChain:(NSString*)leafClassName
                                              mangled:(NSString*)mangled
                                             bareName:(NSString*)bareName
                                        outOwnerClass:(NSString**)outOwnerClass
    {
    XTClassDeclNode* leaf = _classesByName[leafClassName];
    for (XTClassDeclNode* c = leaf; c != nil; c = c.parentClass)
        {
        NSString* key = [NSString stringWithFormat:@"%@::%@", c.className, mangled];
        XTMethodDeclNode* m = _methodByKey[key];
        if (!m)
            {
            NSString* nameKey = [NSString stringWithFormat:@"%@::%@", c.className, bareName];
            m = _methodByClassAndName[nameKey].firstObject;
            }
        if (m)
            {
            if (outOwnerClass)
                *outOwnerClass = c.className;
            return m;
            }
        }
    return nil;
    }

- (NSString*)ownerClassFor:(XTMethodDeclNode*)method
                startingAt:(NSString*)leafClassName
    {
    XTClassDeclNode* leaf = _classesByName[leafClassName];
    for (XTClassDeclNode* c = leaf; c != nil; c = c.parentClass)
        {
        for (XTMethodDeclNode* m in c.methods)
            {
            if (m == method)
                return c.className;
            }
        }
    return leafClassName;
    }

/****************************************************************************\
|* Recursive AST walker. Picks calls and address-taken idents out of
|* every expression / statement shape; for composite shapes just
|* recurses into their children. Uses isKindOfClass: dispatch for
|* readability — we're walking a dozen-ish node types and the
|* visitor protocol would mean boilerplate across two files.
\****************************************************************************/
- (void)walkNode:(XTASTNode*)node
         reachable:(NSMutableSet<NSString*>*)reachable
          worklist:(NSMutableArray<XTReachableDecl*>*)worklist
    enclosingClass:(NSString* _Nullable)enclosingClass
    {
    if (!node)
        return;

    if ([node isKindOfClass:[XTCallExprNode class]])
        {
        XTCallExprNode* call = (XTCallExprNode*)node;
        NSString* mangled = call.resolvedMangledName ?: call.calleeName;
        // `use Klass;` resolution: sema stamped `resolvedClassName`
        // on a bare-identifier call when it found the callee as a
        // static method on a use-promoted class. The reachability
        // walk has to follow the same path the codegen will take —
        // emit the class's static method body — or the JSR target
        // never gets included and xta links to $0000.
        if (call.resolvedClassName.length > 0)
            {
            XTMethodDeclNode* m =
                [self lookupSelfMethodInChain:call.resolvedClassName
                                      mangled:mangled
                                     bareName:call.calleeName
                                outOwnerClass:NULL];
            if (m)
                {
                NSString* owner = [self ownerClassFor:m
                                           startingAt:call.resolvedClassName];
                [self enqueueMethod:m
                            inClass:owner
                      intoReachable:reachable
                           worklist:worklist];
                }
            for (XTASTNode* arg in call.arguments)
                {
                [self walkNode:arg reachable:reachable worklist:worklist enclosingClass:enclosingClass];
                }
            return;
            }
        XTFunctionDeclNode* fn = _funcByMangled[mangled] ?: _funcByName[call.calleeName].firstObject;
        if (fn)
            {
            [self enqueueFunction:fn intoReachable:reachable worklist:worklist];
            }
        else if (enclosingClass)
            {
            // Unqualified call inside a class body — might be a
            // self-method call (`step();` from inside `rand`).
            // PR3: walk the parent chain — a bare call inside a
            // subclass body can resolve to any ancestor's method,
            // and the reachability analyser has to find the same
            // owner sema did or the callee never gets emitted.
            XTMethodDeclNode* m = [self lookupSelfMethodInChain:enclosingClass
                                                        mangled:mangled
                                                       bareName:call.calleeName
                                                  outOwnerClass:NULL];
            if (m)
                {
                NSString* owner = [self ownerClassFor:m startingAt:enclosingClass];
                [self enqueueMethod:m inClass:owner intoReachable:reachable worklist:worklist];
                // Bare self-call in a method body: codegen routes
                // through the vtable when the method is overridden
                // anywhere (`virtualSlotByLabel` keyed). Treat it
                // the same as `self.X()` — record the slot as
                // virtually called. inline: calls bypass the
                // vtable (the body is pasted at compile time), so
                // they don't widen the reachable cross product.
                if (_virtualSlotByLabel && !call.forceInline)
                    {
                    NSString* resolvedLbl = [self labelForMethod:m inClass:owner];
                    NSNumber* slot = _virtualSlotByLabel[resolvedLbl];
                    if (slot)
                        {
                        [self markSlotCalled:slot.unsignedIntegerValue
                               intoReachable:reachable
                                    worklist:worklist];
                        }
                    }
                }
            }
        for (XTASTNode* arg in call.arguments)
            {
            [self walkNode:arg reachable:reachable worklist:worklist enclosingClass:enclosingClass];
            }
        return;
        }

    if ([node isKindOfClass:[XTMethodCallExprNode class]])
        {
        XTMethodCallExprNode* mc = (XTMethodCallExprNode*)node;
        // PR5: `super.method()` — the receiver isn't a variable or a
        // class name, so classNameForReceiver wouldn't find it. Sema
        // stamps `resolvedClassName` with the owning class in the
        // super-call path; trust it when present.
        BOOL isSuperCall =
            [mc.receiver isKindOfClass:[XTIdentifierNode class]] &&
            [((XTIdentifierNode*)mc.receiver).identName isEqualToString:@"super"];
        NSString* className = isSuperCall
                                  ? mc.resolvedClassName
                                  : [self classNameForReceiver:mc.receiver enclosingClass:enclosingClass];
        if (className)
            {
            NSString* mangled = mc.resolvedMangledName ?: mc.methodName;
            // PR3: walk the parent chain so inherited method calls
            // (receiver typed Dog, method declared on Animal) mark
            // Animal's body reachable.
            XTMethodDeclNode* m = [self lookupSelfMethodInChain:className
                                                        mangled:mangled
                                                       bareName:mc.methodName
                                                  outOwnerClass:NULL];
            if (m)
                {
                NSString* owner = [self ownerClassFor:m startingAt:className];
                [self enqueueMethod:m inClass:owner intoReachable:reachable worklist:worklist];
                // Virtual-dispatch tracking. If the static-resolved
                // method label is in the vtable, the runtime can
                // route the call to a different override depending
                // on the receiver's actual class. Record the slot
                // as virtually called and replay against every
                // previously-instantiated class so their slot fill
                // also gets pulled in. super.X() and inline: calls
                // are excluded — both bypass the vtable (super
                // JSRs the parent body directly; inline pastes
                // the body at compile time).
                if (!isSuperCall && !mc.forceInline && _virtualSlotByLabel)
                    {
                    NSString* resolvedLbl = [self labelForMethod:m inClass:owner];
                    NSNumber* slot = _virtualSlotByLabel[resolvedLbl];
                    if (slot)
                        {
                        [self markSlotCalled:slot.unsignedIntegerValue
                               intoReachable:reachable
                                    worklist:worklist];
                        }
                    }
                }
            else if (!isSuperCall && !mc.forceInline && _virtualSlotByLabel)
                {
                // Protocol-typed receiver: the receiver's class name
                // resolves to a protocol declaration, not a class, so
                // the chain walk above returns nil. Find every
                // conforming class's method matching the call by
                // scanning virtualSlotByLabel for a method-name match
                // and marking its slot called. The replay against
                // instantiated classes pulls in every conforming
                // class's body without the analyser needing the
                // protocol → slot map directly.
                [self markSlotsForProtocolCallNamed:mc.methodName
                                            mangled:mc.resolvedMangledName
                                      intoReachable:reachable
                                           worklist:worklist];
                }
            }
        [self walkNode:mc.receiver reachable:reachable worklist:worklist enclosingClass:enclosingClass];
        for (XTASTNode* arg in mc.arguments)
            {
            [self walkNode:arg reachable:reachable worklist:worklist enclosingClass:enclosingClass];
            }
        return;
        }

    if ([node isKindOfClass:[XTForInNode class]])
        {
        // for (T x in coll) lowers to virtual dispatches on coll's
        // Enumerable conformance: one `enumLength()` per loop and
        // one `enumAt(i)` per iteration. The codegen looks up
        // those slots in `virtualSlotByLabel` at emit time
        // (see emitForInEnumerable in XTCodeGenerator+StmtLoops);
        // mirror that here so the conforming class's bodies stay
        // reachable. Both methods are name-only protocol calls
        // (no overload), so the bare-name fallback is enough.
        XTForInNode* fi = (XTForInNode*)node;
        if (_virtualSlotByLabel)
            {
            [self markSlotsForProtocolCallNamed:@"enumLength"
                                        mangled:nil
                                  intoReachable:reachable
                                       worklist:worklist];
            [self markSlotsForProtocolCallNamed:@"enumAt"
                                        mangled:nil
                                  intoReachable:reachable
                                       worklist:worklist];
            }
        [self walkNode:fi.loopVar reachable:reachable worklist:worklist enclosingClass:enclosingClass];
        [self walkNode:fi.collection reachable:reachable worklist:worklist enclosingClass:enclosingClass];
        [self walkNode:fi.body reachable:reachable worklist:worklist enclosingClass:enclosingClass];
        return;
        }

    if ([node isKindOfClass:[XTUnaryExprNode class]])
        {
        XTUnaryExprNode* u = (XTUnaryExprNode*)node;
        // Address-of applied to a function identifier — treat as
        // a root. The operand's resolvedType is "pointer to
        // function" after sema, but we just detect the textual
        // shape: & <identifier> where identifier names a function.
        if (u.op == XTUnaryOpAddrOf && [u.operand isKindOfClass:[XTIdentifierNode class]])
            {
            XTIdentifierNode* id = (XTIdentifierNode*)u.operand;
            XTFunctionDeclNode* fn = _funcByMangled[id.identName] ?: _funcByName[id.identName].firstObject;
            if (fn)
                {
                [self enqueueFunction:fn intoReachable:reachable worklist:worklist];
                }
            }
        [self walkNode:u.operand reachable:reachable worklist:worklist enclosingClass:enclosingClass];
        return;
        }

    if ([node isKindOfClass:[XTIdentifierNode class]])
        {
        // Identifier used as an rvalue where it names a function
        // (e.g. `fp = foo;` assigning a function pointer). Without
        // an explicit `&`, sema still resolves the identifier to
        // the function symbol. Marking it here keeps such
        // assignments working at O0 / O2.
        XTIdentifierNode* id = (XTIdentifierNode*)node;
        XTType* rt = id.resolvedType;
        if (rt && [rt isKindOfClass:[XTPointerType class]])
            {
            // pointer — could be function-pointer; only mark when
            // the name actually matches a function.
            }
        XTFunctionDeclNode* fn = _funcByName[id.identName].firstObject;
        if (fn)
            {
            [self enqueueFunction:fn intoReachable:reachable worklist:worklist];
            }
        return;
        }

    if ([node isKindOfClass:[XTAsmBlockNode class]])
        {
        XTAsmBlockNode* ab = (XTAsmBlockNode*)node;
        for (NSString* line in ab.lines)
            {
            [self scanAsmLineForCallees:line
                              reachable:reachable
                               worklist:worklist];
            }
        return;
        }

    if ([node isKindOfClass:[XTNewExprNode class]])
        {
        XTNewExprNode* ne = (XTNewExprNode*)node;
        XTClassDeclNode* cls = _classesByName[ne.className];
        if (cls)
            {
            // `new ClassName` constructs an instance. Any init
            // method of that class is reachable, and under ARC any
            // scope that holds a strong pointer to the new'd object
            // will eventually call the class's dealloc from the
            // auto-release at scope exit — so dealloc is reachable
            // too, even without a source-level `delete` / `release`.
            for (XTMethodDeclNode* m in cls.methods)
                {
                if ([m.methodName isEqualToString:@"init"])
                    {
                    [self enqueueMethod:m inClass:ne.className intoReachable:reachable worklist:worklist];
                    }
                if ([m.methodName isEqualToString:@"dealloc"])
                    {
                    [self enqueueMethod:m inClass:ne.className intoReachable:reachable worklist:worklist];
                    }
                }
            // PR6: if the leaf class has no dealloc of its own, the
            // codegen's auto-generated stub chains to the nearest
            // ancestor that does. Walk the parent chain and mark
            // that ancestor's dealloc reachable too, otherwise the
            // stub's JSR points at a trimmed label.
            BOOL leafHasDealloc = NO;
            for (XTMethodDeclNode* m in cls.methods)
                {
                if ([m.methodName isEqualToString:@"dealloc"])
                    {
                    leafHasDealloc = YES;
                    break;
                    }
                }
            if (!leafHasDealloc)
                {
                for (XTClassDeclNode* p = cls.parentClass; p != nil; p = p.parentClass)
                    {
                    XTMethodDeclNode* parentDealloc = nil;
                    for (XTMethodDeclNode* pm in p.methods)
                        {
                        if ([pm.methodName isEqualToString:@"dealloc"])
                            {
                            parentDealloc = pm;
                            break;
                            }
                        }
                    if (parentDealloc)
                        {
                        [self enqueueMethod:parentDealloc
                                    inClass:p.className
                              intoReachable:reachable
                                   worklist:worklist];
                        break;
                        }
                    }
                }
            // Record the class as instantiated. Per-slot reachability
            // is delayed until a virtual call site is observed: the
            // pre-existing rule that pulled in every vtable method
            // of a constructed class made every binary linking the
            // class drag in *every* override of every overridden
            // method, even ones the program never calls (Gfx8.line
            // alone is ~3 KB of asm-optimised body). The new rule
            // marks only (slot × instantiated class) pairs that are
            // actually called somewhere in reachable code.
            [self markClassInstantiated:ne.className
                          intoReachable:reachable
                               worklist:worklist];
            }
        for (XTASTNode* arg in ne.arguments)
            {
            [self walkNode:arg reachable:reachable worklist:worklist enclosingClass:enclosingClass];
            }
        return;
        }

    if ([node isKindOfClass:[XTDeleteNode class]])
        {
        XTDeleteNode* dn = (XTDeleteNode*)node;
        // Recurse into the operand first so any sub-expressions get
        // walked before we try to read its resolvedType.
        [self walkNode:dn.operand reachable:reachable worklist:worklist enclosingClass:enclosingClass];
        // For delete/release of a class pointer, mark that class's
        // dealloc() method reachable — the codegen emits a
        // JSR _cls_<Class>_dealloc when the refcount hits 0. retain
        // never invokes dealloc, so we skip the mark for that op.
        if (dn.op != XTRefOpRetain)
            {
            XTType* ot = dn.operand.resolvedType;
            if ([ot isKindOfClass:[XTPointerType class]])
                {
                XTType* pointee = ((XTPointerType*)ot).pointeeType;
                if (pointee && pointee.kind == XTTypeKindClass)
                    {
                    NSString* cname = pointee.displayName;
                    XTClassDeclNode* tc = _classesByName[cname];
                    if (tc)
                        {
                        for (XTMethodDeclNode* m in tc.methods)
                            {
                            if ([m.methodName isEqualToString:@"dealloc"])
                                {
                                [self enqueueMethod:m inClass:cname intoReachable:reachable worklist:worklist];
                                break;
                                }
                            }
                        }
                    }
                }
            }
        return;
        }

    // Composite shapes: recurse into children that are themselves
    // AST nodes. Reflection would be nicer but we only have a
    // dozen types and they all expose their payloads as readable
    // properties.
    [self recurseChildrenOf:node
                  reachable:reachable
                   worklist:worklist
             enclosingClass:enclosingClass];
    }

- (nullable NSString*)classNameForReceiver:(XTASTNode*)receiver
                            enclosingClass:(NSString* _Nullable)enclosingClass
    {
    // Static call on the class itself: `Math.sqrt(...)`. Receiver
    // is an identifier whose name matches a class.
    if ([receiver isKindOfClass:[XTIdentifierNode class]])
        {
        NSString* ident = ((XTIdentifierNode*)receiver).identName;
        if (_classesByName[ident])
            return ident;
        }
    // Instance call: receiver has a class (or class-pointer) type.
    XTType* rt = receiver.resolvedType;
    if (rt)
        {
        if (rt.kind == XTTypeKindClass)
            return rt.displayName;
        if ([rt isKindOfClass:[XTPointerType class]])
            {
            XTType* pointee = ((XTPointerType*)rt).pointeeType;
            if (pointee && pointee.kind == XTTypeKindClass)
                return pointee.displayName;
            }
        }
    return enclosingClass; // fallback (self-method call without explicit receiver)
    }

- (void)scanAsmLineForCallees:(NSString*)rawLine
                    reachable:(NSMutableSet<NSString*>*)reachable
                     worklist:(NSMutableArray<XTReachableDecl*>*)worklist
    {
    NSRange cmt = [rawLine rangeOfString:@";"];
    NSString* stripped = (cmt.location != NSNotFound) ? [rawLine substringToIndex:cmt.location] : rawLine;
    for (NSString* stmt in [stripped componentsSeparatedByString:@":"])
        {
        NSString* s = [stmt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString* upper = s.uppercaseString;
        if (![upper hasPrefix:@"JSR "] && ![upper hasPrefix:@"JMP "])
            continue;
        NSString* target = [[s substringFromIndex:4]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([target hasPrefix:@"_fn_"])
            {
            NSString* mangled = [target substringFromIndex:4];
            XTFunctionDeclNode* fn = _funcByMangled[mangled];
            if (fn)
                [self enqueueFunction:fn intoReachable:reachable worklist:worklist];
            continue;
            }
        if ([target hasPrefix:@"_cls_"])
            {
            NSString* rest = [target substringFromIndex:5];
            NSRange sep = [rest rangeOfString:@"_"];
            if (sep.location == NSNotFound)
                continue;
            NSString* cls = [rest substringToIndex:sep.location];
            NSString* mangled = [rest substringFromIndex:sep.location + 1];
            NSString* key = [NSString stringWithFormat:@"%@::%@", cls, mangled];
            XTMethodDeclNode* m = _methodByKey[key];
            if (m)
                [self enqueueMethod:m inClass:cls intoReachable:reachable worklist:worklist];
            }
        }
    }

/****************************************************************************\
|* Recurse into every AST node type that acts as a container, so
|* the call / address-of / asm visitors upstream get to see every
|* expression. Shapes not yet handled silently fall through — if a
|* new AST node introduces a call-graph edge, adding a case here
|* hooks it in.
\****************************************************************************/
- (void)recurseChildrenOf:(XTASTNode*)node
                reachable:(NSMutableSet<NSString*>*)reachable
                 worklist:(NSMutableArray<XTReachableDecl*>*)worklist
           enclosingClass:(NSString* _Nullable)enclosingClass
    {
#define REC(x) [self walkNode:(x) reachable:reachable worklist:worklist enclosingClass:enclosingClass]

    if ([node isKindOfClass:[XTBlockNode class]])
        {
        for (XTASTNode* s in ((XTBlockNode*)node).statements)
            REC(s);
        return;
        }
    if ([node isKindOfClass:[XTIfNode class]])
        {
        XTIfNode* n = (XTIfNode*)node;
        REC(n.condition);
        REC(n.thenBlock);
        REC(n.elseBlock);
        return;
        }
    if ([node isKindOfClass:[XTWhileNode class]])
        {
        XTWhileNode* n = (XTWhileNode*)node;
        REC(n.condition);
        REC(n.body);
        return;
        }
    if ([node isKindOfClass:[XTForCStyleNode class]])
        {
        XTForCStyleNode* n = (XTForCStyleNode*)node;
        REC(n.loopInit);
        REC(n.condition);
        REC(n.increment);
        REC(n.body);
        return;
        }
    if ([node isKindOfClass:[XTForInNode class]])
        {
        XTForInNode* n = (XTForInNode*)node;
        REC(n.collection);
        REC(n.body);
        return;
        }
    if ([node isKindOfClass:[XTReturnNode class]])
        {
        for (XTASTNode* v in ((XTReturnNode*)node).values)
            REC(v);
        return;
        }
    if ([node isKindOfClass:[XTExpressionStatementNode class]])
        {
        REC(((XTExpressionStatementNode*)node).expression);
        return;
        }
    if ([node isKindOfClass:[XTVariableDeclNode class]])
        {
        REC(((XTVariableDeclNode*)node).initialiser);
        return;
        }
    if ([node isKindOfClass:[XTTupleAssignNode class]])
        {
        XTTupleAssignNode* n = (XTTupleAssignNode*)node;
        REC(n.sourceExpr);
        for (XTASTNode* t in n.targets)
            REC(t);
        return;
        }
    if ([node isKindOfClass:[XTBinaryExprNode class]])
        {
        REC(((XTBinaryExprNode*)node).left);
        REC(((XTBinaryExprNode*)node).right);
        return;
        }
    if ([node isKindOfClass:[XTAssignExprNode class]])
        {
        XTAssignExprNode* an = (XTAssignExprNode*)node;
        REC(an.lhs);
        REC(an.rhs);
        // Property-accessor setter: sema stamped the method when the
        // LHS resolves to a class-member with a matching
        // `set<Name>(T)` method. Enqueue so codegen emits the body.
        if (an.resolvedSetterMethod && an.resolvedSetterClass)
            {
            XTMethodDeclNode* m = (XTMethodDeclNode*)an.resolvedSetterMethod;
            [self enqueueMethod:m
                        inClass:an.resolvedSetterClass
                  intoReachable:reachable
                       worklist:worklist];
            }
        return;
        }
    if ([node isKindOfClass:[XTPostfixExprNode class]])
        {
        REC(((XTPostfixExprNode*)node).operand);
        return;
        }
    if ([node isKindOfClass:[XTSubscriptExprNode class]])
        {
        REC(((XTSubscriptExprNode*)node).base);
        REC(((XTSubscriptExprNode*)node).index);
        return;
        }
    if ([node isKindOfClass:[XTSliceExprNode class]])
        {
        XTSliceExprNode* sn = (XTSliceExprNode*)node;
        REC(sn.base);
        if (sn.startExpr)
            REC(sn.startExpr);
        if (sn.endExpr)
            REC(sn.endExpr);
        return;
        }
    if ([node isKindOfClass:[XTRangeExprNode class]])
        {
        XTRangeExprNode* rn = (XTRangeExprNode*)node;
        REC(rn.startExpr);
        REC(rn.endExpr);
        return;
        }
    if ([node isKindOfClass:[XTMemberAccessNode class]])
        {
        XTMemberAccessNode* mn = (XTMemberAccessNode*)node;
        REC(mn.base);
        // Property-accessor getter: sema stamped the method when the
        // member name resolves to a zero-arg method on the class.
        // Enqueue so codegen emits the body.
        if (mn.resolvedGetterMethod && mn.resolvedGetterClass)
            {
            XTMethodDeclNode* m = (XTMethodDeclNode*)mn.resolvedGetterMethod;
            [self enqueueMethod:m
                        inClass:mn.resolvedGetterClass
                  intoReachable:reachable
                       worklist:worklist];
            }
        return;
        }
    if ([node isKindOfClass:[XTTernaryExprNode class]])
        {
        XTTernaryExprNode* n = (XTTernaryExprNode*)node;
        REC(n.condition);
        REC(n.thenExpr);
        REC(n.elseExpr);
        return;
        }
    if ([node isKindOfClass:[XTCastExprNode class]])
        {
        XTCastExprNode* cn = (XTCastExprNode*)node;
        REC(cn.operand);
        // A class-pointer downcast names a target class by type
        // without instantiating it. The vtable for the target is
        // still emitted — it references each slot's filling
        // method, and the codegen wants those labels to resolve.
        // Treat the cast target as instantiated so the smart
        // reachability rule still pulls in slot fills for any
        // slot that's virtually called somewhere in reachable
        // code. Slots with no call site stay trimmed; the vtable
        // reference for those slots resolves to $0000 but never
        // executes (no virtual dispatch ever lands on them).
        NSString* tname = cn.targetClassName;
        XTClassDeclNode* cls = tname ? _classesByName[tname] : nil;
        if (cls)
            {
            [self markClassInstantiated:cls.className
                          intoReachable:reachable
                               worklist:worklist];
            }
        return;
        }
    // Leaves (literals, sizeof of a type, break, continue) have no
    // edges to collect — no-op.

#undef REC
    }

@end
