#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTSourceLocation : NSObject <NSCopying>

@property(nonatomic, readonly) NSString* filename;
@property(nonatomic, readonly) NSUInteger line;
@property(nonatomic, readonly) NSUInteger column;

/****************************************************************************\
|* Designated initialiser for a source location.
|* @param filename  The source filename.
|* @param line      The 1-based line number.
|* @param column    The 1-based column number.
|* @return A new source location.
\****************************************************************************/
- (instancetype)initWithFilename:(NSString*)filename
                            line:(NSUInteger)line
                          column:(NSUInteger)column NS_DESIGNATED_INITIALIZER;

/****************************************************************************\
|* Convenience factory for creating a source location.
|* @param filename  The source filename.
|* @param line      The 1-based line number.
|* @param column    The 1-based column number.
|* @return A new autoreleased source location.
\****************************************************************************/
+ (instancetype)locationWithFilename:(NSString*)filename
                                line:(NSUInteger)line
                              column:(NSUInteger)column;

/****************************************************************************\
|* Human-readable description in the form "filename:line:column".
|* @return The formatted location string.
\****************************************************************************/
- (NSString*)description;

@end

NS_ASSUME_NONNULL_END
