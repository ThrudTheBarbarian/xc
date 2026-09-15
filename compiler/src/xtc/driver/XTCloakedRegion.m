#import "XTCloakedRegion.h"

@implementation XTCloakedRegion

+ (instancetype)regionWithStart:(uint16_t)start
                            end:(uint16_t)end
                      bankIndex:(int)bankIndex
                       regionId:(NSString*)regionId
    {
    XTCloakedRegion* r = [[self alloc] init];
    r.start = start;
    r.end = end;
    r.bankIndex = bankIndex;
    r.bankIndexEnd = bankIndex;
    r.regionId = [regionId copy];
    return r;
    }

@end
