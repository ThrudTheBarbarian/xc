#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class XTASTNode;
@class XTTypeTable;

// Reads the `.xtc.iface` section that --emit-lib embedded in a binary xtc library
// (the inverse of XTInterfaceSerializer) and reconstructs its public declarations.
// This is the xtc-module sibling of XTDwarfReader (which imports C libraries): an
// app that `#import <XTGem>`s a .so gets its classes/protocols/enums back without
// the source, so it type-checks and dispatches against them; the bodies live in
// the .so (B1: binary xtc modules).
@interface XTInterfaceImporter : NSObject

// The `.xtc.iface` JSON embedded in the ELF `.so` at `path`, or nil if the file
// carries no such section (⇒ it's a C library, not an xtc module).
+ (nullable NSString*)interfaceJSONFromLibrary:(NSString*)path;

// Reconstruct the declarations described by `json`: register class/protocol/enum
// type markers in `tt` (so the importing source names them) and return the rebuilt
// declaration nodes to prepend to the program. Class method bodies are nil — they
// are external symbols (Class$method) the linker resolves against the .so.
/****************************************************************************\
|* The vtable slot indices a library committed to: @{ @"protocolSlots": …,
|* @"methodSlots": … }. The client must ADOPT these — its own numbering would
|* disagree, and the library's vtables are already emitted.
\****************************************************************************/
+ (NSDictionary*)slotsFromJSON:(NSString*)json;

/****************************************************************************\
|* The C libraries an imported xtc library depends on for its types (`#import
|* <GEM>`), so the client can re-import the SAME .so and resolve them from the one
|* source of truth. A reference, not a copy.
\****************************************************************************/
+ (NSArray<NSString*>*)cImportsFromJSON:(NSString*)json;

/****************************************************************************\
|* Type names an imported interface NAMED but that could not be resolved. Drained
|* by the driver and turned into real, FATAL diagnostics — printing to stderr and
|* carrying on is how the compiler ends up emitting a program built on a type it
|* silently replaced with `void`.
\****************************************************************************/
+ (NSArray<NSString*>*)drainUnresolvedTypeNames;

+ (NSArray<XTASTNode*>*)declarationsFromJSON:(NSString*)json
                               intoTypeTable:(XTTypeTable*)tt;

@end

NS_ASSUME_NONNULL_END
