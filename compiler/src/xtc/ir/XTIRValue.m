// XTIRValue.m
#import "XTIRValue.h"
#import "XTIRBlock.h"
#import "XTIRType.h"

#pragma mark - XTIRDefSite

@implementation XTIRDefSite

- (instancetype)initWithBlock:(nullable XTIRBlock*)block
                    insnIndex:(NSUInteger)insnIndex
    {
    self = [super init];
    if (self)
        {
        _block = block;
        _insnIndex = insnIndex;
        }
    return self;
    }

+ (instancetype)parameterDef
    {
    return [[self alloc] initWithBlock:nil insnIndex:0];
    }

- (BOOL)isParameter
    {
    return self.block == nil;
    }

@end

#pragma mark - XTIRValue

@implementation XTIRValue

- (instancetype)initWithValueId:(XTIRValueId)valueId
                           type:(XTIRType*)type
                        defSite:(XTIRDefSite*)defSite
    {
    NSParameterAssert(type != nil);
    NSParameterAssert(defSite != nil);
    self = [super init];
    if (self)
        {
        _valueId = valueId;
        _type = type;
        _defSite = defSite;
        }
    return self;
    }

- (NSString*)description
    {
    return [NSString stringWithFormat:@"%%%u:%@", self.valueId, self.type];
    }

@end
