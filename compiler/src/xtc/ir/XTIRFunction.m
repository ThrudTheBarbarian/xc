// XTIRFunction.m
#import "XTIRFunction.h"
#import "XTIRType.h"
#import "XTIRBlock.h"
#import "XTIRValue.h"
#import "XTIRInsn.h"

#pragma mark - XTIRPinnedLocal

@implementation XTIRPinnedLocal
- (instancetype)initWithName:(NSString*)name
                        type:(XTIRType*)type
                  byteOffset:(uint32_t)byteOffset
                     valueId:(XTIRValueId)valueId
    {
    NSParameterAssert(name.length > 0);
    NSParameterAssert(type != nil);
    self = [super init];
    if (self)
        {
        _name = [name copy];
        _type = type;
        _byteOffset = byteOffset;
        _valueId = valueId;
        }
    return self;
    }
@end

#pragma mark - XTIRFrameInfo

@implementation XTIRFrameInfo
- (instancetype)init
    {
    self = [super init];
    if (self)
        {
        _pinnedLocals = @[];
        }
    return self;
    }
@end

#pragma mark - XTIRFunction

@interface XTIRFunction ()
@property(nonatomic, readwrite) XTIRValueId nextValueId;
@end

@implementation XTIRFunction

- (instancetype)initWithName:(NSString*)name
                  returnType:(XTIRType*)returnType
                  paramTypes:(NSArray<XTIRType*>*)paramTypes
                  entryBlock:(XTIRBlock*)entryBlock
    {
    NSParameterAssert(name.length > 0);
    NSParameterAssert(returnType != nil);
    NSParameterAssert(entryBlock != nil);
    self = [super init];
    if (self)
        {
        _name = [name copy];
        _returnType = returnType;
        _paramTypes = [paramTypes copy];
        _entryBlock = entryBlock;
        _blocks = [NSMutableArray arrayWithObject:entryBlock];
        _frameInfo = [[XTIRFrameInfo alloc] init];
        _forcedUnrollHeaders = [NSMutableSet set];
        _values = [NSMutableDictionary dictionary];
        _nextValueId = 0;
        }
    return self;
    }

- (XTIRValueId)allocateValueId
    {
    XTIRValueId vid = self.nextValueId;
    _nextValueId = vid + 1;
    return vid;
    }

- (void)registerValue:(XTIRValue*)value
    {
    NSParameterAssert(value != nil);
    NSAssert(self.values[@(value.valueId)] == nil,
             @"Duplicate value id %u in function '%@'",
             (unsigned)value.valueId, self.name);
    self.values[@(value.valueId)] = value;
    }

- (nullable XTIRValue*)valueForId:(XTIRValueId)valueId
    {
    return self.values[@(valueId)];
    }

// Keep this walk identical to XTIRPrinter's buildContextForFunction: — the
// printer numbers by id and needs no value object, so it stays its own loop,
// but the ORDER is one contract and both must follow it.
- (NSArray<XTIRValue*>*)valuesInPrintOrder
    {
    NSMutableArray<XTIRValue*>* out = [NSMutableArray array];
    NSMutableSet<NSNumber*>* seen = [NSMutableSet set];
    void (^add)(XTIRValue* _Nullable) = ^(XTIRValue* _Nullable v) {
      if (!v || [seen containsObject:@(v.valueId)])
          return;
      [seen addObject:@(v.valueId)];
      [out addObject:v];
    };
    for (NSUInteger i = 0; i < self.paramTypes.count; i++)
        add([self valueForId:(XTIRValueId)i]);
    for (XTIRPinnedLocal* local in self.frameInfo.pinnedLocals)
        add([self valueForId:local.valueId]);
    for (XTIRBlock* block in self.blocks)
        {
        for (XTIRInsn* phi in block.phiNodes)
            {
            add(phi.result);
            add(phi.memoryResult);
            }
        for (XTIRInsn* insn in block.instructions)
            {
            add(insn.result);
            add(insn.memoryResult);
            }
        if (block.terminator)
            {
            add(block.terminator.result);
            add(block.terminator.memoryResult);
            }
        }
    return out;
    }

@end
