#import <Foundation/Foundation.h>
#import "XTSymbol.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTScope : NSObject

@property(nonatomic, readonly, nullable) XTScope* parentScope;
/****************************************************************************\
|* All symbols defined directly in this scope, flattened. For
|* overloaded function names this returns every overload in turn.
\****************************************************************************/
@property(nonatomic, readonly) NSArray<XTSymbol*>* allSymbols;
/****************************************************************************\
|* Set of symbol names defined directly in this scope (keys only).
\****************************************************************************/
@property(nonatomic, readonly) NSArray<NSString*>* symbolNames;

/****************************************************************************\
|* Create a new scope, optionally nested inside a parent scope.
|* @param parent  The enclosing scope, or nil for the global scope.
|* @return A new empty scope.
\****************************************************************************/
- (instancetype)initWithParent:(nullable XTScope*)parent NS_DESIGNATED_INITIALIZER;

/****************************************************************************\
|* Define a symbol in this (innermost) scope. Returns NO if an
|* identical definition already exists (same name + same mangled
|* name — duplicate signature). For overloaded functions with
|* distinct mangled names the new symbol is appended to the
|* overload set and YES is returned.
\****************************************************************************/
- (BOOL)defineSymbol:(XTSymbol*)symbol;

/****************************************************************************\
|* Look up a symbol by name, walking the scope chain. Returns the
|* first entry if the name refers to an overload set.
\****************************************************************************/
- (nullable XTSymbol*)lookupSymbol:(NSString*)name;

/****************************************************************************\
|* Look up only in the current (innermost) scope.
\****************************************************************************/
- (nullable XTSymbol*)lookupLocalSymbol:(NSString*)name;

/****************************************************************************\
|* Return every candidate symbol for the given name, walking the
|* scope chain. For non-overloaded names returns a single-element
|* array (or empty if undefined).
\****************************************************************************/
- (NSArray<XTSymbol*>*)lookupFunctionCandidates:(NSString*)name;

@end

NS_ASSUME_NONNULL_END
