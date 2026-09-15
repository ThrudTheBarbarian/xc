#import <Foundation/Foundation.h>
#import "XTType.h"

NS_ASSUME_NONNULL_BEGIN

/****************************************************************************\
|* Global registry mapping type names → XTType.
|* Handles typedef resolution, struct/enum/class registration.
\****************************************************************************/
@interface XTTypeTable : NSObject

/****************************************************************************\
|* Initialise the type table with all built-in scalar types pre-registered.
|* @return A new type table.
\****************************************************************************/
- (instancetype)init NS_DESIGNATED_INITIALIZER;

/****************************************************************************\
|* Registers a named type (struct, enum, class, typedef alias).
\****************************************************************************/
- (void)registerType:(XTType*)type forName:(NSString*)name;

/****************************************************************************\
|* Returns a type by name, or nil if not found.
\****************************************************************************/
- (nullable XTType*)typeForName:(NSString*)name;

/****************************************************************************\
|* Returns YES if the name refers to a known type.
\****************************************************************************/
- (BOOL)isTypeName:(NSString*)name;

/****************************************************************************\
|* Pre-populated scalar type lookup by token type name.
\****************************************************************************/
- (nullable XTType*)scalarTypeForKeyword:(NSString*)keyword;

/// Every registered struct type, in no particular order. Used to SETTLE field
/// offsets once all declarations are in (see XTSemanticAnalyzer+Analysis).
- (NSArray*)allStructTypes;

@end

NS_ASSUME_NONNULL_END
