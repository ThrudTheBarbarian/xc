// XTIRLayout.h — aggregate layout descriptor (IR-SPEC §3 "Layouts")
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class XTIRType;

@interface XTIRLayoutField : NSObject
@property(nonatomic, readonly) uint32_t byteOffset;
@property(nonatomic, readonly) XTIRType* type;

- (instancetype)initWithOffset:(uint32_t)byteOffset type:(XTIRType*)type;
@end

@interface XTIRLayout : NSObject <NSCopying>
@property(nonatomic, readonly) uint32_t size;
@property(nonatomic, readonly) uint8_t alignment;

/****************************************************************************\
|* The fields. An ARRAY layout (`u32 xs[N]`: N elements of one type, each at
|* i * stride) keeps no field objects: it answers fieldCount, fieldTypeAt:
|* and fieldOffsetAt: from its element and count, and `fields` is built on
|* demand for the consumers that walk a list. A 64M-element global used to
|* be 64M field objects — a two-minute, 23 GB compile — so a reader that
|* needs a count, a type or an offset takes the accessors and never builds it.
\****************************************************************************/
@property(nonatomic, readonly) NSArray<XTIRLayoutField*>* fields;
@property(nonatomic, readonly) BOOL isArray;
@property(nonatomic, readonly, nullable) XTIRType* elementType;  // array form only
@property(nonatomic, readonly) uint32_t elementCount;            // array form only
@property(nonatomic, readonly) uint32_t elementStride;           // array form only
@property(nonatomic, readonly) NSUInteger fieldCount;
- (nullable XTIRType*)fieldTypeAt:(NSUInteger)idx;
- (uint32_t)fieldOffsetAt:(NSUInteger)idx;

- (instancetype)initWithSize:(uint32_t)size
                   alignment:(uint8_t)alignment
                      fields:(NSArray<XTIRLayoutField*>*)fields;
- (instancetype)initArrayOf:(XTIRType*)elementType
                      count:(uint32_t)count
                     stride:(uint32_t)stride
                  alignment:(uint8_t)alignment;

/****************************************************************************\
|* Fill in a layout's size and fields after construction. Used ONLY to break
|* self-referential struct cycles during IR lowering: the layout object must
|* be created and registered (so a pointer-to-self field resolves to THIS
|* same object) before its fields — which reference it — can be built. After
|* the fields are ready, this fills them in place so every captured
|* `Ptr(Agg(self))` sees the completed layout. Not for general mutation.
\****************************************************************************/
- (void)fillWithSize:(uint32_t)size fields:(NSArray<XTIRLayoutField*>*)fields;
@end

NS_ASSUME_NONNULL_END
