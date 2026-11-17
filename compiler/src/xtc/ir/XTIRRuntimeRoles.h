// XTIRRuntimeRoles.h — the runtime's check symbols and the role of each.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The runtime's check symbols (Checked.xc, CheckedVtbl.xc) and the role of
// each: one table, which every pass that treats them apart reads, so a new
// one is classified the same everywhere. The port's IRRuntime (Ir.xc).
//
//   Check          a check: compares, and calls a trap when it fails
//   Limit          the bound a hoisted check compares against
//   Trap           reports a failed check and stops the program
//   TrapReturns    a check's slow path: stops the program, or returns when a
//                  closer look finds the value good
//   Helper         the runtime's own output and lookup helpers
//   Data           the runtime's own data
//
// A name with the runtime's prefix that is not listed is a TrapReturns when
// it ends `_trap`, else a Helper: never taken to stop the program, nor
// inlined with the checks.
typedef NS_ENUM(uint8_t, XTIRRuntimeRole) {
    XTIRRuntimeRoleNone = 0,
    XTIRRuntimeRoleCheck,
    XTIRRuntimeRoleLimit,
    XTIRRuntimeRoleTrap,
    XTIRRuntimeRoleTrapReturns,
    XTIRRuntimeRoleHelper,
    XTIRRuntimeRoleData,
};

static inline XTIRRuntimeRole XTIRRuntimeRoleOf(NSString* _Nullable n)
    {
    if (!n || ![n hasPrefix:@"_xt_check_"])
        return XTIRRuntimeRoleNone;
    static NSDictionary<NSString*, NSNumber*>* table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"_xt_check_bounds" : @(XTIRRuntimeRoleCheck),
            @"_xt_check_bounds_n" : @(XTIRRuntimeRoleCheck),
            @"_xt_check_interior" : @(XTIRRuntimeRoleCheck),
            @"_xt_check_object" : @(XTIRRuntimeRoleCheck),
            @"_xt_check_vtbl" : @(XTIRRuntimeRoleCheck),
            @"_xt_check_limit" : @(XTIRRuntimeRoleLimit),
            @"_xt_check_trap" : @(XTIRRuntimeRoleTrap),
            @"_xt_check_cast_trap" : @(XTIRRuntimeRoleTrap),
            @"_xt_check_vtbl_trap" : @(XTIRRuntimeRoleTrapReturns),
            @"_xt_check_put" : @(XTIRRuntimeRoleHelper),
            @"_xt_check_putNum" : @(XTIRRuntimeRoleHelper),
            @"_xt_check_vtbl_put" : @(XTIRRuntimeRoleHelper),
            @"_xt_check_vtbl_putHex" : @(XTIRRuntimeRoleHelper),
            @"_xt_check_vtbl_phdrs" : @(XTIRRuntimeRoleHelper),
            @"_xt_check_vtbl_image" : @(XTIRRuntimeRoleHelper),
            @"_xt_check_vtbl_lo" : @(XTIRRuntimeRoleData),
            @"_xt_check_vtbl_len" : @(XTIRRuntimeRoleData),
            @"_xt_check_vtbl_seen" : @(XTIRRuntimeRoleData),
        };
    });
    NSNumber* r = table[n];
    if (r)
        return (XTIRRuntimeRole)r.unsignedCharValue;
    return [n hasSuffix:@"_trap"] ? XTIRRuntimeRoleTrapReturns : XTIRRuntimeRoleHelper;
    }

// Part of the check runtime: not itself checked, and a call to it frees and
// writes nothing the program reads.
static inline BOOL XTIRRuntimeIsRuntime(NSString* _Nullable n)
    {
    return XTIRRuntimeRoleOf(n) != XTIRRuntimeRoleNone;
    }

// A failed check's report: the cold path of an inlined check.
static inline BOOL XTIRRuntimeIsTrap(NSString* _Nullable n)
    {
    XTIRRuntimeRole r = XTIRRuntimeRoleOf(n);
    return r == XTIRRuntimeRoleTrap || r == XTIRRuntimeRoleTrapReturns;
    }

// Never returns: the block can end at the call.
static inline BOOL XTIRRuntimeStops(NSString* _Nullable n)
    {
    return XTIRRuntimeRoleOf(n) == XTIRRuntimeRoleTrap;
    }

// Inlined with the checks, after bounds-elide, and not before.
static inline BOOL XTIRRuntimeInlinesWithChecks(NSString* _Nullable n)
    {
    return XTIRRuntimeIsRuntime(n) && !XTIRRuntimeIsTrap(n);
    }

NS_ASSUME_NONNULL_END
