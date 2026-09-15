#import <Foundation/Foundation.h>
#import "XTType.h"
#import "XTSourceLocation.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, XTStorageClass) {
    XTStorageClassZeroPage,   // zero-page RAM address
    XTStorageClassHeap,       // heap-relative (global)
    XTStorageClassStack,      // xtc stack (local temporaries that don't fit ZP)
    XTStorageClassRegister,   // 6502 register (A/X/Y — transient, managed by allocator)
    XTStorageClassFunction,   // code address
    XTStorageClassConst,      // compile-time constant
    XTStorageClassUnresolved, // not yet assigned by the allocator
};

@interface XTSymbol : NSObject

@property(nonatomic, readonly) NSString* symbolName;
/****************************************************************************\
|* For function symbols that are part of an overload set, the
|* parameter-type-suffixed label used by codegen (e.g.
|* `print__u32`). Defaults to `symbolName` for non-overloaded
|* functions and all non-function symbols.
\****************************************************************************/
@property(nonatomic, copy) NSString* mangledName;
@property(nonatomic) XTType* symbolType;
@property(nonatomic) XTStorageClass storageClass;
/****************************************************************************\
|* Source location where this symbol was first defined.
\****************************************************************************/
@property(nonatomic, nullable) XTSourceLocation* definedAt;
/****************************************************************************\
|* Absolute address for ZP/heap/function symbols. Stack offset for stack symbols.
\****************************************************************************/
@property(nonatomic) NSInteger address;
/****************************************************************************\
|* For constants, the folded integer value.
\****************************************************************************/
@property(nonatomic, nullable) NSNumber* constantValue;
/****************************************************************************\
|* For function symbols, the bank-switched page index (0 = unbanked).
\****************************************************************************/
@property(nonatomic) NSUInteger pageIndex;

/****************************************************************************\
|* Designated initialiser for a symbol. Storage class defaults to Unresolved,
|* address to 0, mangledName to name, and pageIndex to 0.
|* @param name  The symbol name as it appears in source.
|* @param type  The symbol's type.
|* @return A new symbol.
\****************************************************************************/
- (instancetype)initWithName:(NSString*)name
                        type:(XTType*)type NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
