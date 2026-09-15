// MainWindowController.h — the editor window: palette | canvas | outline+inspector.

#import <AppKit/AppKit.h>

@interface MainWindowController : NSWindowController
- (void)openFileAtPath:(NSString*)path; // Rocks <file> on the command line
// File
- (void)newDocument:(id)sender;
- (void)openDocument:(id)sender;
- (void)saveDocument:(id)sender;
- (void)importRsc:(id)sender;
- (void)exportRsc:(id)sender;
// Edit
- (void)undo:(id)sender;
- (void)redo:(id)sender;
- (void)cutObject:(id)sender;
- (void)copyObject:(id)sender;
- (void)pasteObject:(id)sender;
- (void)duplicateObject:(id)sender;
- (void)deleteObject:(id)sender;
- (void)selectAllObjects:(id)sender;
// Menu editing
- (void)addMenuTitle:(id)sender;
- (void)addMenuItem:(id)sender;
// Object
- (void)alignLeft:(id)sender;
- (void)alignRight:(id)sender;
- (void)alignTop:(id)sender;
- (void)alignBottom:(id)sender;
- (void)alignCenterH:(id)sender;
- (void)alignCenterV:(id)sender;
- (void)distributeH:(id)sender;
- (void)distributeV:(id)sender;
- (void)bringToFront:(id)sender;
- (void)sendToBack:(id)sender;
// View
- (void)toggleSnap:(id)sender;
- (void)toggleGuides:(id)sender;
- (void)zoomIn:(id)sender;
- (void)zoomOut:(id)sender;
- (void)zoomActual:(id)sender;
@end
