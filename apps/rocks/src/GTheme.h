// GTheme.h — loads an XT GEM theme (GTEX atlas + locations.txt + theme.ini)
// and 9-slice-blits named elements, matching aes/object.c's theme_draw.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface GTheme : NSObject
@property(readonly) NSColor* fg; // text colour (theme.ini fg)
@property(readonly, copy) NSString* name;

// Locate & load the default theme (bundle Resources, then $ROCKS_GEM_DIR/themes).
+ (nullable GTheme*)defaultTheme;
// Where the theme was found, for diagnostics (Rocks --resources).
+ (nullable NSString*)loadedFrom;
- (nullable instancetype)initWithDir:(NSString*)dir;

- (BOOL)hasSlice:(NSString*)name;
// 9-slice draw a named element into dst (model coords, inside a flipped view).
- (void)draw:(NSString*)name inRect:(NSRect)dst;
// natural (source) size of a slice, or NSZeroSize.
- (NSSize)sliceSize:(NSString*)name;
@end

NS_ASSUME_NONNULL_END
