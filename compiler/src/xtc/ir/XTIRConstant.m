// XTIRConstant.m
#import "XTIRConstant.h"
#import "XTIRType.h"

@interface XTIRConstant ()
@property(nonatomic, readwrite) XTIRConstantKind kind;
@property(nonatomic, readwrite) XTIRType* type;
@property(nonatomic, readwrite) int64_t intValue;
@property(nonatomic, readwrite) uint64_t floatRawBytes;
@property(nonatomic, readwrite, nullable) NSData* stringBytes;
@property(nonatomic, readwrite, nullable) NSArray<XTIRConstant*>* elements;
@end

@implementation XTIRConstant

+ (instancetype)intConstantWithType:(XTIRType*)type value:(int64_t)value
    {
    XTIRConstant* c = [[self alloc] init];
    c.kind = XTIRConstantKindInt;
    c.type = type;
    c.intValue = value;
    return c;
    }

+ (instancetype)floatConstantWithType:(XTIRType*)type rawBytes:(uint64_t)rawBytes
    {
    XTIRConstant* c = [[self alloc] init];
    c.kind = XTIRConstantKindFloat;
    c.type = type;
    c.floatRawBytes = rawBytes;
    return c;
    }

+ (instancetype)stringConstantWithBytes:(NSData*)bytes
    {
    XTIRConstant* c = [[self alloc] init];
    c.kind = XTIRConstantKindString;
    c.type = [XTIRType ptrToType:[XTIRType u8Type] window:XTIRWindowUnbanked];
    c.stringBytes = bytes;
    return c;
    }

+ (instancetype)aggConstantWithElements:(NSArray<XTIRConstant*>*)elements type:(XTIRType*)type
    {
    XTIRConstant* c = [[self alloc] init];
    c.kind = XTIRConstantKindAgg;
    c.type = type;
    c.elements = elements;
    return c;
    }

@end
