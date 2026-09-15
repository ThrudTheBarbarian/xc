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
@property(nonatomic, readonly) NSArray<XTIRLayoutField*>* fields;

- (instancetype)initWithSize:(uint32_t)size
                   alignment:(uint8_t)alignment
                      fields:(NSArray<XTIRLayoutField*>*)fields;

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
