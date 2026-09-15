// XTIRInsn.m
#import "XTIRInsn.h"
#import "XTIRValue.h"
#import "XTIROperand.h"
#import "XTIRSupport.h"

@interface XTIRInsn ()
@property(nonatomic, readwrite, nullable) XTIRCallConv* callConv;
@property(nonatomic, readwrite) uint8_t predicate;
@end

@implementation XTIRInsn

- (instancetype)initWithOpcode:(XTIROpcode)opcode
                        result:(nullable XTIRValue*)result
                      operands:(NSArray<XTIROperand*>*)operands
                        dbgLoc:(nullable XTIRDbgLoc*)dbgLoc
    {
    self = [super init];
    if (self)
        {
        _opcode = opcode;
        _result = result;
        _operands = [operands copy];
        _dbgLoc = dbgLoc;
        _callConv = nil;
        _predicate = 0;
        }
    return self;
    }

- (instancetype)initWithOpcode:(XTIROpcode)opcode
                        result:(nullable XTIRValue*)result
                      operands:(NSArray<XTIROperand*>*)operands
                      callConv:(nullable XTIRCallConv*)callConv
                        dbgLoc:(nullable XTIRDbgLoc*)dbgLoc
    {
    self = [self initWithOpcode:opcode result:result operands:operands dbgLoc:dbgLoc];
    if (self)
        {
        _callConv = callConv;
        }
    return self;
    }

- (instancetype)initWithOpcode:(XTIROpcode)opcode
                        result:(nullable XTIRValue*)result
                      operands:(NSArray<XTIROperand*>*)operands
                     predicate:(uint8_t)predicate
                        dbgLoc:(nullable XTIRDbgLoc*)dbgLoc
    {
    self = [self initWithOpcode:opcode result:result operands:operands dbgLoc:dbgLoc];
    if (self)
        {
        _predicate = predicate;
        }
    return self;
    }

- (BOOL)isTerminator
    {
    return XTIROpcodeIsTerminator(self.opcode);
    }

- (void)replaceOperands:(NSArray<XTIROperand*>*)operands
    {
    _operands = [operands copy];
    }

- (NSString*)description
    {
    NSString* resultStr = self.result ? [self.result description] : @"(void)";
    return [NSString stringWithFormat:@"%@ op=%d (%lu ops)",
                                      resultStr, (int)self.opcode,
                                      (unsigned long)self.operands.count];
    }

@end
