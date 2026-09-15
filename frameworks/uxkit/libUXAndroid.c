/* libUXAndroid.c — the Android shim under UXAndroidDriver: the seventh
 * backend, and the production half of what spikes/android-bridge proved.
 *
 * TWO LIBS, ONE APK — the load-time architecture this whole file rests on:
 * the manifest's android.app.lib_name points HERE, so the framework's
 * NativeActivity dlopens this shim and calls OUR onCreate.  We stash the
 * activity and VM (which the compiler's glue receives and discards), load
 * the bridge dex through the app's class loader (finding #2 of the spike:
 * FindClass from a native frame sees only the system loader), promote
 * ourselves to the global symbol group, dlopen the pure-xcc app lib
 * (libxtapp.so, `xcc -A android --emit-apk`'s payload — its undefined
 * ux_and_* imports bind against us right here), and then DELEGATE to that
 * lib's own exported ANativeActivity_onCreate: the compiler's glue runs
 * exactly as shipped — stdout piped to logcat tag `xcapp`, xt_main spawned
 * on a detached thread.  Nothing in the compiler changes.
 *
 * Threading: onCreate and every widget callback run on the UI thread;
 * xt_main runs on the glue's detached thread.  The driver's runLoop()
 * therefore posts the app's start onto the UI thread through the dex's
 * UXRun and parks xt_main's thread forever — so boot(), window building,
 * drawing, and firing all happen UI-side, the discipline iOS enforces
 * implicitly.  Widgets are pure JNI name-lookup over classic
 * android.widget; absolute layout is FrameLayout + setTranslationX/Y;
 * custom views are the dex's UXDrawView, whose onDraw funnels its Canvas
 * here.  The offscreen proof rig renders the content walk into a
 * Bitmap-backed Canvas and reads pixels — the renderInContext analogue.
 */
#include <jni.h>
#include <android/log.h>
#include <android/native_activity.h>
#include <dlfcn.h>
#include <unistd.h>
#include <string.h>
#include <time.h>
#include <stdio.h>

#define LOG(...) __android_log_print(ANDROID_LOG_INFO, "uxkit", __VA_ARGS__)
#define UXA_MAXW 16

typedef void (*ux_entry_fn)(void);
typedef void (*ux_content_fn)(int handle, int wx, int wy, int ww, int wh, void *ud);
typedef void (*ux_fire_fn)(int handle, int node);
typedef void (*ux_value_fn)(int handle, int node, int value);

static JavaVM        *gVm;
static jobject        gActivity;          /* global ref */
static ux_entry_fn    gEntry;
static ux_fire_fn     gFire;
static ux_value_fn    gValueChanged;      /* value controls: a later slice */
static ux_fire_fn     gFieldChanged;      /* the field overlay: a later slice */

static jclass gBridgeCls, gRunCls, gDrawCls;          /* global refs, dex classes  */
static jclass gBtnCls, gLabelCls, gFrameCls, gViewCls, gCanvasCls, gPaintCls,
    gBitmapCls, gPathCls,
    gCheckCls, gRadioCls, gCompoundCls, gSeekCls, gProgCls, gSpinCls, gEditCls, gAdapterCls, gLinearCls;
static jmethodID gRadioSetChecked;
static jmethodID gBtnInit, gBtnSetText, gLabelInit, gLabelSetText, gFrameInit,
    gAddView, gSetContentView, gSetTransX, gSetTransY, gPerformClick,
    gSetOnClick, gSetEnabled, gSetVisibility, gInvalidate, gRemoveView,
    gBridgeInit, gRunInit, gDrawInit,
    gCheckInit, gCheckSetText, gSetChecked, gIsChecked,
    gSeekInit, gSeekSetMin, gSeekSetMax, gSeekSetProgress, gSeekListen,
    gProgInit, gProgSetMax, gProgSetProgress, gProgSetIndet,
    gSpinInit, gSpinSetAdapter, gSpinSetSel, gSpinListen,
    gAdapterInit, gAdapterAdd,
    gEditInit, gEditSetText, gEditGetText, gEditWatch, gEditSetInputType,
    gCanvasDrawRect, gCanvasDrawText, gCanvasDrawPath, gCanvasInitBmp,
    gPaintInit, gPaintSetColor, gPaintSetTextSize, gPaintSetStyle,
    gPaintSetStrokeWidth, gPaintSetStrokeCap, gPaintMeasure,
    gPathInit, gPathMoveTo, gPathLineTo, gPathCubicTo, gPathClose,
    gBmpCreate, gBmpGetPixel;
static jobject gPaint;                    /* the one Paint, global ref */
static jobject gStyleFill, gStyleStroke;  /* Paint.Style values, global refs */
static jobject gCapButt, gCapRound, gCapSquare;   /* Paint.Cap values */

static JNIEnv *envNow(void) {
    JNIEnv *env = NULL;
    (*gVm)->GetEnv(gVm, (void **)&env, JNI_VERSION_1_6);
    if (!env) (*gVm)->AttachCurrentThread(gVm, &env, NULL);
    return env;
}
static int check(JNIEnv *env, const char *what) {
    if ((*env)->ExceptionCheck(env)) {
        LOG("EXC at %s", what);
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        return 0;
    }
    return 1;
}

/* windows: child FrameLayouts inside one root FrameLayout (content view) */
static jobject gRoot;                     /* global ref */
static jobject gWinV[UXA_MAXW];           /* global refs, per-window FrameLayout */
static jobject gCtl[UXA_MAXW][64];        /* global refs, per-node widget */
static ux_content_fn gContent[UXA_MAXW];
static void         *gContentUd[UXA_MAXW];
static int gWinW[UXA_MAXW], gWinH[UXA_MAXW];
static int gNextH = 1, gLive = 0;
static int gScreenW, gScreenH;          /* in NEUTRAL units (px / density) */
/* Neutral units are density-independent (the other backends' point space);
 * every JNI boundary scales by the display density — view sizes and
 * translations out, pixel probes in — and the draw seam pre-scales its
 * Canvas so app-drawn art rides along.  PX() is that boundary. */
static float gDensity = 1.0f;
#define PX(v) ((int)((v) * gDensity + 0.5f))
static char *gFieldBuf[UXA_MAXW][64];     /* EditText overlays sync into these */
static int   gFieldCap[UXA_MAXW][64];
static int   gFieldMute;                  /* programmatic setText must not re-fire */
static jobject gSpinAdapter[UXA_MAXW][64];   /* global refs, per-popup adapter */

void ux_and_set_entry(void *fn)         { gEntry = (ux_entry_fn)fn; }
void ux_and_set_control_fire(void *fn)  { gFire = (ux_fire_fn)fn; }
void ux_and_set_value_changed(void *fn) { gValueChanged = (ux_value_fn)fn; }
void ux_and_set_field_hooks(void *fn)   { gFieldChanged = (ux_fire_fn)fn; }

/* ── the natives the dex classes funnel into ────────────────────────────── */
static void alertFinish(JNIEnv *env, int neutralIdx);   /* the modal alert, below */
static void alertAuto(JNIEnv *env, int shot);
#define UXA_ALERT_ID 0x7F7F
static int gAlertCancelIdx;
static void n_fire(JNIEnv *env, jclass c, jint id) {
    (void)c;
    if (id == UXA_ALERT_ID) { alertFinish(env, gAlertCancelIdx); return; }   /* dialog cancelled */
    (void)env;
    if (gFire) gFire(id >> 8, id & 0xFF);
}
static void n_value(JNIEnv *env, jclass c, jint id, jint value) {
    (void)c;
    if (id == UXA_ALERT_ID) {
        /* which: -1 positive, -2 negative, -3 neutral -> the neutral 1-based index */
        int idx = gAlertCancelIdx;
        if (value == -1) idx = 1;
        else if (value == -3) idx = 2;                       /* only exists at 3 buttons */
        else if (value == -2) idx = gAlertCancelIdx;         /* negative IS the cancel role */
        alertFinish(env, idx);
        return;
    }
    (void)env;
    if (gValueChanged) gValueChanged(id >> 8, id & 0xFF, value);
}
static void n_text(JNIEnv *env, jclass c, jint id, jstring s) {
    (void)c;
    int handle = id >> 8, node = id & 0xFF;
    if (gFieldMute || handle < 0 || handle >= UXA_MAXW || node < 0 || node >= 64) return;
    char *buf = gFieldBuf[handle][node];
    if (!buf) return;
    /* the shared field rule: the buffer is synced shim-side FIRST, then the
     * neutral field hears about it (fieldDidChange fires with the truth) */
    const char *u = (*env)->GetStringUTFChars(env, s, NULL);
    int cap = gFieldCap[handle][node];
    strncpy(buf, u, cap - 1);
    buf[cap - 1] = 0;
    (*env)->ReleaseStringUTFChars(env, s, u);
    if (gFieldChanged) gFieldChanged(handle, node);
}
void ux_and_test_click(int handle, int node);
static void n_run(JNIEnv *env, jclass c, jint id) {
    (void)env; (void)c;
    if (id == 0) { if (gEntry) gEntry(); return; }         /* id 0 = the app's start */
    if (id & 0x10000) { ux_and_test_click((id >> 8) & 0xFF, id & 0xFF); return; }
    if (id & 0x40000) { alertAuto(env, id & 1); return; }  /* the alert rig's auto-cancel */
    if (id & 0x20000) {                                    /* the loop gate's watchdog */
        LOG("watchdog fired");
        fflush(NULL); usleep(200000);
        _exit(id & 0xFF);
    }
}
static jobject gDrawCanvas;               /* the Canvas of the draw in flight */
static jmethodID gCanvasScale, gCanvasSave, gCanvasRestore, gCanvasClipRect;
static int gInsetsKnown;                  /* shared with queryInsets below */
static void queryInsets(JNIEnv *env);
static void applyInsets(JNIEnv *env);
static void n_draw(JNIEnv *env, jclass c, jint id, jobject canvas, jint w, jint h) {
    (void)c;
    int handle = id >> 8;
    if (handle < 0 || handle >= UXA_MAXW || !gContent[handle]) return;
    /* the decor is certainly attached by the first draw: if boot ran too
     * early to see the insets, learn and apply them now */
    if (!gInsetsKnown) { queryInsets(env); applyInsets(env); }
    /* the view is density-scaled; pre-scale the canvas so the content walk
     * (and every draw op under it) works in neutral units */
    if (gCanvasScale)
        (*env)->CallVoidMethod(env, canvas, gCanvasScale, (jfloat)gDensity, (jfloat)gDensity);
    gDrawCanvas = canvas;
    gContent[handle](handle, 0, 0, gWinW[handle], gWinH[handle], gContentUd[handle]);
    gDrawCanvas = NULL;
}

/* ── UI-thread posting (Handler on the main looper + the dex's UXRun) ───── */
static jobject gHandler;                  /* global ref */
static jmethodID gPost, gPostDelayed;
static void postRun(JNIEnv *env, int id) {
    jobject r = (*env)->NewObject(env, gRunCls, gRunInit, id);
    (*env)->CallBooleanMethod(env, gHandler, gPost, r);
    (*env)->DeleteLocalRef(env, r);
}
static void postRunDelayed(JNIEnv *env, int id, int ms) {
    jobject r = (*env)->NewObject(env, gRunCls, gRunInit, id);
    (*env)->CallBooleanMethod(env, gHandler, gPostDelayed, r, (jlong)ms);
    (*env)->DeleteLocalRef(env, r);
}
/* the loop gate's rig: clicks and a watchdog as REAL Handler timers, so
 * they arrive through the platform's own loop (n_run decodes the ids) */
void ux_and_test_click_later(int handle, int node, int ms) {
    postRunDelayed(envNow(), 0x10000 | (handle << 8) | node, ms);
}
void ux_and_test_watchdog(int ms, int rc) {
    postRunDelayed(envNow(), 0x20000 | (rc & 0xFF), ms);
}

/* ── boot: cache the widget world (UI thread, from the posted entry) ────── */
static jclass gref(JNIEnv *env, const char *name) {
    jclass c = (*env)->FindClass(env, name);
    if (!c) { check(env, name); return NULL; }
    return (jclass)(*env)->NewGlobalRef(env, c);
}
static jobject enumVal(JNIEnv *env, const char *cls, const char *name) {
    jclass c = (*env)->FindClass(env, cls);
    char sig[128];
    snprintf(sig, sizeof sig, "L%s;", cls);
    jfieldID f = (*env)->GetStaticFieldID(env, c, name, sig);
    return (*env)->NewGlobalRef(env, (*env)->GetStaticObjectField(env, c, f));
}
/* Out-of-bounds areas (status bar, display cutout, gesture bar) are the
 * PLATFORM's problem, solved by window positioning: the root gets padded by
 * the system-window insets at attach, so a toolkit window at y=0 sits below
 * the cutout and the app never learns the word "inset". */
static int gInsetL, gInsetT, gInsetR, gInsetB;   /* raw px */
static void queryInsets(JNIEnv *env) {
    jclass actC = (*env)->GetObjectClass(env, gActivity);
    jmethodID getWin = (*env)->GetMethodID(env, actC, "getWindow", "()Landroid/view/Window;");
    jobject win = (*env)->CallObjectMethod(env, gActivity, getWin);
    if (!win) return;
    jclass winC = (*env)->GetObjectClass(env, win);
    jmethodID getDecor = (*env)->GetMethodID(env, winC, "getDecorView", "()Landroid/view/View;");
    jobject decor = (*env)->CallObjectMethod(env, win, getDecor);
    if (!decor) return;
    jmethodID getIns = (*env)->GetMethodID(env, gViewCls, "getRootWindowInsets",
                                           "()Landroid/view/WindowInsets;");
    jobject ins = (*env)->CallObjectMethod(env, decor, getIns);
    if (!ins) { check(env, "insets"); return; }      /* pre-attach: try again at first draw */
    gInsetsKnown = 1;
    jclass insC = (*env)->GetObjectClass(env, ins);
    gInsetL = (*env)->CallIntMethod(env, ins, (*env)->GetMethodID(env, insC, "getSystemWindowInsetLeft", "()I"));
    gInsetT = (*env)->CallIntMethod(env, ins, (*env)->GetMethodID(env, insC, "getSystemWindowInsetTop", "()I"));
    gInsetR = (*env)->CallIntMethod(env, ins, (*env)->GetMethodID(env, insC, "getSystemWindowInsetRight", "()I"));
    gInsetB = (*env)->CallIntMethod(env, ins, (*env)->GetMethodID(env, insC, "getSystemWindowInsetBottom", "()I"));
    check(env, "queryInsets");
}
/* pad the attached root and shrink the reported usable screen — the late
 * half of the safe-area work, for when boot ran before the decor attached */
static void applyInsets(JNIEnv *env) {
    if (!gInsetsKnown || !gRoot) return;
    jmethodID setPad = (*env)->GetMethodID(env, gViewCls, "setPadding", "(IIII)V");
    (*env)->CallVoidMethod(env, gRoot, setPad, gInsetL, gInsetT, gInsetR, gInsetB);
    gScreenW = gScreenW - (int)((gInsetL + gInsetR) / gDensity);
    gScreenH = gScreenH - (int)((gInsetT + gInsetB) / gDensity);
    check(env, "applyInsets");
}
int ux_and_boot(int *w, int *h) {
    JNIEnv *env = envNow();
    gBtnCls    = gref(env, "android/widget/Button");
    gLabelCls  = gref(env, "android/widget/TextView");
    gFrameCls  = gref(env, "android/widget/FrameLayout");
    gViewCls   = gref(env, "android/view/View");
    gCanvasCls = gref(env, "android/graphics/Canvas");
    gPaintCls  = gref(env, "android/graphics/Paint");
    gBitmapCls = gref(env, "android/graphics/Bitmap");
    gPathCls   = gref(env, "android/graphics/Path");
    gCheckCls  = gref(env, "android/widget/CheckBox");
    gRadioCls  = gref(env, "android/widget/RadioButton");
    gCompoundCls = gref(env, "android/widget/CompoundButton");
    gSeekCls   = gref(env, "android/widget/SeekBar");
    gProgCls   = gref(env, "android/widget/ProgressBar");
    gSpinCls   = gref(env, "android/widget/Spinner");
    gEditCls   = gref(env, "android/widget/EditText");
    gAdapterCls= gref(env, "android/widget/ArrayAdapter");
    gLinearCls = gref(env, "android/widget/LinearLayout");
    if (!gBtnCls || !gLabelCls || !gFrameCls || !gViewCls || !gCanvasCls
        || !gPaintCls || !gBitmapCls || !gPathCls || !gCheckCls || !gRadioCls || !gCompoundCls || !gSeekCls
        || !gProgCls || !gSpinCls || !gEditCls || !gAdapterCls || !gLinearCls) {
        LOG("boot: widget classes missing"); return 0;
    }
    gBtnInit      = (*env)->GetMethodID(env, gBtnCls, "<init>", "(Landroid/content/Context;)V");
    gBtnSetText   = (*env)->GetMethodID(env, gBtnCls, "setText", "(Ljava/lang/CharSequence;)V");
    gLabelInit    = (*env)->GetMethodID(env, gLabelCls, "<init>", "(Landroid/content/Context;)V");
    gLabelSetText = (*env)->GetMethodID(env, gLabelCls, "setText", "(Ljava/lang/CharSequence;)V");
    gFrameInit    = (*env)->GetMethodID(env, gFrameCls, "<init>", "(Landroid/content/Context;)V");
    gAddView      = (*env)->GetMethodID(env, gFrameCls, "addView", "(Landroid/view/View;II)V");
    gRemoveView   = (*env)->GetMethodID(env, gFrameCls, "removeView", "(Landroid/view/View;)V");
    gSetTransX    = (*env)->GetMethodID(env, gViewCls, "setTranslationX", "(F)V");
    gSetTransY    = (*env)->GetMethodID(env, gViewCls, "setTranslationY", "(F)V");
    gPerformClick = (*env)->GetMethodID(env, gViewCls, "performClick", "()Z");
    gSetEnabled   = (*env)->GetMethodID(env, gViewCls, "setEnabled", "(Z)V");
    gSetVisibility= (*env)->GetMethodID(env, gViewCls, "setVisibility", "(I)V");
    gInvalidate   = (*env)->GetMethodID(env, gViewCls, "invalidate", "()V");
    gSetOnClick   = (*env)->GetMethodID(env, gViewCls, "setOnClickListener",
                                        "(Landroid/view/View$OnClickListener;)V");
    jclass actCls = (*env)->GetObjectClass(env, gActivity);
    gSetContentView = (*env)->GetMethodID(env, actCls, "setContentView", "(Landroid/view/View;)V");
    gBridgeInit = (*env)->GetMethodID(env, gBridgeCls, "<init>", "(I)V");
    gDrawInit   = (*env)->GetMethodID(env, gDrawCls, "<init>", "(Landroid/content/Context;I)V");
    /* the value controls */
    gCheckInit    = (*env)->GetMethodID(env, gCheckCls, "<init>", "(Landroid/content/Context;)V");
    gCheckSetText = (*env)->GetMethodID(env, gCheckCls, "setText", "(Ljava/lang/CharSequence;)V");
    gSetChecked   = (*env)->GetMethodID(env, gCheckCls, "setChecked", "(Z)V");
    gIsChecked    = (*env)->GetMethodID(env, gCheckCls, "isChecked", "()Z");
    gRadioSetChecked = (*env)->GetMethodID(env, gRadioCls, "setChecked", "(Z)V");
    gSeekInit     = (*env)->GetMethodID(env, gSeekCls, "<init>", "(Landroid/content/Context;)V");
    gSeekSetMin   = (*env)->GetMethodID(env, gSeekCls, "setMin", "(I)V");
    gSeekSetMax   = (*env)->GetMethodID(env, gSeekCls, "setMax", "(I)V");
    gSeekSetProgress = (*env)->GetMethodID(env, gSeekCls, "setProgress", "(I)V");
    gSeekListen   = (*env)->GetMethodID(env, gSeekCls, "setOnSeekBarChangeListener",
                                        "(Landroid/widget/SeekBar$OnSeekBarChangeListener;)V");
    /* horizontal ProgressBar: the three-arg ctor with the platform style attr */
    gProgInit     = (*env)->GetMethodID(env, gProgCls, "<init>",
                                        "(Landroid/content/Context;Landroid/util/AttributeSet;I)V");
    gProgSetMax   = (*env)->GetMethodID(env, gProgCls, "setMax", "(I)V");
    gProgSetProgress = (*env)->GetMethodID(env, gProgCls, "setProgress", "(I)V");
    gProgSetIndet = (*env)->GetMethodID(env, gProgCls, "setIndeterminate", "(Z)V");
    gSpinInit     = (*env)->GetMethodID(env, gSpinCls, "<init>", "(Landroid/content/Context;)V");
    gSpinSetAdapter = (*env)->GetMethodID(env, gSpinCls, "setAdapter",
                                          "(Landroid/widget/SpinnerAdapter;)V");
    gSpinSetSel   = (*env)->GetMethodID(env, gSpinCls, "setSelection", "(I)V");
    gSpinListen   = (*env)->GetMethodID(env, gSpinCls, "setOnItemSelectedListener",
                                        "(Landroid/widget/AdapterView$OnItemSelectedListener;)V");
    gAdapterInit  = (*env)->GetMethodID(env, gAdapterCls, "<init>", "(Landroid/content/Context;I)V");
    gAdapterAdd   = (*env)->GetMethodID(env, gAdapterCls, "add", "(Ljava/lang/Object;)V");
    gEditInit     = (*env)->GetMethodID(env, gEditCls, "<init>", "(Landroid/content/Context;)V");
    gEditSetText  = (*env)->GetMethodID(env, gEditCls, "setText", "(Ljava/lang/CharSequence;)V");
    gEditGetText  = (*env)->GetMethodID(env, gEditCls, "getText", "()Landroid/text/Editable;");
    gEditWatch    = (*env)->GetMethodID(env, gEditCls, "addTextChangedListener",
                                        "(Landroid/text/TextWatcher;)V");
    gEditSetInputType = (*env)->GetMethodID(env, gEditCls, "setInputType", "(I)V");
    /* drawing */
    gCanvasDrawRect = (*env)->GetMethodID(env, gCanvasCls, "drawRect",
                                          "(FFFFLandroid/graphics/Paint;)V");
    gCanvasDrawText = (*env)->GetMethodID(env, gCanvasCls, "drawText",
                                          "(Ljava/lang/String;FFLandroid/graphics/Paint;)V");
    gCanvasDrawPath = (*env)->GetMethodID(env, gCanvasCls, "drawPath",
                                          "(Landroid/graphics/Path;Landroid/graphics/Paint;)V");
    gCanvasInitBmp  = (*env)->GetMethodID(env, gCanvasCls, "<init>", "(Landroid/graphics/Bitmap;)V");
    gCanvasScale    = (*env)->GetMethodID(env, gCanvasCls, "scale", "(FF)V");
    gCanvasSave     = (*env)->GetMethodID(env, gCanvasCls, "save", "()I");
    gCanvasRestore  = (*env)->GetMethodID(env, gCanvasCls, "restore", "()V");
    gCanvasClipRect = (*env)->GetMethodID(env, gCanvasCls, "clipRect", "(FFFF)Z");
    gPaintInit        = (*env)->GetMethodID(env, gPaintCls, "<init>", "()V");
    gPaintSetColor    = (*env)->GetMethodID(env, gPaintCls, "setColor", "(I)V");
    gPaintSetTextSize = (*env)->GetMethodID(env, gPaintCls, "setTextSize", "(F)V");
    gPaintSetStyle    = (*env)->GetMethodID(env, gPaintCls, "setStyle",
                                            "(Landroid/graphics/Paint$Style;)V");
    gPaintSetStrokeWidth = (*env)->GetMethodID(env, gPaintCls, "setStrokeWidth", "(F)V");
    gPaintSetStrokeCap   = (*env)->GetMethodID(env, gPaintCls, "setStrokeCap",
                                               "(Landroid/graphics/Paint$Cap;)V");
    gPaintMeasure = (*env)->GetMethodID(env, gPaintCls, "measureText", "(Ljava/lang/String;)F");
    gPathInit    = (*env)->GetMethodID(env, gPathCls, "<init>", "()V");
    gPathMoveTo  = (*env)->GetMethodID(env, gPathCls, "moveTo", "(FF)V");
    gPathLineTo  = (*env)->GetMethodID(env, gPathCls, "lineTo", "(FF)V");
    gPathCubicTo = (*env)->GetMethodID(env, gPathCls, "cubicTo", "(FFFFFF)V");
    gPathClose   = (*env)->GetMethodID(env, gPathCls, "close", "()V");
    gBmpCreate = (*env)->GetStaticMethodID(env, gBitmapCls, "createBitmap",
                    "(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;");
    gBmpGetPixel = (*env)->GetMethodID(env, gBitmapCls, "getPixel", "(II)I");
    if (!check(env, "method ids")) return 0;

    jobject p = (*env)->NewObject(env, gPaintCls, gPaintInit);
    gPaint = (*env)->NewGlobalRef(env, p);
    gStyleFill   = enumVal(env, "android/graphics/Paint$Style", "FILL");
    gStyleStroke = enumVal(env, "android/graphics/Paint$Style", "STROKE");
    gCapButt     = enumVal(env, "android/graphics/Paint$Cap", "BUTT");
    gCapRound    = enumVal(env, "android/graphics/Paint$Cap", "ROUND");
    gCapSquare   = enumVal(env, "android/graphics/Paint$Cap", "SQUARE");
    if (!check(env, "paint")) return 0;

    /* the root FrameLayout is the content view; windows nest in it.  View
     * CONSTRUCTION is thread-free; only setContentView touches the attached
     * hierarchy, so it waits for the first window_create (always UI-side —
     * boot() itself may run on xt_main's detached thread under run()). */
    jobject root = (*env)->NewObject(env, gFrameCls, gFrameInit, gActivity);
    gRoot = (*env)->NewGlobalRef(env, root);
    if (!check(env, "root")) return 0;

    /* screen size via Resources.getDisplayMetrics() */
    jclass ctxCls = (*env)->GetObjectClass(env, gActivity);
    jmethodID getRes = (*env)->GetMethodID(env, ctxCls, "getResources",
                                           "()Landroid/content/res/Resources;");
    jobject res = (*env)->CallObjectMethod(env, gActivity, getRes);
    jclass resCls = (*env)->GetObjectClass(env, res);
    jmethodID getDm = (*env)->GetMethodID(env, resCls, "getDisplayMetrics",
                                          "()Landroid/util/DisplayMetrics;");
    jobject dm = (*env)->CallObjectMethod(env, res, getDm);
    jclass dmCls = (*env)->GetObjectClass(env, dm);
    gDensity = (*env)->GetFloatField(env, dm, (*env)->GetFieldID(env, dmCls, "density", "F"));
    if (gDensity <= 0) gDensity = 1.0f;
    queryInsets(env);
    /* the USABLE screen, in neutral units: raw pixels minus the out-of-bounds
     * areas, over density */
    gScreenW = (int)(((*env)->GetIntField(env, dm, (*env)->GetFieldID(env, dmCls, "widthPixels", "I"))
                      - gInsetL - gInsetR) / gDensity);
    gScreenH = (int)(((*env)->GetIntField(env, dm, (*env)->GetFieldID(env, dmCls, "heightPixels", "I"))
                      - gInsetT - gInsetB) / gDensity);
    *w = gScreenW; *h = gScreenH;
    return check(env, "metrics");
}
int ux_and_form_factor(void) {
    /* the platform's own idiom: smallest width in dp, tablet at 600 */
    int sw = gScreenW < gScreenH ? gScreenW : gScreenH;
    return sw >= 600 ? 2 /* UX_FORM_TABLET */ : 3 /* UX_FORM_PHONE */;
}

/* ── windows ────────────────────────────────────────────────────────────── */
static int gRootAttached;
int ux_and_window_create(int x, int y, int w, int h) {
    if (gNextH >= UXA_MAXW) return 0;
    JNIEnv *env = envNow();
    if (!gRootAttached) {
        /* the safe-area shift: windows at y=0 land below the cutout */
        jmethodID setPad = (*env)->GetMethodID(env, gViewCls, "setPadding", "(IIII)V");
        (*env)->CallVoidMethod(env, gRoot, setPad, gInsetL, gInsetT, gInsetR, gInsetB);
        (*env)->CallVoidMethod(env, gActivity, gSetContentView, gRoot);
        if (!check(env, "setContentView(root)")) return 0;
        gRootAttached = 1;
    }
    int hh = gNextH++;
    jobject win = (*env)->NewObject(env, gFrameCls, gFrameInit, gActivity);
    (*env)->CallVoidMethod(env, gRoot, gAddView, win, PX(w), PX(h));
    (*env)->CallVoidMethod(env, win, gSetTransX, (jfloat)PX(x));
    (*env)->CallVoidMethod(env, win, gSetTransY, (jfloat)PX(y));
    gWinV[hh] = (*env)->NewGlobalRef(env, win);
    gWinW[hh] = w; gWinH[hh] = h;
    /* the paint seam: a UXDrawView across the window (id = handle<<8) */
    jobject area = (*env)->NewObject(env, gDrawCls, gDrawInit, gActivity, hh << 8);
    (*env)->CallVoidMethod(env, gWinV[hh], gAddView, area, PX(w), PX(h));
    check(env, "window_create");
    gLive++;
    return hh;
}
void ux_and_window_set_content(int handle, void *fn, void *ud) {
    gContent[handle] = (ux_content_fn)fn; gContentUd[handle] = ud;
}
void ux_and_window_open(int handle, int x, int y, int w, int h) {
    JNIEnv *env = envNow();
    gWinW[handle] = w; gWinH[handle] = h;
    (*env)->CallVoidMethod(env, gWinV[handle], gSetTransX, (jfloat)PX(x));
    (*env)->CallVoidMethod(env, gWinV[handle], gSetTransY, (jfloat)PX(y));
}
void ux_and_window_front(int handle) {
    JNIEnv *env = envNow();
    if (!gWinV[handle]) return;
    jmethodID bringToFront = (*env)->GetMethodID(env, gViewCls, "bringToFront", "()V");
    (*env)->CallVoidMethod(env, gWinV[handle], bringToFront);
}
void ux_and_window_close(int handle) {
    JNIEnv *env = envNow();
    if (!gWinV[handle]) return;
    (*env)->CallVoidMethod(env, gRoot, gRemoveView, gWinV[handle]);
    (*env)->DeleteGlobalRef(env, gWinV[handle]);
    gWinV[handle] = NULL; gContent[handle] = NULL;
    for (int n = 0; n < 64; n++) {
        if (gCtl[handle][n]) { (*env)->DeleteGlobalRef(env, gCtl[handle][n]); gCtl[handle][n] = NULL; }
        if (gSpinAdapter[handle][n]) { (*env)->DeleteGlobalRef(env, gSpinAdapter[handle][n]); gSpinAdapter[handle][n] = NULL; }
        gFieldBuf[handle][n] = NULL;
    }
    gLive--;
    check(env, "window_close");
}
void ux_and_window_invalidate(int handle) {
    JNIEnv *env = envNow();
    if (gWinV[handle]) (*env)->CallVoidMethod(env, gWinV[handle], gInvalidate);
}
void ux_and_content_geometry(int handle, int *w, int *h) { *w = gWinW[handle]; *h = gWinH[handle]; }
int ux_and_native_count(void) { return gLive; }

/* ── native controls (button + label this slice; the set grows) ─────────── */
int ux_and_has_control(int handle, int node) {
    return handle > 0 && handle < UXA_MAXW && node >= 0 && node < 64
        && gCtl[handle][node] != NULL;
}
static void place(JNIEnv *env, int handle, int node, jobject v, int x, int y, int w, int h) {
    (*env)->CallVoidMethod(env, gWinV[handle], gAddView, v, PX(w), PX(h));
    (*env)->CallVoidMethod(env, v, gSetTransX, (jfloat)PX(x));
    (*env)->CallVoidMethod(env, v, gSetTransY, (jfloat)PX(y));
    gCtl[handle][node] = (*env)->NewGlobalRef(env, v);
}
void ux_and_make_button(int handle, int node, int x, int y, int w, int h, const char *title) {
    JNIEnv *env = envNow();
    jobject b = (*env)->NewObject(env, gBtnCls, gBtnInit, gActivity);
    (*env)->CallVoidMethod(env, b, gBtnSetText, (*env)->NewStringUTF(env, title));
    /* the platform's 48dp minimum fights the toolkit's cell heights: drop
     * the minimums and padding so the EXACT frame wins (text stays centred) */
    jmethodID minH = (*env)->GetMethodID(env, gBtnCls, "setMinHeight", "(I)V");
    jmethodID minMH = (*env)->GetMethodID(env, gBtnCls, "setMinimumHeight", "(I)V");
    jmethodID pad = (*env)->GetMethodID(env, gBtnCls, "setPadding", "(IIII)V");
    (*env)->CallVoidMethod(env, b, minH, 0);
    (*env)->CallVoidMethod(env, b, minMH, 0);
    (*env)->CallVoidMethod(env, b, pad, 0, 0, 0, 0);
    jobject br = (*env)->NewObject(env, gBridgeCls, gBridgeInit, (handle << 8) | node);
    (*env)->CallVoidMethod(env, b, gSetOnClick, br);
    place(env, handle, node, b, x, y, w, h);
    check(env, "make_button");
}
void ux_and_make_label(int handle, int node, int x, int y, int w, int h, const char *text) {
    JNIEnv *env = envNow();
    jobject l = (*env)->NewObject(env, gLabelCls, gLabelInit, gActivity);
    (*env)->CallVoidMethod(env, l, gLabelSetText, (*env)->NewStringUTF(env, text));
    place(env, handle, node, l, x, y, w, h);
    check(env, "make_label");
}
static jobject bridge(JNIEnv *env, int handle, int node) {
    return (*env)->NewObject(env, gBridgeCls, gBridgeInit, (handle << 8) | node);
}
void ux_and_make_checkbox(int handle, int node, int x, int y, int w, int h,
                          const char *title, int on) {
    JNIEnv *env = envNow();
    jobject cb = (*env)->NewObject(env, gCheckCls, gCheckInit, gActivity);
    (*env)->CallVoidMethod(env, cb, gCheckSetText, (*env)->NewStringUTF(env, title));
    (*env)->CallVoidMethod(env, cb, gSetChecked, (jboolean)(on != 0));
    (*env)->CallVoidMethod(env, cb, gSetOnClick, bridge(env, handle, node));
    place(env, handle, node, cb, x, y, w, h);
    check(env, "make_checkbox");
}
/* a REAL RadioButton — exclusivity stays NEUTRAL (UXRadioGroup), so no
 * RadioGroup container: the model pushes selection back via set_checkbox */
void ux_and_make_radio(int handle, int node, int x, int y, int w, int h,
                       const char *title, int on) {
    JNIEnv *env = envNow();
    jmethodID init = (*env)->GetMethodID(env, gRadioCls, "<init>", "(Landroid/content/Context;)V");
    jmethodID setText = (*env)->GetMethodID(env, gRadioCls, "setText", "(Ljava/lang/CharSequence;)V");
    jobject rb = (*env)->NewObject(env, gRadioCls, init, gActivity);
    (*env)->CallVoidMethod(env, rb, setText, (*env)->NewStringUTF(env, title));
    (*env)->CallVoidMethod(env, rb, gRadioSetChecked, (jboolean)(on != 0));
    (*env)->CallVoidMethod(env, rb, gSetOnClick, bridge(env, handle, node));
    place(env, handle, node, rb, x, y, w, h);
    check(env, "make_radio");
}
/* shared by checkbox AND radio: pick the id by the instance's class */
void ux_and_set_checkbox(int handle, int node, int on) {
    JNIEnv *env = envNow();
    jobject c = gCtl[handle][node];
    if (!c) return;
    jmethodID m = (*env)->IsInstanceOf(env, c, gRadioCls) ? gRadioSetChecked : gSetChecked;
    (*env)->CallVoidMethod(env, c, m, (jboolean)(on != 0));
}
void ux_and_make_slider(int handle, int node, int x, int y, int w, int h,
                        int lo, int hi, int val) {
    JNIEnv *env = envNow();
    jobject s = (*env)->NewObject(env, gSeekCls, gSeekInit, gActivity);
    (*env)->CallVoidMethod(env, s, gSeekSetMin, lo);
    (*env)->CallVoidMethod(env, s, gSeekSetMax, hi);
    (*env)->CallVoidMethod(env, s, gSeekSetProgress, val);
    (*env)->CallVoidMethod(env, s, gSeekListen, bridge(env, handle, node));
    place(env, handle, node, s, x, y, w, h);
    check(env, "make_slider");
}
void ux_and_set_slider_value(int handle, int node, int val) {
    JNIEnv *env = envNow();
    if (gCtl[handle][node])
        (*env)->CallVoidMethod(env, gCtl[handle][node], gSeekSetProgress, val);
}
void ux_and_make_progress(int handle, int node, int x, int y, int w, int h, int mille) {
    JNIEnv *env = envNow();
    /* android.R.attr.progressBarStyleHorizontal — a platform constant */
    jobject p = (*env)->NewObject(env, gProgCls, gProgInit, gActivity, NULL, 0x01010078);
    (*env)->CallVoidMethod(env, p, gProgSetMax, 1000);
    (*env)->CallVoidMethod(env, p, gProgSetProgress, mille);
    place(env, handle, node, p, x, y, w, h);
    check(env, "make_progress");
}
void ux_and_set_progress(int handle, int node, int mille, int indeterminate) {
    JNIEnv *env = envNow();
    jobject p = gCtl[handle][node];
    if (!p) return;
    (*env)->CallVoidMethod(env, p, gProgSetIndet, (jboolean)(indeterminate != 0));
    if (!indeterminate) (*env)->CallVoidMethod(env, p, gProgSetProgress, mille);
}
void ux_and_make_popup(int handle, int node, int x, int y, int w, int h) {
    JNIEnv *env = envNow();
    jobject sp = (*env)->NewObject(env, gSpinCls, gSpinInit, gActivity);
    /* android.R.layout.simple_spinner_item — a platform constant */
    jobject ad = (*env)->NewObject(env, gAdapterCls, gAdapterInit, gActivity, 0x01090008);
    (*env)->CallVoidMethod(env, sp, gSpinSetAdapter, ad);
    gSpinAdapter[handle][node] = (*env)->NewGlobalRef(env, ad);
    (*env)->DeleteLocalRef(env, ad);
    place(env, handle, node, sp, x, y, w, h);
    check(env, "make_popup");
}
void ux_and_popup_add_item(int handle, int node, const char *title) {
    JNIEnv *env = envNow();
    if (gSpinAdapter[handle][node])
        (*env)->CallVoidMethod(env, gSpinAdapter[handle][node], gAdapterAdd,
                               (*env)->NewStringUTF(env, title));
}
void ux_and_popup_select(int handle, int node, int i) {
    JNIEnv *env = envNow();
    jobject sp = gCtl[handle][node];
    if (!sp) return;
    (*env)->CallVoidMethod(env, sp, gSpinSetSel, i);
    /* the listener attaches AFTER the initial selection so it reports only
     * user picks (Spinner fires onItemSelected for programmatic ones too) */
    (*env)->CallVoidMethod(env, sp, gSpinListen, bridge(env, handle, node));
}
void ux_and_make_field(int handle, int node, int x, int y, int w, int h,
                       char *buf, int cap, int secure) {
    JNIEnv *env = envNow();
    jobject ed = (*env)->NewObject(env, gEditCls, gEditInit, gActivity);
    /* the platform's minimums and padding push the text past a toolkit-sized
     * frame (descenders clipped against the underline): drop the floors and
     * centre vertically, as the button does */
    jmethodID minH = (*env)->GetMethodID(env, gEditCls, "setMinHeight", "(I)V");
    jmethodID minMH = (*env)->GetMethodID(env, gEditCls, "setMinimumHeight", "(I)V");
    jmethodID pad = (*env)->GetMethodID(env, gEditCls, "setPadding", "(IIII)V");
    jmethodID grav = (*env)->GetMethodID(env, gEditCls, "setGravity", "(I)V");
    (*env)->CallVoidMethod(env, ed, minH, 0);
    (*env)->CallVoidMethod(env, ed, minMH, 0);
    (*env)->CallVoidMethod(env, ed, pad, PX(2), 0, PX(2), 0);
    (*env)->CallVoidMethod(env, ed, grav, 16);            /* CENTER_VERTICAL */
    gFieldBuf[handle][node] = buf;
    gFieldCap[handle][node] = cap;
    if (secure)   /* TYPE_CLASS_TEXT | TYPE_TEXT_VARIATION_PASSWORD */
        (*env)->CallVoidMethod(env, ed, gEditSetInputType, 0x81);
    gFieldMute = 1;
    (*env)->CallVoidMethod(env, ed, gEditSetText, (*env)->NewStringUTF(env, buf));
    gFieldMute = 0;
    (*env)->CallVoidMethod(env, ed, gEditWatch, bridge(env, handle, node));
    place(env, handle, node, ed, x, y, w, h);
    check(env, "make_field");
}
void ux_and_update_field(int handle, int node) {
    JNIEnv *env = envNow();
    jobject ed = gCtl[handle][node];
    char *buf = gFieldBuf[handle][node];
    if (!ed || !buf) return;
    gFieldMute = 1;
    (*env)->CallVoidMethod(env, ed, gEditSetText, (*env)->NewStringUTF(env, buf));
    gFieldMute = 0;
}
/* Android has no platform stepper; the Material idiom is a -/+ button pair.
 * Two REAL Buttons in a horizontal LinearLayout; each click reports through
 * the bridge with the direction folded into the id's spare node bits
 * (nodes stop at 63): node|0x40 = increment, node|0x80 = decrement.  The
 * driver decodes and steps the peer — the value lives neutral-side, shown
 * by whatever field the app pairs the stepper with (the mac arrangement). */
static jobject stepHalf(JNIEnv *env, const char *label, int id) {
    jobject b = (*env)->NewObject(env, gBtnCls, gBtnInit, gActivity);
    (*env)->CallVoidMethod(env, b, gBtnSetText, (*env)->NewStringUTF(env, label));
    jmethodID minH = (*env)->GetMethodID(env, gBtnCls, "setMinHeight", "(I)V");
    jmethodID minMH = (*env)->GetMethodID(env, gBtnCls, "setMinimumHeight", "(I)V");
    jmethodID minW = (*env)->GetMethodID(env, gBtnCls, "setMinWidth", "(I)V");
    jmethodID minMW = (*env)->GetMethodID(env, gBtnCls, "setMinimumWidth", "(I)V");
    jmethodID pad = (*env)->GetMethodID(env, gBtnCls, "setPadding", "(IIII)V");
    (*env)->CallVoidMethod(env, b, minH, 0);  (*env)->CallVoidMethod(env, b, minMH, 0);
    (*env)->CallVoidMethod(env, b, minW, 0);  (*env)->CallVoidMethod(env, b, minMW, 0);
    (*env)->CallVoidMethod(env, b, pad, 0, 0, 0, 0);
    jobject br = (*env)->NewObject(env, gBridgeCls, gBridgeInit, id);
    (*env)->CallVoidMethod(env, b, gSetOnClick, br);
    return b;
}
void ux_and_make_stepper(int handle, int node, int x, int y, int w, int h) {
    JNIEnv *env = envNow();
    jmethodID linInit = (*env)->GetMethodID(env, gLinearCls, "<init>", "(Landroid/content/Context;)V");
    jmethodID setOrient = (*env)->GetMethodID(env, gLinearCls, "setOrientation", "(I)V");
    jmethodID addV = (*env)->GetMethodID(env, gLinearCls, "addView", "(Landroid/view/View;II)V");
    jobject box = (*env)->NewObject(env, gLinearCls, linInit, gActivity);
    (*env)->CallVoidMethod(env, box, setOrient, 0);   /* horizontal */
    int half = PX(w) / 2;
    (*env)->CallVoidMethod(env, box, addV, stepHalf(env, "\xe2\x88\x92", (handle << 8) | node | 0x80), half, PX(h));
    (*env)->CallVoidMethod(env, box, addV, stepHalf(env, "+",              (handle << 8) | node | 0x40), half, PX(h));
    place(env, handle, node, box, x, y, w, h);
    check(env, "make_stepper");
}

/* the rigs' value pokes: set natively AND report as the platform would */
void ux_and_test_set_slider(int handle, int node, int val) {
    ux_and_set_slider_value(handle, node, val);
    if (gValueChanged) gValueChanged(handle, node, val);
}
void ux_and_set_control_frame(int handle, int node, int x, int y, int w, int h) {
    JNIEnv *env = envNow();
    jobject c = gCtl[handle][node];
    if (!c) return;
    (*env)->CallVoidMethod(env, c, gSetTransX, (jfloat)PX(x));
    (*env)->CallVoidMethod(env, c, gSetTransY, (jfloat)PX(y));
}
void ux_and_set_control_enabled(int handle, int node, int on) {
    JNIEnv *env = envNow();
    if (gCtl[handle][node])
        (*env)->CallVoidMethod(env, gCtl[handle][node], gSetEnabled, (jboolean)(on != 0));
}
void ux_and_set_control_hidden(int handle, int node, int on) {
    JNIEnv *env = envNow();
    if (gCtl[handle][node])
        (*env)->CallVoidMethod(env, gCtl[handle][node], gSetVisibility, on ? 8 : 0); /* GONE/VISIBLE */
}
void ux_and_test_click(int handle, int node) {
    JNIEnv *env = envNow();
    if (gCtl[handle][node]) (*env)->CallBooleanMethod(env, gCtl[handle][node], gPerformClick);
}

/* ── drawing ops (the Canvas of the draw in flight) ─────────────────────── */
static void paintColor(JNIEnv *env, int r, int g, int b) {
    (*env)->CallVoidMethod(env, gPaint, gPaintSetColor,
                           (jint)(0xFF000000u | ((unsigned)r << 16) | ((unsigned)g << 8) | (unsigned)b));
}
void ux_and_fill(int x, int y, int w, int h, int r, int g, int b) {
    if (!gDrawCanvas) return;
    JNIEnv *env = envNow();
    paintColor(env, r, g, b);
    (*env)->CallVoidMethod(env, gPaint, gPaintSetStyle, gStyleFill);
    (*env)->CallVoidMethod(env, gDrawCanvas, gCanvasDrawRect,
                           (jfloat)x, (jfloat)y, (jfloat)(x + w), (jfloat)(y + h), gPaint);
}
void ux_and_text(const char *s, int x, int y, int r, int g, int b, int size) {
    if (!gDrawCanvas) return;
    JNIEnv *env = envNow();
    int px = size > 0 ? size : 14;
    paintColor(env, r, g, b);
    (*env)->CallVoidMethod(env, gPaint, gPaintSetStyle, gStyleFill);
    (*env)->CallVoidMethod(env, gPaint, gPaintSetTextSize, (jfloat)px);
    jstring js = (*env)->NewStringUTF(env, s);
    /* the seam's y is text TOP; Canvas.drawText wants the baseline */
    (*env)->CallVoidMethod(env, gDrawCanvas, gCanvasDrawText, js,
                           (jfloat)x, (jfloat)(y + px), gPaint);
    (*env)->DeleteLocalRef(env, js);
}
void ux_and_tri(int x0, int y0, int x1, int y1, int x2, int y2, int r, int g, int b) {
    if (!gDrawCanvas) return;
    JNIEnv *env = envNow();
    jobject path = (*env)->NewObject(env, gPathCls, gPathInit);
    (*env)->CallVoidMethod(env, path, gPathMoveTo, (jfloat)x0, (jfloat)y0);
    (*env)->CallVoidMethod(env, path, gPathLineTo, (jfloat)x1, (jfloat)y1);
    (*env)->CallVoidMethod(env, path, gPathLineTo, (jfloat)x2, (jfloat)y2);
    (*env)->CallVoidMethod(env, path, gPathClose);
    paintColor(env, r, g, b);
    (*env)->CallVoidMethod(env, gPaint, gPaintSetStyle, gStyleFill);
    (*env)->CallVoidMethod(env, gDrawCanvas, gCanvasDrawPath, path, gPaint);
    (*env)->DeleteLocalRef(env, path);
}
void ux_and_poly(short *xy, int n, int r, int g, int b) {
    if (!gDrawCanvas || n < 3) return;
    JNIEnv *env = envNow();
    jobject path = (*env)->NewObject(env, gPathCls, gPathInit);
    (*env)->CallVoidMethod(env, path, gPathMoveTo, (jfloat)xy[0], (jfloat)xy[1]);
    for (int i = 1; i < n; i++)
        (*env)->CallVoidMethod(env, path, gPathLineTo, (jfloat)xy[i * 2], (jfloat)xy[i * 2 + 1]);
    (*env)->CallVoidMethod(env, path, gPathClose);
    paintColor(env, r, g, b);
    (*env)->CallVoidMethod(env, gPaint, gPaintSetStyle, gStyleFill);
    (*env)->CallVoidMethod(env, gDrawCanvas, gCanvasDrawPath, path, gPaint);
    (*env)->DeleteLocalRef(env, path);
}
/* ops encoding: UXSTROKE_MOVE x y | LINE x y | CURVE c1..c2..xy | CLOSE */
void ux_and_stroke_path(int *ops, int n, int width, int startCap, int endCap, int r, int g, int b) {
    if (!gDrawCanvas) return;
    JNIEnv *env = envNow();
    jobject path = (*env)->NewObject(env, gPathCls, gPathInit);
    int i = 0;
    while (i < n) {
        int op = ops[i++];
        if (op == 0) {                         /* MOVE */
            (*env)->CallVoidMethod(env, path, gPathMoveTo, (jfloat)ops[i], (jfloat)ops[i + 1]); i += 2;
        } else if (op == 1) {                  /* LINE */
            (*env)->CallVoidMethod(env, path, gPathLineTo, (jfloat)ops[i], (jfloat)ops[i + 1]); i += 2;
        } else if (op == 2) {                  /* CURVE */
            (*env)->CallVoidMethod(env, path, gPathCubicTo,
                (jfloat)ops[i],     (jfloat)ops[i + 1], (jfloat)ops[i + 2],
                (jfloat)ops[i + 3], (jfloat)ops[i + 4], (jfloat)ops[i + 5]); i += 6;
        } else if (op == 3) {                  /* CLOSE */
            (*env)->CallVoidMethod(env, path, gPathClose);
        } else break;
    }
    paintColor(env, r, g, b);
    (*env)->CallVoidMethod(env, gPaint, gPaintSetStyle, gStyleStroke);
    (*env)->CallVoidMethod(env, gPaint, gPaintSetStrokeWidth, (jfloat)(width > 0 ? width : 1));
    /* one Cap per Paint: round if either end asks, square above butt */
    jobject cap = (startCap == 1 || endCap == 1) ? gCapRound
                : (startCap == 2 || endCap == 2) ? gCapSquare : gCapButt;
    (*env)->CallVoidMethod(env, gPaint, gPaintSetStrokeCap, cap);
    (*env)->CallVoidMethod(env, gDrawCanvas, gCanvasDrawPath, path, gPaint);
    (*env)->CallVoidMethod(env, gPaint, gPaintSetStyle, gStyleFill);
    (*env)->DeleteLocalRef(env, path);
}
/* subtree clipping for the draw walk (neutral coords — the canvas is pre-scaled) */
void ux_and_clip(int x, int y, int w, int h) {
    if (!gDrawCanvas) return;
    JNIEnv *env = envNow();
    (*env)->CallIntMethod(env, gDrawCanvas, gCanvasSave);
    (*env)->CallBooleanMethod(env, gDrawCanvas, gCanvasClipRect,
                              (jfloat)x, (jfloat)y, (jfloat)(x + w), (jfloat)(y + h));
}
void ux_and_clip_end(void) {
    if (!gDrawCanvas) return;
    JNIEnv *env = envNow();
    (*env)->CallVoidMethod(env, gDrawCanvas, gCanvasRestore);
}

int ux_and_text_width(const char *s, int size) {
    JNIEnv *env = envNow();
    if (!gPaint) return (int)strlen(s) * (size > 0 ? size : 14) / 2;
    (*env)->CallVoidMethod(env, gPaint, gPaintSetTextSize, (jfloat)(size > 0 ? size : 14));
    jstring js = (*env)->NewStringUTF(env, s);
    jfloat w = (*env)->CallFloatMethod(env, gPaint, gPaintMeasure, js);
    (*env)->DeleteLocalRef(env, js);
    return (int)(w + 0.5f);
}
int ux_and_text_width_font(const char *s, const char *family, int size, int bold, int italic) {
    (void)family; (void)bold; (void)italic;   /* Typeface: a later slice */
    return ux_and_text_width(s, size);
}

/* ── the offscreen proof rig (Bitmap-backed Canvas, getPixel) ───────────── */
static jobject gShotBmp;                  /* global ref */
void ux_and_render(int handle) {
    JNIEnv *env = envNow();
    int w = PX(gWinW[handle]), h = PX(gWinH[handle]);
    if (w <= 0 || h <= 0 || !gContent[handle]) return;
    jclass cfgCls = (*env)->FindClass(env, "android/graphics/Bitmap$Config");
    jfieldID f8888 = (*env)->GetStaticFieldID(env, cfgCls, "ARGB_8888",
                                              "Landroid/graphics/Bitmap$Config;");
    jobject cfg = (*env)->GetStaticObjectField(env, cfgCls, f8888);
    jobject bmp = (*env)->CallStaticObjectMethod(env, gBitmapCls, gBmpCreate, w, h, cfg);
    if (gShotBmp) (*env)->DeleteGlobalRef(env, gShotBmp);
    gShotBmp = (*env)->NewGlobalRef(env, bmp);
    jobject canvas = (*env)->NewObject(env, gCanvasCls, gCanvasInitBmp, bmp);
    /* white ground, then the REAL view hierarchy — native overlays included
     * (the renderInContext analogue).  Just-created views have no layout
     * pass behind them yet, so run one by hand before drawing. */
    jmethodID white = (*env)->GetMethodID(env, gCanvasCls, "drawColor", "(I)V");
    (*env)->CallVoidMethod(env, canvas, white, (jint)0xFFFFFFFF);
    jmethodID measure = (*env)->GetMethodID(env, gViewCls, "measure", "(II)V");
    jmethodID layout  = (*env)->GetMethodID(env, gViewCls, "layout", "(IIII)V");
    jmethodID draw    = (*env)->GetMethodID(env, gViewCls, "draw", "(Landroid/graphics/Canvas;)V");
    (*env)->CallVoidMethod(env, gWinV[handle], measure,
                           (jint)(0x40000000 | w), (jint)(0x40000000 | h));  /* MeasureSpec.EXACTLY */
    (*env)->CallVoidMethod(env, gWinV[handle], layout, 0, 0, w, h);
    /* Material toggles animate between drawable states; a one-shot draw
     * catches frame ZERO of the uncheck->check animation and renders a
     * checked box unchecked.  Jump every drawable to its settled state. */
    jmethodID jump = (*env)->GetMethodID(env, gViewCls, "jumpDrawablesToCurrentState", "()V");
    (*env)->CallVoidMethod(env, gWinV[handle], jump);
    (*env)->CallVoidMethod(env, gWinV[handle], draw, canvas);
    (*env)->DeleteLocalRef(env, canvas);
    (*env)->DeleteLocalRef(env, bmp);
    check(env, "render");
}
int ux_and_pixel(int x, int y) {
    JNIEnv *env = envNow();
    if (!gShotBmp) return -1;
    /* neutral coords in; sample the density-scaled shot at the cell centre */
    jint px = (*env)->CallIntMethod(env, gShotBmp, gBmpGetPixel,
                                    (jint)(x * gDensity + gDensity * 0.5f),
                                    (jint)(y * gDensity + gDensity * 0.5f));
    return (int)(px & 0x00FFFFFF);
}
/* dump the last render as a P6 PPM under the app's files dir (the capture
 * pipeline's sheet; adb run-as pulls it — the APK is debuggable there) */
int ux_and_dump_ppm(const char *name) {
    JNIEnv *env = envNow();
    if (!gShotBmp) return 0;
    jclass bc = (*env)->GetObjectClass(env, gShotBmp);
    jmethodID getW = (*env)->GetMethodID(env, bc, "getWidth", "()I");
    jmethodID getH = (*env)->GetMethodID(env, bc, "getHeight", "()I");
    jmethodID getPx = (*env)->GetMethodID(env, bc, "getPixels", "([IIIIIII)V");
    int w = (*env)->CallIntMethod(env, gShotBmp, getW);
    int h = (*env)->CallIntMethod(env, gShotBmp, getH);
    jintArray arr = (*env)->NewIntArray(env, w * h);
    (*env)->CallVoidMethod(env, gShotBmp, getPx, arr, 0, w, 0, 0, w, h);
    jint *px = (*env)->GetIntArrayElements(env, arr, NULL);

    jclass ctx = (*env)->GetObjectClass(env, gActivity);
    jmethodID getFiles = (*env)->GetMethodID(env, ctx, "getFilesDir", "()Ljava/io/File;");
    jobject dirF = (*env)->CallObjectMethod(env, gActivity, getFiles);
    jclass fileCls = (*env)->GetObjectClass(env, dirF);
    jmethodID absPath = (*env)->GetMethodID(env, fileCls, "getAbsolutePath", "()Ljava/lang/String;");
    jstring jdir = (jstring)(*env)->CallObjectMethod(env, dirF, absPath);
    const char *dir = (*env)->GetStringUTFChars(env, jdir, NULL);
    char path[512];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    (*env)->ReleaseStringUTFChars(env, jdir, dir);

    FILE *f = fopen(path, "wb");
    if (!f) { (*env)->ReleaseIntArrayElements(env, arr, px, JNI_ABORT); return 0; }
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (int i = 0; i < w * h; i++) {
        unsigned p = (unsigned)px[i];
        unsigned char rgb[3] = { (p >> 16) & 255, (p >> 8) & 255, p & 255 };
        fwrite(rgb, 1, 3, f);
    }
    fclose(f);
    (*env)->ReleaseIntArrayElements(env, arr, px, JNI_ABORT);
    LOG("sheet -> %s", path);
    return check(env, "dump_ppm");
}

/* ── time (pure libc — safe on any thread, no JNI) ──────────────────────── */
int ux_and_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}
void ux_and_now_utc(int *out7) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm tm;
    gmtime_r(&ts.tv_sec, &tm);
    out7[0] = tm.tm_year + 1900; out7[1] = tm.tm_mon + 1; out7[2] = tm.tm_mday;
    out7[3] = tm.tm_hour; out7[4] = tm.tm_min; out7[5] = tm.tm_sec;
    out7[6] = (int)(ts.tv_nsec / 1000000);
}
int ux_and_local_offset_minutes(void) {
    time_t t = time(NULL);
    struct tm loc;
    localtime_r(&t, &loc);
    return (int)(loc.tm_gmtoff / 60);
}

/* ── settings: REAL SharedPreferences, one file per domain ──────────────── */
/* The platform's own store (thread-safe, so callable from any thread — the
 * settings seam needs no boot() and no UI hop).  Method ids cached lazily:
 * settings can be asked for before boot's cache pass runs. */
static jmethodID gGetPrefs, gPrefContains, gPrefGetString, gPrefEdit,
    gEditPut, gEditRemove, gEditCommit;
static jobject prefsFor(JNIEnv *env, const char *domain) {
    if (!gGetPrefs) {
        jclass actC = (*env)->GetObjectClass(env, gActivity);
        gGetPrefs = (*env)->GetMethodID(env, actC, "getSharedPreferences",
                        "(Ljava/lang/String;I)Landroid/content/SharedPreferences;");
        jclass prefC = (*env)->FindClass(env, "android/content/SharedPreferences");
        gPrefContains  = (*env)->GetMethodID(env, prefC, "contains", "(Ljava/lang/String;)Z");
        gPrefGetString = (*env)->GetMethodID(env, prefC, "getString",
                        "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
        gPrefEdit = (*env)->GetMethodID(env, prefC, "edit",
                        "()Landroid/content/SharedPreferences$Editor;");
        jclass edC = (*env)->FindClass(env, "android/content/SharedPreferences$Editor");
        gEditPut = (*env)->GetMethodID(env, edC, "putString",
                        "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;");
        gEditRemove = (*env)->GetMethodID(env, edC, "remove",
                        "(Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;");
        gEditCommit = (*env)->GetMethodID(env, edC, "commit", "()Z");
        if (!check(env, "prefs ids")) return NULL;
    }
    jstring d = (*env)->NewStringUTF(env, domain);
    jobject p = (*env)->CallObjectMethod(env, gActivity, gGetPrefs, d, 0 /* MODE_PRIVATE */);
    (*env)->DeleteLocalRef(env, d);
    return p;
}
int ux_and_setting_get(const char *domain, const char *key, char *out, int cap) {
    JNIEnv *env = envNow();
    jobject p = prefsFor(env, domain);
    if (!p) return 0;
    jstring k = (*env)->NewStringUTF(env, key);
    int ok = 0;
    if ((*env)->CallBooleanMethod(env, p, gPrefContains, k)) {
        jstring def = (*env)->NewStringUTF(env, "");
        jstring v = (jstring)(*env)->CallObjectMethod(env, p, gPrefGetString, k, def);
        if (v) {
            const char *u = (*env)->GetStringUTFChars(env, v, NULL);
            strncpy(out, u, cap - 1);
            out[cap - 1] = 0;
            (*env)->ReleaseStringUTFChars(env, v, u);
            ok = 1;
        }
    }
    (*env)->DeleteLocalRef(env, k);
    (*env)->DeleteLocalRef(env, p);
    return check(env, "setting_get") ? ok : 0;
}
int ux_and_setting_set(const char *domain, const char *key, const char *value) {
    JNIEnv *env = envNow();
    jobject p = prefsFor(env, domain);
    if (!p) return 0;
    jobject ed = (*env)->CallObjectMethod(env, p, gPrefEdit);
    (*env)->CallObjectMethod(env, ed, gEditPut,
        (*env)->NewStringUTF(env, key), (*env)->NewStringUTF(env, value));
    int ok = (*env)->CallBooleanMethod(env, ed, gEditCommit) ? 1 : 0;
    (*env)->DeleteLocalRef(env, ed);
    (*env)->DeleteLocalRef(env, p);
    return check(env, "setting_set") ? ok : 0;
}
int ux_and_setting_remove(const char *domain, const char *key) {
    JNIEnv *env = envNow();
    jobject p = prefsFor(env, domain);
    if (!p) return 0;
    jstring k = (*env)->NewStringUTF(env, key);
    int had = (*env)->CallBooleanMethod(env, p, gPrefContains, k) ? 1 : 0;
    if (had) {
        jobject ed = (*env)->CallObjectMethod(env, p, gPrefEdit);
        (*env)->CallObjectMethod(env, ed, gEditRemove, k);
        (*env)->CallBooleanMethod(env, ed, gEditCommit);
        (*env)->DeleteLocalRef(env, ed);
    }
    (*env)->DeleteLocalRef(env, k);
    (*env)->DeleteLocalRef(env, p);
    return check(env, "setting_remove") ? had : 0;
}

/* ── the modal alert: AlertDialog + a nested Looper.loop() ──────────────────
 * alertRun's synchronous contract on a platform whose dialogs are async:
 * show the dialog, then nest Looper.loop().  A button (or cancel) lands in
 * the UXBridge listener -> n_value/n_fire intercept -> alertFinish, which
 * records the result and THROWS a marker exception to unwind the nested
 * loop; ux_and_alert clears it at the JNI boundary — the classic Android
 * sync-dialog shape, kept entirely inside the shim.  The rigs arm
 * ux_and_alert_auto: a Handler timer (n_run id 0x40000) that optionally
 * renders the OPEN dialog into the shot bitmap, then cancels it. */
static jobject gAlertDialog;             /* global ref while modal */
static int gAlertResult, gAlertDone, gAlertNesting;
static int gAlertAutoMs, gAlertAutoShot;
void ux_and_alert_auto(int ms, int shot) { gAlertAutoMs = ms; gAlertAutoShot = shot; }

static void alertFinish(JNIEnv *env, int neutralIdx) {
    if (gAlertDone) return;
    gAlertResult = neutralIdx; gAlertDone = 1;
    if (gAlertNesting) {
        jclass ex = (*env)->FindClass(env, "java/lang/RuntimeException");
        (*env)->ThrowNew(env, ex, "ux-alert-unwind");
    }
}

/* render an arbitrary (laid-out, shown) view into the shot bitmap */
static void andRenderViewToShot(JNIEnv *env, jobject view) {
    jclass vc = (*env)->GetObjectClass(env, view);
    jmethodID getW = (*env)->GetMethodID(env, vc, "getWidth", "()I");
    jmethodID getH = (*env)->GetMethodID(env, vc, "getHeight", "()I");
    int w = (*env)->CallIntMethod(env, view, getW);
    int h = (*env)->CallIntMethod(env, view, getH);
    if (w <= 0 || h <= 0) return;
    jclass cfgCls = (*env)->FindClass(env, "android/graphics/Bitmap$Config");
    jfieldID f8888 = (*env)->GetStaticFieldID(env, cfgCls, "ARGB_8888",
                                              "Landroid/graphics/Bitmap$Config;");
    jobject cfg = (*env)->GetStaticObjectField(env, cfgCls, f8888);
    jobject bmp = (*env)->CallStaticObjectMethod(env, gBitmapCls, gBmpCreate, w, h, cfg);
    if (gShotBmp) (*env)->DeleteGlobalRef(env, gShotBmp);
    gShotBmp = (*env)->NewGlobalRef(env, bmp);
    jobject canvas = (*env)->NewObject(env, gCanvasCls, gCanvasInitBmp, bmp);
    jmethodID white = (*env)->GetMethodID(env, gCanvasCls, "drawColor", "(I)V");
    (*env)->CallVoidMethod(env, canvas, white, (jint)0xFFFFFFFF);
    jmethodID jump = (*env)->GetMethodID(env, gViewCls, "jumpDrawablesToCurrentState", "()V");
    (*env)->CallVoidMethod(env, view, jump);
    jmethodID draw = (*env)->GetMethodID(env, gViewCls, "draw", "(Landroid/graphics/Canvas;)V");
    (*env)->CallVoidMethod(env, view, draw, canvas);
    (*env)->DeleteLocalRef(env, canvas);
    (*env)->DeleteLocalRef(env, bmp);
    check(env, "alert-shot");
}

static void alertAuto(JNIEnv *env, int shot) {
    if (!gAlertDialog) return;
    if (shot) {
        jclass dc = (*env)->GetObjectClass(env, gAlertDialog);
        jmethodID getWin = (*env)->GetMethodID(env, dc, "getWindow", "()Landroid/view/Window;");
        jobject win = (*env)->CallObjectMethod(env, gAlertDialog, getWin);
        if (win) {
            jclass wc = (*env)->GetObjectClass(env, win);
            jmethodID getDecor = (*env)->GetMethodID(env, wc, "getDecorView", "()Landroid/view/View;");
            jobject decor = (*env)->CallObjectMethod(env, win, getDecor);
            if (decor) andRenderViewToShot(env, decor);
        }
    }
    jclass dc = (*env)->GetObjectClass(env, gAlertDialog);
    jmethodID cancel = (*env)->GetMethodID(env, dc, "cancel", "()V");
    (*env)->CallVoidMethod(env, gAlertDialog, cancel);
    /* the cancel listener fires inside that call: alertFinish has thrown the
     * unwind — leave it pending, Looper.loop() carries it out */
}

int ux_and_alert(int icon, const char *lines, const char *buttons, int defBtn) {
    JNIEnv *env = envNow();
    /* split "a|b|c" (worst case 8 each, in place on copies) */
    char lbuf[512], bbuf[256];
    snprintf(lbuf, sizeof lbuf, "%s", lines);
    snprintf(bbuf, sizeof bbuf, "%s", buttons);
    char *ls[8]; int nl = 0;
    for (char *t = strtok(lbuf, "|"); t && nl < 8; t = strtok(NULL, "|")) ls[nl++] = t;
    char *bs[8]; int nb = 0;
    for (char *t = strtok(bbuf, "|"); t && nb < 8; t = strtok(NULL, "|")) bs[nb++] = t;
    if (!nb) return 1;
    /* the message body: the lines past the first, newline-joined */
    char body[512]; body[0] = 0;
    for (int i = 1; i < nl; i++) {
        if (i > 1) strlcat(body, "\n", sizeof body);
        strlcat(body, ls[i], sizeof body);
    }

    jclass bldCls = (*env)->FindClass(env, "android/app/AlertDialog$Builder");
    jmethodID bInit = (*env)->GetMethodID(env, bldCls, "<init>", "(Landroid/content/Context;)V");
    jmethodID bTitle = (*env)->GetMethodID(env, bldCls, "setTitle",
        "(Ljava/lang/CharSequence;)Landroid/app/AlertDialog$Builder;");
    jmethodID bMsg = (*env)->GetMethodID(env, bldCls, "setMessage",
        "(Ljava/lang/CharSequence;)Landroid/app/AlertDialog$Builder;");
    jmethodID bPos = (*env)->GetMethodID(env, bldCls, "setPositiveButton",
        "(Ljava/lang/CharSequence;Landroid/content/DialogInterface$OnClickListener;)Landroid/app/AlertDialog$Builder;");
    jmethodID bNeg = (*env)->GetMethodID(env, bldCls, "setNegativeButton",
        "(Ljava/lang/CharSequence;Landroid/content/DialogInterface$OnClickListener;)Landroid/app/AlertDialog$Builder;");
    jmethodID bNeu = (*env)->GetMethodID(env, bldCls, "setNeutralButton",
        "(Ljava/lang/CharSequence;Landroid/content/DialogInterface$OnClickListener;)Landroid/app/AlertDialog$Builder;");
    jmethodID bCan = (*env)->GetMethodID(env, bldCls, "setOnCancelListener",
        "(Landroid/content/DialogInterface$OnCancelListener;)Landroid/app/AlertDialog$Builder;");
    jmethodID bCreate = (*env)->GetMethodID(env, bldCls, "create", "()Landroid/app/AlertDialog;");

    jobject bld = (*env)->NewObject(env, bldCls, bInit, gActivity);
    jobject br  = (*env)->NewObject(env, gBridgeCls, gBridgeInit, UXA_ALERT_ID);
    jstring jt  = (*env)->NewStringUTF(env, nl ? ls[0] : "");
    (*env)->CallObjectMethod(env, bld, bTitle, jt);
    if (body[0]) {
        jstring jm = (*env)->NewStringUTF(env, body);
        (*env)->CallObjectMethod(env, bld, bMsg, jm);
        (*env)->DeleteLocalRef(env, jm);
    }
    /* the mapping: positive = button 1; at 3, neutral = 2; negative = last
     * (the cancel role — Android's own convention) */
    gAlertCancelIdx = nb;
    jstring jb0 = (*env)->NewStringUTF(env, bs[0]);
    (*env)->CallObjectMethod(env, bld, bPos, jb0, br);
    (*env)->DeleteLocalRef(env, jb0);
    if (nb == 2) {
        jstring jb1 = (*env)->NewStringUTF(env, bs[1]);
        (*env)->CallObjectMethod(env, bld, bNeg, jb1, br);
        (*env)->DeleteLocalRef(env, jb1);
    } else if (nb >= 3) {
        jstring jb1 = (*env)->NewStringUTF(env, bs[1]);
        jstring jb2 = (*env)->NewStringUTF(env, bs[2]);
        (*env)->CallObjectMethod(env, bld, bNeu, jb1, br);
        (*env)->CallObjectMethod(env, bld, bNeg, jb2, br);
        (*env)->DeleteLocalRef(env, jb1);
        (*env)->DeleteLocalRef(env, jb2);
    }
    (*env)->CallObjectMethod(env, bld, bCan, br);
    jobject dlg = (*env)->CallObjectMethod(env, bld, bCreate);
    gAlertDialog = (*env)->NewGlobalRef(env, dlg);
    jclass dc = (*env)->GetObjectClass(env, dlg);
    jmethodID show = (*env)->GetMethodID(env, dc, "show", "()V");
    gAlertResult = nb; gAlertDone = 0;
    (*env)->CallVoidMethod(env, gAlertDialog, show);
    if (gAlertAutoMs > 0) {
        postRunDelayed(env, 0x40000 | (gAlertAutoShot ? 1 : 0), gAlertAutoMs);
        gAlertAutoMs = 0; gAlertAutoShot = 0;
    }
    /* nest the platform's own loop until a listener unwinds it */
    jclass looperCls = (*env)->FindClass(env, "android/os/Looper");
    jmethodID loop = (*env)->GetStaticMethodID(env, looperCls, "loop", "()V");
    gAlertNesting = 1;
    while (!gAlertDone) {
        (*env)->CallStaticVoidMethod(env, looperCls, loop);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);   /* the unwind marker */
    }
    gAlertNesting = 0;
    (*env)->DeleteGlobalRef(env, gAlertDialog); gAlertDialog = NULL;
    (*env)->DeleteLocalRef(env, dlg);
    (*env)->DeleteLocalRef(env, bld);
    (*env)->DeleteLocalRef(env, br);
    (*env)->DeleteLocalRef(env, jt);
    return gAlertResult;
}

/* ── the shell ──────────────────────────────────────────────────────────── */
/* runLoop(): post the app's start (UXRun id 0) to the UI thread, then park —
 * the platform owns the loop; xt_main's thread never comes back, by design. */
void ux_and_shell_run(void) {
    JNIEnv *env = envNow();
    postRun(env, 0);
    for (;;) pause();
}
void ux_and_quit(int rc) {
    LOG("quit rc=%d", rc);
    fflush(NULL);
    usleep(200000);                       /* let the glue's log pump drain */
    _exit(rc);
}

/* ── onCreate: ours by lib_name; delegates to the app lib's (the glue) ──── */
typedef void (*onCreate_fn)(ANativeActivity *, void *, size_t);

JNIEXPORT void ANativeActivity_onCreate(ANativeActivity *activity,
                                        void *saved, size_t savedSize) {
    JNIEnv *env = activity->env;
    gVm = activity->vm;
    gActivity = (*env)->NewGlobalRef(env, activity->clazz);

    /* the bridge dex, via the APP loader (the spike's finding #2) */
    jclass actC = (*env)->GetObjectClass(env, gActivity);
    jmethodID getCl = (*env)->GetMethodID(env, actC, "getClassLoader",
                                          "()Ljava/lang/ClassLoader;");
    jobject loader = (*env)->CallObjectMethod(env, gActivity, getCl);
    jclass clCls = (*env)->GetObjectClass(env, loader);
    jmethodID loadClass = (*env)->GetMethodID(env, clCls, "loadClass",
                                              "(Ljava/lang/String;)Ljava/lang/Class;");
    #define LOADC(var, name) \
        var = (jclass)(*env)->NewGlobalRef(env, (*env)->CallObjectMethod(env, loader, \
                  loadClass, (*env)->NewStringUTF(env, name))); \
        if (!check(env, "loadClass " name) || !var) { LOG("FAIL: no %s", name); return; }
    LOADC(gBridgeCls, "UXBridge")
    LOADC(gRunCls, "UXRun")
    LOADC(gDrawCls, "UXDrawView")

    static const JNINativeMethod nb[] = {
        { "nativeFire", "(I)V", (void *)n_fire },
        { "nativeValue", "(II)V", (void *)n_value },
        { "nativeText", "(ILjava/lang/String;)V", (void *)n_text },
    };
    static const JNINativeMethod nr[] = { { "nativeRun", "(I)V", (void *)n_run } };
    static const JNINativeMethod nd[] = { { "nativeDraw", "(ILandroid/graphics/Canvas;II)V", (void *)n_draw } };
    (*env)->RegisterNatives(env, gBridgeCls, nb, 3);
    (*env)->RegisterNatives(env, gRunCls, nr, 1);
    (*env)->RegisterNatives(env, gDrawCls, nd, 1);
    gRunInit = (*env)->GetMethodID(env, gRunCls, "<init>", "(I)V");
    if (!check(env, "RegisterNatives")) return;

    /* a Handler on the main looper, for runLoop()'s post */
    jclass looperCls = (*env)->FindClass(env, "android/os/Looper");
    jmethodID getMain = (*env)->GetStaticMethodID(env, looperCls, "getMainLooper",
                                                  "()Landroid/os/Looper;");
    jobject mainLooper = (*env)->CallStaticObjectMethod(env, looperCls, getMain);
    jclass handlerCls = (*env)->FindClass(env, "android/os/Handler");
    jmethodID hInit = (*env)->GetMethodID(env, handlerCls, "<init>", "(Landroid/os/Looper;)V");
    jobject h = (*env)->NewObject(env, handlerCls, hInit, mainLooper);
    gHandler = (*env)->NewGlobalRef(env, h);
    gPost = (*env)->GetMethodID(env, handlerCls, "post", "(Ljava/lang/Runnable;)Z");
    gPostDelayed = (*env)->GetMethodID(env, handlerCls, "postDelayed", "(Ljava/lang/Runnable;J)Z");
    if (!check(env, "Handler")) return;

    /* promote this lib to the global group so the app lib's undefined
     * ux_and_* imports can bind against it, then load + delegate */
    if (!dlopen("libUXAndroid.so", RTLD_NOW | RTLD_GLOBAL))
        LOG("self-promote failed: %s", dlerror());
    void *app = dlopen("libxtapp.so", RTLD_NOW);
    if (!app) { LOG("FAIL: dlopen libxtapp.so: %s", dlerror()); return; }
    onCreate_fn glue = (onCreate_fn)dlsym(app, "ANativeActivity_onCreate");
    if (!glue) { LOG("FAIL: no glue onCreate in libxtapp.so"); return; }
    LOG("uxkit: shell up; delegating to the app lib's glue");
    glue(activity, saved, savedSize);     /* the glue spawns xt_main, pipes logcat */
}
