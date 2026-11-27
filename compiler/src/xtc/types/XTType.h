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
    // A small float, one width (f16 or f8) in one pack: f16 (IEEE binary16,
    // pack e5m10), bf16 (pack e8m7), f8 (OCP E4M3), f8:pack(e5m2) and the
    // rest. Every pack is a distinct type object of this kind, one per name
    // (packTypeNamed:); packExpBits/packMantBits/packKind say which. The value
    // is its bit pattern: the IR holds it as a U16 or a U8, and every
    // operation converts through f32 (FloatPack.xc, FloatPackKinds.xc).
    XTTypeKindPack,
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
/// A class held by value — a struct field `V v;` — is the instance inline
/// (#756): once lowering has laid the class out it records the instance's
/// size here, for struct layout. A class type's own byteWidth is unchanged.
+ (void)setInstanceByteWidth:(NSUInteger)width forClassNamed:(NSString*)name;
+ (NSUInteger)instanceByteWidthForClassNamed:(NSString*)name;

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
/// f16, IEEE binary16 (pack e5m10).
+ (instancetype)f16Type;
/// bf16, bfloat16 (pack e8m7), spelled `f16:pack(e8m7)` too.
+ (instancetype)bf16Type;
/// f8, OCP FP8 E4M3 (pack e4m3, finite).
+ (instancetype)f8Type;
/// f4, OCP MX FP4 (pack e2m1, none): a byte as a scalar, a nibble in an
/// array (XTArrayType).
+ (instancetype)f4Type;
/// The pack type a canonical name denotes (`f16`, `bf16`, `f8`, `f8$e5m2`,
/// `f8$ue8m0`, `f8$e4m3$ieee`, `f16$e6m9`), one object per name; nil for any
/// other name. A diagnostic writes `f8$e5m2` as `f8:pack(e5m2)`.
+ (nullable XTType*)packTypeNamed:(NSString*)name;
/// The canonical name of `base:pack(pk)` or `base:pack(pk, kind)` (kind nil
/// when not written), as the parser fuses it: nil with *err set when the
/// pack is refused, the message saying what to write.
+ (nullable NSString*)packNameForBase:(NSString*)base
                                 pack:(NSString*)pk
                                 kind:(nullable NSString*)kind
                                error:(NSString* _Nullable* _Nonnull)err;
/// YES for a small float (f16, bf16, f8 and their packs). Neither isInteger
/// nor isFloating: its value is a bit pattern, converted through f32 for
/// every operation.
@property(nonatomic, readonly) BOOL isFloatPack;
/// The pack's exponent and mantissa widths (f16 5/10, bf16 8/7, f8 4/3,
/// ue8m0 8/0); 0 otherwise.
@property(nonatomic, readonly) NSUInteger packExpBits;
@property(nonatomic, readonly) NSUInteger packMantBits;
/// The pack's special values: 0 ieee (infinities and NaNs), 1 finite (no
/// infinity, the all-ones pattern is NaN), 2 none (neither).
@property(nonatomic, readonly) NSUInteger packKind;
/// YES for an unsigned scale pack (ue8m0): no sign bit, the value 2^(E-127),
/// 0xFF NaN, no zero.
@property(nonatomic, readonly) BOOL packUnsigned;
/// The routines' pack word beyond (e, m): the kind, with 4 for unsigned.
/// 0 for an ieee signed pack, which FloatPack.xc's routines take as (e, m).
@property(nonatomic, readonly) uint32_t packFlags;
/// YES for f4 (step F4). An f4 array element is half a byte, two to a byte
/// with element 0 in the low nibble, so it has no address: `f4[]`, a pointer
/// to f4 inside, references an array's first byte and is indexed, never
/// dereferenced or stepped.
@property(nonatomic, readonly) BOOL isF4;
/// An `f4[]` (a pointer to f4).
+ (BOOL)isF4Ref:(nullable XTType*)t;
/// An f4 array, `f4[N]` (or `f4[]` before its initialiser sizes it).
+ (BOOL)isF4Array:(nullable XTType*)t;
/// YES for the two packs C has (_Float16 and __bf16): f16 and bf16.
@property(nonatomic, readonly) BOOL isCPack;
/// The pack's sign bit (0x8000 for f16, 0x80 for f8), 0 when unsigned.
@property(nonatomic, readonly) uint32_t packSignBit;
/// The pack's largest finite value (f16 65504, f8 448).
@property(nonatomic, readonly) double packMaxFinite;
/// It as a diagnostic writes it: `65504`, `448`, `3.39e38`.
@property(nonatomic, readonly) NSString* packMaxFiniteText;
/// A double rounded to the pack (nearest, ties to even, subnormals kept; too
/// large: an infinity where the pack has one, else its largest finite
/// value), as its bit pattern. The routines' _xt_fpk_pack_f64(k).
- (uint16_t)packBitsForDouble:(double)v;
/// Is a literal of this value beyond the pack: rounds past its largest
/// finite value, or (unsigned) is zero or negative?
- (BOOL)packLiteralOutOfRange:(double)v;
/// Does every value of `from` (a pack, f32 or f64) convert exactly to `to`
/// (the same), its infinities and NaNs included?
+ (BOOL)packHolds:(XTType*)from in:(XTType*)to;
/// Can a value of `from` reach a slot of `to` with no cast? Only when every
/// value converts exactly (packHolds:in:): a pack to itself, to a pack that
/// holds it, to f32 or f64. An integer reaches a pack through a cast (a
/// literal takes the pack's type at the site). Asked only when one side is a
/// pack.
+ (BOOL)packConvertsImplicitly:(XTType*)from to:(XTType*)to;

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

/****************************************************************************\
|* The type an operand of `+` or `-` takes part as: a one-dimensional array
|* decays to a pointer to its element when the other operand is an integer, a
|* pointer or such an array. Any other type is returned unchanged.
\****************************************************************************/
+ (XTType*)arithmeticDecay:(XTType*)t other:(XTType*)other;

@end

NS_ASSUME_NONNULL_END
