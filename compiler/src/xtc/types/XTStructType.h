#import "XTType.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTStructField : NSObject

@property(nonatomic, readonly) NSString* fieldName;
@property(nonatomic, readonly) XTType* fieldType;
@property(nonatomic) NSUInteger byteOffset;

/****************************************************************************\
|* Create a struct field descriptor.
|* @param name  The field name.
|* @param type  The field's type.
|* @return A new struct field with byteOffset initialised to 0.
\****************************************************************************/
- (instancetype)initWithName:(NSString*)name type:(XTType*)type NS_DESIGNATED_INITIALIZER;

@end

@interface XTStructType : XTType

@property(nonatomic, readonly) NSString* structName;
@property(nonatomic, readonly) NSArray<XTStructField*>* fields;
// `:packed` — no padding anywhere: field offsets are the raw sum of the
// widths before them, and the total size is that sum with NO tail rounding
// (structAlignment reports 1). This is the byte-compatibility knob for
// kernel/wire structs like epoll_event (u32 @0, u64 @4, size 12), and it is
// what the DWARF importer marks C structs with (their padding arrives as
// explicit __padN fields, so tight packing reproduces the C offsets
// verbatim). Setting it re-lays existing fields, so parser/import order
// doesn't matter. docs/bugs/OPEN.md, blewit #3 and #5.
@property(nonatomic) BOOL packed;

/****************************************************************************\
|* The per-target cap on FIELD alignment (blewit #5). Unpacked struct fields
|* align to min(natural alignment, this cap):
|*   1 → tightly packed offsets (xt6502, and the default so unit tests and
|*       IR goldens that never configure a target keep today's layout)
|*   2 → the m68k C ABI (everything 2-aligned; also what keeps a u32 field
|*       off an odd address, where a 68000 takes an address error)
|*   8 → full C natural alignment (arm64 / x86_64 / win64 / arm9 / wasm32)
|* Set once per compile by the driver alongside setHeapPointerWidth: — the
|* offsets it produces are recorded in the IR layout, which every backend
|* reads verbatim, so FE and backend cannot disagree on an offset.
\****************************************************************************/
+ (void)setFieldAlignmentCap:(NSUInteger)cap;
+ (NSUInteger)fieldAlignmentCap;

/****************************************************************************\
|* Set both caps explicitly. The TAIL cap bounds what sizeof rounds up to
|* (bug 015): m68k caps it at 2 (its C ABI — sizeof{char,int} is 6), the
|* register targets at 8, and xt6502 keeps 8 (the historical pow2 rounding)
|* even though its field cap is 1. The one-argument setter derives the tail
|* cap (cap 1 → tail 8, else tail = cap), which is right for every target.
\****************************************************************************/
+ (void)setFieldAlignmentCap:(NSUInteger)cap tailCap:(NSUInteger)tailCap;
+ (NSUInteger)tailAlignmentCap;

/****************************************************************************\
|* Alignment a field of type `t` gets inside an UNPACKED aggregate: its
|* natural alignment (power-of-two width; a nested struct's structAlignment)
|* capped at fieldAlignmentCap. The one rule shared by struct layout, class
|* instance layout and tuple-return layout.
\****************************************************************************/
+ (NSUInteger)fieldAlignmentForType:(XTType*)t;

/****************************************************************************\
|* Create a struct type with the given name and fields. Byte offsets are
|* computed automatically: each field is placed at the next offset aligned
|* to fieldAlignmentForType: (tightly packed when the cap is 1 or the
|* struct is :packed).
|* @param name    The struct tag name.
|* @param fields  Array of XTStructField descriptors.
|* @return A new struct type.
\****************************************************************************/
+ (instancetype)structNamed:(NSString*)name fields:(NSArray<XTStructField*>*)fields;

/****************************************************************************\
|* Replace the fields of an existing struct type in place. Used by the
|* parser's forward-reference placeholder mechanism: a pre-scan over
|* top-level tokens registers an empty struct for every `struct Foo`
|* declaration so earlier code can name it, and the real declaration
|* later fills in the fields via this method. Any AST node that
|* captured the placeholder picks up the real fields automatically.
\****************************************************************************/
- (void)replaceFields:(NSArray<XTStructField*>*)fields;

/****************************************************************************\
|* Give an ANONYMOUS struct the name of the typedef that aliases it.
|*
|* `typedef struct { … } OBJECT;` — in C the typedef name IS the type's name,
|* but the DWARF reader had already called it `$anon_<DIE offset>`, and that is
|* the name --emit-lib then serialised. A client could not resolve it (its type
|* table knows `OBJECT`), so a C type imported from another library could not
|* cross an xtc library's interface at all — which blocks the whole category of
|* BINDING library. Only ever applied to a `$anon_` name; a real tag wins.
\****************************************************************************/
- (void)adoptTypedefName:(NSString*)name;

/****************************************************************************\
|* Look up a field by name.
|* @param fieldName  The field name to search for.
|* @return The matching field descriptor, or nil if not found.
\****************************************************************************/
- (nullable XTStructField*)fieldNamed:(NSString*)fieldName;

/****************************************************************************\
|* The struct's natural alignment: the max alignment of its members (a power
|* of two). `byteWidth` is rounded up to this, so an array of the struct
|* strides like the equivalent C array (bug 015).
\****************************************************************************/
- (NSUInteger)structAlignment;

@end

NS_ASSUME_NONNULL_END
