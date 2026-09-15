// XTIRSymbol.h — symbol table entries (IR-SPEC §5)
#import <Foundation/Foundation.h>
#import "XTIRSupport.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIRType;
@class XTIRFunction;
@class XTIRLayout;

typedef NS_ENUM(uint8_t, XTIRSymbolKind) {
    XTIRSymbolKindFunction,
    XTIRSymbolKindDataGlobal,
    XTIRSymbolKindRuntimeHelper,
    XTIRSymbolKindZpEquate,
    XTIRSymbolKindStringLit,
    XTIRSymbolKindVTable,
};

/// Clobber set for runtime helpers (IR-SPEC §5, Lesson L10).
@interface XTIRClobberSet : NSObject
@property(nonatomic, readonly) NSArray<NSString*>* clobberedNames;
- (instancetype)initWithClobberedNames:(NSArray<NSString*>*)names;
@end

@interface XTIRSymbol : NSObject

@property(nonatomic, readonly) XTIRSymbolKind kind;
@property(nonatomic, readonly, copy) NSString* name;

// -- Function --
@property(nonatomic, readonly, nullable) XTIRFunction* function;
@property(nonatomic, readonly, nullable) XTIRType* functionType;

// -- DataGlobal --
@property(nonatomic, readonly, nullable) XTIRType* globalType;
@property(nonatomic, readonly) BOOL volatileAccess;
@property(nonatomic, readonly) BOOL escapes;
@property(nonatomic, readonly) BOOL taskLocal;
/// Initial bytes for a DataGlobal: nil = uninit (.lcomm / .space
/// in backends); non-nil = LE-packed payload (.byte / .data
/// emission). Set by the lowering's pre-scan when the
/// initialiser expression folds; left nil otherwise.
@property(nonatomic, copy, nullable) NSData* initialBytes;
/// A DataGlobal DEFINED IN ANOTHER MODULE (`extern`). Backends emit a reference to
/// the label and reserve NO storage — defining it here would give this module a second
/// copy whose writes never reach the other's.
///
/// Backed by the `extern` ATTRIBUTE, not a bare ivar: xtc-fe and xtcg-<arch> are
/// separate processes and the IR crosses between them as TEXT, so a property that the
/// printer does not emit is silently lost at the boundary. (It was, and the client
/// happily re-defined the global.)
@property(nonatomic) BOOL isExternalGlobal;

// -- RuntimeHelper --
@property(nonatomic, readonly, nullable) XTIRClobberSet* clobberSet;
@property(nonatomic, readonly) BOOL mayAlloc;
@property(nonatomic, readonly) BOOL mayThrow;

// -- ZpEquate --
@property(nonatomic, readonly) uint16_t address;

// -- StringLit --
@property(nonatomic, readonly, nullable) NSData* stringBytes;

// -- VTable --
@property(nonatomic, readonly, nullable) XTIRLayout* vtableLayout;
/// One method-function symbol name per vtable slot, in slot order
/// (bare names like `Sprite$draw`; the backend prefixes `_`). An empty
/// string marks an unfilled slot. Set by the lowering after the symbol
/// is built; the backend emits the vtable as `.word` of these labels.
@property(nonatomic, copy, nullable) NSArray<NSString*>* vtableEntryNames;

/// Symbol-level annotations parsed from the IR text format's
/// `attributes: { cloaked: false, banked: false, variadic: false, ... }`
/// block. Keys are attribute names; values are NSNumber-wrapped bools.
/// Defaults to an empty dictionary. The verifier reads `cloaked` and
/// `banked` here to enforce invariant §12.9.
@property(nonatomic, copy) NSDictionary<NSString*, NSNumber*>* attributes;

+ (instancetype)functionWithName:(NSString*)name
                        function:(nullable XTIRFunction*)function
                            type:(nullable XTIRType*)type;

+ (instancetype)dataGlobalWithName:(NSString*)name
                              type:(XTIRType*)type
                          volatile:(BOOL)volatileAccess
                           escapes:(BOOL)escapes
                         taskLocal:(BOOL)taskLocal;

+ (instancetype)runtimeHelperWithName:(NSString*)name
                           clobberSet:(XTIRClobberSet*)clobberSet
                             mayAlloc:(BOOL)mayAlloc
                             mayThrow:(BOOL)mayThrow;

+ (instancetype)zpEquateWithName:(NSString*)name address:(uint16_t)address;
+ (instancetype)stringLitWithName:(NSString*)name bytes:(NSData*)bytes;
+ (instancetype)vTableWithName:(NSString*)name layout:(nullable XTIRLayout*)layout;

@end

NS_ASSUME_NONNULL_END
