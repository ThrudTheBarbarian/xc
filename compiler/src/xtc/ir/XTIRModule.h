// XTIRModule.h — top-level IR container (IR-SPEC §2)
#import <Foundation/Foundation.h>
#import "XTIRSupport.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIRFunction;
@class XTIRSymbol;
@class XTIRConstant;
@class XTIRType;
@class XTIRLayout;

/// The top-level IR module.  Owns the symbol table, type table,
/// constant pool, and function list.
@interface XTIRModule : NSObject

/// Module name (usually the source filename).
@property(nonatomic, readonly, copy) NSString* name;

/// All functions in the module.
@property(nonatomic, readonly) NSMutableArray<XTIRFunction*>* functions;

/// Symbol table.  Use -addSymbol: / -symbolForId: / -symbolForName:.
@property(nonatomic, readonly) NSMutableArray<XTIRSymbol*>* symbols;

/// Type table (canonical types referenced by Ptr/Agg).
@property(nonatomic, readonly) NSMutableArray<XTIRType*>* typeTable;

/// Layout table (Agg layouts).
@property(nonatomic, readonly) NSMutableArray<XTIRLayout*>* layoutTable;

/// Constant pool.
@property(nonatomic, readonly) NSMutableArray<XTIRConstant*>* constants;

/// Names of void() functions to run at load time (before `main`), in order.
/// Each backend emits a pointer to these in the target's constructor list
/// (`__mod_init_func` on Mach-O, `.init_array` on ELF, `.CRT$XCU` on PE). The
/// XG-NIB object-factory self-registration rides this.
@property(nonatomic, readonly) NSMutableArray<NSString*>* moduleInitFunctionNames;

- (instancetype)initWithName:(NSString*)name NS_DESIGNATED_INITIALIZER;

/// Add a symbol and return its id.
- (XTIRSymbolId)addSymbol:(XTIRSymbol*)symbol;

/// Look up symbol by id.
- (nullable XTIRSymbol*)symbolForId:(XTIRSymbolId)symbolId;

/// Look up symbol by name (linear scan).
- (nullable XTIRSymbol*)symbolForName:(NSString*)name;

/// Add a type to the type table and return its id.
- (XTIRLayoutId)addLayout:(XTIRLayout*)layout;
- (nullable XTIRLayout*)layoutForId:(XTIRLayoutId)layoutId;

/// Add a constant and return its id.
- (XTIRConstantId)addConstant:(XTIRConstant*)constant;
- (nullable XTIRConstant*)constantForId:(XTIRConstantId)constantId;

/// Add a function.
- (void)addFunction:(XTIRFunction*)function;

/// Does any instruction in the module name `symbolName`?
///
/// Threading uses this to answer "can this program have two threads?" — the
/// backends turn the ARC refcount into an atomic read-modify-write only when
/// the answer is yes (private:docs/Design/threading.md §4.1), so a single-threaded
/// program keeps today's plain load/add/store. Asking about the INSTRUCTION
/// stream rather than the symbol table matters: a symbol survives dead-function
/// elimination whether or not anything still calls it, and a program that
/// merely `#import`s a library it never spawns from should not pay.
- (BOOL)referencesSymbolNamed:(NSString*)symbolName;

@end

NS_ASSUME_NONNULL_END
