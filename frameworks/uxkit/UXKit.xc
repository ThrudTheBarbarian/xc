// UXKit.xc — the toolkit as ONE translation unit, for `xtc --emit-lib`.
//
// xcc's --emit-lib takes a single input, and #import is include-once, so this
// umbrella is the library.  Clients then say `#use <UXKit>` and link libUXKit.
//
// One library per target: UXPlatform brings in the driver for the target it is built for (and only
// that one), so libUXKit.dylib for arm64 is AppKit's, libUXKit.so for x86_64 is GTK's, and so on.
#import "UXPlatform.xc"
#if UX_PLATFORM_IOS
// the frameworks the iOS driver and its shim use, so libUXKit links them itself (a build of the
// library names the simulator's or the device's SDK with SDKROOT)
#import <UIKit>
#import <QuartzCore>
#import <CoreGraphics>
#endif
#if UX_PLATFORM_GEM
#import "UXGem.h.xc"
#endif
#import "UXVersion.xc"

// The LIBRARY half of the version gate: define the ABI symbol, and have it return the patch
// level. One line, now that xtc has `##` (XTC-BUGS #16) — it used to be a generated file.
i32 UXK_ABI_SYM(void)
    {
    return (i32)UXK_PATCH;
    }
#import "UXLibc.xc"
#import "UXGeometry.xc"
#import "UXString.xc"
#import "UXResponder.xc"
#import "UXViewTree.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGraphics.xc"
#if UX_PLATFORM_GEM
#import "UXGemGraphics.xc"
#endif
#import "UXEvent.xc"
#import "UXViewDriver.xc"
#import "UXWindow.xc"
#import "UXApplication.xc"
#import "UXMenu.xc"
#import "UXAlert.xc"
#import "UXDesignable.xc" // the ONE rsc-reflection protocol declaration libUXKit.so exports
#import "UXRsc.xc"
#if UX_PLATFORM_GEM
#import "UXRscGem.xc"
#endif
#import "UXTableView.xc"
#import "UXTextView.xc"
#import "UXOutlineView.xc"

// ---- the rest of the toolkit ------------------------------------------------
// These were kept OUT of the umbrella by bug 021: merging them pushed the translation
// unit past 1024 distinct method names, and the arm9 backend could not address a vtable
// slot past 4095 bytes, so libUXKit.so simply would not assemble.  That is fixed in the
// compiler (see doc/bugs/021), the cap is gone, and `#import <UXKit>` now means the whole
// toolkit rather than the third of it that happened to fit.
//
// Backend-specific files come in only through UXPlatform, for the target being built: a driver
// names its platform's system libraries, which do not exist elsewhere.  UXBoot is test scaffolding.
#import "UXAnimation.xc"
#import "UXBreadcrumb.xc"
#import "UXCollectionView.xc"
#import "UXColor.xc"
#import "UXColorList.xc"
#import "UXColorPanel.xc"
#import "UXComboBox.xc"
#import "Data.xc"
#import "UXDate.xc"
#import "UXDatePicker.xc"
#import "UXDragSession.xc"
#import "UXEventRecorder.xc"
#import "UXFileChooser.xc"
#import "UXFilePanel.xc"
#import "UXFont.xc"
#if UX_PLATFORM_GEM
#import "UXGem.xc"
#endif
#import "UXGradient.xc"
#import "UXImage.xc"
#import "UXJpeg.xc"   // the image decoders: JPEG (baseline) and PNG
#import "UXMovie.xc"  // frames to a WebM movie (VP8)
#import "UXKeyValueStore.xc"
#import "UXMarkdown.xc"
#import "UXOpenPanel.xc"
#import "UXPasteboard.xc"
#import "UXPng.xc"
#import "UXPopUpButton.xc"
#import "UXProgressBar.xc"
#import "UXScrollView.xc"
#import "UXSegmentedControl.xc"
#import "UXShapePath.xc"
#import "UXSlider.xc"
#import "UXSound.xc"
#import "UXSplitView.xc"
#import "UXStepper.xc"
#import "UXTabView.xc"
#import "UXNavigationController.xc"
#import "UXText.xc"
#import "UXTextLayout.xc"
#import "UXTimer.xc"
#import "UXToolbar.xc"
#import "UXViewport.xc"
