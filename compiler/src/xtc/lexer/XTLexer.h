#import <Foundation/Foundation.h>
#import "XTToken.h"
#import "XTDiagnosticEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTLexer : NSObject

/****************************************************************************\
|* Designated initialiser for the lexer.
|* @param source       The full source text to tokenise.
|* @param filename     The filename used in source-location tracking.
|* @param diagnostics  The diagnostic engine for reporting errors.
|* @return A new lexer ready to tokenise.
\****************************************************************************/
- (instancetype)initWithSource:(NSString*)source
                      filename:(NSString*)filename
                   diagnostics:(XTDiagnosticEngine*)diagnostics NS_DESIGNATED_INITIALIZER;

/****************************************************************************\
|* Tokenise the entire source and return the token array (including a final EOF token).
\****************************************************************************/
- (NSArray<XTToken*>*)tokenise;

@end

NS_ASSUME_NONNULL_END
