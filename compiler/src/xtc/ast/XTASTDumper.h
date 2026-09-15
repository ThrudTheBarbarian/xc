#import <Foundation/Foundation.h>
#import "XTASTNode.h"

NS_ASSUME_NONNULL_BEGIN

/****************************************************************************\
|* XTASTDumper — a canonical S-expression rendering of an AST.
|*
|* Written for self-hosting M5: the xtc-language parser (selfhost/parser/) has
|* to produce the same tree as this one, and "the same tree" only means
|* something if both can be printed in a form that is comparable byte for byte.
|* This dumper defines that form, and selfhost/tools/ast-diff.sh does the
|* comparison.
|*
|* `dump:` includes ONLY what the parser decides — kinds, operators, names,
|* literal values, structural nesting. Everything sema later stamps onto a node
|* is left out: it is not the parser's output, and including it would make the
|* comparison a test of sema instead.
|*
|* `dumpWithSema:` is the same walk WITH those stamps — resolved types, the
|* symbol each call resolved to, virtual slots, inferred storage. It is the M6
|* oracle (`xtc-fe --dump-sema`), and it shares this one walk with `dump:` so
|* the two forms cannot drift apart.
|*
|* Format:  (Kind field=value … child child …)
|* one node per line, two spaces of indent per level.
\****************************************************************************/
@interface XTASTDumper : NSObject

/****************************************************************************\
|* Render `node` and everything below it.
|* @param node  Root of the tree (usually an XTProgramNode).
|* @return  The S-expression text, newline-terminated.
\****************************************************************************/
+ (NSString*)dump:(XTASTNode*)node;
+ (NSString*)dumpWithSema:(XTASTNode*)node;

@end

NS_ASSUME_NONNULL_END
