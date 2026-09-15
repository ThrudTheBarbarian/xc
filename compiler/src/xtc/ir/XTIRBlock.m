// XTIRBlock.m
#import "XTIRBlock.h"
#import "XTIRInsn.h"

@interface XTIRBlock ()
@property(nonatomic, readwrite, nullable) XTIRInsn* terminator;
@end

@implementation XTIRBlock

- (instancetype)init
    {
    self = [super init];
    if (self)
        {
        _phiNodes = [NSMutableArray array];
        _instructions = [NSMutableArray array];
        }
    return self;
    }

- (void)appendInstruction:(XTIRInsn*)insn
    {
    NSParameterAssert(insn != nil);
    NSAssert(self.terminator == nil,
             @"Cannot append instruction to block '%@' after terminator has been set",
             self.name);
    NSAssert(!insn.isTerminator,
             @"Use -setTerminator: for terminator instructions, not -appendInstruction:");
    [self.instructions addObject:insn];
    }

- (void)setTerminator:(XTIRInsn*)terminatorInsn
    {
    NSParameterAssert(terminatorInsn != nil);
    NSAssert(terminatorInsn.isTerminator,
             @"Instruction is not a terminator (opcode=%d)", (int)terminatorInsn.opcode);
    NSAssert(self.terminator == nil,
             @"Block '%@' already has a terminator", self.name);
    _terminator = terminatorInsn;
    }

- (void)resetTerminator
    {
    _terminator = nil;
    _hasInstructionAfterTerminator = NO;
    }

- (NSUInteger)insnCount
    {
    NSUInteger count = self.phiNodes.count + self.instructions.count;
    if (self.terminator)
        count += 1;
    return count;
    }

- (NSString*)description
    {
    NSString* label = self.name ?: [NSString stringWithFormat:@"block_%p", self];
    return [NSString stringWithFormat:@"%@: %lu phis, %lu insns, term=%d",
                                      label, (unsigned long)self.phiNodes.count,
                                      (unsigned long)self.instructions.count,
                                      (int)(self.terminator != nil)];
    }

@end
