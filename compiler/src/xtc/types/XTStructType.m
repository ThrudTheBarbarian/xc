#import "XTStructType.h"
#import "XTPointerType.h"
#import "XTArrayType.h"

// Natural alignment of a type, for C-ABI struct layout (bug 015). A scalar leaf
// aligns to its byte width when that is a power of two (every C scalar: i8→1,
// i16→2, i32/f32→4, pointer/f64→8); a width that is NOT a power of two — xtc's
// 5-byte float or xt6502's 3-byte pointer, neither of which has a C counterpart —
// imposes no alignment (1). A nested struct aligns to its own alignment; an array
// to its element's. This is what the struct's total size is rounded up to so an
// array of the struct strides the same as the equivalent C array.
static NSUInteger XTAlignOfType(XTType* t);
static NSUInteger XTWeakLinkBytesFor(XTType* ty);
static NSUInteger sTailAlignCap; // defined below, near sFieldAlignCap
static NSUInteger XTStructAlignment(XTStructType* s)
    {
    // `:packed` — no alignment at all. Field offsets are ALREADY tight on
    // every layer (the FE accumulates raw widths; the backends sum their own
    // widths), so the only thing natural alignment ever contributed was the
    // bug-015 TAIL rounding of the total — which is exactly what broke
    // epoll_event: offsets 0/4 were already right, but sizeof said 16 where
    // the kernel strides 12. Packed structs skip the rounding, and a packed
    // struct nested in a normal one contributes alignment 1.
    if (s.packed)
        return 1;
    NSUInteger a = 1;
    for (XTStructField* f in s.fields)
        {
        NSUInteger fa = XTAlignOfType(f.fieldType);
        if (fa > a)
            a = fa;
        }
    // The TAIL cap: what sizeof's rounding is limited to. 2 on m68k (its C
    // ABI: sizeof{char,int} is 6, not 8); 8 everywhere else — including
    // xt6502, which keeps the original bug-015 pow2 rounding (it has no C
    // ABI to match; the rounding IS its ABI) even though its FIELD cap is 1.
    return MIN(a, sTailAlignCap) ?: 1;
    }
static NSUInteger XTAlignOfType(XTType* t)
    {
    if (!t)
        return 1;
    if ([t isKindOfClass:[XTStructType class]])
        return XTStructAlignment((XTStructType*)t);
    if ([t isKindOfClass:[XTArrayType class]])
        return XTAlignOfType(((XTArrayType*)t).elementType);
    NSUInteger w = t.byteWidth;
    return (w && (w & (w - 1)) == 0) ? w : 1; // power-of-two width → that alignment, else 1
    }

// The per-target FIELD alignment cap (blewit #5): 1 = tightly packed offsets
// (xt6502, and the default), 2 = the m68k C ABI, 8 = full natural alignment.
// The driver sets it alongside setHeapPointerWidth:. The offsets the cap
// produces are recorded in the IR layout, which the backends read verbatim.
static NSUInteger sFieldAlignCap = 1;
// The TAIL alignment cap: what sizeof rounds up to (bug 015). Separate from
// the field cap because xt6502 packs fields (cap 1) but KEEPS the pow2 tail
// rounding (cap 8) — its historical ABI — while m68k caps both at 2 (its C
// ABI). Default 8 = today's uncapped pow2 rule for every unconfigured path.
static NSUInteger sTailAlignCap = 8;

// Lay `fields` out in declaration order: hidden weak/bound link words first,
// then the payload at the next offset aligned to the field's (capped) natural
// alignment — so the links stay immediately before the payload, and any pad
// falls before the links. `packed` forces alignment 1 everywhere. Returns the
// tight end of the last field (NOT tail-rounded; byteWidth does the rounding).
static NSUInteger XTLayoutStructFields(NSArray<XTStructField*>* fields, BOOL packed)
    {
    NSUInteger offset = 0;
    for (XTStructField* f in fields)
        {
        NSUInteger link = XTWeakLinkBytesFor(f.fieldType);
        NSUInteger a = packed ? 1 : [XTStructType fieldAlignmentForType:f.fieldType];
        offset = ((offset + link) + a - 1) & ~(a - 1); // payload position
        f.byteOffset = offset;
        offset += f.fieldType.byteWidth;
        }
    return offset;
    }

@implementation XTStructField

/****************************************************************************\
|* Create a struct field descriptor.
|* @param name  The field name.
|* @param type  The field's type.
|* @return A new struct field with byteOffset initialised to 0.
\****************************************************************************/
- (instancetype)initWithName:(NSString*)name type:(XTType*)type
    {
    self = [super init];
    if (self)
        {
        _fieldName = [name copy];
        _fieldType = type;
        _byteOffset = 0;
        }
    return self;
    }

@end

@implementation XTStructType

/****************************************************************************\
|* Internal initialiser. Computes tightly-packed byte offsets for each field.
|* @param name    The struct tag name.
|* @param fields  Array of XTStructField descriptors.
|* @return A new struct type.
\****************************************************************************/

/****************************************************************************\
|* Bytes of hidden LINK words a field needs before its payload.
|*
|* An auto-zeroing slot — `weak:T@` or a bound method (`^`) — is linked into its
|* referent's chain, and the links live immediately before the payload
|* (slot[-2] = pprev, slot[-1] = next). Reserving them HERE, in the AST layout,
|* means the field's byteOffset already points at the payload and the struct's
|* byteWidth already includes them — so the IR layout mirrors it and NO field
|* index shifts. See private:docs/Design/weak-refs-intrusive.md.
\****************************************************************************/
static NSUInteger XTWeakLinkBytesFor(XTType* ty)
    {
    if (!ty)
        return 0;
    BOOL weakPtr = [ty isKindOfClass:[XTPointerType class]] && ((XTPointerType*)ty).isWeak;
    BOOL bound = ty.boundMethodSignature != nil;
    if (!weakPtr && !bound)
        return 0;
    return 2 * [XTPointerType pointerToType:[XTType u8Type]].byteWidth;
    }

- (instancetype)initWithStructName:(NSString*)name fields:(NSArray<XTStructField*>*)fields
    {
    // `packed` isn't known yet on this path (the parser sets it after the
    // type exists); the setter re-lays, so lay unpacked here.
    XTLayoutStructFields(fields, NO);
    self = [super initWithKind:XTTypeKindStruct displayName:name];
    if (self)
        {
        _structName = [name copy];
        _fields = [fields copy];
        }
    return self;
    }

/****************************************************************************\
|* Create a struct type with the given name and fields.
|* @param name    The struct tag name.
|* @param fields  Array of XTStructField descriptors.
|* @return A new struct type.
\****************************************************************************/
+ (instancetype)structNamed:(NSString*)name fields:(NSArray<XTStructField*>*)fields
    {
    return [[self alloc] initWithStructName:name fields:fields];
    }

/****************************************************************************\
|* Replace the fields of an existing struct type in place. Used by the
|* parser's forward-reference placeholder mechanism. Recomputes byte offsets.
|* @param fields  The new array of field descriptors.
\****************************************************************************/
- (void)adoptTypedefName:(NSString*)name
    {
    if (name.length == 0)
        return;
    if (![_structName hasPrefix:@"$anon_"])
        return; // a real tag already: keep it
    _structName = [name copy];
    [self overrideDisplayName:name];
    }

- (void)replaceFields:(NSArray<XTStructField*>*)fields
    {
    XTLayoutStructFields(fields, _packed);
    _fields = [fields copy];
    }

/****************************************************************************\
|* `:packed` participates in FIELD layout (not just tail rounding), and it is
|* set after the type exists on both the parser and the import paths — so
|* setting it re-lays the fields. Order-independent by construction.
\****************************************************************************/
- (void)setPacked:(BOOL)packed
    {
    if (_packed == packed)
        return;
    _packed = packed;
    XTLayoutStructFields(_fields, _packed);
    }

+ (void)setFieldAlignmentCap:(NSUInteger)cap
    {
    [self setFieldAlignmentCap:cap tailCap:(cap == 1 ? 8 : cap)];
    }

+ (void)setFieldAlignmentCap:(NSUInteger)cap tailCap:(NSUInteger)tailCap
    {
    NSAssert(cap == 1 || cap == 2 || cap == 4 || cap == 8,
             @"field alignment cap must be a power of two ≤ 8");
    NSAssert(tailCap == 1 || tailCap == 2 || tailCap == 4 || tailCap == 8,
             @"tail alignment cap must be a power of two ≤ 8");
    sFieldAlignCap = cap ?: 1;
    sTailAlignCap = tailCap ?: 8;
    }

+ (NSUInteger)fieldAlignmentCap
    {
    return sFieldAlignCap;
    }

+ (NSUInteger)tailAlignmentCap
    {
    return sTailAlignCap;
    }

+ (NSUInteger)fieldAlignmentForType:(XTType*)t
    {
    NSUInteger a = XTAlignOfType(t);
    return MIN(a, sFieldAlignCap) ?: 1;
    }

/****************************************************************************\
|* Total size of the struct in bytes (sum of all field widths, tightly packed).
|* @return The total byte width.
\****************************************************************************/
- (NSUInteger)structAlignment
    {
    return XTStructAlignment(self);
    }

- (NSUInteger)byteWidth
    {
    // End of the last field as laid out (fields carry their real offsets, so
    // inter-field padding is included; a field's hidden weak links precede
    // its byteOffset and are inside the previous field's gap or the running
    // offset either way).
    NSUInteger total = 0;
    for (XTStructField* f in _fields)
        {
        NSUInteger end = f.byteOffset + f.fieldType.byteWidth;
        if (end > total)
            total = end;
        }
    // Round the total up to the struct's alignment (bug 015): C rounds `sizeof`
    // up so an array strides correctly, and the IR layout / every backend must
    // agree, or an optimised array access folds the wrong stride out of the IR
    // layout (see private:docs/Design/type-width-invariant.md). align is a power of two.
    NSUInteger align = XTStructAlignment(self);
    return (total + align - 1) & ~(align - 1);
    }

/****************************************************************************\
|* Look up a field by name.
|* @param fieldName  The field name to search for.
|* @return The matching field descriptor, or nil if not found.
\****************************************************************************/
- (nullable XTStructField*)fieldNamed:(NSString*)fieldName
    {
    for (XTStructField* f in _fields)
        {
        if ([f.fieldName isEqualToString:fieldName])
            return f;
        }
    return nil;
    }

@end
