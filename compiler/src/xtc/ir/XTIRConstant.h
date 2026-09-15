// XTIRConstant.h — constant-pool entries (IR-SPEC §4)
#import <Foundation/Foundation.h>
#import "XTIRSupport.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIRType;

typedef NS_ENUM(uint8_t, XTIRConstantKind) {
    XTIRConstantKindInt,    // integer overflow constant
    XTIRConstantKindFloat,  // float/double (canonical IEEE double)
    XTIRConstantKindString, // string literal bytes
    XTIRConstantKindAgg,    // aggregate constant (struct/array literal)
};

@interface XTIRConstant : NSObject

@property(nonatomic, readonly) XTIRConstantKind kind;
@property(nonatomic, readonly) XTIRType* type;

// -- Int --
@property(nonatomic, readonly) int64_t intValue;

// -- Float (canonical IEEE 754 double bits) --
@property(nonatomic, readonly) uint64_t floatRawBytes;

// -- String --
@property(nonatomic, readonly, nullable) NSData* stringBytes;

// -- Agg (sub-constants) --
@property(nonatomic, readonly, nullable) NSArray<XTIRConstant*>* elements;

+ (instancetype)intConstantWithType:(XTIRType*)type value:(int64_t)value;
+ (instancetype)floatConstantWithType:(XTIRType*)type rawBytes:(uint64_t)rawBytes;
+ (instancetype)stringConstantWithBytes:(NSData*)bytes;
+ (instancetype)aggConstantWithElements:(NSArray<XTIRConstant*>*)elements type:(XTIRType*)type;

@end

NS_ASSUME_NONNULL_END
