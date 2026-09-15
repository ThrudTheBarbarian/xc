#import <Foundation/Foundation.h>
#import "XTMemoryModel.h"

NS_ASSUME_NONNULL_BEGIN

/****************************************************************************\
|* Parse a `.lnk` linker-script file and populate an XTMemoryModel.
|* Returns nil on error; the error's localizedDescription contains
|* the filename, line number, and a human-readable message.
\****************************************************************************/
@interface XTLinkerScriptParser : NSObject

/****************************************************************************\
|* Parse a .lnk linker-script file and populate an XTMemoryModel.
|* @param path   Absolute or relative path to the .lnk file.
|* @param error  On failure, receives an NSError with filename and line info.
|* @return  A populated memory model, or nil on parse error.
\****************************************************************************/
+ (nullable XTMemoryModel*)parseFile:(NSString*)path
                               error:(NSError* _Nullable*)error;

@end

NS_ASSUME_NONNULL_END
