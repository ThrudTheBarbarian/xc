#import "XTSourceLocation.h"

@implementation XTSourceLocation

/****************************************************************************\
|* Designated initialiser for a source location.
|* @param filename  The source filename.
|* @param line      The 1-based line number.
|* @param column    The 1-based column number.
|* @return A new source location.
\****************************************************************************/
- (instancetype)initWithFilename:(NSString*)filename
                            line:(NSUInteger)line
                          column:(NSUInteger)column
    {
    self = [super init];
    if (self)
        {
        _filename = [filename copy];
        _line = line;
        _column = column;
        }
    return self;
    }

/****************************************************************************\
|* Convenience factory for creating a source location.
|* @param filename  The source filename.
|* @param line      The 1-based line number.
|* @param column    The 1-based column number.
|* @return A new autoreleased source location.
\****************************************************************************/
+ (instancetype)locationWithFilename:(NSString*)filename
                                line:(NSUInteger)line
                              column:(NSUInteger)column
    {
    return [[self alloc] initWithFilename:filename line:line column:column];
    }

/****************************************************************************\
|* Create an independent copy of this source location.
|* @param zone  The allocation zone (may be nil).
|* @return A new source location with the same filename, line, and column.
\****************************************************************************/
- (id)copyWithZone:(nullable NSZone*)zone
    {
    return [[XTSourceLocation allocWithZone:zone] initWithFilename:_filename line:_line column:_column];
    }

/****************************************************************************\
|* Human-readable description in the form "filename:line:column".
|* @return The formatted location string.
\****************************************************************************/
- (NSString*)description
    {
    return [NSString stringWithFormat:@"%@:%lu:%lu", _filename, (unsigned long)_line, (unsigned long)_column];
    }

@end
