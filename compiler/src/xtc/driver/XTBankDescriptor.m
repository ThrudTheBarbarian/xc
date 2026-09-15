#import "XTBankDescriptor.h"

@implementation XTBankDescriptor

- (BOOL)is16Bit
    {
    return _regAddrHi != 0;
    }

- (NSUInteger)pageCount
    {
    if (_pageSize == 0)
        return 0;
    return (NSUInteger)(_regionSpan / _pageSize);
    }

@end
