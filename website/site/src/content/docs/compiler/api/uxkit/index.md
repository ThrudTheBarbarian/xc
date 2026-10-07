---
title: UXKit
description: "The UI framework for the xc language: one neutral API, with native realization on GEM, Win32, macOS, the web and iOS."
---

UXKit is the toolkit the compiler ships. It has one neutral widget, view and
window API, realized natively on each platform by interchangeable drivers. An
app says `#use <UXKit>` and `app.setDriver(...)`, and nothing else in it names
a platform. The platforms are grouped by realm:

- **the web**: canvas, with the Aristo theme
- **devices**: iOS and Android
- **desktops**: macOS, Windows, Linux (GTK) and GEM

## Views & controls

- [`UXBreadcrumb`](/compiler/api/uxkit/uxbreadcrumb/)
- [`UXButton`](/compiler/api/uxkit/uxbutton/)
- [`UXCheckbox`](/compiler/api/uxkit/uxcheckbox/)
- [`UXCollectionView`](/compiler/api/uxkit/uxcollectionview/)
- [`UXColorList`](/compiler/api/uxkit/uxcolorlist/)
- [`UXColorPanel`](/compiler/api/uxkit/uxcolorpanel/)
- [`UXComboBox`](/compiler/api/uxkit/uxcombobox/)
- [`UXControl`](/compiler/api/uxkit/uxcontrol/)
- [`UXDatePicker`](/compiler/api/uxkit/uxdatepicker/)
- [`UXFrameHud`](/compiler/api/uxkit/uxframehud/)
- [`UXOutlineView`](/compiler/api/uxkit/uxoutlineview/)
- [`UXPopUpButton`](/compiler/api/uxkit/uxpopupbutton/)
- [`UXProgressBar`](/compiler/api/uxkit/uxprogressbar/)
- [`UXRadioButton`](/compiler/api/uxkit/uxradiobutton/)
- [`UXRadioGroup`](/compiler/api/uxkit/uxradiogroup/)
- [`UXResponder`](/compiler/api/uxkit/uxresponder/)
- [`UXScrollView`](/compiler/api/uxkit/uxscrollview/)
- [`UXSegmentedControl`](/compiler/api/uxkit/uxsegmentedcontrol/)
- [`UXSlider`](/compiler/api/uxkit/uxslider/)
- [`UXSplitView`](/compiler/api/uxkit/uxsplitview/)
- [`UXStepper`](/compiler/api/uxkit/uxstepper/)
- [`UXTabView`](/compiler/api/uxkit/uxtabview/)
- [`UXTableView`](/compiler/api/uxkit/uxtableview/)
- [`UXTextField`](/compiler/api/uxkit/uxtextfield/)
- [`UXToolbar`](/compiler/api/uxkit/uxtoolbar/)
- [`UXView`](/compiler/api/uxkit/uxview/)
- [`UXGLView`](/compiler/api/uxkit/uxglview/)
- [`UXGL`](/compiler/api/uxkit/uxgl/)
- [`UXViewTree`](/compiler/api/uxkit/uxviewtree/)

## Application & windows

- [`UXAlert`](/compiler/api/uxkit/uxalert/)
- [`UXApplication`](/compiler/api/uxkit/uxapplication/)
- [`UXDragSession`](/compiler/api/uxkit/uxdragsession/)
- [`UXEvent`](/compiler/api/uxkit/uxevent/)
- [`UXEventRecorder`](/compiler/api/uxkit/uxeventrecorder/)
- [`UXFileChooser`](/compiler/api/uxkit/uxfilechooser/)
- [`UXFilePanel`](/compiler/api/uxkit/uxfilepanel/)
- [`UXKeyValueStore`](/compiler/api/uxkit/uxkeyvaluestore/)
- [`UXMenu`](/compiler/api/uxkit/uxmenu/)
- [`UXMenuBar`](/compiler/api/uxkit/uxmenubar/)
- [`UXOpenPanel`](/compiler/api/uxkit/uxopenpanel/)
- [`UXSavePanel`](/compiler/api/uxkit/uxsavepanel/)
- [`UXPasteboard`](/compiler/api/uxkit/uxpasteboard/)
- [`UXTimer`](/compiler/api/uxkit/uxtimer/)
- [`UXWindow`](/compiler/api/uxkit/uxwindow/)

## Text & content

- [`UXDate`](/compiler/api/uxkit/uxdate/)
- [`UXFont`](/compiler/api/uxkit/uxfont/)
- [`UXMarkdown`](/compiler/api/uxkit/uxmarkdown/)
- [`UXText`](/compiler/api/uxkit/uxtext/)
- [`UXTextLayout`](/compiler/api/uxkit/uxtextlayout/)

## Geometry & drawing

- [`UXAnimation`](/compiler/api/uxkit/uxanimation/)
- [`UXColor`](/compiler/api/uxkit/uxcolor/)
- [`UXFileIO`](/compiler/api/uxkit/uxfileio/)
- [`UXGeom`](/compiler/api/uxkit/uxgeom/)
- [`UXGradient`](/compiler/api/uxkit/uxgradient/)
- [`UXGraphics`](/compiler/api/uxkit/uxgraphics/)
- [`UXImage`](/compiler/api/uxkit/uximage/)
- [`UXJpeg`](/compiler/api/uxkit/uxjpeg/)
- [`UXMovie`](/compiler/api/uxkit/uxmovie/)
- [`UXPainter`](/compiler/api/uxkit/uxpainter/)
- [`UXPng`](/compiler/api/uxkit/uxpng/)
- [`UXShapePath`](/compiler/api/uxkit/uxshapepath/)
- [`UXSound`](/compiler/api/uxkit/uxsound/)
- [`UXViewport`](/compiler/api/uxkit/uxviewport/)

## Rsc files & the designer

- [`UXDesignable`](/compiler/api/uxkit/uxdesignable/)
- [`UXRsc`](/compiler/api/uxkit/uxrsc/)
- [`UXRscInstance`](/compiler/api/uxkit/uxrscinstance/)
- [`UXRscAwaking`](/compiler/api/uxkit/uxrscawaking/)
- [`UXRscGem`](/compiler/api/uxkit/uxrscgem/)
- [`UXRscV2`](/compiler/api/uxkit/uxrscv2/)
- [`UXRscDoc`](/compiler/api/uxkit/uxrscdoc/)
- [`UXRscConnection`](/compiler/api/uxkit/uxrscconnection/)
- [`UXRscReader`](/compiler/api/uxkit/uxrscreader/)
- [`UXRscWriter`](/compiler/api/uxkit/uxrscwriter/)

## Drivers & backends

- [`UXAppKitDriver`](/compiler/api/uxkit/uxappkitdriver/)
- [`UXPlatform`](/compiler/api/uxkit/uxplatform/)
- [`UXCanvasGraphics`](/compiler/api/uxkit/uxcanvasgraphics/)
- [`UXCocoaGraphics`](/compiler/api/uxkit/uxcocoagraphics/)
- [`UXGdiGraphics`](/compiler/api/uxkit/uxgdigraphics/)
- [`UXGemDriver`](/compiler/api/uxkit/uxgemdriver/)
- [`UXGemGraphics`](/compiler/api/uxkit/uxgemgraphics/)
- [`UXIosDriver`](/compiler/api/uxkit/uxiosdriver/)
- [`UXIosGraphics`](/compiler/api/uxkit/uxiosgraphics/)
- [`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/)
- [`UXWebDriver`](/compiler/api/uxkit/uxwebdriver/)
- [`UXWin32Driver`](/compiler/api/uxkit/uxwin32driver/)

## Utilities

- [`UXAndroidDriver`](/compiler/api/uxkit/uxandroiddriver/)
- [`UXAndroidGraphics`](/compiler/api/uxkit/uxandroidgraphics/)
- [`UXApplicationDelegate`](/compiler/api/uxkit/uxapplicationdelegate/)
- [`UXBoot`](/compiler/api/uxkit/uxboot/)
- [`UXBreadcrumbSegment`](/compiler/api/uxkit/uxbreadcrumbsegment/)
- [`UXCairoGraphics`](/compiler/api/uxkit/uxcairographics/)
- [`UXCollectionItem`](/compiler/api/uxkit/uxcollectionitem/)
- [`UXColorEntry`](/compiler/api/uxkit/uxcolorentry/)
- [`UXComboItem`](/compiler/api/uxkit/uxcomboitem/)
- [`UXDateFormatter`](/compiler/api/uxkit/uxdateformatter/)
- [`UXDragDestination`](/compiler/api/uxkit/uxdragdestination/)
- [`UXEdge`](/compiler/api/uxkit/uxedge/)
- [`UXFileEntry`](/compiler/api/uxkit/uxfileentry/)
- [`UXFileHeader`](/compiler/api/uxkit/uxfileheader/)
- [`UXFileListView`](/compiler/api/uxkit/uxfilelistview/)
- [`UXFilePanelBack`](/compiler/api/uxkit/uxfilepanelback/)
- [`UXFileRow`](/compiler/api/uxkit/uxfilerow/)
- [`UXGradientStop`](/compiler/api/uxkit/uxgradientstop/)
- [`UXGroupBox`](/compiler/api/uxkit/uxgroupbox/)
- [`UXGtkDriver`](/compiler/api/uxkit/uxgtkdriver/)
- [`UXKVEntry`](/compiler/api/uxkit/uxkventry/)
- [`UXLabel`](/compiler/api/uxkit/uxlabel/)
- [`UXMenuItem`](/compiler/api/uxkit/uxmenuitem/)
- [`UXMenuKey`](/compiler/api/uxkit/uxmenukey/)
- [`UXMetrics`](/compiler/api/uxkit/uxmetrics/)
- [`UXNavItem`](/compiler/api/uxkit/uxnavitem/)
- [`UXNavigationController`](/compiler/api/uxkit/uxnavigationcontroller/)
- [`UXNavigationDelegate`](/compiler/api/uxkit/uxnavigationdelegate/)
- [`UXOutlineDataSource`](/compiler/api/uxkit/uxoutlinedatasource/)
- [`UXOutlineNode`](/compiler/api/uxkit/uxoutlinenode/)
- [`UXOutlineRow`](/compiler/api/uxkit/uxoutlinerow/)
- [`UXPasteboardEntry`](/compiler/api/uxkit/uxpasteboardentry/)
- [`UXPathElement`](/compiler/api/uxkit/uxpathelement/)
- [`UXPopUpItem`](/compiler/api/uxkit/uxpopupitem/)
- [`UXRecordedEvent`](/compiler/api/uxkit/uxrecordedevent/)
- [`UXScrollbar`](/compiler/api/uxkit/uxscrollbar/)
- [`UXSegment`](/compiler/api/uxkit/uxsegment/)
- [`UXShieldView`](/compiler/api/uxkit/uxshieldview/)
- [`UXSplitDivider`](/compiler/api/uxkit/uxsplitdivider/)
- [`UXStr`](/compiler/api/uxkit/uxstr/)
- [`UXStrItem`](/compiler/api/uxkit/uxstritem/)
- [`UXTab`](/compiler/api/uxkit/uxtab/)
- [`UXTableCell`](/compiler/api/uxkit/uxtablecell/)
- [`UXTableColumn`](/compiler/api/uxkit/uxtablecolumn/)
- [`UXTableDataSource`](/compiler/api/uxkit/uxtabledatasource/)
- [`UXTableDelegate`](/compiler/api/uxkit/uxtabledelegate/)
- [`UXTableHeader`](/compiler/api/uxkit/uxtableheader/)
- [`UXTableRow`](/compiler/api/uxkit/uxtablerow/)
- [`UXTextRun`](/compiler/api/uxkit/uxtextrun/)
- [`UXTimeZone`](/compiler/api/uxkit/uxtimezone/)
- [`UXTimerScheduler`](/compiler/api/uxkit/uxtimerscheduler/)
- [`UXToolbarItem`](/compiler/api/uxkit/uxtoolbaritem/)
