#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, XTTypeKind) {
    XTTypeKindI8,
    XTTypeKindU8,
    XTTypeKindI16,
    XTTypeKindU16,
    XTTypeKindI32,
    XTTypeKindU32,
    XTTypeKindBool,
    XTTypeKindFloat,
    XTTypeKindDouble,
    XTTypeKindVoid,
    XTTypeKindPointer, // pointer-to-type
    XTTypeKindArray,
    XTTypeKindStruct,
    XTTypeKindEnum,
    XTTypeKindFunction,
    XTTypeKindClass,
    XTTypeKindAuto, // placeholder until inference resolves it
    // Appended so no existing kind's value shifts — several places persist or
    // compare these numerically, and renumbering broke auto-inference and the
    // DWARF struct import.
    XTTypeKindI64,
    XTTypeKindU64,
};

@interface XTType : NSObject <NSCopying>

@property(nonatomic, readonly) XTTypeKind kind;
@property(nonatomic, readonly) NSString* displayName;

/****************************************************************************\
|* Designated initialiser for type objects.
|* @param kind  The type-kind enum value.
|* @param name  The human-readable display name for diagnostics.
|* @return A new type object.
\****************************************************************************/
- (instancetype)initWithKind:(XTTypeKind)kind displayName:(NSString*)name NS_DESIGNATED_INITIALIZER;

/****************************************************************************\
|* Rename a type in place. Exists for ONE caller: the DWARF reader, giving an
|* anonymous struct the name of the typedef that aliases it (see
|* XTStructType.adoptTypedefName:). Do not use it for anything else — an XTType's
|* name is its identity in the type table.
\****************************************************************************/
- (void)overrideDisplayName:(NSString*)name;

/****************************************************************************\
|* Width in bytes. 0 for void/auto.
\****************************************************************************/
@property(nonatomic, readonly) NSUInteger byteWidth;

/****************************************************************************\
|* YES for i8/i16/i32.
\****************************************************************************/
@property(nonatomic, readonly) BOOL isSigned;
/****************************************************************************\
|* YES for i8/u8/i16/u16/i32/u32/bool/enum.
\****************************************************************************/
@property(nonatomic, readonly) BOOL isInteger;
/****************************************************************************\
|* YES for float or double.
\****************************************************************************/
@property(nonatomic, readonly) BOOL isFloating;
/****************************************************************************\
|* YES for pointer / array / string.
\****************************************************************************/
@property(nonatomic, readonly) BOOL isPointerLike;
/****************************************************************************\
|* YES for void.
\****************************************************************************/
@property(nonatomic, readonly) BOOL isVoid;
/****************************************************************************\
|* YES for auto.
\****************************************************************************/
@property(nonatomic, readonly) BOOL isAuto;
/****************************************************************************\
|* PR9: protocol constraint for class-marker types. Stamped on a
|* cloned class-kind marker when the user writes a bare protocol
|* name as a type (`Drawable` / `Drawable@`). The pointer pointee
|* carries the protocol name so sema's method-call resolution can
|* route through the protocol's method set. nil on every other
|* type; set only by the parser for protocol-typed uses.
\****************************************************************************/
@property(nonatomic, copy, nullable) NSString* protocolConstraint;

/****************************************************************************\
|* Element type of a typed collection — the `String` in `Array<String>*`.
|*
|* Typed collections are ERASED: there is one `Array` at runtime, holding
|* `Object*` exactly as it always has, and this field exists only so sema can
|* substitute. On a call whose RECEIVER carries one, every `Object*` in the
|* callee's signature reads as this type instead: `get` returns `String*`
|* without a cast, and `add` refuses anything that is not a `String*`.
|*
|* That substitution is why the standard library needs no generic declaration
|* and no second copy of anything — which is the point, because instantiating
|* a container per element type would multiply its code on a target where a
|* function cannot span a 12 KB bank.
|*
|* nil on every other type; set only by the parser for `C<T>` uses.
|* See private:docs/Design/typed-collections.md.
\****************************************************************************/
@property(nonatomic, strong, nullable) XTType* collectionElementType;

/****************************************************************************\
|* The KEY of a two-argument collection — the `K` in `Map<K, V>`; the value is
|* `collectionElementType`.
|*
|* One argument leaves this nil, which is what keeps `Array<T>`, `Set<T>` and
|* the legacy `Map<V>` spelling behaving exactly as before. The substitution
|* rule is positional against what the container's signature ERASES to:
|* `Object*` takes the element/value, `Hashable*` takes the key — and the key
|* only when a second argument was actually written, so a `Map<V>` leaves its
|* keys unchecked as it always did.
|*
|* nil on every other type. See private:docs/bugs/049.
\****************************************************************************/
@property(nonatomic, strong, nullable) XTType* collectionKeyType;

/****************************************************************************\
|* Bound-method ("fat pointer") tag. Set on the compiler-synthesised
|* 2-field struct that `<fn-typedef>^` denotes — `{recv, code}` — and holds
|* the XTFunctionType the `^` was taken on, so sema can type-check a call
|* through it and lowering knows the callee's signature.
|*
|* A `^` is deliberately a plain struct: struct-by-value already works on
|* every backend (pass, return, store, call through a field), so this reuses
|* proven paths rather than inventing a new multi-word value kind — and the
|* front-end and backend widths therefore agree by construction, which keeps
|* it clear of the type-width invariant (private:docs/Design/type-width-invariant.md).
|*
|* nil on every other type. Declared as XTType* rather than XTFunctionType*
|* only to avoid a circular import; it is always an XTFunctionType.
|* See private:docs/Design/bound-methods.md.
\****************************************************************************/
@property(nonatomic, strong, nullable) XTType* boundMethodSignature;

/****************************************************************************\
|* `weak:` on a bound method (`weak:action_t^ action;`). A `^` NEVER owns its
|* recv, so this does not mean "don't retain" (nothing retains it anyway) — it
|* means AUTO-ZERO: register the `^` in the weak side table so it goes falsy
|* the instant the receiver dies. That is AppKit's target semantics.
|*
|* The registered slot is the `^`'s CODE word, not its recv. Zeroing recv would
|* leave code non-null, so `if (h)` — which tests code — would stay TRUE and the
|* call would pass `self = 0`, which is worse than a dangling pointer. Zeroing
|* code makes the `^` correctly falsy, and recv is then never read.
|*
|* A separate interned type from the strong `^` of the same signature (the type
|* object is shared, so the flag can't be stamped on the common one).
|* See private:docs/Design/bound-methods.md.
\****************************************************************************/
@property(nonatomic) BOOL isWeakBound;

/****************************************************************************\
|* Convenience singleton accessors for all scalar types. Each returns the
|* same instance on every call (dispatch_once singletons).
\****************************************************************************/
+ (instancetype)i8Type;
+ (instancetype)u8Type;
+ (instancetype)i16Type;
+ (instancetype)u16Type;
+ (instancetype)i32Type;
+ (instancetype)u32Type;
+ (instancetype)i64Type;
+ (instancetype)u64Type;
+ (instancetype)boolType;
+ (instancetype)floatType;

/****************************************************************************\
|* The target's `float` storage: 4 bytes of IEEE-754 single on every native
|* backend, 5 bytes of xtc's own format on xt6502. Set once per compilation
|* from the selected target, exactly like XTPointerType's pointer width — the
|* AST/IR layout MUST agree with what the backend lays out, because the IR opt
|* passes fold field and element offsets straight out of the layout. When they
|* disagreed (AST float 5, arm64 F32 4) a struct's element stride came out one
|* byte long and every element after the first was read shifted.
\****************************************************************************/
+ (NSUInteger)floatWidth;
+ (void)setFloatWidth:(NSUInteger)width;
/// YES when the target stores floats as IEEE-754 (all but xt6502's 5-byte).
+ (BOOL)floatIsIEEE;
+ (void)setFloatIsIEEE:(BOOL)isIEEE;
+ (instancetype)doubleType;
+ (instancetype)voidType;
+ (instancetype)autoType;
/****************************************************************************\
|* Bare pointer type (2-byte address, no pointee information).
\****************************************************************************/
+ (instancetype)pointerType;

/****************************************************************************\
|* Returns YES if this type can be implicitly converted to `other` without data loss.
\****************************************************************************/
- (BOOL)isCompatibleWithType:(XTType*)other;

/****************************************************************************\
|* Returns the wider of the two types for binary-op type promotion.
\****************************************************************************/
+ (XTType*)widenType:(XTType*)a with:(XTType*)b;

@end

NS_ASSUME_NONNULL_END
