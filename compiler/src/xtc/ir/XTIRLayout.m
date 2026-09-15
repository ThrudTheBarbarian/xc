// XTIRLayout.m
#import "XTIRLayout.h"

#pragma mark - XTIRLayoutField

@implementation XTIRLayoutField

- (instancetype)initWithOffset:(uint32_t)byteOffset type:(XTIRType*)type
    {
    self = [super init];
    if (self)
        {
        _byteOffset = byteOffset;
        _type = type;
        }
    return self;
    }

@end

#pragma mark - XTIRLayout

@implementation XTIRLayout

- (instancetype)initWithSize:(uint32_t)size
                   alignment:(uint8_t)alignment
                      fields:(NSArray<XTIRLayoutField*>*)fields
    {
    self = [super init];
    if (self)
        {
        _size = size;
        _alignment = alignment;
        _fields = [fields copy];
        }
    return self;
    }

- (void)fillWithSize:(uint32_t)size fields:(NSArray<XTIRLayoutField*>*)fields
    {
    _size = size;
    _fields = [fields copy];
    }

- (id)copyWithZone:(nullable NSZone*)zone
    {
    return [[XTIRLayout alloc] initWithSize:self.size
                                  alignment:self.alignment
                                     fields:self.fields];
    }

- (BOOL)isEqual:(nullable id)object
    {
    if (![object isKindOfClass:[XTIRLayout class]])
        return NO;
    XTIRLayout* other = (XTIRLayout*)object;
    return self.size == other.size && self.alignment == other.alignment && [self.fields isEqualToArray:other.fields];
    }

- (NSUInteger)hash
    {
    return (NSUInteger)self.size;
    }

@end
