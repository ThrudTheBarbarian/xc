#import "XTSymbol.h"

@implementation XTSymbol

/****************************************************************************\
|* Designated initialiser for a symbol. Storage class defaults to Unresolved,
|* address to 0, mangledName to name, and pageIndex to 0.
|* @param name  The symbol name as it appears in source.
|* @param type  The symbol's type.
|* @return A new symbol.
\****************************************************************************/
- (instancetype)initWithName:(NSString*)name type:(XTType*)type
    {
    self = [super init];
    if (self)
        {
        _symbolName = [name copy];
        _mangledName = [name copy];
        _symbolType = type;
        _storageClass = XTStorageClassUnresolved;
        _address = 0;
        _constantValue = nil;
        _pageIndex = 0;
        }
    return self;
    }

@end
