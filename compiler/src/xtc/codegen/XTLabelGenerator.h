#import <Foundation/Foundation.h>
#import "XTType.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTLabelGenerator : NSObject

/****************************************************************************\
|* Build the overload suffix for a function name given its parameter
|* types, producing e.g. `print__u32` or `log__s_u8`. For empty
|* parameter lists returns `<name>__v`. Used by sema when stamping
|* mangled names onto decl nodes that participate in an overload set.
\****************************************************************************/
+ (NSString*)mangleName:(NSString*)base paramTypes:(NSArray<XTType*>*)types;

/****************************************************************************\
|* Return-type-aware mangling. For zero-arg overloads the parameter
|* list alone (`__v`) can't distinguish candidates, so the return
|* type becomes the differentiator (`PI__v_f` vs `PI__v_double`).
|* For non-zero-arg overloads the return type is ignored and the
|* output matches `mangleName:paramTypes:` exactly — existing call-
|* site labels don't shift.
\****************************************************************************/
+ (NSString*)mangleName:(NSString*)base
             paramTypes:(NSArray<XTType*>*)types
             returnType:(nullable XTType*)returnType;

/****************************************************************************\
|* Suffix string for a single type (e.g. `u8`, `pu8`, `SPoint`,
|* `eDirection`). Exposed mainly for tests/diagnostics.
\****************************************************************************/
+ (NSString*)manglingSuffixForType:(XTType*)type;

/****************************************************************************\
|* Optional prefix for module-scoped labels (e.g. "m0_" for module 0)
\****************************************************************************/
@property(nonatomic, nullable) NSString* modulePrefix;

/****************************************************************************\
|* Returns a fresh unique label, e.g. "_L001"
\****************************************************************************/
- (NSString*)nextLabel;

/****************************************************************************\
|* Returns a label derived from a function name, e.g. "_fn_main"
\****************************************************************************/
- (NSString*)labelForFunction:(NSString*)name;

/****************************************************************************\
|* Returns a label for a string constant, e.g. "_str003"
\****************************************************************************/
- (NSString*)nextStringLabel;

@end

NS_ASSUME_NONNULL_END
