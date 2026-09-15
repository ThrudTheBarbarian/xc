#import "XTInterfaceSerializer.h"
#import "XTASTNode.h"
#import "XTDeclNodes.h"
#import "XTType.h"

@implementation XTInterfaceSerializer

// One method signature → dict {name, static, varargs, symbol, params[], returns[]}.
// `symbol` is the body's exported name in the .so. For a class method that's the
// lowering convention `Class$method` (matches .dynsym); protocol methods carry no
// symbol (they're reached through a conforming class's vtable slot).
+ (NSDictionary *)dictForMethod:(XTMethodDeclNode *)m inClass:(nullable NSString *)cls {
    NSMutableArray *params = [NSMutableArray array];
    for (XTParamNode *p in m.parameters) {
        [params addObject:@{ @"name": p.paramName ?: @"",
                             @"type": p.paramType.displayName ?: @"void" }];
    }
    NSMutableArray *rets = [NSMutableArray array];
    for (XTType *r in m.returnTypes) [rets addObject:r.displayName ?: @"void"];
    NSString *bare = m.mangledName.length ? m.mangledName : (m.methodName ?: @"");
    NSString *symbol = cls.length ? [NSString stringWithFormat:@"%@$%@", cls, bare] : @"";
    NSMutableDictionary *d = [@{ @"name":     m.methodName ?: @"",
              @"static":   @(m.isStatic),
              @"varargs":  @(m.isVarArgs),
              @"optional": @(m.isOptional),   // a protocol's `optional` must round-trip,
                                              // else an importer re-checks conformance and
                                              // demands a method the class may legally omit
              @"symbol":   symbol,
              @"params":   params,
              @"returns":  rets } mutableCopy];
    // §4.3b: a chain-dispatched method must round-trip AS one, so an importer
    // can refuse a client-side override (the iface has no chain shape to give
    // it). Written only when set, keeping every other iface byte-stable.
    if (m.isChainMethod) d[@"chain"] = @YES;
    return d;
}

+ (NSString *)jsonForProgram:(XTProgramNode *)program {
    return [self jsonForProgram:program protocolSlots:nil methodSlots:nil];
}

+ (NSString *)jsonForProgram:(XTProgramNode *)program
               protocolSlots:(NSDictionary *)protocolSlots
                 methodSlots:(NSDictionary *)methodSlots {
    return [self jsonForProgram:program protocolSlots:protocolSlots
                    methodSlots:methodSlots cImports:nil];
}

+ (NSString *)jsonForProgram:(XTProgramNode *)program
               protocolSlots:(NSDictionary *)protocolSlots
                 methodSlots:(NSDictionary *)methodSlots
                    cImports:(NSArray<NSString *> *)cImports {
    return [self jsonForProgram:program protocolSlots:protocolSlots
                    methodSlots:methodSlots cImports:cImports excludeFiles:nil];
}

+ (NSString *)jsonForProgram:(XTProgramNode *)program
               protocolSlots:(NSDictionary *)protocolSlots
                 methodSlots:(NSDictionary *)methodSlots
                    cImports:(NSArray<NSString *> *)cImports
                excludeFiles:(NSSet<NSString *> *)excludeFiles {
    if (!program) return nil;
    NSMutableArray *classes   = [NSMutableArray array];
    NSMutableArray *protocols = [NSMutableArray array];
    NSMutableArray *enums     = [NSMutableArray array];
    NSMutableArray *structs   = [NSMutableArray array];
    NSMutableArray *functions = [NSMutableArray array];   // free (non-method) functions
    NSMutableArray *globals   = [NSMutableArray array];   // global variables
    NSMutableArray *typedefs  = [NSMutableArray array];   // type aliases

    NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    for (XTASTNode *d in program.declarations) {
        // Prelude-originated declarations are the AMBIENT surface — every
        // unit already has them, so they are not this module's to export
        // (task #36). Locations carry the #line spelling; anchor at the cwd
        // exactly as the preprocessor keyed its set.
        // A declaration with no source position at all is the compiler's own
        // (a runtime helper declaration), not this module's public surface.
        // Mirrors the shipped compiler's first `ambient()` test.
        if (!d.location.filename.length) continue;
        if (excludeFiles.count && d.location.filename.length) {
            NSString *df = d.location.filename;
            NSString *abs = df.isAbsolutePath ? df
                : [cwd stringByAppendingPathComponent:df];
            if ([excludeFiles containsObject:[abs stringByStandardizingPath]])
                continue;
        }
        if ([d isKindOfClass:[XTClassDeclNode class]]) {
            XTClassDeclNode *c = (XTClassDeclNode *)d;
            // A class that ARRIVED through an import is not this module's to
            // re-export: its record belongs to its own library's interface,
            // and re-serialising it here (a) collides with that record in any
            // client importing both libraries, and (b) after a category
            // merge would leak this module's chain methods into the class's
            // method list, where a client would read them as plain methods
            // and direct-call the base body past every override (§4.3b).
            // A client that wants the type imports the library that owns it.
            if (c.isExternal) continue;
            // A COMPILER-GENERATED class: `BlkImpl$N`, the `Blk$…` shapes.
            // `$` is the hex-literal prefix in this language, so it cannot
            // appear in a name anybody wrote — the test is exact, not a
            // heuristic. These must not be published: the name is a per-unit
            // ORDINAL, so two libraries that both use blocks each export
            // `BlkImpl$0` and a client importing both collides on it, and no
            // client could name one anyway. The shipped compiler drops them
            // (it happens to have no position on the node, which is a
            // different rule for the same decision — spelled explicitly on
            // both sides now, because a contract spelled two ways drifts).
            if ([c.className containsString:@"$"]) continue;
            NSMutableArray *ivars = [NSMutableArray array];
            for (XTVariableDeclNode *v in c.ivars) {
                // A `static` ivar occupies no instance slot — it is a module
                // global private to this unit. Emitting it here would insert a
                // phantom field into every importer's layout and shift every
                // ivar after it.
                if (v.isStatic) continue;
                [ivars addObject:@{ @"name": v.varName ?: @"",
                                    @"type": v.declaredType.displayName ?: @"void" }];
            }
            NSMutableArray *methods = [NSMutableArray array];
            for (XTMethodDeclNode *m in c.methods) [methods addObject:[self dictForMethod:m inClass:c.className]];
            // XG-NIB designable surface: the `outlet` fields and `:action`
            // methods Rocks reflects on to offer connections and validate wires.
            NSMutableArray *outlets = [NSMutableArray array];
            for (XTVariableDeclNode *v in c.ivars) {
                if (!v.isOutlet) continue;
                [outlets addObject:@{ @"name": v.varName ?: @"",
                                      @"type": v.declaredType.displayName ?: @"void" }];
            }
            NSMutableArray *actions = [NSMutableArray array];
            for (XTMethodDeclNode *m in c.methods) {
                if (!m.isAction) continue;
                NSString *senderType = m.parameters.firstObject.paramType.displayName ?: @"Object@";
                [actions addObject:@{ @"name": m.methodName ?: @"",
                                      @"sender": senderType }];
            }
            NSMutableDictionary *cd = [@{ @"name":      c.className ?: @"",
                                         @"parent":    c.parentName ?: @"",
                                         @"protocols": c.protocolNames ?: @[],
                                         @"ivars":     ivars,
                                         @"methods":   methods } mutableCopy];
            if (outlets.count || actions.count) {
                cd[@"designable"] = @YES;
                cd[@"outlets"]    = outlets;
                cd[@"actions"]    = actions;
            }
            [classes addObject:cd];
        } else if ([d isKindOfClass:[XTStructDeclNode class]]) {
            // Structs are part of the API just as much as classes are: a library that
            // takes `XGRect` in a method signature is unusable without the type. They
            // were never emitted, so the NAME appeared all over the interface (inside
            // signatures, as a string) while the TYPE was nowhere — the client could
            // not declare `XGRect r;` at all, and worse, a `XGRect` PARAMETER parsed
            // as u8 and miscompiled silently.
            XTStructDeclNode *st = (XTStructDeclNode *)d;
            if (st.structName.length == 0) continue;      // anonymous: not nameable
            NSMutableArray *fields = [NSMutableArray array];
            for (XTVariableDeclNode *v in st.fields) {
                [fields addObject:@{ @"name": v.varName ?: @"",
                                     @"type": v.declaredType.displayName ?: @"void" }];
            }
            [structs addObject:@{ @"name": st.structName, @"fields": fields,
                                  @"packed": @(st.isPacked) }];
        } else if ([d isKindOfClass:[XTTypedefNode class]]) {
            // A type ALIAS. `typedef struct {...} Foo;` is covered by the struct export
            // (the alias names a struct type, which we emit); this carries the plain
            // `typedef <type> <alias>;` form so the client can spell the alias too.
            XTTypedefNode *td = (XTTypedefNode *)d;
            if (td.aliasName.length == 0 || !td.targetType) continue;
            [typedefs addObject:@{ @"name":   td.aliasName,
                                   @"target": td.targetType.displayName ?: @"void" }];
        } else if ([d isKindOfClass:[XTFunctionDeclNode class]]) {
            // A library's free functions are API too. Only DEFINED ones (body != nil):
            // a body-less decl in the library's own source is a prototype for something
            // it imported, not something it exports.
            XTFunctionDeclNode *f = (XTFunctionDeclNode *)d;
            if (!f.body || f.funcName.length == 0) continue;
            // Compiler-generated internal helpers (`_xtc_obj_conforms` and the
            // XG-NIB synthesis functions) are injected into EVERY module — they are
            // per-module implementation, not API. Keeping them out of the interface
            // stops a client that imports this library from seeing a second
            // declaration and redefining its own injected copy.
            if ([f.funcName hasPrefix:@"_xtc_"]) continue;
            NSMutableArray *params = [NSMutableArray array];
            for (XTParamNode *pn in f.parameters) {
                [params addObject:@{ @"name": pn.paramName ?: @"",
                                     @"type": pn.paramType.displayName ?: @"void" }];
            }
            NSMutableArray *rets = [NSMutableArray array];
            for (XTType *r in f.returnTypes) [rets addObject:r.displayName ?: @"void"];
            [functions addObject:@{ @"name":    f.funcName,
                                    @"symbol":  f.mangledName.length ? f.mangledName : f.funcName,
                                    @"varargs": @(f.isVarArgs),
                                    @"params":  params,
                                    @"returns": rets }];
        } else if ([d isKindOfClass:[XTVariableDeclNode class]]) {
            XTVariableDeclNode *v = (XTVariableDeclNode *)d;
            if (v.varName.length == 0) continue;
            [globals addObject:@{ @"name": v.varName,
                                  @"type": v.declaredType.displayName ?: @"void" }];
        } else if ([d isKindOfClass:[XTProtocolDeclNode class]]) {
            XTProtocolDeclNode *p = (XTProtocolDeclNode *)d;
            NSMutableArray *methods = [NSMutableArray array];
            for (XTMethodDeclNode *m in p.methods) [methods addObject:[self dictForMethod:m inClass:nil]];
            [protocols addObject:@{ @"name": p.protocolName ?: @"", @"methods": methods }];
        } else if ([d isKindOfClass:[XTEnumDeclNode class]]) {
            XTEnumDeclNode *e = (XTEnumDeclNode *)d;
            // `$imported_constants` is the synthesised bucket holding the enum
            // constants THIS module imported from ITS libraries (on arm9, libc is
            // auto-imported, so every module has one). It is a private artefact of
            // how this module was built, not part of the API it exports — and
            // serialising it into the interface made every client that imports an
            // xtc library fail to compile outright: the client synthesises its own
            // bucket of the same name, and sema rejects the duplicate enum.
            if ([e.enumName isEqualToString:@"$imported_constants"]) continue;
            NSMutableArray *members = [NSMutableArray array];
            for (XTEnumMemberNode *mem in e.members) {
                [members addObject:@{ @"name":  mem.memberName ?: @"",
                                      @"value": @(mem.resolvedValue) }];
            }
            [enums addObject:@{ @"name": e.enumName ?: @"", @"members": members }];
        }
    }


    // Slot maps carry the WHOLE unit's numbering; restrict both to the

    // declarations that survived the exclude filter, or a pruned iface

    // still names prelude types (the importer resolves every class a

    // _cls_<C>_… label mentions — 'String' was the first casualty).

    NSMutableSet<NSString *> *keptClasses = [NSMutableSet set];

    for (NSDictionary *c in classes) [keptClasses addObject:c[@"name"] ?: @""];

    NSMutableSet<NSString *> *keptProtos = [NSMutableSet set];

    for (NSDictionary *p in protocols) [keptProtos addObject:p[@"name"] ?: @""];

    NSMutableDictionary *prunedMethodSlots = [NSMutableDictionary dictionary];

    // …and the slots this module assigned to classes it does NOT export: the
    // AMBIENT ones (String, Object, Array — the prelude). They are not this
    // library's declarations to publish, and 115 is right to keep them out of
    // `classes`. But the library still ASSUMED a vtable layout for them, and
    // under shared-everything wasm the object a client hands in carries the
    // CLIENT's table. With the assumption published nowhere, the library
    // indexed slot 110 of a 16-slot table (bug 091).
    //
    // A separate key, deliberately: these are an ABI assumption, not an export,
    // and merging them into methodSlots would make a client believe the library
    // declares String.
    NSMutableDictionary *ambientSlots = [NSMutableDictionary dictionary];

    for (NSString *label in methodSlots) {

        if (![label hasPrefix:@"_cls_"]) continue;

        NSString *rest = [label substringFromIndex:5];

        BOOL owned = NO;

        for (NSString *cn in keptClasses) {

            if ([rest hasPrefix:[cn stringByAppendingString:@"_"]]) {

                prunedMethodSlots[label] = methodSlots[label];

                owned = YES;

                break;

            }

        }

        // …but NOT a compiler-generated class. `BlkImpl$N` is a per-unit
        // ORDINAL, so its slot number means nothing to anyone else — the same
        // reason its DECLARATION is not published. `$` is the hex-literal
        // prefix and cannot occur in a name anybody wrote, so the test is
        // exact.
        if (!owned && [rest rangeOfString:@"$"].location == NSNotFound)
            ambientSlots[label] = methodSlots[label];

    }

    NSMutableDictionary *prunedProtoSlots = [NSMutableDictionary dictionary];

    for (NSString *pn in protocolSlots)

        if ([keptProtos containsObject:pn]) prunedProtoSlots[pn] = protocolSlots[pn];


    NSDictionary *root = @{ @"version":   @1,
                            // Interface FORMAT version, checked on import.
                            // One shared /opt/xcc/3p tree serves every
                            // installed compiler version, so an incompatible
                            // interface must be a clear diagnostic, not a
                            // misparse. Bump on any change a strict reader of
                            // the previous format would misread.
                            @"ifaceVersion": @1,
                            @"classes":   classes,
                            @"protocols": protocols,
                            @"enums":     enums,
                            @"structs":   structs,
                            @"functions": functions,
                            @"globals":   globals,
                            @"typedefs":  typedefs,
                            @"protocolSlots": prunedProtoSlots,
                            @"methodSlots":   prunedMethodSlots,
                            @"ambientSlots":  ambientSlots,
                            @"cImports":      cImports      ?: @[] };
    NSError *err = nil;
    // NSJSONWritingSortedKeys (macOS 10.13+) gives deterministic key order but is
    // absent in GNUstep 1.31; the importer reads the object back by key, so its
    // only effect is byte-stability, not correctness. Use it where available.
    NSJSONWritingOptions jsonOpts = NSJSONWritingPrettyPrinted;
#if defined(__APPLE__)
    jsonOpts |= NSJSONWritingSortedKeys;
#endif
    NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                  options:jsonOpts
                                                    error:&err];
    if (!data) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

@end
