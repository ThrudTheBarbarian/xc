---
title: UXKit
description: "The UI framework for the xc language: one neutral API, with native realization on GEM, Win32, macOS, the web and iOS."
slug: versions/1.0.1/compiler/api/uxkit
banner:
  content: 'This is the documentation for xc 1.0.1. <a href="/compiler/">The current documentation</a> describes the newest version.'
pagefind: false
---

UXKit is the toolkit the compiler ships. It has one neutral widget, view and
window API, realized natively on each platform by interchangeable drivers. An
app says `#use <UXKit>` and `app.setDriver(...)`, and nothing else in it names
a platform. The platforms are grouped by realm:

- **the web**: canvas, with the Aristo theme
- **devices**: iOS and Android
- **desktops**: macOS, Windows, Linux (GTK) and GEM

## Views & controls

- [`UXBreadcrumb`](/versions/1.0.1/compiler/api/uxkit/uxbreadcrumb/)
- [`UXButton`](/versions/1.0.1/compiler/api/uxkit/uxbutton/)
- [`UXCheckbox`](/versions/1.0.1/compiler/api/uxkit/uxcheckbox/)
- [`UXCollectionView`](/versions/1.0.1/compiler/api/uxkit/uxcollectionview/)
- [`UXColorList`](/versions/1.0.1/compiler/api/uxkit/uxcolorlist/)
- [`UXColorPanel`](/versions/1.0.1/compiler/api/uxkit/uxcolorpanel/)
- [`UXComboBox`](/versions/1.0.1/compiler/api/uxkit/uxcombobox/)
- [`UXControl`](/versions/1.0.1/compiler/api/uxkit/uxcontrol/)
- [`UXDatePicker`](/versions/1.0.1/compiler/api/uxkit/uxdatepicker/)
- [`UXFrameHud`](/versions/1.0.1/compiler/api/uxkit/uxframehud/)
- [`UXOutlineView`](/versions/1.0.1/compiler/api/uxkit/uxoutlineview/)
- [`UXPopUpButton`](/versions/1.0.1/compiler/api/uxkit/uxpopupbutton/)
- [`UXProgressBar`](/versions/1.0.1/compiler/api/uxkit/uxprogressbar/)
- [`UXRadioButton`](/versions/1.0.1/compiler/api/uxkit/uxradiobutton/)
- [`UXRadioGroup`](/versions/1.0.1/compiler/api/uxkit/uxradiogroup/)
- [`UXResponder`](/versions/1.0.1/compiler/api/uxkit/uxresponder/)
- [`UXScrollView`](/versions/1.0.1/compiler/api/uxkit/uxscrollview/)
- [`UXSegmentedControl`](/versions/1.0.1/compiler/api/uxkit/uxsegmentedcontrol/)
- [`UXSlider`](/versions/1.0.1/compiler/api/uxkit/uxslider/)
- [`UXSplitView`](/versions/1.0.1/compiler/api/uxkit/uxsplitview/)
- [`UXStepper`](/versions/1.0.1/compiler/api/uxkit/uxstepper/)
- [`UXTabView`](/versions/1.0.1/compiler/api/uxkit/uxtabview/)
- [`UXTableView`](/versions/1.0.1/compiler/api/uxkit/uxtableview/)
- [`UXTextField`](/versions/1.0.1/compiler/api/uxkit/uxtextfield/)
- [`UXToolbar`](/versions/1.0.1/compiler/api/uxkit/uxtoolbar/)
- [`UXView`](/versions/1.0.1/compiler/api/uxkit/uxview/)
- [`UXGLView`](/versions/1.0.1/compiler/api/uxkit/uxglview/)
- [`UXGL`](/versions/1.0.1/compiler/api/uxkit/uxgl/)
- [`UXViewTree`](/versions/1.0.1/compiler/api/uxkit/uxviewtree/)

## Application & windows

- [`UXAlert`](/versions/1.0.1/compiler/api/uxkit/uxalert/)
- [`UXApplication`](/versions/1.0.1/compiler/api/uxkit/uxapplication/)
- [`UXDragSession`](/versions/1.0.1/compiler/api/uxkit/uxdragsession/)
- [`UXEvent`](/versions/1.0.1/compiler/api/uxkit/uxevent/)
- [`UXEventRecorder`](/versions/1.0.1/compiler/api/uxkit/uxeventrecorder/)
- [`UXFileChooser`](/versions/1.0.1/compiler/api/uxkit/uxfilechooser/)
- [`UXFilePanel`](/versions/1.0.1/compiler/api/uxkit/uxfilepanel/)
- [`UXKeyValueStore`](/versions/1.0.1/compiler/api/uxkit/uxkeyvaluestore/)
- [`UXMenu`](/versions/1.0.1/compiler/api/uxkit/uxmenu/)
- [`UXMenuBar`](/versions/1.0.1/compiler/api/uxkit/uxmenubar/)
- [`UXOpenPanel`](/versions/1.0.1/compiler/api/uxkit/uxopenpanel/)
- [`UXSavePanel`](/versions/1.0.1/compiler/api/uxkit/uxsavepanel/)
- [`UXPasteboard`](/versions/1.0.1/compiler/api/uxkit/uxpasteboard/)
- [`UXTimer`](/versions/1.0.1/compiler/api/uxkit/uxtimer/)
- [`UXWindow`](/versions/1.0.1/compiler/api/uxkit/uxwindow/)

## Text & content

- [`UXDate`](/versions/1.0.1/compiler/api/uxkit/uxdate/)
- [`UXFont`](/versions/1.0.1/compiler/api/uxkit/uxfont/)
- [`UXMarkdown`](/versions/1.0.1/compiler/api/uxkit/uxmarkdown/)
- [`UXText`](/versions/1.0.1/compiler/api/uxkit/uxtext/)
- [`UXTextLayout`](/versions/1.0.1/compiler/api/uxkit/uxtextlayout/)

## Geometry & drawing

- [`UXAnimation`](/versions/1.0.1/compiler/api/uxkit/uxanimation/)
- [`UXColor`](/versions/1.0.1/compiler/api/uxkit/uxcolor/)
- [`UXFileIO`](/versions/1.0.1/compiler/api/uxkit/uxfileio/)
- [`UXGeom`](/versions/1.0.1/compiler/api/uxkit/uxgeom/)
- [`UXGradient`](/versions/1.0.1/compiler/api/uxkit/uxgradient/)
- [`UXGraphics`](/versions/1.0.1/compiler/api/uxkit/uxgraphics/)
- [`UXImage`](/versions/1.0.1/compiler/api/uxkit/uximage/)
- [`UXJpeg`](/versions/1.0.1/compiler/api/uxkit/uxjpeg/)
- [`UXMovie`](/versions/1.0.1/compiler/api/uxkit/uxmovie/)
- [`UXPainter`](/versions/1.0.1/compiler/api/uxkit/uxpainter/)
- [`UXPng`](/versions/1.0.1/compiler/api/uxkit/uxpng/)
- [`UXShapePath`](/versions/1.0.1/compiler/api/uxkit/uxshapepath/)
- [`UXSound`](/versions/1.0.1/compiler/api/uxkit/uxsound/)
- [`UXViewport`](/versions/1.0.1/compiler/api/uxkit/uxviewport/)

## Rsc files & the designer

- [`UXDesignable`](/versions/1.0.1/compiler/api/uxkit/uxdesignable/)
- [`UXRsc`](/versions/1.0.1/compiler/api/uxkit/uxrsc/)
- [`UXRscInstance`](/versions/1.0.1/compiler/api/uxkit/uxrscinstance/)
- [`UXRscAwaking`](/versions/1.0.1/compiler/api/uxkit/uxrscawaking/)
- [`UXRscGem`](/versions/1.0.1/compiler/api/uxkit/uxrscgem/)
- [`UXRscV2`](/versions/1.0.1/compiler/api/uxkit/uxrscv2/)
- [`UXRscDoc`](/versions/1.0.1/compiler/api/uxkit/uxrscdoc/)
- [`UXRscConnection`](/versions/1.0.1/compiler/api/uxkit/uxrscconnection/)
- [`UXRscReader`](/versions/1.0.1/compiler/api/uxkit/uxrscreader/)
- [`UXRscWriter`](/versions/1.0.1/compiler/api/uxkit/uxrscwriter/)

## Drivers & backends

- [`UXAppKitDriver`](/versions/1.0.1/compiler/api/uxkit/uxappkitdriver/)
- [`UXPlatform`](/versions/1.0.1/compiler/api/uxkit/uxplatform/)
- [`UXCanvasGraphics`](/versions/1.0.1/compiler/api/uxkit/uxcanvasgraphics/)
- [`UXCocoaGraphics`](/versions/1.0.1/compiler/api/uxkit/uxcocoagraphics/)
- [`UXGdiGraphics`](/versions/1.0.1/compiler/api/uxkit/uxgdigraphics/)
- [`UXGemDriver`](/versions/1.0.1/compiler/api/uxkit/uxgemdriver/)
- [`UXGemGraphics`](/versions/1.0.1/compiler/api/uxkit/uxgemgraphics/)
- [`UXIosDriver`](/versions/1.0.1/compiler/api/uxkit/uxiosdriver/)
- [`UXIosGraphics`](/versions/1.0.1/compiler/api/uxkit/uxiosgraphics/)
- [`UXViewDriver`](/versions/1.0.1/compiler/api/uxkit/uxviewdriver/)
- [`UXWebDriver`](/versions/1.0.1/compiler/api/uxkit/uxwebdriver/)
- [`UXWin32Driver`](/versions/1.0.1/compiler/api/uxkit/uxwin32driver/)

## Utilities

- [`UXAndroidDriver`](/versions/1.0.1/compiler/api/uxkit/uxandroiddriver/)
- [`UXAndroidGraphics`](/versions/1.0.1/compiler/api/uxkit/uxandroidgraphics/)
- [`UXApplicationDelegate`](/versions/1.0.1/compiler/api/uxkit/uxapplicationdelegate/)
- [`UXBoot`](/versions/1.0.1/compiler/api/uxkit/uxboot/)
- [`UXBreadcrumbSegment`](/versions/1.0.1/compiler/api/uxkit/uxbreadcrumbsegment/)
- [`UXCairoGraphics`](/versions/1.0.1/compiler/api/uxkit/uxcairographics/)
- [`UXCollectionItem`](/versions/1.0.1/compiler/api/uxkit/uxcollectionitem/)
- [`UXColorEntry`](/versions/1.0.1/compiler/api/uxkit/uxcolorentry/)
- [`UXComboItem`](/versions/1.0.1/compiler/api/uxkit/uxcomboitem/)
- [`UXDateFormatter`](/versions/1.0.1/compiler/api/uxkit/uxdateformatter/)
- [`UXDragDestination`](/versions/1.0.1/compiler/api/uxkit/uxdragdestination/)
- [`UXEdge`](/versions/1.0.1/compiler/api/uxkit/uxedge/)
- [`UXFileEntry`](/versions/1.0.1/compiler/api/uxkit/uxfileentry/)
- [`UXFileHeader`](/versions/1.0.1/compiler/api/uxkit/uxfileheader/)
- [`UXFileListView`](/versions/1.0.1/compiler/api/uxkit/uxfilelistview/)
- [`UXFilePanelBack`](/versions/1.0.1/compiler/api/uxkit/uxfilepanelback/)
- [`UXFileRow`](/versions/1.0.1/compiler/api/uxkit/uxfilerow/)
- [`UXGradientStop`](/versions/1.0.1/compiler/api/uxkit/uxgradientstop/)
- [`UXGroupBox`](/versions/1.0.1/compiler/api/uxkit/uxgroupbox/)
- [`UXGtkDriver`](/versions/1.0.1/compiler/api/uxkit/uxgtkdriver/)
- [`UXKVEntry`](/versions/1.0.1/compiler/api/uxkit/uxkventry/)
- [`UXLabel`](/versions/1.0.1/compiler/api/uxkit/uxlabel/)
- [`UXMenuItem`](/versions/1.0.1/compiler/api/uxkit/uxmenuitem/)
- [`UXMenuKey`](/versions/1.0.1/compiler/api/uxkit/uxmenukey/)
- [`UXMetrics`](/versions/1.0.1/compiler/api/uxkit/uxmetrics/)
- [`UXNavItem`](/versions/1.0.1/compiler/api/uxkit/uxnavitem/)
- [`UXNavigationController`](/versions/1.0.1/compiler/api/uxkit/uxnavigationcontroller/)
- [`UXNavigationDelegate`](/versions/1.0.1/compiler/api/uxkit/uxnavigationdelegate/)
- [`UXOutlineDataSource`](/versions/1.0.1/compiler/api/uxkit/uxoutlinedatasource/)
- [`UXOutlineNode`](/versions/1.0.1/compiler/api/uxkit/uxoutlinenode/)
- [`UXOutlineRow`](/versions/1.0.1/compiler/api/uxkit/uxoutlinerow/)
- [`UXPasteboardEntry`](/versions/1.0.1/compiler/api/uxkit/uxpasteboardentry/)
- [`UXPathElement`](/versions/1.0.1/compiler/api/uxkit/uxpathelement/)
- [`UXPopUpItem`](/versions/1.0.1/compiler/api/uxkit/uxpopupitem/)
- [`UXRecordedEvent`](/versions/1.0.1/compiler/api/uxkit/uxrecordedevent/)
- [`UXScrollbar`](/versions/1.0.1/compiler/api/uxkit/uxscrollbar/)
- [`UXSegment`](/versions/1.0.1/compiler/api/uxkit/uxsegment/)
- [`UXShieldView`](/versions/1.0.1/compiler/api/uxkit/uxshieldview/)
- [`UXSplitDivider`](/versions/1.0.1/compiler/api/uxkit/uxsplitdivider/)
- [`UXStr`](/versions/1.0.1/compiler/api/uxkit/uxstr/)
- [`UXStrItem`](/versions/1.0.1/compiler/api/uxkit/uxstritem/)
- [`UXTab`](/versions/1.0.1/compiler/api/uxkit/uxtab/)
- [`UXTableCell`](/versions/1.0.1/compiler/api/uxkit/uxtablecell/)
- [`UXTableColumn`](/versions/1.0.1/compiler/api/uxkit/uxtablecolumn/)
- [`UXTableDataSource`](/versions/1.0.1/compiler/api/uxkit/uxtabledatasource/)
- [`UXTableDelegate`](/versions/1.0.1/compiler/api/uxkit/uxtabledelegate/)
- [`UXTableHeader`](/versions/1.0.1/compiler/api/uxkit/uxtableheader/)
- [`UXTableRow`](/versions/1.0.1/compiler/api/uxkit/uxtablerow/)
- [`UXTextRun`](/versions/1.0.1/compiler/api/uxkit/uxtextrun/)
- [`UXTimeZone`](/versions/1.0.1/compiler/api/uxkit/uxtimezone/)
- [`UXTimerScheduler`](/versions/1.0.1/compiler/api/uxkit/uxtimerscheduler/)
- [`UXToolbarItem`](/versions/1.0.1/compiler/api/uxkit/uxtoolbaritem/)
