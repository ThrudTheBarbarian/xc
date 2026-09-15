// XTIRModule.m
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRSymbol.h"
#import "XTIRConstant.h"
#import "XTIRType.h"
#import "XTIRLayout.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"

@interface XTIRModule ()
@property(nonatomic, readwrite, copy) NSString* name;
@end

@implementation XTIRModule

- (instancetype)initWithName:(NSString*)name
    {
    self = [super init];
    if (self)
        {
        _name = [name copy];
        _functions = [NSMutableArray array];
        _symbols = [NSMutableArray array];
        _typeTable = [NSMutableArray array];
        _layoutTable = [NSMutableArray array];
        _constants = [NSMutableArray array];
        _moduleInitFunctionNames = [NSMutableArray array];
        }
    return self;
    }

- (XTIRSymbolId)addSymbol:(XTIRSymbol*)symbol
    {
    NSParameterAssert(symbol != nil);
    [self.symbols addObject:symbol];
    return self.symbols.count - 1;
    }

- (nullable XTIRSymbol*)symbolForId:(XTIRSymbolId)symbolId
    {
    if (symbolId >= self.symbols.count)
        return nil;
    return self.symbols[symbolId];
    }

- (nullable XTIRSymbol*)symbolForName:(NSString*)name
    {
    for (XTIRSymbol* sym in self.symbols)
        {
        if ([sym.name isEqualToString:name])
            return sym;
        }
    return nil;
    }

- (XTIRLayoutId)addLayout:(XTIRLayout*)layout
    {
    NSParameterAssert(layout != nil);
    [self.layoutTable addObject:layout];
    return self.layoutTable.count - 1;
    }

- (nullable XTIRLayout*)layoutForId:(XTIRLayoutId)layoutId
    {
    if (layoutId >= self.layoutTable.count)
        return nil;
    return self.layoutTable[layoutId];
    }

- (XTIRConstantId)addConstant:(XTIRConstant*)constant
    {
    NSParameterAssert(constant != nil);
    [self.constants addObject:constant];
    return self.constants.count - 1;
    }

- (nullable XTIRConstant*)constantForId:(XTIRConstantId)constantId
    {
    if (constantId >= self.constants.count)
        return nil;
    return self.constants[constantId];
    }

- (void)addFunction:(XTIRFunction*)function
    {
    NSParameterAssert(function != nil);
    [self.functions addObject:function];
    }

- (BOOL)referencesSymbolNamed:(NSString*)symbolName
    {
    if (!symbolName.length)
        return NO;
    // The symbol has to exist before any instruction can name it, so resolve the
    // name to its id once and then compare integers rather than strings.
    XTIRSymbolId wanted = 0;
    BOOL found = NO;
    for (NSUInteger i = 0; i < self.symbols.count; i++)
        {
        if ([self.symbols[i].name isEqualToString:symbolName])
            {
            wanted = (XTIRSymbolId)i;
            found = YES;
            break;
            }
        }
    if (!found)
        return NO;
    for (XTIRFunction* fn in self.functions)
        {
        for (XTIRBlock* b in fn.blocks)
            {
            NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
            [all addObjectsFromArray:b.phiNodes];
            [all addObjectsFromArray:b.instructions];
            if (b.terminator)
                [all addObject:b.terminator];
            for (XTIRInsn* insn in all)
                {
                for (XTIROperand* op in insn.operands)
                    {
                    if (op.kind == XTIROperandKindSym && op.symbolId == wanted)
                        return YES;
                    }
                }
            }
        }
    return NO;
    }

@end
