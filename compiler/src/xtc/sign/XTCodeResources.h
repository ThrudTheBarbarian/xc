//
//  XTCodeResources.h — seal an app bundle's resources into a
//  `_CodeSignature/CodeResources` property list, byte-identical to Apple
//  codesign's output (docs/ios/bundle-signing.md, gate 1).
//
//  This is the resource half of Mac-free bundle signing. The executable half
//  (embedding the Info.plist and CodeResources hashes as CodeDirectory special
//  slots 1 and 3) lives in XTCodeSign.
//
//  Enumeration is explicit: the caller passes the resource paths it placed in
//  the bundle (the compiler-driven bundler knows them), so no directory walker
//  — and no readdir runtime primitive — is needed. `resources` are paths
//  RELATIVE to the bundle root; the main executable and `_CodeSignature/` are
//  never passed.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTCodeResources : NSObject

// Build the CodeResources plist bytes for `bundleDir`, sealing each file in
// `resources` (relative paths). `files` carries SHA-1 of every sealed file;
// `files2` carries SHA-256 of every sealed file NOT matched by an omit rule
// (Info.plist, PkgInfo, *.DS_Store). Returns nil and sets `*err` on a read
// failure.
+ (nullable NSData*)codeResourcesForBundle:(NSString*)bundleDir
                                 resources:(NSArray<NSString*>*)resources
                                     error:(NSString* _Nullable* _Nullable)err;

@end

NS_ASSUME_NONNULL_END
