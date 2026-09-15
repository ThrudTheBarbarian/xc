#import "XTScope.h"

@interface XTScope ()
/****************************************************************************\
|* Value is either XTSymbol* (single) or NSMutableArray<XTSymbol*>* (overload set).
\****************************************************************************/
@property(nonatomic) NSMutableDictionary<NSString*, id>* table;
@end

@implementation XTScope

/****************************************************************************\
|* Create a new scope, optionally nested inside a parent scope.
|* @param parent  The enclosing scope, or nil for the global scope.
|* @return A new empty scope.
\****************************************************************************/
- (instancetype)initWithParent:(nullable XTScope*)parent
    {
    self = [super init];
    if (self)
        {
        _parentScope = parent;
        _table = [NSMutableDictionary dictionary];
        }
    return self;
    }

/****************************************************************************\
|* Return all symbols defined directly in this scope, flattened. For
|* overloaded function names this returns every overload.
|* @return Array of all symbols in this scope.
\****************************************************************************/
- (NSArray<XTSymbol*>*)allSymbols
    {
    NSMutableArray<XTSymbol*>* out = [NSMutableArray array];
    for (id v in _table.allValues)
        {
        if ([v isKindOfClass:[NSArray class]])
            {
            [out addObjectsFromArray:(NSArray*)v];
            }
        else
            {
            [out addObject:(XTSymbol*)v];
            }
        }
    return out;
    }

/****************************************************************************\
|* Return the set of symbol names defined directly in this scope.
|* @return Array of symbol name strings.
\****************************************************************************/
- (NSArray<NSString*>*)symbolNames
    {
    return _table.allKeys;
    }

/****************************************************************************\
|* Define a symbol in this (innermost) scope. Returns NO if an identical
|* definition already exists (same name + same mangled name). For overloaded
|* functions with distinct mangled names, appends and returns YES.
|* @param symbol  The symbol to define.
|* @return YES if the symbol was successfully added, NO for a duplicate.
\****************************************************************************/
- (BOOL)defineSymbol:(XTSymbol*)symbol
    {
    id existing = _table[symbol.symbolName];
    if (!existing)
        {
        _table[symbol.symbolName] = symbol;
        return YES;
        }
    // If the existing entry (or set) contains a function symbol with
    // the SAME mangled name, it's a duplicate signature — reject.
    // Otherwise append as a new overload.
    if ([existing isKindOfClass:[NSArray class]])
        {
        for (XTSymbol* s in (NSArray*)existing)
            {
            if ([s.mangledName isEqualToString:symbol.mangledName])
                return NO;
            }
        [(NSMutableArray*)existing addObject:symbol];
        return YES;
        }
    XTSymbol* single = (XTSymbol*)existing;
    // Non-function or same-mangled: duplicate.
    if (single.storageClass != XTStorageClassFunction ||
        symbol.storageClass != XTStorageClassFunction)
        return NO;
    if ([single.mangledName isEqualToString:symbol.mangledName])
        return NO;
    // Promote to overload set.
    NSMutableArray<XTSymbol*>* set = [NSMutableArray arrayWithObjects:single, symbol, nil];
    _table[symbol.symbolName] = set;
    return YES;
    }

/****************************************************************************\
|* Look up a symbol by name, walking the scope chain outward. Returns the
|* first entry if the name refers to an overload set.
|* @param name  The symbol name to search for.
|* @return The matching symbol, or nil if not found in any enclosing scope.
\****************************************************************************/
- (nullable XTSymbol*)lookupSymbol:(NSString*)name
    {
    id v = _table[name];
    if (v)
        {
        if ([v isKindOfClass:[NSArray class]])
            return ((NSArray*)v).firstObject;
        return (XTSymbol*)v;
        }
    return [_parentScope lookupSymbol:name];
    }

/****************************************************************************\
|* Look up a symbol only in the current (innermost) scope, without walking
|* the chain.
|* @param name  The symbol name to search for.
|* @return The matching symbol, or nil if not found locally.
\****************************************************************************/
- (nullable XTSymbol*)lookupLocalSymbol:(NSString*)name
    {
    id v = _table[name];
    if (!v)
        return nil;
    if ([v isKindOfClass:[NSArray class]])
        return ((NSArray*)v).firstObject;
    return (XTSymbol*)v;
    }

/****************************************************************************\
|* Return every candidate symbol for the given name, walking the scope chain.
|* Stops at the first scope that defines the name (inner shadows outer).
|* @param name  The function name to search for.
|* @return Array of candidate symbols (may be empty if undefined).
\****************************************************************************/
- (NSArray<XTSymbol*>*)lookupFunctionCandidates:(NSString*)name
    {
    NSMutableArray<XTSymbol*>* out = [NSMutableArray array];
    for (XTScope* s = self; s; s = s.parentScope)
        {
        id v = s.table[name];
        if (!v)
            continue;
        if ([v isKindOfClass:[NSArray class]])
            {
            [out addObjectsFromArray:(NSArray*)v];
            }
        else
            {
            [out addObject:(XTSymbol*)v];
            }
        // Stop at first scope that defines the name — inner shadows outer.
        break;
        }
    return out;
    }

@end
