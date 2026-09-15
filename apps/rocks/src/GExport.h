// GExport.h — generate source code from a resource.
//
// Three emitters, one symbol table:
//
//   .h   symbolic names — one #define per tree (its index) and per object (its
//        index within that tree), so application code never hard-codes indices.
//   .c   the trees as static initialised data (OBJECT / TEDINFO / ICONBLK /
//        CICON).  C folds address constants, so ob_spec is resolved by the
//        compiler and nothing runs at start-up.
//   .xt  the same, for the xtc language.  xtc refuses to constant-fold ANY
//        global whose type contains a pointer, so the tables are pure-integer
//        (ob_spec is the AES 32-bit LONG) and a generated <stem>_fixup() pokes
//        the addresses in at run time — which is what rsrc_load does anyway.
//
// Symbols are prefixed with the tree's name: tree "MAIN" holding an OK button
// yields `#define MAIN 0` and `#define MAIN_OK 3`.  An object's name is used if
// set, otherwise one is derived from its text/label, otherwise from its type.

#import <Foundation/Foundation.h>
#import "GModel.h"

NS_ASSUME_NONNULL_BEGIN

// `stem` is the output base name ("app" -> app.h / app.c / app.xt). It seeds the
// include guard, the file comment and the fixup function name.
NSString* GExportHeader(GResource* res, NSString* stem);
NSString* GExportCSource(GResource* res, NSString* stem);
NSString* GExportXtc(GResource* res, NSString* stem);

// The symbol table the emitters agree on: "MAIN_OK" -> object index within its
// tree, "MAIN" -> tree index. Exposed so tests and tooling can check it.
NSDictionary<NSString*, NSNumber*>* GExportSymbols(GResource* res);

// The symbol one object would export as ("MAIN_OK"), or nil if it is not in the
// resource. Test-drive mode names the exit object with this, so what the editor
// reports is exactly what the generated header calls it.
NSString* _Nullable GExportSymbolForObject(GResource* res, GObject* o);

NS_ASSUME_NONNULL_END
