#import <Foundation/Foundation.h>
#import "XTType.h"

NS_ASSUME_NONNULL_BEGIN

/****************************************************************************\
|* One exported function discovered in a shared library's `.dynsym` ∩ DWARF.
|* The name is the dynamic-symbol name (what the client links against); the
|* signature is reconstructed from the matching DWARF `DW_TAG_subprogram`.
\****************************************************************************/
@interface XTDwarfFunction : NSObject

@property(nonatomic, readonly) NSString* name;
/****************************************************************************\
|* void-returning functions carry XTType.voidType here (never nil).
\****************************************************************************/
@property(nonatomic, readonly) XTType* returnType;
@property(nonatomic, readonly) NSArray<XTType*>* paramTypes;
/****************************************************************************\
|* Parameter names where DWARF recorded them (parallel to paramTypes; an
|* entry is the empty string when the parameter was anonymous).
\****************************************************************************/
@property(nonatomic, readonly) NSArray<NSString*>* paramNames;
@property(nonatomic, readonly) BOOL isVarArgs;

- (instancetype)initWithName:(NSString*)name
                  returnType:(XTType*)returnType
                  paramTypes:(NSArray<XTType*>*)paramTypes
                  paramNames:(NSArray<NSString*>*)paramNames
                   isVarArgs:(BOOL)isVarArgs NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

/****************************************************************************\
|* The importable interface of one shared library, derived entirely from the
|* `.so` itself: its `.dynsym` export set intersected with the type/signature
|* information in its DWARF. This is the value `#import <lib>` brings into
|* scope — typed function declarations plus first-class named types whose
|* layouts are pinned byte-for-byte to the DWARF the library was built with.
\****************************************************************************/
@interface XTDwarfInterface : NSObject

/****************************************************************************\
|* The DT_SONAME recorded in `.dynamic` (what a client's DT_NEEDED must name),
|* or the file's base name if the library carries no explicit soname.
\****************************************************************************/
@property(nonatomic, readonly) NSString* soname;
/****************************************************************************\
|* The filesystem path the interface was read from (the sysroot `.so`). The
|* driver links against this path so the linker records DT_NEEDED from its
|* DT_SONAME. Empty when read from an in-memory image.
\****************************************************************************/
@property(nonatomic, copy) NSString* sourcePath;
/****************************************************************************\
|* The raw export-name set from `.dynsym` (GLOBAL/WEAK, defined). Names here
|* without a DWARF signature are exports the importer could not type.
\****************************************************************************/
@property(nonatomic, readonly) NSSet<NSString*>* exports;
/****************************************************************************\
|* Exported functions that were successfully typed (name ∈ exports AND a
|* DWARF subprogram described them). Keyed by name in `functionsByName`.
\****************************************************************************/
@property(nonatomic, readonly) NSArray<XTDwarfFunction*>* functions;
@property(nonatomic, readonly) NSDictionary<NSString*, XTDwarfFunction*>* functionsByName;
/****************************************************************************\
|* Named aggregate / typedef / enum types discovered in the DWARF, keyed by
|* name (struct tag, typedef name, or enum tag). These become first-class
|* xtc types on import. Layouts honour DW_AT_data_member_location and
|* DW_AT_byte_size verbatim (padding reconstructed as explicit bytes).
\****************************************************************************/
@property(nonatomic, readonly) NSDictionary<NSString*, XTType*>* types;

/****************************************************************************\
|* Every enumerator discovered in the DWARF, keyed by name — INCLUDING those
|* of ANONYMOUS enums.
|*
|* C headers routinely declare their constants as anonymous enums:
|*
|*     enum { G_BOX = 20, ..., G_USERDEF = 24 };
|*     enum { OF_NONE = 0x00, ..., OF_HIDETREE = 0x80 };
|*
|* Nothing references such an enum's TYPE, so it is never reached through
|* typeForRef: and its constants were invisible on import — every binding had
|* to hand-mirror them, and silently drifted when the header changed. These are
|* collected by sweeping ALL DIEs, not by following type references.
\****************************************************************************/
@property(nonatomic, readonly) NSDictionary<NSString*, NSNumber*>* enumConstants;

- (instancetype)initWithSoname:(NSString*)soname
                       exports:(NSSet<NSString*>*)exports
                     functions:(NSArray<XTDwarfFunction*>*)functions
                         types:(NSDictionary<NSString*, XTType*>*)types;
- (instancetype)initWithSoname:(NSString*)soname
                       exports:(NSSet<NSString*>*)exports
                     functions:(NSArray<XTDwarfFunction*>*)functions
                         types:(NSDictionary<NSString*, XTType*>*)types
                 enumConstants:(NSDictionary<NSString*, NSNumber*>*)enumConstants NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
