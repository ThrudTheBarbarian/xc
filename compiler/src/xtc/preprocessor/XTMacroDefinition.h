#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/****************************************************************************\
|* Represents a #define macro, with or without parameters.
\****************************************************************************/
@interface XTMacroDefinition : NSObject

@property(nonatomic, readonly) NSString* name;
/****************************************************************************\
|* nil for object-like macros. Last element is @"..." for varargs macros.
\****************************************************************************/
@property(nonatomic, readonly, nullable) NSArray<NSString*>* parameters;
/****************************************************************************\
|* The body as a raw string (to be re-tokenised during expansion).
\****************************************************************************/
@property(nonatomic, readonly) NSString* body;
@property(nonatomic, readonly) BOOL isFunctionLike;
@property(nonatomic, readonly) BOOL isVarArgs;

/****************************************************************************\
|* Designated initialiser for a macro definition.
|* @param name        The macro name (the identifier after #define).
|* @param parameters  Parameter names for function-like macros, or nil for
|*                    object-like macros. Last element is @"..." for varargs.
|* @param body        The macro body as a raw string (re-tokenised on expansion).
|* @return A new macro definition.
\****************************************************************************/
- (instancetype)initWithName:(NSString*)name
                  parameters:(nullable NSArray<NSString*>*)parameters
                        body:(NSString*)body NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
