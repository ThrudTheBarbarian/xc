// UXKit.xc — the toolkit as ONE translation unit, for `xtc --emit-lib`.
//
// xtc's --emit-lib takes a single input, and #import is include-once, so this
// umbrella is the library.  Clients then say `#import <UXKit>` and link libUXKit.so.
#import "UXGem.h.xc"
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
#import "UXGemGraphics.xc"
#import "UXEvent.xc"
#import "UXNotificationCenter.xc"
#import "UXViewDriver.xc"
#import "UXGemDriver.xc"
#import "UXWindow.xc"
#import "UXApplication.xc"
#import "UXMenu.xc"
#import "UXAlert.xc"
#import "UXDesignable.xc" // the ONE nib-reflection protocol declaration libUXKit.so exports
#import "UXNib.xc"
#import "UXTableView.xc"
#import "UXOutlineView.xc"

// ---- the rest of the toolkit ------------------------------------------------
// These were kept OUT of the umbrella by bug 021: merging them pushed the translation
// unit past 1024 distinct method names, and the arm9 backend could not address a vtable
// slot past 4095 bytes, so libUXKit.so simply would not assemble.  That is fixed in the
// compiler (see doc/bugs/021), the cap is gone, and `#import <UXKit>` now means the whole
// toolkit rather than the third of it that happened to fit.
//
// Backend-SPECIFIC files stay out on purpose and always will: UXWin32Driver/UXGdiGraphics
// name win64-only libraries and UXAppKitDriver/UXCocoaGraphics name Cocoa, neither of which
// exists on the board this library is built for.  UXBoot is test scaffolding.
#import "UXAnimation.xc"
#import "UXAttributedString.xc"
#import "UXBag.xc"
#import "UXBinaryHeap.xc"
#import "UXBreadcrumb.xc"
#import "UXCSV.xc"
#import "UXCache.xc"
#import "UXCharacterSet.xc"
#import "UXCollectionView.xc"
#import "UXColor.xc"
#import "UXColorList.xc"
#import "UXColorPanel.xc"
#import "UXComboBox.xc"
#import "UXData.xc"
#import "UXDate.xc"
#import "UXDatePicker.xc"
#import "UXDragSession.xc"
#import "UXEventRecorder.xc"
#import "UXExpression.xc"
#import "UXFileChooser.xc"
#import "UXFilePanel.xc"
#import "UXFont.xc"
#import "UXGem.xc"
#import "UXGradient.xc"
#import "UXImage.xc"
#import "UXIndexSet.xc"
#import "UXJSON.xc"
#import "UXKeyValueStore.xc"
#import "UXLog.xc"
#import "UXMarkdown.xc"
#import "UXNull.xc"
#import "UXNumberFormatter.xc"
#import "UXOpenPanel.xc"
#import "UXOperationQueue.xc"
#import "UXPasteboard.xc"
#import "UXPath.xc"
#import "UXPopUpButton.xc"
#import "UXPredicate.xc"
#import "UXProgress.xc"
#import "UXProgressBar.xc"
#import "UXRange.xc"
#import "UXRegex.xc"
#import "UXScrollView.xc"
#import "UXSearchIndex.xc"
#import "UXSegmentedControl.xc"
#import "UXShapePath.xc"
#import "UXSlider.xc"
#import "UXSortDescriptor.xc"
#import "UXSplitView.xc"
#import "UXStateMachine.xc"
#import "UXStepper.xc"
#import "UXTabView.xc"
#import "UXNavigationController.xc"
#import "UXText.xc"
#import "UXTextLayout.xc"
#import "UXTimer.xc"
#import "UXToolbar.xc"
#import "UXURL.xc"
#import "UXUndoManager.xc"
#import "UXValidator.xc"
#import "UXViewport.xc"
