#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/****************************************************************************\
|* XTWasmWriter — WAT text → .wasm binary module, in-house.
|*
|* Sibling of XTMachOWriter / XTElfWriter / XTPEWriter, and deliberately the
|* easiest of the family: a self-contained wasm module is LEB128-framed
|* sections with NO relocations at all (private:docs/Design/wasm-target.md §8). The
|* input is the WAT dialect xcc-cg-wasm32 emits — a known, linear subset,
|* not general s-expression WAT. Emits the `name` custom section from day
|* one so browser stack traces stay legible.
|*
|* Per the native-toolchain rule there is NO external-tool fallback: a
|* failure here is a hard error, never a silent degradation. (wat2wasm is
|* used only as an independent byte-level ORACLE in the codegen tests.)
\****************************************************************************/
@interface XTWasmWriter : NSObject

/****************************************************************************\
|* Assemble the codegen's WAT text into a binary module. Returns nil and
|* sets *error on any construct outside the emitter's dialect.
\****************************************************************************/
+ (nullable NSData*)wasmModuleFromWat:(NSString*)watText
                                error:(NSError* _Nullable* _Nullable)error;

@end

NS_ASSUME_NONNULL_END
