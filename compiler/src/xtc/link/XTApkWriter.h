// XTApkWriter — the APK container, in-house.
//
// `-A android --emit-apk` used four SDK tools to build a file the compiler had
// already finished: aapt2 to compile the manifest, `zip` to add the library,
// zipalign to align it and apksigner to sign it. None of that is compilation,
// but it is still a second toolchain the user has to install, which the project
// does not accept anywhere else (THE RULE).
//
// This is the container and the manifest; XTApkSign is the signature.
//
// What an APK is: a plain ZIP with `AndroidManifest.xml` compiled to Android's
// binary XML, the native libraries under `lib/<abi>/`, and a signature. Nothing
// here is compressed — an APK may store entries, and storing them is what makes
// the native library page-alignable so the loader can map it in place.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTApkWriter : NSObject

// AndroidManifest.xml, compiled. A NativeActivity manifest and nothing else:
// package, uses-sdk, an application with one activity, the `lib_name`
// meta-data the framework dlsym()s through, and a LAUNCHER intent-filter.
//
// The string pool's first entries ARE the attribute names, in ascending
// framework-resource-id order, because the resource-map chunk is positional:
// entry i gives the resource id of pool string i. Get that order wrong and the
// attributes silently bind to the wrong framework attribute.
// `hasCode` must be YES whenever the package carries a classes.dex: ART SKIPS
// the dex entirely when the manifest says hasCode="false", and skipping it looks
// exactly like a dex that failed to load (uxkit/031).
+ (NSData*)binaryManifestForPackage:(NSString*)pkg
                            libName:(NSString*)libName
                              label:(NSString*)label
                             minSdk:(int)minSdk
                          targetSdk:(int)targetSdk
                            hasCode:(BOOL)hasCode;

// A ZIP with every entry STORED. `entries` is an ordered array of
// @{@"name": NSString, @"data": NSData}.
//
// An entry whose name ends in `alignSuffix` has its DATA offset aligned to
// `alignment` by padding the local header's extra field — which is what
// zipalign does, and why it is not needed afterwards. The native library has to
// be aligned because the loader mmaps it straight out of the APK.
//
// AGAINST THE DAY THIS WRITER EMITS RESOURCES (uxkit/031): Android R and later
// refuse to install a package whose `resources.arsc` is compressed or is not
// 4-byte aligned — it surfaces as a -124 parse failure, which names neither
// cause. Every entry here is already STORED, so only the alignment would be
// missing: `resources.arsc` would have to join the `alignSuffix` rule rather
// than ride the default. No resources are emitted today.
+ (NSData*)zipWithEntries:(NSArray<NSDictionary*>*)entries
                alignment:(NSUInteger)alignment
              alignSuffix:(nullable NSString*)alignSuffix;

// CRC-32 (the zip/PNG polynomial), exposed for the tests.
+ (uint32_t)crc32:(NSData*)data;

@end

NS_ASSUME_NONNULL_END
