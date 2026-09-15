#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class XTProgramNode;

// Serialises a compiled module's PUBLIC declarations (classes, protocols, enums)
// into a JSON "module interface" — the payload embedded in a binary library's
// `.xtc.iface` ELF section under --emit-lib. An app that `#import <Lib>`s the .so
// reads this back to reconstruct the declarations (B1: binary xtc modules), so it
// can type-check and dispatch against the library without its source.
//
// Only declarations are captured (no statement bodies): the importing compiler
// re-lowers them with the same algorithm, so ivar offsets, vtable slots and the
// `Class$method` symbol mangling are recomputed identically — the bodies live in
// the .so, referenced by those deterministic names.
@interface XTInterfaceSerializer : NSObject
+ (nullable NSString*)jsonForProgram:(XTProgramNode*)program;

/****************************************************************************\
|* As above, but also records the VTABLE SLOT indices this build committed to.
|*
|* Slots are numbered per compilation unit, and a library's set of methods is not
|* the client's — so without this the client renumbers from 0 and dispatches
|* through a `Proto@` receiver into the wrong slot. The library's numbering has to
|* travel with it. `protocolSlots` is protocol → (method → slot); `methodSlots` is
|* label → slot.
\****************************************************************************/
+ (nullable NSString*)jsonForProgram:(XTProgramNode*)program
                       protocolSlots:(nullable NSDictionary*)protocolSlots
                         methodSlots:(nullable NSDictionary*)methodSlots;

/****************************************************************************\
|* As above, plus `cImports` — the C libraries this one `#import`ed, recorded as
|* a REFERENCE rather than a copy.
|*
|* A binding library's whole point is to expose a C library's types (Xtg's claim
|* is literally "a view IS a GEM object", so XGViewTree.objects() returns
|* OBJECT@). Those types come from libGEM's DWARF, not from this library's source,
|* so it cannot describe them — and it must not TRY: re-serialising OBJECT would
|* let two libraries silently disagree about its layout after an aes.h change, and
|* a layout disagreement across a .so is the worst failure this project has —
|* nothing type-checks it and nothing reports it.
|*
|* So record only WHERE the type lives. The client re-imports the same libGEM.so
|* through the same DWARF reader, and there is exactly one source of truth.
\****************************************************************************/
+ (nullable NSString*)jsonForProgram:(XTProgramNode*)program
                       protocolSlots:(nullable NSDictionary*)protocolSlots
                         methodSlots:(nullable NSDictionary*)methodSlots
                            cImports:(nullable NSArray<NSString*>*)cImports;

/****************************************************************************|* As above, excluding declarations whose source file is in `excludeFiles`
|* (standardized absolute paths — the driver's preludeFiles). The ambient
|* platform surface is every unit's; a module's interface must not re-export
|* it, or a consumer's own prelude collides with the metadata (task #36).
\****************************************************************************/
+ (nullable NSString*)jsonForProgram:(XTProgramNode*)program
                       protocolSlots:(nullable NSDictionary*)protocolSlots
                         methodSlots:(nullable NSDictionary*)methodSlots
                            cImports:(nullable NSArray<NSString*>*)cImports
                        excludeFiles:(nullable NSSet<NSString*>*)excludeFiles;
@end

NS_ASSUME_NONNULL_END
