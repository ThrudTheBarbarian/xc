// XTIRLayout.m
#import "XTIRLayout.h"
#import "XTIRType.h"

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
    {
    NSArray<XTIRLayoutField*>* _fieldList;   // struct form: the fields; array form: built on demand
    }

- (instancetype)initWithSize:(uint32_t)size
                   alignment:(uint8_t)alignment
                      fields:(NSArray<XTIRLayoutField*>*)fields
    {
    self = [super init];
    if (self)
        {
        _size = size;
        _alignment = alignment;
        _fieldList = [fields copy];
        }
    return self;
    }

- (instancetype)initArrayOf:(XTIRType*)elementType
                      count:(uint32_t)count
                     stride:(uint32_t)stride
                  alignment:(uint8_t)alignment
    {
    self = [super init];
    if (self)
        {
        _size = stride * count;
        _alignment = alignment;
        _isArray = YES;
        _elementType = elementType;
        _elementCount = count;
        _elementStride = stride;
        }
    return self;
    }

- (void)fillWithSize:(uint32_t)size fields:(NSArray<XTIRLayoutField*>*)fields
    {
    _size = size;
    _fieldList = [fields copy];
    _isArray = NO;
    _elementType = nil;
    _elementCount = 0;
    _elementStride = 0;
    }

- (NSUInteger)fieldCount
    {
    return _isArray ? _elementCount : _fieldList.count;
    }

- (nullable XTIRType*)fieldTypeAt:(NSUInteger)idx
    {
    if (_isArray)
        return idx < _elementCount ? _elementType : nil;
    return idx < _fieldList.count ? _fieldList[idx].type : nil;
    }

- (uint32_t)fieldOffsetAt:(NSUInteger)idx
    {
    if (_isArray)
        return (uint32_t)(idx * _elementStride);
    return idx < _fieldList.count ? _fieldList[idx].byteOffset : 0;
    }

- (NSArray<XTIRLayoutField*>*)fields
    {
    if (_fieldList == nil && _isArray)
        {
        NSMutableArray<XTIRLayoutField*>* fs = [NSMutableArray arrayWithCapacity:_elementCount];
        for (uint32_t i = 0; i < _elementCount; i++)
            [fs addObject:[[XTIRLayoutField alloc] initWithOffset:i * _elementStride type:_elementType]];
        _fieldList = fs;
        }
    return _fieldList ?: @[];
    }

- (id)copyWithZone:(nullable NSZone*)zone
    {
    if (_isArray)
        return [[XTIRLayout alloc] initArrayOf:_elementType count:_elementCount stride:_elementStride alignment:_alignment];
    return [[XTIRLayout alloc] initWithSize:self.size
                                  alignment:self.alignment
                                     fields:self.fields];
    }

- (BOOL)isEqual:(nullable id)object
    {
    if (![object isKindOfClass:[XTIRLayout class]])
        return NO;
    XTIRLayout* other = (XTIRLayout*)object;
    if (self.size != other.size || self.alignment != other.alignment)
        return NO;
    if (_isArray || other.isArray)
        return _isArray && other.isArray && _elementCount == other.elementCount
            && _elementStride == other.elementStride && [_elementType isEqual:other.elementType];
    return [self.fields isEqualToArray:other.fields];
    }

- (NSUInteger)hash
    {
    return (NSUInteger)self.size;
    }

@end
