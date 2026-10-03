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
#include <android/api-level.h>
#include <stdint.h>
#include <stdlib.h>
#include <android/native_activity.h>
#include <dlfcn.h>
#include <unistd.h>
#include <string.h>
#include <time.h>
#include <stdio.h>
#include "ux_posix_fs.h" // listDir / delete / rename / copy for the drawn file panel

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
static ux_fire_fn     gFieldSubmit;       /* the same field's Return (onEditorAction) */

static jclass gBridgeCls, gRunCls, gDrawCls;          /* global refs, dex classes  */
static jclass gBtnCls, gLabelCls, gFrameCls, gViewCls, gCanvasCls, gPaintCls,
    gBitmapCls, gPathCls, gDashCls,
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
    gPaintSetStrokeWidth, gPaintSetStrokeCap, gPaintSetStrokeJoin, gPaintSetTypeface, gPaintMeasure,
    gPaintSetPathEffect, gDashInit, gPaintMetricsInt,
    gTypefaceCreate,
    gPathInit, gPathMoveTo, gPathLineTo, gPathCubicTo, gPathClose,
    gBmpCreate, gBmpGetPixel;
static jobject gPaint;                    /* the one Paint, global ref */
static jobject gStyleFill, gStyleStroke;  /* Paint.Style values, global refs */
static jobject gCapButt, gCapRound, gCapSquare;   /* Paint.Cap values */
static jobject gJoinMiter, gJoinRound, gJoinBevel; /* Paint.Join values */
static jobject gDuffClear;                         /* PorterDuff.Mode.CLEAR */
static jclass gTypefaceCls;                        /* android.graphics.Typeface */
static jclass gMetricsIntCls;                      /* android.graphics.Paint$FontMetricsInt */
static jfieldID gMetricsAscent;                    /* ...its `ascent` field */

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
static jclass gTableCls;                     /* UXTable (the bridge dex): the native table */
static jclass gMenuCls;                      /* UXMenuButton: the app's menus from an overflow button */
static jclass gPickerCls;                    /* UXBridge$Picker: the system document picker */
static char gPicked[1024];                   /* the picked document's path, "" if cancelled */
static int gPickDone, gPickNesting;
static jobject gMenuBtn;                     /* global ref, made with the first window */
typedef void (*menu_pick_fn)(int, int);
static menu_pick_fn gMenuPick;
static void *gTblPeer[UXA_MAXW][64];         /* the peer UXTableView, by the table's id */
typedef int (*tbl_rows_fn)(void *);
typedef const char *(*tbl_cell_fn)(void *, int, int);
typedef int (*tbl_cols_fn)(void *);
typedef const char *(*tbl_title_fn)(void *, int);
typedef int (*tbl_width_fn)(void *, int);
typedef int (*tbl_multi_fn)(void *);
typedef void (*tbl_selset_fn)(void *, int *, int);
typedef int (*tbl_rowint_fn)(void *, int);
typedef void (*tbl_toggle_fn)(void *, int);
static tbl_rowint_fn gTblLevel, gTblDisclosure;
static tbl_toggle_fn gTblToggle;
static tbl_rows_fn gTblRows;
static tbl_cell_fn gTblCell;
static tbl_cols_fn gTblCols;
static tbl_title_fn gTblTitle;
static tbl_width_fn gTblWidth;
static tbl_multi_fn gTblMulti;
static tbl_selset_fn gTblSelSet;

void ux_and_set_entry(void *fn)         { gEntry = (ux_entry_fn)fn; }
void ux_and_set_control_fire(void *fn)  { gFire = (ux_fire_fn)fn; }
void ux_and_set_value_changed(void *fn) { gValueChanged = (ux_value_fn)fn; }
void ux_and_set_field_hooks(void *fn)   { gFieldChanged = (ux_fire_fn)fn; }
void ux_and_set_field_submit_hooks(void *fn) { gFieldSubmit = (ux_fire_fn)fn; }

/* ── the natives the dex classes funnel into ────────────────────────────── */
static void alertFinish(JNIEnv *env, int neutralIdx);   /* the modal alert, below */
static void alertAuto(JNIEnv *env, int shot);
#define UXA_ALERT_ID 0x7F7F
static int gAlertCancelIdx;
static void navUserBack(JNIEnv *env, int navId);       /* the navigation bar, below */
#define UXA_NAV_ID_BASE 0x7E000                          /* a toolbar's Up: base + navId */
static void n_fire(JNIEnv *env, jclass c, jint id) {
    (void)c;
    if (id == UXA_ALERT_ID) { alertFinish(env, gAlertCancelIdx); return; }   /* dialog cancelled */
    if (id >= UXA_NAV_ID_BASE && id < UXA_NAV_ID_BASE + 0x1000) { navUserBack(env, id - UXA_NAV_ID_BASE); return; }
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
static void n_submit(JNIEnv *env, jclass c, jint id) {
    (void)env; (void)c;
    if (gFieldSubmit) gFieldSubmit(id >> 8, id & 0xFF);
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
/* the frame clock (everyTurn): a self-reposting Handler message on the UI
 * thread.  n_run re-arms it after each call; clearing the hook stops it. */
static void (*gTurnFn)(void);
static void (*gLater[16])(void);          /* tests: steps run later through the real loop */
static int gTurnMs;
static int gTurnArmed;
static void uxTurnArm(void);
static void n_run(JNIEnv *env, jclass c, jint id) {
    (void)env; (void)c;
    if (id == 0) { if (gEntry) gEntry(); return; }         /* id 0 = the app's start */
    if (id == 0x80000) {                                   /* the app's frame clock */
        if (gTurnFn) { void (*f)(void) = gTurnFn; f(); uxTurnArm(); }
        return;
    }
    if (id & 0x100000) { void (*f)(void) = gLater[id & 0xF]; if (f) f(); return; } /* a test's step */
    if (id & 0x10000) { ux_and_test_click((id >> 8) & 0xFF, id & 0xFF); return; }
    if (id & 0x40000) { alertAuto(env, id & 1); return; }  /* the alert rig's auto-cancel */
    if (id & 0x20000) {                                    /* the loop gate's watchdog */
        LOG("watchdog fired");
        fflush(NULL); usleep(200000);
        _exit(id & 0xFF);
    }
}
static jobject gDrawCanvas;               /* the Canvas of the draw in flight */
static jmethodID gCanvasScale, gCanvasSave, gCanvasRestore, gCanvasClipRect, gCanvasDrawColor;
static int gInsetsKnown;                  /* shared with queryInsets below */
static void queryInsets(JNIEnv *env);
static void applyInsets(JNIEnv *env);
/* the native table's data, from the peer UXTableView (UXTable's natives) */
static void *tblPeer(jint id) {
    int h = id >> 8, n = id & 0xFF;
    return (h > 0 && h < UXA_MAXW && n >= 0 && n < 64) ? gTblPeer[h][n] : NULL;
}
static jint n_tbl_rows(JNIEnv *env, jclass c, jint id) {
    (void)env; (void)c;
    void *p = tblPeer(id);
    return p && gTblRows ? gTblRows(p) : 0;
}
static jstring n_tbl_cell(JNIEnv *env, jclass c, jint id, jint r, jint col) {
    (void)c;
    void *p = tblPeer(id);
    const char *t = p && gTblCell ? gTblCell(p, r, col) : "";
    return (*env)->NewStringUTF(env, t ? t : "");
}
static jint n_tbl_cols(JNIEnv *env, jclass c, jint id) {
    (void)env; (void)c;
    void *p = tblPeer(id);
    return p && gTblCols ? gTblCols(p) : 0;
}
static jstring n_tbl_title(JNIEnv *env, jclass c, jint id, jint col) {
    (void)c;
    void *p = tblPeer(id);
    const char *t = p && gTblTitle ? gTblTitle(p, col) : "";
    return (*env)->NewStringUTF(env, t ? t : "");
}
static jint n_tbl_width(JNIEnv *env, jclass c, jint id, jint col) {
    (void)env; (void)c;
    void *p = tblPeer(id);
    return p && gTblWidth ? gTblWidth(p, col) : 80;
}
static jint n_tbl_level(JNIEnv *env, jclass c, jint id, jint r) {
    (void)env; (void)c;
    void *p = tblPeer(id);
    return p && gTblLevel ? gTblLevel(p, r) : 0;
}
static jint n_tbl_disclosure(JNIEnv *env, jclass c, jint id, jint r) {
    (void)env; (void)c;
    void *p = tblPeer(id);
    return p && gTblDisclosure ? gTblDisclosure(p, r) : 0;
}
static void n_tbl_toggle(JNIEnv *env, jclass c, jint id, jint r) {
    (void)env; (void)c;
    void *p = tblPeer(id);
    if (p && gTblToggle) gTblToggle(p, r);
}
static void n_tbl_select(JNIEnv *env, jclass c, jint id, jintArray rows) {
    (void)c;
    void *p = tblPeer(id);
    if (!p || !gTblSelSet) return;
    jsize n = (*env)->GetArrayLength(env, rows);
    jint *e = (*env)->GetIntArrayElements(env, rows, NULL);
    int buf[256];
    int k = n < 256 ? (int)n : 256;
    for (int i = 0; i < k; i++) buf[i] = e[i];
    (*env)->ReleaseIntArrayElements(env, rows, e, JNI_ABORT);
    gTblSelSet(p, buf, k);
}
/* the picker's answer: the copied document's path (null if cancelled), then unwind the nested loop */
static void n_picked(JNIEnv *env, jclass c, jstring path) {
    (void)c;
    gPicked[0] = 0;
    if (path) {
        const char *u = (*env)->GetStringUTFChars(env, path, NULL);
        snprintf(gPicked, sizeof gPicked, "%s", u);
        (*env)->ReleaseStringUTFChars(env, path, u);
    }
    gPickDone = 1;
    if (gPickNesting) (*env)->ThrowNew(env, (*env)->FindClass(env, "java/lang/RuntimeException"), "ux-pick-unwind");
}
static void n_menu_pick(JNIEnv *env, jclass c, jint t, jint j) {
    (void)env; (void)c;
    if (gMenuPick) gMenuPick(t, j);
}
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

/* Touches on the drawn content -> UXKit's mouse events (UXTouch.xc): phase 0 down, 1 move, 2 up,
 * 3 cancelled, in neutral units (dp).  MotionEvent actions: 0 DOWN, 1 UP, 2 MOVE, 3 CANCEL. */
typedef void (*ux_touch_fn)(void *, int, int, int);
static ux_touch_fn gTouch;
void ux_and_set_touch(void *fn) { gTouch = (ux_touch_fn)fn; }
static void n_touch(JNIEnv *env, jclass c, jint id, jint action, jfloat x, jfloat y) {
    (void)env; (void)c;
    int handle = id >> 8;
    if (handle < 0 || handle >= UXA_MAXW || !gTouch || !gContentUd[handle]) return;
    int phase = action == 0 ? 0 : action == 2 ? 1 : action == 1 ? 2 : action == 3 ? 3 : -1;
    if (phase < 0) return;
    gTouch(gContentUd[handle], phase, (int)(x / gDensity + 0.5f), (int)(y / gDensity + 0.5f)); /* nearest dp */
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
void ux_and_test_call_later(void *fn, int ms) {
    static int slot;
    slot = (slot + 1) & 0xF;
    gLater[slot] = (void (*)(void))fn;
    postRunDelayed(envNow(), 0x100000 | slot, ms);
}
/* Tests: is a native button with this title on screen (attached and shown, ancestors included)? */
int ux_and_test_control_visible(int handle, const char *title) {
    JNIEnv *env = envNow();
    for (int n = 0; n < 256; n++) {
        jobject c = gCtl[handle][n];
        if (!c || !(*env)->IsInstanceOf(env, c, gBtnCls)) continue;
        jclass tvC = (*env)->FindClass(env, "android/widget/TextView");
        jmethodID getText = (*env)->GetMethodID(env, tvC, "getText", "()Ljava/lang/CharSequence;");
        jobject cs = (*env)->CallObjectMethod(env, c, getText);
        jclass oC = (*env)->FindClass(env, "java/lang/Object");
        jmethodID toS = (*env)->GetMethodID(env, oC, "toString", "()Ljava/lang/String;");
        jstring js = (jstring)(*env)->CallObjectMethod(env, cs, toS);
        const char *got = (*env)->GetStringUTFChars(env, js, NULL);
        int same = strcmp(got, title) == 0;
        (*env)->ReleaseStringUTFChars(env, js, got);
        if (!same) continue;
        jclass vC = (*env)->FindClass(env, "android/view/View");
        jmethodID shown = (*env)->GetMethodID(env, vC, "isShown", "()Z");
        return (*env)->CallBooleanMethod(env, c, shown) ? 1 : 0;
    }
    return 0;
}
/* Tests: a touch on window `handle` through ANDROID'S OWN dispatch -- a MotionEvent handed to the
 * window's FrameLayout, which offers it to the native widgets on top first and the UXDrawView last,
 * exactly as a finger would.  phase 0 down, 1 move, 2 up; x/y in the window's neutral units. */
static long gTouchDown;
void ux_and_test_touch(int handle, int phase, int x, int y) {
    JNIEnv *env = envNow();
    jclass meC = (*env)->FindClass(env, "android/view/MotionEvent");
    jmethodID obtain = (*env)->GetStaticMethodID(env, meC, "obtain", "(JJIFFI)Landroid/view/MotionEvent;");
    jclass sc = (*env)->FindClass(env, "android/os/SystemClock");
    jlong now = (*env)->CallStaticLongMethod(env, sc, (*env)->GetStaticMethodID(env, sc, "uptimeMillis", "()J"));
    if (phase == 0) gTouchDown = (long)now;
    int action = phase == 0 ? 0 : phase == 1 ? 2 : 1;
    jobject ev = (*env)->CallStaticObjectMethod(env, meC, obtain, (jlong)gTouchDown, now, action,
                                                (jfloat)PX(x), (jfloat)PX(y), 0);
    jclass vC = (*env)->FindClass(env, "android/view/View");
    (*env)->CallBooleanMethod(env, gWinV[handle], (*env)->GetMethodID(env, vC, "dispatchTouchEvent", "(Landroid/view/MotionEvent;)Z"), ev);
    (*env)->CallVoidMethod(env, ev, (*env)->GetMethodID(env, meC, "recycle", "()V"));
    check(env, "test touch");
}
/* Tests: does the native field at (handle, node) mask its text (a password transformation)? */
int ux_and_test_field_masked(int handle, int node) {
    JNIEnv *env = envNow();
    jobject ed = gCtl[handle][node];
    if (!ed) return -1;
    jclass tvC = (*env)->FindClass(env, "android/widget/TextView");
    jobject tm = (*env)->CallObjectMethod(env, ed, (*env)->GetMethodID(env, tvC, "getTransformationMethod", "()Landroid/text/method/TransformationMethod;"));
    jclass pwC = (*env)->FindClass(env, "android/text/method/PasswordTransformationMethod");
    int masked = tm && (*env)->IsInstanceOf(env, tm, pwC);
    check(env, "field masked");
    return masked;
}
void ux_and_test_watchdog(int ms, int rc) {
    postRunDelayed(envNow(), 0x20000 | (rc & 0xFF), ms);
}
static void uxTurnArm(void) {
    if (!gTurnFn) { gTurnArmed = 0; return; }
    postRunDelayed(envNow(), 0x80000, gTurnMs > 0 ? gTurnMs : 16);
}
/* Install (or clear) the app's frame clock.  Android's loop belongs to the
 * platform, so the driver answers setTurnHook with true and arms this Handler
 * instead: fn runs on the UI thread, outside any draw, once per post. */
void ux_and_set_turn_hook(void *fn, int ms) {
    gTurnFn = (void (*)(void))fn;
    gTurnMs = ms;
    if (gTurnFn) { if (!gTurnArmed) { gTurnArmed = 1; uxTurnArm(); } }
    else { gTurnArmed = 0; }
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
static int apiLevel(void);
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
    if (!ins && apiLevel() >= 30) {
        /* not attached yet: the window manager knows the insets anyway (API 30+) */
        check(env, "insets");
        jmethodID getWm = (*env)->GetMethodID(env, actC, "getWindowManager", "()Landroid/view/WindowManager;");
        jobject wm = (*env)->CallObjectMethod(env, gActivity, getWm);
        jclass wmC = (*env)->FindClass(env, "android/view/WindowManager");
        jobject wmx = (*env)->CallObjectMethod(env, wm, (*env)->GetMethodID(env, wmC, "getCurrentWindowMetrics",
                                               "()Landroid/view/WindowMetrics;"));
        jclass wmxC = (*env)->FindClass(env, "android/view/WindowMetrics");
        ins = wmx ? (*env)->CallObjectMethod(env, wmx, (*env)->GetMethodID(env, wmxC, "getWindowInsets",
                                             "()Landroid/view/WindowInsets;")) : NULL;
        check(env, "window metrics insets");
    }
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
    gDashCls   = gref(env, "android/graphics/DashPathEffect");
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
    gPaintSetStrokeJoin  = (*env)->GetMethodID(env, gPaintCls, "setStrokeJoin",
                                               "(Landroid/graphics/Paint$Join;)V");
    /* setTypeface returns the PREVIOUS typeface, not void. */
    gPaintSetTypeface    = (*env)->GetMethodID(env, gPaintCls, "setTypeface",
                                               "(Landroid/graphics/Typeface;)Landroid/graphics/Typeface;");
    jclass tfCls = gref(env, "android/graphics/Typeface");
    gTypefaceCls  = tfCls;
    gTypefaceCreate = tfCls ? (*env)->GetStaticMethodID(env, tfCls, "create",
                                              "(Ljava/lang/String;I)Landroid/graphics/Typeface;") : 0;
    gPaintMeasure = (*env)->GetMethodID(env, gPaintCls, "measureText", "(Ljava/lang/String;)F");
    /* FontMetricsInt: the FACE's ascent (above the baseline, reported negative), which is the
       distance from the top of a line to its baseline. */
    gPaintMetricsInt = (*env)->GetMethodID(env, gPaintCls, "getFontMetricsInt",
                                           "()Landroid/graphics/Paint$FontMetricsInt;");
    gMetricsIntCls = gref(env, "android/graphics/Paint$FontMetricsInt");
    gMetricsAscent = gMetricsIntCls
        ? (*env)->GetFieldID(env, gMetricsIntCls, "ascent", "I") : 0;
    /* Canvas has no clearRect.  gCanvasSave/gCanvasClipRect/gCanvasRestore already exist for the
       offscreen rig, so a clear is save, clip to the rect, drawColor(0, Mode.CLEAR), restore.
       Only the drawColor id and the PorterDuff Mode are new. */
    gCanvasDrawColor   = (*env)->GetMethodID(env, gCanvasCls, "drawColor",
                                             "(ILandroid/graphics/PorterDuff$Mode;)V");
    gPathInit    = (*env)->GetMethodID(env, gPathCls, "<init>", "()V");
    gPathMoveTo  = (*env)->GetMethodID(env, gPathCls, "moveTo", "(FF)V");
    gPathLineTo  = (*env)->GetMethodID(env, gPathCls, "lineTo", "(FF)V");
    gPathCubicTo = (*env)->GetMethodID(env, gPathCls, "cubicTo", "(FFFFFF)V");
    gPathClose   = (*env)->GetMethodID(env, gPathCls, "close", "()V");
    /* The dash: DashPathEffect(float[] intervals, float phase) set on the Paint.  setPathEffect
       returns the PREVIOUS effect, the way setTypeface returns the previous face. */
    gDashInit = gDashCls
              ? (*env)->GetMethodID(env, gDashCls, "<init>", "([FF)V") : 0;
    gPaintSetPathEffect = (*env)->GetMethodID(env, gPaintCls, "setPathEffect",
                                              "(Landroid/graphics/PathEffect;)Landroid/graphics/PathEffect;");
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
    gJoinMiter   = enumVal(env, "android/graphics/Paint$Join", "MITER");
    gJoinRound   = enumVal(env, "android/graphics/Paint$Join", "ROUND");
    gJoinBevel   = enumVal(env, "android/graphics/Paint$Join", "BEVEL");
    gDuffClear   = enumVal(env, "android/graphics/PorterDuff$Mode", "CLEAR");
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

int ux_and_orientation(void) {
    return gScreenW > gScreenH ? 2 /* UX_ORIENT_LANDSCAPE */ : 1 /* UX_ORIENT_PORTRAIT */;
}

/* ── native navigation: a Toolbar, and the system Back (UXNB v2 §5) ─────────
 * UXNavigationController hands its pushes and pops here.  Android's own vocabulary for them is the
 * top app bar -- an android.widget.Toolbar with the form's title and, when there is somewhere to go
 * back to, the theme's Up arrow -- and the system Back (button or gesture).  Both Up and Back pop;
 * that pop is the USER's and is reported to the neutral side through gNavPopped, never as an app
 * event.  Back is caught with an OnBackInvokedCallback (UXBack, API 33+) registered only while the
 * stack is deeper than one, so Back at the root still leaves the app.  (API 26-32 is a gap: Back
 * there leaves the app at any depth.)  The toolbar sits over the nav's bar strip; the forms below
 * are UXKit's own drawing, as everywhere else on this backend. */
#define UXA_NAV_MAX 16
#define UXA_NAV_DEPTH 32
typedef void (*ux_nav_popped_fn)(int);
static ux_nav_popped_fn gNavPopped;
void ux_and_set_nav_popped(void *fn) { gNavPopped = (ux_nav_popped_fn)fn; }
static struct {
    int used, handle, navId, depth;
    jobject toolbar, back;          /* global refs; back = the UXBack, while registered */
    char *titles[UXA_NAV_DEPTH];
} gNav[UXA_NAV_MAX];
static jclass gBackCls;
static void n_back(JNIEnv *env, jclass c, jint id) { (void)c; navUserBack(env, id); }
static jclass loadAppClass(JNIEnv *env, const char *name);
static int apiLevel(void) { return android_get_device_api_level(); }

/* Title, Up arrow and the Back registration, from the depth. */
static void navSync(JNIEnv *env, int i) {
    jclass tbC = (*env)->GetObjectClass(env, gNav[i].toolbar);
    jmethodID setTitle = (*env)->GetMethodID(env, tbC, "setTitle", "(Ljava/lang/CharSequence;)V");
    const char *t = gNav[i].depth > 0 ? gNav[i].titles[gNav[i].depth - 1] : "";
    (*env)->CallVoidMethod(env, gNav[i].toolbar, setTitle, (*env)->NewStringUTF(env, t));
    jmethodID setIcon = (*env)->GetMethodID(env, tbC, "setNavigationIcon", "(Landroid/graphics/drawable/Drawable;)V");
    jobject icon = NULL;
    if (gNav[i].depth > 1) {
        /* the theme's own Up arrow: ?android:attr/homeAsUpIndicator */
        jclass ctxC = (*env)->GetObjectClass(env, gActivity);
        jmethodID getTheme = (*env)->GetMethodID(env, ctxC, "getTheme", "()Landroid/content/res/Resources$Theme;");
        jobject theme = (*env)->CallObjectMethod(env, gActivity, getTheme);
        jclass thC = (*env)->GetObjectClass(env, theme);
        jmethodID osa = (*env)->GetMethodID(env, thC, "obtainStyledAttributes", "([I)Landroid/content/res/TypedArray;");
        jintArray attrs = (*env)->NewIntArray(env, 1);
        jint up = 0x0101030b; /* android.R.attr.homeAsUpIndicator */
        (*env)->SetIntArrayRegion(env, attrs, 0, 1, &up);
        jobject ta = (*env)->CallObjectMethod(env, theme, osa, attrs);
        jclass taC = (*env)->GetObjectClass(env, ta);
        jmethodID getD = (*env)->GetMethodID(env, taC, "getDrawable", "(I)Landroid/graphics/drawable/Drawable;");
        icon = (*env)->CallObjectMethod(env, ta, getD, 0);
        jmethodID recycle = (*env)->GetMethodID(env, taC, "recycle", "()V");
        (*env)->CallVoidMethod(env, ta, recycle);
    }
    if (icon) {
        /* the theme's arrow is drawn for ITS bar (white on the dark default); this bar is UXKit's
         * light one, so tint it to the title's colour */
        jclass dC = (*env)->FindClass(env, "android/graphics/drawable/Drawable");
        jmethodID mut = (*env)->GetMethodID(env, dC, "mutate", "()Landroid/graphics/drawable/Drawable;");
        icon = (*env)->CallObjectMethod(env, icon, mut);
        (*env)->CallVoidMethod(env, icon, (*env)->GetMethodID(env, dC, "setTint", "(I)V"), (jint)0xFF1C1B1F);
    }
    (*env)->CallVoidMethod(env, gNav[i].toolbar, setIcon, icon);
    if (gNav[i].depth > 1) {
        jmethodID setNavClick = (*env)->GetMethodID(env, tbC, "setNavigationOnClickListener", "(Landroid/view/View$OnClickListener;)V");
        jobject br = (*env)->NewObject(env, gBridgeCls, gBridgeInit, UXA_NAV_ID_BASE + gNav[i].navId);
        (*env)->CallVoidMethod(env, gNav[i].toolbar, setNavClick, br);
    }
    /* Back: registered while there is something to pop */
    if (apiLevel() >= 33 && gBackCls) {
        jclass actC = (*env)->GetObjectClass(env, gActivity);
        jmethodID getD = (*env)->GetMethodID(env, actC, "getOnBackInvokedDispatcher", "()Landroid/window/OnBackInvokedDispatcher;");
        jobject disp = (*env)->CallObjectMethod(env, gActivity, getD);
        jclass dC = (*env)->FindClass(env, "android/window/OnBackInvokedDispatcher");
        if (gNav[i].depth > 1 && !gNav[i].back) {
            jmethodID init = (*env)->GetMethodID(env, gBackCls, "<init>", "(I)V");
            jobject cb = (*env)->NewObject(env, gBackCls, init, gNav[i].navId);
            jmethodID reg = (*env)->GetMethodID(env, dC, "registerOnBackInvokedCallback", "(ILandroid/window/OnBackInvokedCallback;)V");
            (*env)->CallVoidMethod(env, disp, reg, 0 /* PRIORITY_DEFAULT */, cb);
            gNav[i].back = (*env)->NewGlobalRef(env, cb);
        } else if (gNav[i].depth <= 1 && gNav[i].back) {
            jmethodID unreg = (*env)->GetMethodID(env, dC, "unregisterOnBackInvokedCallback", "(Landroid/window/OnBackInvokedCallback;)V");
            (*env)->CallVoidMethod(env, disp, unreg, gNav[i].back);
            (*env)->DeleteGlobalRef(env, gNav[i].back);
            gNav[i].back = NULL;
        }
    }
    check(env, "nav sync");
}
static int navIndex(void *token) {
    int i = (int)(intptr_t)token - 1;
    return (i >= 0 && i < UXA_NAV_MAX && gNav[i].used) ? i : -1;
}
void *ux_and_nav_attach(int win, int navId, int x, int y, int w, int h) {
    if (win <= 0 || win >= UXA_MAXW || !gWinV[win]) return NULL;
    JNIEnv *env = envNow();
    int i = 0;
    while (i < UXA_NAV_MAX && gNav[i].used) i++;
    if (i == UXA_NAV_MAX) return NULL;
    if (!gBackCls && apiLevel() >= 33) {
        gBackCls = loadAppClass(env, "UXBack");
        if (gBackCls) {
            static const JNINativeMethod nbk[] = { { "nativeBack", "(I)V", (void *)n_back } };
            (*env)->RegisterNatives(env, gBackCls, nbk, 1);
            check(env, "UXBack natives");
        }
    }
    jclass tbC = (*env)->FindClass(env, "android/widget/Toolbar");
    jmethodID init = (*env)->GetMethodID(env, tbC, "<init>", "(Landroid/content/Context;)V");
    jobject tb = (*env)->NewObject(env, tbC, init, gActivity);
    jmethodID minH = (*env)->GetMethodID(env, tbC, "setMinimumHeight", "(I)V");
    (*env)->CallVoidMethod(env, tb, minH, 0);
    jmethodID ttc = (*env)->GetMethodID(env, tbC, "setTitleTextColor", "(I)V");
    (*env)->CallVoidMethod(env, tb, ttc, (jint)0xFF1C1B1F);
    jmethodID bg = (*env)->GetMethodID(env, tbC, "setBackgroundColor", "(I)V");
    (*env)->CallVoidMethod(env, tb, bg, (jint)0xFFF2F2F2);
    jmethodID elev = (*env)->GetMethodID(env, tbC, "setElevation", "(F)V");
    (*env)->CallVoidMethod(env, tb, elev, (jfloat)PX(4));
    (void)h;
    int bar = 44; /* UXMetrics.navBarHeightFor(a device): the strip the drawn bar would have used */
    (*env)->CallVoidMethod(env, gWinV[win], gAddView, tb, PX(w), PX(bar));
    (*env)->CallVoidMethod(env, tb, gSetTransX, (jfloat)PX(x));
    (*env)->CallVoidMethod(env, tb, gSetTransY, (jfloat)PX(y));
    memset(&gNav[i], 0, sizeof gNav[i]);
    gNav[i].used = 1;
    gNav[i].handle = win;
    gNav[i].navId = navId;
    gNav[i].toolbar = (*env)->NewGlobalRef(env, tb);
    check(env, "nav attach");
    return (void *)(intptr_t)(i + 1);
}
void ux_and_nav_push(void *token, const char *title, int animated) {
    (void)animated;
    int i = navIndex(token);
    if (i < 0 || gNav[i].depth >= UXA_NAV_DEPTH) return;
    gNav[i].titles[gNav[i].depth++] = strdup(title ? title : "");
    navSync(envNow(), i);
}
static void navDrop(int i) {
    if (gNav[i].depth <= 1) return;
    free(gNav[i].titles[--gNav[i].depth]);
    gNav[i].titles[gNav[i].depth] = NULL;
}
void ux_and_nav_pop(void *token, int animated) {
    (void)animated;
    int i = navIndex(token);
    if (i < 0) return;
    navDrop(i);
    navSync(envNow(), i);
}
/* Up or Back: the user's pop.  The bar follows, then the model is told. */
static void navUserBack(JNIEnv *env, int navId) {
    for (int i = 0; i < UXA_NAV_MAX; i++) {
        if (!gNav[i].used || gNav[i].navId != navId || gNav[i].depth <= 1) continue;
        navDrop(i);
        navSync(env, i);
        if (gNavPopped) gNavPopped(navId);
        return;
    }
}
/* Tests: the bar's title and Up arrow, and a press of Back / Up. */
int ux_and_test_nav_title_is(void *token, const char *want) {
    int i = navIndex(token);
    if (i < 0) return 0;
    JNIEnv *env = envNow();
    jclass tbC = (*env)->GetObjectClass(env, gNav[i].toolbar);
    jmethodID getT = (*env)->GetMethodID(env, tbC, "getTitle", "()Ljava/lang/CharSequence;");
    jobject cs = (*env)->CallObjectMethod(env, gNav[i].toolbar, getT);
    jclass csC = (*env)->FindClass(env, "java/lang/Object");
    jmethodID toS = (*env)->GetMethodID(env, csC, "toString", "()Ljava/lang/String;");
    jstring js = cs ? (jstring)(*env)->CallObjectMethod(env, cs, toS) : NULL;
    const char *got = js ? (*env)->GetStringUTFChars(env, js, NULL) : "";
    int same = strcmp(got, want) == 0;
    if (js) (*env)->ReleaseStringUTFChars(env, js, got);
    return same;
}
int ux_and_test_nav_has_up(void *token) {
    int i = navIndex(token);
    if (i < 0) return 0;
    JNIEnv *env = envNow();
    jclass tbC = (*env)->GetObjectClass(env, gNav[i].toolbar);
    jmethodID getI = (*env)->GetMethodID(env, tbC, "getNavigationIcon", "()Landroid/graphics/drawable/Drawable;");
    return (*env)->CallObjectMethod(env, gNav[i].toolbar, getI) != NULL;
}
int ux_and_test_nav_back_registered(void *token) {
    int i = navIndex(token);
    return i >= 0 && gNav[i].back != NULL;
}
void ux_and_test_nav_press_up(void *token) {
    int i = navIndex(token);
    if (i >= 0) navUserBack(envNow(), gNav[i].navId);
}
/* Tests: the system Back, as the platform delivers it -- the registered callback's onBackInvoked. */
void ux_and_test_nav_system_back(void *token) {
    int i = navIndex(token);
    if (i < 0 || !gNav[i].back) return;
    JNIEnv *env = envNow();
    jmethodID ob = (*env)->GetMethodID(env, gBackCls, "onBackInvoked", "()V");
    (*env)->CallVoidMethod(env, gNav[i].back, ob);
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
        /* the theme's action bar: UXKit owns the chrome (a window's title is not an app bar) */
        jclass aC = (*env)->GetObjectClass(env, gActivity);
        jmethodID getAB = (*env)->GetMethodID(env, aC, "getActionBar", "()Landroid/app/ActionBar;");
        jobject ab = (*env)->CallObjectMethod(env, gActivity, getAB);
        if (ab) {
            jclass abC = (*env)->GetObjectClass(env, ab);
            (*env)->CallVoidMethod(env, ab, (*env)->GetMethodID(env, abC, "hide", "()V"));
        }
        check(env, "hide action bar");
        /* UXKit's palette is light, so the status bar's icons must be dark (API 30+) */
        if (apiLevel() >= 30) {
            jmethodID getWin = (*env)->GetMethodID(env, aC, "getWindow", "()Landroid/view/Window;");
            jobject w = (*env)->CallObjectMethod(env, gActivity, getWin);
            jclass wC = (*env)->GetObjectClass(env, w);
            jobject ic = (*env)->CallObjectMethod(env, w, (*env)->GetMethodID(env, wC, "getInsetsController", "()Landroid/view/WindowInsetsController;"));
            if (ic) {
                jclass icC = (*env)->GetObjectClass(env, ic);
                (*env)->CallVoidMethod(env, ic, (*env)->GetMethodID(env, icC, "setSystemBarsAppearance", "(II)V"), 8, 8); /* APPEARANCE_LIGHT_STATUS_BARS */
            }
            check(env, "light status bar");
        }
        gRootAttached = 1;
    }
    int hh = gNextH++;
    jobject win = (*env)->NewObject(env, gFrameCls, gFrameInit, gActivity);
    /* a window is white, as on iOS (and as UXKit's light palette assumes): left transparent, the
     * theme's grey showed through every view that does not fill itself */
    (*env)->CallVoidMethod(env, win, (*env)->GetMethodID(env, gViewCls, "setBackgroundColor", "(I)V"),
                           (jint)0xFFFFFFFF);
    (*env)->CallVoidMethod(env, gRoot, gAddView, win, PX(w), PX(h));
    /* the menu button stays above every window */
    if (gMenuBtn) (*env)->CallVoidMethod(env, gMenuBtn, (*env)->GetMethodID(env, gViewCls, "bringToFront", "()V"));
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
/* The window's content as it is on screen, region (x, y, w, h) in dp, into out as w * h opaque
 * 0xAARRGGBB words: UXBridge.snapshot draws the window's FrameLayout, every view on it, into a bitmap
 * at one pixel a dp. */
int ux_and_window_snapshot(int handle, int x, int y, int w, int h, uint32_t *out) {
    if (handle <= 0 || handle >= UXA_MAXW || !gWinV[handle] || w <= 0 || h <= 0 || !out) return 0;
    JNIEnv *env = envNow();
    jmethodID m = (*env)->GetStaticMethodID(env, gBridgeCls, "snapshot", "(Landroid/view/View;IIIIF)[I");
    if (!check(env, "snapshot method") || !m) return 0;
    jintArray px = (jintArray)(*env)->CallStaticObjectMethod(env, gBridgeCls, m, gWinV[handle], x, y, w, h, (jfloat)gDensity);
    if (!check(env, "snapshot") || !px) return 0;
    (*env)->GetIntArrayRegion(env, px, 0, w * h, (jint *)out);
    (*env)->DeleteLocalRef(env, px);
    for (int i = 0; i < w * h; i++) out[i] |= 0xFF000000u;
    return 1;
}
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
/* ── the app's menus: UXMenuButton, an overflow button at the top right ── */
void ux_and_set_menu_pick(void *fn) { gMenuPick = (menu_pick_fn)fn; }
/* the button rides on the root, above every window, at the top right of the safe area */
static void menuButtonEnsure(JNIEnv *env) {
    if (gMenuBtn || !gRoot) return;
    jobject b = (*env)->NewObject(env, gMenuCls, (*env)->GetMethodID(env, gMenuCls, "<init>",
                                  "(Landroid/content/Context;)V"), gActivity);
    if (!check(env, "menu button") || !b) return;
    jclass flpC = (*env)->FindClass(env, "android/widget/FrameLayout$LayoutParams");
    jobject lp = (*env)->NewObject(env, flpC, (*env)->GetMethodID(env, flpC, "<init>", "(III)V"),
                                   PX(48), PX(48), 0x30 | 0x05 /* Gravity.TOP | RIGHT */);
    jmethodID addV = (*env)->GetMethodID(env, (*env)->FindClass(env, "android/view/ViewGroup"),
                                         "addView", "(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V");
    (*env)->CallVoidMethod(env, gRoot, addV, b, lp);
    gMenuBtn = (*env)->NewGlobalRef(env, b);
    check(env, "menu button add");
}
void ux_and_menu_set(const char *enc) {
    JNIEnv *env = envNow();
    menuButtonEnsure(env);
    if (!gMenuBtn) return;
    (*env)->CallVoidMethod(env, gMenuBtn, (*env)->GetMethodID(env, gMenuCls, "set", "(Ljava/lang/String;)V"),
                           (*env)->NewStringUTF(env, enc ? enc : ""));
    jmethodID bring = (*env)->GetMethodID(env, gViewCls, "bringToFront", "()V");
    (*env)->CallVoidMethod(env, gMenuBtn, bring);
    check(env, "menu set");
}
void ux_and_menu_state(int t, int j, int what, int on) {
    if (!gMenuBtn) return;
    JNIEnv *env = envNow();
    (*env)->CallVoidMethod(env, gMenuBtn, (*env)->GetMethodID(env, gMenuCls, "state", "(IIIZ)V"), t, j, what, (jboolean)(on != 0));
    check(env, "menu state");
}
/* tests: the titles the button carries, a title's text, an item's state (1 there, 2 checked, 4 disabled) */
int ux_and_test_menu_shown(void) {
    if (!gMenuBtn) return 0;
    JNIEnv *env = envNow();
    return (*env)->CallIntMethod(env, gMenuBtn, (*env)->GetMethodID(env, gMenuCls, "titleCount", "()I"));
}
int ux_and_test_menu_title_is(int t, const char *want) {
    if (!gMenuBtn) return 0;
    JNIEnv *env = envNow();
    jstring s = (*env)->CallObjectMethod(env, gMenuBtn, (*env)->GetMethodID(env, gMenuCls, "title", "(I)Ljava/lang/String;"), t);
    const char *u = (*env)->GetStringUTFChars(env, s, NULL);
    int ok = strcmp(u, want) == 0;
    (*env)->ReleaseStringUTFChars(env, s, u);
    return ok;
}
int ux_and_test_menu_item(int t, int j) {
    if (!gMenuBtn) return 0;
    JNIEnv *env = envNow();
    return (*env)->CallIntMethod(env, gMenuBtn, (*env)->GetMethodID(env, gMenuCls, "item", "(II)I"), t, j);
}

/* ── the native table: UXTable (a ListView under a header of titles) ─── */
void ux_and_set_table_hooks(void *rows, void *cell, void *cols, void *title, void *width,
                            void *multi, void *selset) {
    gTblRows = (tbl_rows_fn)rows;
    gTblCell = (tbl_cell_fn)cell;
    gTblCols = (tbl_cols_fn)cols;
    gTblTitle = (tbl_title_fn)title;
    gTblWidth = (tbl_width_fn)width;
    gTblMulti = (tbl_multi_fn)multi;
    gTblSelSet = (tbl_selset_fn)selset;
}
void ux_and_set_outline_hooks(void *level, void *disclosure, void *toggle) {
    gTblLevel = (tbl_rowint_fn)level;
    gTblDisclosure = (tbl_rowint_fn)disclosure;
    gTblToggle = (tbl_toggle_fn)toggle;
}
void ux_and_make_table(int handle, int node, int x, int y, int w, int h, void *peer, int outline) {
    if (handle <= 0 || handle >= UXA_MAXW || node < 0 || node >= 64) return;
    JNIEnv *env = envNow();
    gTblPeer[handle][node] = peer;
    jmethodID init = (*env)->GetMethodID(env, gTableCls, "<init>", "(Landroid/content/Context;IZZ)V");
    jobject t = (*env)->NewObject(env, gTableCls, init, gActivity, (handle << 8) | node,
                                  (jboolean)(gTblMulti && gTblMulti(peer) != 0), (jboolean)(outline != 0));
    if (!check(env, "make_table") || !t) return;
    place(env, handle, node, t, x, y, w, h);
}
static jobject tableAt(int handle, int node) {
    return ux_and_has_control(handle, node) && gTblPeer[handle][node] ? gCtl[handle][node] : NULL;
}
void ux_and_table_reload(int handle, int node) {
    jobject t = tableAt(handle, node);
    if (!t) return;
    JNIEnv *env = envNow();
    (*env)->CallVoidMethod(env, t, (*env)->GetMethodID(env, gTableCls, "reload", "()V"));
    check(env, "table_reload");
}
void ux_and_table_select(int handle, int node, int *rows, int n) {
    jobject t = tableAt(handle, node);
    if (!t) return;
    JNIEnv *env = envNow();
    jintArray a = (*env)->NewIntArray(env, n);
    (*env)->SetIntArrayRegion(env, a, 0, n, (const jint *)rows);
    (*env)->CallVoidMethod(env, t, (*env)->GetMethodID(env, gTableCls, "select", "([I)V"), a);
    (*env)->DeleteLocalRef(env, a);
    check(env, "table_select");
}
/* tests: the list's row count, a row's checked state, a cell's text as its view shows it, a tap */
int ux_and_test_table_rows(int handle, int node) {
    jobject t = tableAt(handle, node);
    if (!t) return -1;
    JNIEnv *env = envNow();
    return (*env)->CallIntMethod(env, t, (*env)->GetMethodID(env, gTableCls, "rowCount", "()I"));
}
int ux_and_test_table_selected(int handle, int node, int row) {
    jobject t = tableAt(handle, node);
    if (!t) return 0;
    JNIEnv *env = envNow();
    return (*env)->CallBooleanMethod(env, t, (*env)->GetMethodID(env, gTableCls, "isSelected", "(I)Z"), row) ? 1 : 0;
}
int ux_and_test_table_cell_is(int handle, int node, int row, int col, const char *want) {
    jobject t = tableAt(handle, node);
    if (!t) return 0;
    JNIEnv *env = envNow();
    jstring s = (*env)->CallObjectMethod(env, t, (*env)->GetMethodID(env, gTableCls, "cellText",
                                         "(II)Ljava/lang/String;"), row, col);
    if (!s) return 0;
    const char *u = (*env)->GetStringUTFChars(env, s, NULL);
    int ok = strcmp(u, want) == 0;
    (*env)->ReleaseStringUTFChars(env, s, u);
    return ok;
}
int ux_and_test_table_shown(int handle, int node) {
    jobject t = tableAt(handle, node);
    if (!t) return -1;
    JNIEnv *env = envNow();
    return (*env)->CallIntMethod(env, t, (*env)->GetMethodID(env, gTableCls, "shownRows", "()I"));
}
void ux_and_test_table_row_at(int handle, int node, int row, int *x, int *y) {
    jobject t = tableAt(handle, node);
    *x = *y = -1;
    if (!t) return;
    JNIEnv *env = envNow();
    *x = (*env)->CallIntMethod(env, t, (*env)->GetMethodID(env, gTableCls, "rowScreenX", "(I)I"), row);
    *y = (*env)->CallIntMethod(env, t, (*env)->GetMethodID(env, gTableCls, "rowScreenY", "(I)I"), row);
    check(env, "table_row_at");
}
/* tests: an outline row's arrow (0 none, 1 closed, 2 open), its indent in dp, where its arrow is */
int ux_and_test_table_chevron(int handle, int node, int row) {
    jobject t = tableAt(handle, node);
    if (!t) return -1;
    JNIEnv *env = envNow();
    jstring s = (*env)->CallObjectMethod(env, t, (*env)->GetMethodID(env, gTableCls, "arrowText", "(I)Ljava/lang/String;"), row);
    const char *u = (*env)->GetStringUTFChars(env, s, NULL);
    int r = u[0] == 0 ? 0 : (strcmp(u, "\xE2\x96\xBE") == 0 ? 2 : 1);
    (*env)->ReleaseStringUTFChars(env, s, u);
    return r;
}
int ux_and_test_table_indent(int handle, int node, int row) {
    jobject t = tableAt(handle, node);
    if (!t) return -1;
    JNIEnv *env = envNow();
    return (*env)->CallIntMethod(env, t, (*env)->GetMethodID(env, gTableCls, "indentDp", "(I)I"), row);
}
void ux_and_test_table_arrow_at(int handle, int node, int row, int *x, int *y) {
    jobject t = tableAt(handle, node);
    *x = *y = -1;
    if (!t) return;
    JNIEnv *env = envNow();
    *x = (*env)->CallIntMethod(env, t, (*env)->GetMethodID(env, gTableCls, "arrowScreenX", "(I)I"), row);
    *y = (*env)->CallIntMethod(env, t, (*env)->GetMethodID(env, gTableCls, "arrowScreenY", "(I)I"), row);
    check(env, "table_arrow_at");
}
void ux_and_test_table_tap(int handle, int node, int row) {
    jobject t = tableAt(handle, node);
    if (!t) return;
    JNIEnv *env = envNow();
    (*env)->CallVoidMethod(env, t, (*env)->GetMethodID(env, gTableCls, "tap", "(I)V"), row);
    check(env, "table_tap");
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
    gFieldMute = 1;
    (*env)->CallVoidMethod(env, ed, gEditSetText, (*env)->NewStringUTF(env, buf));
    gFieldMute = 0;
    (*env)->CallVoidMethod(env, ed, gEditWatch, bridge(env, handle, node));
    /* ONE line, and the keyboard's Return becomes the IME's done action rather than a newline
     * in the buffer -- which is also what makes the editor-action listener below fire. */
    jmethodID single = (*env)->GetMethodID(env, gEditCls, "setSingleLine", "(Z)V");
    if (single) (*env)->CallVoidMethod(env, ed, single, (jboolean)1);
    /* A secure field's input type goes on AFTER setSingleLine: setSingleLine installs its own
     * transformation and so threw away the password one -- the field showed its text in plain
     * view.  Password input is single-line by itself, so this order keeps both. */
    if (secure)   /* TYPE_CLASS_TEXT | TYPE_TEXT_VARIATION_PASSWORD */
        (*env)->CallVoidMethod(env, ed, gEditSetInputType, 0x81);
    jmethodID onAct = (*env)->GetMethodID(env, gEditCls, "setOnEditorActionListener",
                                          "(Landroid/widget/TextView$OnEditorActionListener;)V");
    if (onAct) (*env)->CallVoidMethod(env, ed, onAct, bridge(env, handle, node));
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

/* ── the segmented control: native ToggleButtons in a row (UXBridge.segmented) ── */
void ux_and_make_segmented(int handle, int node, int x, int y, int w, int h, int nseg, int multi) {
    JNIEnv *env = envNow();
    jmethodID mk = (*env)->GetStaticMethodID(env, gBridgeCls, "segmented", "(Landroid/app/Activity;IIIIZ)Landroid/view/View;");
    if (!check(env, "segmented method") || !mk) return;
    jobject box = (*env)->CallStaticObjectMethod(env, gBridgeCls, mk, gActivity, (handle << 8) | node, nseg, PX(w), PX(h),
                                                 (jboolean)(multi != 0));
    if (!check(env, "make_segmented") || !box) return;
    place(env, handle, node, box, x, y, w, h);
    check(env, "place segmented");
}
void ux_and_seg_set_label(int handle, int node, int seg, const char *label) {
    JNIEnv *env = envNow();
    if (!gCtl[handle][node]) return;
    jmethodID m = (*env)->GetStaticMethodID(env, gBridgeCls, "segLabel", "(Landroid/view/View;ILjava/lang/String;)V");
    jstring s = (*env)->NewStringUTF(env, label ? label : "");
    (*env)->CallStaticVoidMethod(env, gBridgeCls, m, gCtl[handle][node], seg, s);
    (*env)->DeleteLocalRef(env, s);
    check(env, "seg label");
}
/* one segment's state, from the model */
void ux_and_seg_set(int handle, int node, int seg, int on) {
    JNIEnv *env = envNow();
    if (!gCtl[handle][node]) return;
    jmethodID m = (*env)->GetStaticMethodID(env, gBridgeCls, "segSet", "(Landroid/view/View;IZ)V");
    (*env)->CallStaticVoidMethod(env, gBridgeCls, m, gCtl[handle][node], seg, (jboolean)(on != 0));
    check(env, "seg set");
}
/* tests: the native control's segments, checked segment, a label, and a segment's screen centre */
int ux_and_test_seg_count(int handle, int node) {
    JNIEnv *env = envNow();
    if (!gCtl[handle][node]) return -1;
    jmethodID m = (*env)->GetStaticMethodID(env, gBridgeCls, "segCount", "(Landroid/view/View;)I");
    return (*env)->CallStaticIntMethod(env, gBridgeCls, m, gCtl[handle][node]);
}
int ux_and_test_seg_selected(int handle, int node) {
    JNIEnv *env = envNow();
    if (!gCtl[handle][node]) return -2;
    jmethodID m = (*env)->GetStaticMethodID(env, gBridgeCls, "segSelected", "(Landroid/view/View;)I");
    return (*env)->CallStaticIntMethod(env, gBridgeCls, m, gCtl[handle][node]);
}
int ux_and_test_seg_text_is(int handle, int node, int seg, const char *want) {
    JNIEnv *env = envNow();
    if (!gCtl[handle][node]) return 0;
    jmethodID m = (*env)->GetStaticMethodID(env, gBridgeCls, "segText", "(Landroid/view/View;I)Ljava/lang/String;");
    jstring t = (jstring)(*env)->CallStaticObjectMethod(env, gBridgeCls, m, gCtl[handle][node], seg);
    const char *u = t ? (*env)->GetStringUTFChars(env, t, NULL) : "";
    int same = strcmp(u, want ? want : "") == 0;
    if (t) (*env)->ReleaseStringUTFChars(env, t, u);
    return same;
}
void ux_and_test_seg_centre(int handle, int node, int seg, int *x, int *y) {
    JNIEnv *env = envNow();
    *x = *y = -1;
    if (!gCtl[handle][node]) return;
    jmethodID m = (*env)->GetStaticMethodID(env, gBridgeCls, "segCentre", "(Landroid/view/View;I)[I");
    jintArray a = (jintArray)(*env)->CallStaticObjectMethod(env, gBridgeCls, m, gCtl[handle][node], seg);
    if (!a) return;
    jint v[2];
    (*env)->GetIntArrayRegion(env, a, 0, 2, v);
    *x = v[0];
    *y = v[1];
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
/* alpha is the straight 0..255 value; Canvas blends every fill and stroke source-over, so a
   translucent primitive composites with what is under it.  a == 255 is the opaque case. */
static void paintColor(JNIEnv *env, int r, int g, int b, int a) {
    (*env)->CallVoidMethod(env, gPaint, gPaintSetColor,
                           (jint)(((unsigned)a << 24) | ((unsigned)r << 16) | ((unsigned)g << 8) | (unsigned)b));
}
void ux_and_fill(int x, int y, int w, int h, int r, int g, int b, int a) {
    if (!gDrawCanvas) return;
    JNIEnv *env = envNow();
    paintColor(env, r, g, b, a);
    (*env)->CallVoidMethod(env, gPaint, gPaintSetStyle, gStyleFill);
    (*env)->CallVoidMethod(env, gDrawCanvas, gCanvasDrawRect,
                           (jfloat)x, (jfloat)y, (jfloat)(x + w), (jfloat)(y + h), gPaint);
}
/* drawPixels: the region becomes an int[] of ARGB colours -- Android's ARGB_8888 colour ints are
 * straight 0xAARRGGBB, which is a UXImage's word exactly -- then a Bitmap, drawn into the destination
 * RectF with a filtering Paint that carries the overall alpha.  Region only, per call.  The JNI ids
 * are resolved on first use; a local frame scopes the per-call references, so a panel drawing eighty
 * icons a frame cannot run the local reference table out. */
static jmethodID gBmpFromColors, gBmpRecycle, gCanvasDrawBitmap, gRectFInit, gPaintSetAlpha, gPaintSetFilter;
static jclass gRectFCls;
static jobject gBmpCfg8888, gPixPaint; /* global refs */
void ux_and_draw_pixels(const unsigned char* data, int w, int h, int fmt, int sx, int sy, int sw, int sh,
                        int dx, int dy, int dw, int dh, int alpha) {
    if (!gDrawCanvas || !data || alpha <= 0 || dw <= 0 || dh <= 0) return;
    if (sx < 0) sx = 0;
    if (sy < 0) sy = 0;
    if (sx + sw > w) sw = w - sx;
    if (sy + sh > h) sh = h - sy;
    if (sw <= 0 || sh <= 0) return;
    JNIEnv *env = envNow();
    if (!gCanvasDrawBitmap) {
        gBmpFromColors = (*env)->GetStaticMethodID(env, gBitmapCls, "createBitmap",
                             "([IIILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;");
        gBmpRecycle = (*env)->GetMethodID(env, gBitmapCls, "recycle", "()V");
        gCanvasDrawBitmap = (*env)->GetMethodID(env, gCanvasCls, "drawBitmap",
                             "(Landroid/graphics/Bitmap;Landroid/graphics/Rect;Landroid/graphics/RectF;Landroid/graphics/Paint;)V");
        gRectFCls = gref(env, "android/graphics/RectF");
        gRectFInit = gRectFCls ? (*env)->GetMethodID(env, gRectFCls, "<init>", "(FFFF)V") : 0;
        gPaintSetAlpha = (*env)->GetMethodID(env, gPaintCls, "setAlpha", "(I)V");
        gPaintSetFilter = (*env)->GetMethodID(env, gPaintCls, "setFilterBitmap", "(Z)V");
        jclass cfgCls = (*env)->FindClass(env, "android/graphics/Bitmap$Config");
        jfieldID f8888 = (*env)->GetStaticFieldID(env, cfgCls, "ARGB_8888", "Landroid/graphics/Bitmap$Config;");
        gBmpCfg8888 = (*env)->NewGlobalRef(env, (*env)->GetStaticObjectField(env, cfgCls, f8888));
        gPixPaint = (*env)->NewGlobalRef(env, (*env)->NewObject(env, gPaintCls, gPaintInit));
        (*env)->CallVoidMethod(env, gPixPaint, gPaintSetFilter, (jboolean)1);
        if (!check(env, "drawPixels ids") || !gRectFInit) { gCanvasDrawBitmap = 0; return; }
    }
    if ((*env)->PushLocalFrame(env, 8) != 0) return;
    jintArray colors = (*env)->NewIntArray(env, sw * sh);
    jint* c = colors ? (*env)->GetIntArrayElements(env, colors, NULL) : NULL;
    if (c) {
        for (int y = 0; y < sh; y++)
            for (int x = 0; x < sw; x++) {
                const unsigned char* q = data + ((size_t)(sy + y) * w + (sx + x)) * 4;
                unsigned r = fmt == 1 ? q[2] : q[0], g = q[1], b = fmt == 1 ? q[0] : q[2], a = q[3];
                c[y * sw + x] = (jint)((a << 24) | (r << 16) | (g << 8) | b);
            }
        (*env)->ReleaseIntArrayElements(env, colors, c, 0);
        jobject bmp = (*env)->CallStaticObjectMethod(env, gBitmapCls, gBmpFromColors, colors, sw, sh, gBmpCfg8888);
        jobject dst = (*env)->NewObject(env, gRectFCls, gRectFInit,
                                        (jfloat)dx, (jfloat)dy, (jfloat)(dx + dw), (jfloat)(dy + dh));
        (*env)->CallVoidMethod(env, gPixPaint, gPaintSetAlpha, (jint)(alpha > 255 ? 255 : alpha));
        if (bmp && dst) {
            (*env)->CallVoidMethod(env, gDrawCanvas, gCanvasDrawBitmap, bmp, (jobject)NULL, dst, gPixPaint);
            (*env)->CallVoidMethod(env, bmp, gBmpRecycle);
        }
    }
    check(env, "drawPixels");
    (*env)->PopLocalFrame(env, NULL);
}
/* Canvas has no clearRect: save the clip, clip to the rect, drawColor(0, Mode.CLEAR) to punch it
   back to transparent, restore.  A source-over fill at alpha 0 would paint nothing instead. */
void ux_and_clear(int x, int y, int w, int h) {
    if (!gDrawCanvas) return;
    JNIEnv *env = envNow();
    (*env)->CallIntMethod(env, gDrawCanvas, gCanvasSave);
    (*env)->CallBooleanMethod(env, gDrawCanvas, gCanvasClipRect,
                              (jfloat)x, (jfloat)y, (jfloat)(x + w), (jfloat)(y + h));
    (*env)->CallVoidMethod(env, gDrawCanvas, gCanvasDrawColor, (jint)0, gDuffClear);
    (*env)->CallVoidMethod(env, gDrawCanvas, gCanvasRestore);
}
/* The seam's y is the top of the line; Canvas.drawText wants the baseline.  The step between them is
   the FACE's ascent, read off the Paint that is about to draw (FontMetricsInt reports it above the
   baseline as a negative number), with the em size as the floor when the field is unavailable.
   ux_and_text_ascent calls this same function, so a paint and a measure cannot disagree — the em size
   it used to be put Android text a couple of pixels low, and test_android_real's ink row checks it. */
static int and_line_ascent(JNIEnv *env, int px) {
    if (gPaintMetricsInt && gMetricsAscent) {
        jobject m = (*env)->CallObjectMethod(env, gPaint, gPaintMetricsInt);
        if (m) {
            jint a = (*env)->GetIntField(env, m, gMetricsAscent);
            (*env)->DeleteLocalRef(env, m);
            if (a < 0) return (int)(-a);
        }
    }
    return px;
}
void ux_and_text(const char *s, int x, int y, int r, int g, int b, int a, int size) {
    if (!gDrawCanvas) return;
    JNIEnv *env = envNow();
    int px = size > 0 ? size : 14;
    paintColor(env, r, g, b, a);
    (*env)->CallVoidMethod(env, gPaint, gPaintSetStyle, gStyleFill);
    (*env)->CallVoidMethod(env, gPaint, gPaintSetTextSize, (jfloat)px);
    jstring js = (*env)->NewStringUTF(env, s);
    /* the seam's y is text TOP; Canvas.drawText wants the baseline */
    (*env)->CallVoidMethod(env, gDrawCanvas, gCanvasDrawText, js,
                           (jfloat)x, (jfloat)(y + and_line_ascent(env, px)), gPaint);
    (*env)->DeleteLocalRef(env, js);
}
/* A family at a numeric CSS weight.  Typeface.create(String, int) takes a STYLE, not a weight, so
   the CSS scale folds at semibold into bold — the nearest a Typeface can name below API 28, which
   is this shim's floor. */
void ux_and_text_weight(const char *s, int x, int y, const char *family, int size,
                        int weight, int italic, int r, int g, int b, int a) {
    if (!gDrawCanvas) return;
    JNIEnv *env = envNow();
    int px = size > 0 ? size : 14;
    paintColor(env, r, g, b, a);
    (*env)->CallVoidMethod(env, gPaint, gPaintSetStyle, gStyleFill);
    (*env)->CallVoidMethod(env, gPaint, gPaintSetTextSize, (jfloat)px);
    if (gTypefaceCreate) {
        int bold = weight >= 600;
        int style = (bold ? 1 : 0) | (italic ? 2 : 0);   /* BOLD | ITALIC */
        jstring jf = (*env)->NewStringUTF(env, family ? family : "");
        jobject tf = (*env)->CallStaticObjectMethod(env, gTypefaceCls, gTypefaceCreate, jf, (jint)style);
        if (tf) {
            (*env)->CallVoidMethod(env, gPaint, gPaintSetTypeface, tf);
            (*env)->DeleteLocalRef(env, tf);
        }
        (*env)->DeleteLocalRef(env, jf);
    }
    jstring js = (*env)->NewStringUTF(env, s);
    (*env)->CallVoidMethod(env, gDrawCanvas, gCanvasDrawText, js,
                           (jfloat)x, (jfloat)(y + and_line_ascent(env, px)), gPaint);
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
    paintColor(env, r, g, b, 255);
    (*env)->CallVoidMethod(env, gPaint, gPaintSetStyle, gStyleFill);
    (*env)->CallVoidMethod(env, gDrawCanvas, gCanvasDrawPath, path, gPaint);
    (*env)->DeleteLocalRef(env, path);
}
void ux_and_poly(short *xy, int n, int r, int g, int b, int a) {
    if (!gDrawCanvas || n < 3) return;
    JNIEnv *env = envNow();
    jobject path = (*env)->NewObject(env, gPathCls, gPathInit);
    (*env)->CallVoidMethod(env, path, gPathMoveTo, (jfloat)xy[0], (jfloat)xy[1]);
    for (int i = 1; i < n; i++)
        (*env)->CallVoidMethod(env, path, gPathLineTo, (jfloat)xy[i * 2], (jfloat)xy[i * 2 + 1]);
    (*env)->CallVoidMethod(env, path, gPathClose);
    paintColor(env, r, g, b, a);
    (*env)->CallVoidMethod(env, gPaint, gPaintSetStyle, gStyleFill);
    (*env)->CallVoidMethod(env, gDrawCanvas, gCanvasDrawPath, path, gPaint);
    (*env)->DeleteLocalRef(env, path);
}
/* ops encoding: UXSTROKE_MOVE x y | LINE x y | CURVE c1..c2..xy | CLOSE.  One op run = one Path; a
   dash needs the run split at each MOVE (see ux_and_stroke_path), so the building is its own call. */
static void and_stroke_run(JNIEnv *env, const int *ops, int n) {
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
    (*env)->CallVoidMethod(env, gDrawCanvas, gCanvasDrawPath, path, gPaint);
    (*env)->DeleteLocalRef(env, path);
}
/* The width is in device pixels and may be fractional: Paint.setStrokeWidth takes a float, so a
 * 1.536-px border is exactly that.
 * dash/ndash/phase: the on/off run in device pixels and the offset into it (ndash 0 = solid). */
void ux_and_stroke_path(int *ops, int n, double width, int startCap, int endCap, int join,
                        int *dash, int ndash, int phase, int r, int g, int b, int a) {
    if (!gDrawCanvas) return;
    JNIEnv *env = envNow();
    paintColor(env, r, g, b, a);
    (*env)->CallVoidMethod(env, gPaint, gPaintSetStyle, gStyleStroke);
    (*env)->CallVoidMethod(env, gPaint, gPaintSetStrokeWidth, (jfloat)(width > 0.0 ? width : 1.0));
    /* one Cap per Paint: round if either end asks, square above butt */
    jobject cap = (startCap == 1 || endCap == 1) ? gCapRound
                : (startCap == 2 || endCap == 2) ? gCapSquare : gCapButt;
    (*env)->CallVoidMethod(env, gPaint, gPaintSetStrokeCap, cap);
    /* join: 0 miter, 1 round, 2 bevel (UXJOIN_*) */
    jobject jn = join == 0 ? gJoinMiter : (join == 2 ? gJoinBevel : gJoinRound);
    (*env)->CallVoidMethod(env, gPaint, gPaintSetStrokeJoin, jn);

    int dashed = ndash > 0 && gDashInit;
    if (dashed) {
        jfloat pat[8];
        int k = ndash > 8 ? 8 : ndash;
        for (int j = 0; j < k; j++) pat[j] = dash[j] > 0 ? (jfloat)dash[j] : 1.0f;
        jfloatArray arr = (*env)->NewFloatArray(env, k);
        (*env)->SetFloatArrayRegion(env, arr, 0, k, pat);
        jobject eff = (*env)->NewObject(env, gDashCls, gDashInit, arr, (jfloat)phase);
        (*env)->CallObjectMethod(env, gPaint, gPaintSetPathEffect, eff);
        (*env)->DeleteLocalRef(env, arr);
        if (eff) (*env)->DeleteLocalRef(env, eff);
    } else {
        (*env)->CallObjectMethod(env, gPaint, gPaintSetPathEffect, (jobject)0);
    }

    /* Skia's DashPathEffect restarts the phase at every contour, the browser's rule — measured, not
       assumed, by test_android_real's two-subpath dash: with the run stroked whole the two rows come
       back identical to the pixel (and the AppKit and cairo dashers answer the same way). */
    and_stroke_run(env, ops, n);
    (*env)->CallVoidMethod(env, gPaint, gPaintSetStyle, gStyleFill);
    if (dashed) (*env)->CallObjectMethod(env, gPaint, gPaintSetPathEffect, (jobject)0);
}
/* subtree clipping for the draw walk (neutral coords — the canvas is pre-scaled) */
void ux_and_clip(int x, int y, int w, int h) {
    if (!gDrawCanvas) return;
    JNIEnv *env = envNow();
    (*env)->CallIntMethod(env, gDrawCanvas, gCanvasSave);
    (*env)->CallBooleanMethod(env, gDrawCanvas, gCanvasClipRect,
                              (jfloat)x, (jfloat)y, (jfloat)(x + w), (jfloat)(y + h));
}
/* A rounded clip: Path.addRoundRect(RectF, rx, ry, Direction.CW) + Canvas.clipPath.  The ids are
 * resolved on first use.  ux_and_clip_end pops it. */
static jmethodID gPathAddRoundRect, gCanvasClipPath, gRectFInit2;
static jclass gRectFCls2;
static jobject gDirCW;
void ux_and_clip_round(int x, int y, int w, int h, int r) {
    if (!gDrawCanvas) return;
    if (r <= 0) { ux_and_clip(x, y, w, h); return; }
    JNIEnv *env = envNow();
    if (!gCanvasClipPath) {
        gRectFCls2 = gref(env, "android/graphics/RectF");
        gRectFInit2 = gRectFCls2 ? (*env)->GetMethodID(env, gRectFCls2, "<init>", "(FFFF)V") : 0;
        gPathAddRoundRect = (*env)->GetMethodID(env, gPathCls, "addRoundRect",
                               "(Landroid/graphics/RectF;FFLandroid/graphics/Path$Direction;)V");
        gCanvasClipPath = (*env)->GetMethodID(env, gCanvasCls, "clipPath", "(Landroid/graphics/Path;)Z");
        jobject cw = enumVal(env, "android/graphics/Path$Direction", "CW");
        gDirCW = cw ? (*env)->NewGlobalRef(env, cw) : 0;
        if (!check(env, "clip round ids") || !gRectFInit2 || !gDirCW) { gCanvasClipPath = 0; ux_and_clip(x, y, w, h); return; }
    }
    float rr = r * 2 > w ? w / 2.0f : r * 2 > h ? h / 2.0f : (float)r;
    (*env)->CallIntMethod(env, gDrawCanvas, gCanvasSave);
    if ((*env)->PushLocalFrame(env, 4) != 0) return;
    jobject rect = (*env)->NewObject(env, gRectFCls2, gRectFInit2, (jfloat)x, (jfloat)y, (jfloat)(x + w), (jfloat)(y + h));
    jobject path = (*env)->NewObject(env, gPathCls, gPathInit);
    (*env)->CallVoidMethod(env, path, gPathAddRoundRect, rect, (jfloat)rr, (jfloat)rr, gDirCW);
    (*env)->CallBooleanMethod(env, gDrawCanvas, gCanvasClipPath, path);
    check(env, "clip round");
    (*env)->PopLocalFrame(env, NULL);
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
int ux_and_text_width_weight(const char *s, const char *family, int size, int weight, int italic) {
    (void)family; (void)weight; (void)italic; /* one face until the Typeface slice lands */
    return ux_and_text_width(s, size);
}
/* The FACE's ascent: the same function the two text entries place with, so this answers with the
   distance a paint is offset by.  It is the face's own metric, so a family or weight the caller names
   would move it once the Typeface slice pins the face on the Paint. */
int ux_and_text_ascent(const char *family, int size, int weight, int italic) {
    (void)family; (void)weight; (void)italic;
    JNIEnv *env = envNow();
    if (!gPaint) return (int)((size > 0 ? size : 14) * 0.8);
    (*env)->CallVoidMethod(env, gPaint, gPaintSetTextSize, (jfloat)(size > 0 ? size : 14));
    return and_line_ascent(env, size > 0 ? size : 14);
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

/* ── GL: GLES 3, rendered offscreen, painted in the window's own 2-D pass ──
 * The one-surface model AppKit and Win32 use.  Each GL view gets an EGL ES3 context (on a 1x1
 * pbuffer: it never draws to a window) and a framebuffer object at the view's PIXEL size, bound as
 * the renderer's default, so the renderer does not know.  presentGL reads the frame back into a
 * Bitmap and invalidates the window; the draw walk paints that bitmap where the view sits, in tree
 * order, so a 2-D view after the GL view in the tree is drawn OVER it.  EGL and GLES are opened at
 * run time, so no app's link line changes. */
#define UXA_GL_MAX 8
typedef void *(*egl_getdisplay_fn)(void *);
typedef unsigned (*egl_initialize_fn)(void *, int *, int *);
typedef unsigned (*egl_chooseconfig_fn)(void *, const int *, void **, int, int *);
typedef void *(*egl_createpbuffer_fn)(void *, void *, const int *);
typedef void *(*egl_createcontext_fn)(void *, void *, void *, const int *);
typedef unsigned (*egl_makecurrent_fn)(void *, void *, void *, void *);
typedef unsigned (*egl_destroycontext_fn)(void *, void *);
typedef void *(*egl_getproc_fn)(const char *);
typedef void (*gl_gen_fn)(int, unsigned *);
typedef void (*gl_bind_fn)(unsigned, unsigned);
typedef void (*gl_rbstorage_fn)(unsigned, unsigned, int, int);
typedef void (*gl_fbrb_fn)(unsigned, unsigned, unsigned, unsigned);
typedef void (*gl_viewport_fn)(int, int, int, int);
typedef void (*gl_readpixels_fn)(int, int, int, int, unsigned, unsigned, void *);
typedef void (*gl_del_fn)(int, const unsigned *);
typedef void (*gl_finish_fn)(void);
static void *gEglLib, *gGlesLib, *gEglDpy, *gEglCfg, *gEglPb;
static egl_makecurrent_fn gEglMakeCur;
static egl_getproc_fn gEglGetProc;
static struct {
    void *view, *ctx;
    unsigned fbo, rbColor, rbDepth;
    int pw, ph;             /* the drawable, in pixels */
    unsigned char *px;      /* the last frame, top-down RGBA */
    jobject bmp;            /* global ref: that frame as a Bitmap */
    int win;                /* the window it was last painted in (0: not yet) */
} gGl[UXA_GL_MAX];
static int gGlCount;
static int gGlTestMax;      /* tests: a lower GPU limit, to exercise the clamp */
void ux_and_test_gl_max(int max) { gGlTestMax = max; }
static int glLoad(void) {
    if (gEglDpy) return 1;
    if (!gEglLib) gEglLib = dlopen("libEGL.so", RTLD_NOW);
    if (!gGlesLib) gGlesLib = dlopen("libGLESv3.so", RTLD_NOW);
    if (!gEglLib || !gGlesLib) return 0;
    egl_getdisplay_fn gd = (egl_getdisplay_fn)dlsym(gEglLib, "eglGetDisplay");
    egl_initialize_fn in = (egl_initialize_fn)dlsym(gEglLib, "eglInitialize");
    egl_chooseconfig_fn cc = (egl_chooseconfig_fn)dlsym(gEglLib, "eglChooseConfig");
    egl_createpbuffer_fn cp = (egl_createpbuffer_fn)dlsym(gEglLib, "eglCreatePbufferSurface");
    gEglMakeCur = (egl_makecurrent_fn)dlsym(gEglLib, "eglMakeCurrent");
    gEglGetProc = (egl_getproc_fn)dlsym(gEglLib, "eglGetProcAddress");
    if (!gd || !in || !cc || !cp || !gEglMakeCur) return 0;
    void *dpy = gd(0 /* EGL_DEFAULT_DISPLAY */);
    int maj = 0, min = 0;
    if (!dpy || !in(dpy, &maj, &min)) return 0;
    const int attrs[] = { 0x3040 /* EGL_RENDERABLE_TYPE */, 0x40 /* EGL_OPENGL_ES3_BIT */,
                          0x3033 /* EGL_SURFACE_TYPE */, 0x0001 /* EGL_PBUFFER_BIT */,
                          0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8 /* R G B A */,
                          0x3038 /* EGL_NONE */ };
    void *cfg = NULL;
    int n = 0;
    if (!cc(dpy, attrs, &cfg, 1, &n) || n < 1) return 0;
    const int pb[] = { 0x3057, 1, 0x3056, 1, 0x3038 }; /* EGL_WIDTH 1, EGL_HEIGHT 1 */
    gEglPb = cp(dpy, cfg, pb);
    if (!gEglPb) return 0;
    gEglCfg = cfg;
    gEglDpy = dpy;
    return 1;
}
/* An entry point by name: the GLES library's own symbols first.  eglGetProcAddress answers for
 * extensions only -- for an unknown core-looking name it may hand back a stub, and a renderer
 * must get 0 for a name that is not there. */
void *ux_and_gl_proc(const char *name) {
    if (!glLoad() || !name) return NULL;
    void *p = dlsym(gGlesLib, name);
    if (!p) p = dlsym(gEglLib, name);
    if (!p && gEglGetProc) {
        size_t n = strlen(name);
        const char *suf[] = { "EXT", "OES", "KHR", "NV", "ANDROID", "ARM", "QCOM", "IMG" };
        for (unsigned k = 0; k < sizeof suf / sizeof suf[0]; k++) {
            size_t m = strlen(suf[k]);
            if (n > m && strcmp(name + n - m, suf[k]) == 0) { p = gEglGetProc(name); break; }
        }
    }
    return p;
}
static int glFind(void *view) {
    for (int i = 0; i < gGlCount; i++) if (gGl[i].view == view) return i;
    return -1;
}
static void glCur(int i) { gEglMakeCur(gEglDpy, gEglPb, gEglPb, gGl[i].ctx); }
/* (re)make the framebuffer at w x h pixels and set the viewport to it.  The drawable never exceeds
 * what the GPU can hold (the renderbuffer and viewport limits): over it, both sides shrink by one
 * factor, keeping the aspect, and the paint stretches the frame back over the view. */
static void glFramebuffer(int i, int w, int h) {
    typedef void (*gl_getint_fn)(unsigned, int *);
    gl_getint_fn gi = (gl_getint_fn)dlsym(gGlesLib, "glGetIntegerv");
    int maxRb = 0, maxVp[2] = { 0, 0 };
    gi(0x84E8 /* GL_MAX_RENDERBUFFER_SIZE */, &maxRb);
    gi(0x0D3A /* GL_MAX_VIEWPORT_DIMS */, maxVp);
    int lim = maxRb > 0 ? maxRb : 4096;
    if (maxVp[0] > 0 && maxVp[0] < lim) lim = maxVp[0];
    if (maxVp[1] > 0 && maxVp[1] < lim) lim = maxVp[1];
    if (gGlTestMax > 0 && gGlTestMax < lim) lim = gGlTestMax;
    if (w > lim || h > lim) {
        if (w >= h) { h = (int)((long)h * lim / w); w = lim; }
        else { w = (int)((long)w * lim / h); h = lim; }
    }
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    gl_gen_fn genFb = (gl_gen_fn)dlsym(gGlesLib, "glGenFramebuffers");
    gl_gen_fn genRb = (gl_gen_fn)dlsym(gGlesLib, "glGenRenderbuffers");
    gl_bind_fn bindFb = (gl_bind_fn)dlsym(gGlesLib, "glBindFramebuffer");
    gl_bind_fn bindRb = (gl_bind_fn)dlsym(gGlesLib, "glBindRenderbuffer");
    gl_rbstorage_fn st = (gl_rbstorage_fn)dlsym(gGlesLib, "glRenderbufferStorage");
    gl_fbrb_fn att = (gl_fbrb_fn)dlsym(gGlesLib, "glFramebufferRenderbuffer");
    gl_del_fn delFb = (gl_del_fn)dlsym(gGlesLib, "glDeleteFramebuffers");
    gl_del_fn delRb = (gl_del_fn)dlsym(gGlesLib, "glDeleteRenderbuffers");
    gl_viewport_fn vp = (gl_viewport_fn)dlsym(gGlesLib, "glViewport");
    if (gGl[i].fbo) {
        delFb(1, &gGl[i].fbo);
        delRb(1, &gGl[i].rbColor);
        delRb(1, &gGl[i].rbDepth);
    }
    genFb(1, &gGl[i].fbo);
    genRb(1, &gGl[i].rbColor);
    genRb(1, &gGl[i].rbDepth);
    bindRb(0x8D41 /* GL_RENDERBUFFER */, gGl[i].rbColor);
    st(0x8D41, 0x8058 /* GL_RGBA8 */, w, h);
    bindRb(0x8D41, gGl[i].rbDepth);
    st(0x8D41, 0x88F0 /* GL_DEPTH24_STENCIL8 */, w, h);
    bindFb(0x8D40 /* GL_FRAMEBUFFER */, gGl[i].fbo);
    att(0x8D40, 0x8CE0 /* COLOR_ATTACHMENT0 */, 0x8D41, gGl[i].rbColor);
    att(0x8D40, 0x821A /* DEPTH_STENCIL_ATTACHMENT */, 0x8D41, gGl[i].rbDepth);
    vp(0, 0, w, h);
    gGl[i].pw = w;
    gGl[i].ph = h;
    free(gGl[i].px);
    gGl[i].px = calloc((size_t)w * h, 4);
}
/* bind a context to a view whose size is w x h (neutral units); 0 if there is no GL */
void *ux_and_gl_make(void *view, int w, int h) {
    if (!glLoad()) return NULL;
    int i = glFind(view);
    if (i < 0) {
        if (gGlCount >= UXA_GL_MAX) return NULL;
        i = gGlCount++;
        memset(&gGl[i], 0, sizeof gGl[i]);
        gGl[i].view = view;
    }
    if (!gGl[i].ctx) {
        egl_createcontext_fn cc = (egl_createcontext_fn)dlsym(gEglLib, "eglCreateContext");
        const int ca[] = { 0x3098 /* EGL_CONTEXT_CLIENT_VERSION */, 3, 0x3038 };
        gGl[i].ctx = cc ? cc(gEglDpy, gEglCfg, NULL, ca) : NULL;
        if (!gGl[i].ctx) return NULL;
        glCur(i);
        glFramebuffer(i, PX(w), PX(h));
    } else {
        glCur(i);
    }
    return (void *)(intptr_t)(i + 1); /* the opaque token, never the context */
}
void ux_and_gl_resize(void *view, int w, int h) {
    int i = glFind(view);
    if (i < 0 || !gGl[i].ctx) return;
    glCur(i);
    glFramebuffer(i, PX(w), PX(h)); /* the clamp may change the drawable even at the same size */
}
void ux_and_gl_destroy(void *view) {
    int i = glFind(view);
    if (i < 0 || !gGl[i].ctx) return;
    JNIEnv *env = envNow();
    glCur(i);
    gl_del_fn delFb = (gl_del_fn)dlsym(gGlesLib, "glDeleteFramebuffers");
    gl_del_fn delRb = (gl_del_fn)dlsym(gGlesLib, "glDeleteRenderbuffers");
    if (gGl[i].fbo) { delFb(1, &gGl[i].fbo); delRb(1, &gGl[i].rbColor); delRb(1, &gGl[i].rbDepth); }
    gEglMakeCur(gEglDpy, NULL, NULL, NULL); /* unbind first: a context deleted while current leaks */
    egl_destroycontext_fn dc = (egl_destroycontext_fn)dlsym(gEglLib, "eglDestroyContext");
    if (dc) dc(gEglDpy, gGl[i].ctx);
    free(gGl[i].px);
    if (gGl[i].bmp) (*env)->DeleteGlobalRef(env, gGl[i].bmp);
    memset(&gGl[i], 0, sizeof gGl[i]);
    gGl[i].view = view; /* the slot stays the view's: a remake reuses it */
}
/* The frame is finished: read it back (GL rows are bottom-up), into the view's Bitmap, and have
 * its window repainted, where the draw walk paints it. */
void ux_and_gl_present(void *view) {
    int i = glFind(view);
    if (i < 0 || !gGl[i].ctx) return;
    JNIEnv *env = envNow();
    glCur(i);
    gl_bind_fn bindFb = (gl_bind_fn)dlsym(gGlesLib, "glBindFramebuffer");
    gl_readpixels_fn rp = (gl_readpixels_fn)dlsym(gGlesLib, "glReadPixels");
    int w = gGl[i].pw, h = gGl[i].ph;
    unsigned char *tmp = malloc((size_t)w * h * 4);
    if (!tmp) return;
    bindFb(0x8D40, gGl[i].fbo);
    rp(0, 0, w, h, 0x1908 /* GL_RGBA */, 0x1401 /* UNSIGNED_BYTE */, tmp);
    for (int y = 0; y < h; y++)
        memcpy(gGl[i].px + (size_t)y * w * 4, tmp + (size_t)(h - 1 - y) * w * 4, (size_t)w * 4);
    free(tmp);
    /* the Bitmap at the drawable's size; ARGB_8888 is RGBA in memory, as the read gave */
    jclass bc = gBitmapCls;
    if (gGl[i].bmp) {
        int bw = (*env)->CallIntMethod(env, gGl[i].bmp, (*env)->GetMethodID(env, bc, "getWidth", "()I"));
        int bh = (*env)->CallIntMethod(env, gGl[i].bmp, (*env)->GetMethodID(env, bc, "getHeight", "()I"));
        if (bw != w || bh != h) { (*env)->DeleteGlobalRef(env, gGl[i].bmp); gGl[i].bmp = NULL; }
    }
    if (!gGl[i].bmp) {
        jclass cfgCls = (*env)->FindClass(env, "android/graphics/Bitmap$Config");
        jobject cfg = (*env)->GetStaticObjectField(env, cfgCls, (*env)->GetStaticFieldID(env, cfgCls, "ARGB_8888",
                                                   "Landroid/graphics/Bitmap$Config;"));
        jobject b = (*env)->CallStaticObjectMethod(env, bc, gBmpCreate, w, h, cfg);
        gGl[i].bmp = (*env)->NewGlobalRef(env, b);
        (*env)->DeleteLocalRef(env, b);
    }
    jobject buf = (*env)->NewDirectByteBuffer(env, gGl[i].px, (jlong)w * h * 4);
    (*env)->CallVoidMethod(env, gGl[i].bmp, (*env)->GetMethodID(env, bc, "copyPixelsFromBuffer", "(Ljava/nio/Buffer;)V"), buf);
    (*env)->DeleteLocalRef(env, buf);
    check(env, "gl present");
    if (gGl[i].win > 0) ux_and_window_invalidate(gGl[i].win);
    else for (int hw = 1; hw < gNextH; hw++) if (gWinV[hw]) ux_and_window_invalidate(hw);
}
/* Paint a GL view's last frame where it sits (neutral units, in the draw in flight).  1 if it drew. */
int ux_and_gl_paint(void *view, int win, int x, int y, int w, int h) {
    int i = glFind(view);
    if (i < 0 || !gGl[i].ctx || !gGl[i].bmp || !gDrawCanvas) return 0;
    JNIEnv *env = envNow();
    gGl[i].win = win;
    jclass rc = (*env)->FindClass(env, "android/graphics/RectF");
    jobject dst = (*env)->NewObject(env, rc, (*env)->GetMethodID(env, rc, "<init>", "(FFFF)V"),
                                    (jfloat)x, (jfloat)y, (jfloat)(x + w), (jfloat)(y + h));
    (*env)->CallVoidMethod(env, gDrawCanvas, (*env)->GetMethodID(env, gCanvasCls, "drawBitmap",
                           "(Landroid/graphics/Bitmap;Landroid/graphics/Rect;Landroid/graphics/RectF;Landroid/graphics/Paint;)V"),
                           gGl[i].bmp, NULL, dst, NULL);
    (*env)->DeleteLocalRef(env, dst);
    check(env, "gl paint");
    return 1;
}
/* tests: the drawable's size in pixels */
int ux_and_test_gl_size(void *view, int *w, int *h) {
    int i = glFind(view);
    if (i < 0) return 0;
    *w = gGl[i].pw;
    *h = gGl[i].ph;
    return 1;
}

/* ── the document picker: UXPicker + a nested Looper.loop(), as the alert ── */
int ux_and_file_open(char *out, int cap) {
    JNIEnv *env = envNow();
    gPickDone = 0;
    gPicked[0] = 0;
    (*env)->CallStaticVoidMethod(env, gPickerCls, (*env)->GetStaticMethodID(env, gPickerCls, "open",
                                 "(Landroid/app/Activity;)V"), gActivity);
    if (!check(env, "picker open")) return 0;
    jclass looperCls = (*env)->FindClass(env, "android/os/Looper");
    jmethodID loop = (*env)->GetStaticMethodID(env, looperCls, "loop", "()V");
    gPickNesting = 1;
    while (!gPickDone) {
        (*env)->CallStaticVoidMethod(env, looperCls, loop);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);   /* the unwind marker */
    }
    gPickNesting = 0;
    if (!gPicked[0] || (int)strlen(gPicked) + 1 > cap) return 0;
    memcpy(out, gPicked, strlen(gPicked) + 1);
    return 1;
}

/* ── the save panel: ACTION_CREATE_DOCUMENT, then each write copied on (UXPicker.export) ── */
int ux_and_file_save(const char *defaultName, char *out, int cap) {
    JNIEnv *env = envNow();
    gPickDone = 0;
    gPicked[0] = 0;
    jstring name = (*env)->NewStringUTF(env, defaultName && defaultName[0] ? defaultName : "untitled");
    (*env)->CallStaticVoidMethod(env, gPickerCls, (*env)->GetStaticMethodID(env, gPickerCls, "create",
                                 "(Landroid/app/Activity;Ljava/lang/String;)V"), gActivity, name);
    (*env)->DeleteLocalRef(env, name);
    if (!check(env, "picker create")) return 0;
    jclass looperCls = (*env)->FindClass(env, "android/os/Looper");
    jmethodID loop = (*env)->GetStaticMethodID(env, looperCls, "loop", "()V");
    gPickNesting = 1;
    while (!gPickDone) {
        (*env)->CallStaticVoidMethod(env, looperCls, loop);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);   /* the unwind marker */
    }
    gPickNesting = 0;
    if (!gPicked[0] || (int)strlen(gPicked) + 1 > cap) return 0;
    memcpy(out, gPicked, strlen(gPicked) + 1);
    return 1;
}
/* after a write of a save panel's staging file lands: 1 if it reached its document (or has none) */
int ux_and_file_written(const char *path) {
    JNIEnv *env = envNow();
    jstring p = (*env)->NewStringUTF(env, path);
    jboolean ok = (*env)->CallStaticBooleanMethod(env, gPickerCls, (*env)->GetStaticMethodID(env, gPickerCls,
                                 "export", "(Landroid/app/Activity;Ljava/lang/String;)Z"), gActivity, p);
    (*env)->DeleteLocalRef(env, p);
    if (!check(env, "picker export")) return 0;
    return ok ? 1 : 0;
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

/* A class from the bridge dex, through the APP's class loader (FindClass from a native thread
 * only sees the system loader). */
static jclass loadAppClass(JNIEnv *env, const char *name) {
    jclass actC = (*env)->GetObjectClass(env, gActivity);
    jmethodID getCl = (*env)->GetMethodID(env, actC, "getClassLoader", "()Ljava/lang/ClassLoader;");
    jobject loader = (*env)->CallObjectMethod(env, gActivity, getCl);
    jclass clCls = (*env)->GetObjectClass(env, loader);
    jmethodID loadClass = (*env)->GetMethodID(env, clCls, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
    jobject k = (*env)->CallObjectMethod(env, loader, loadClass, (*env)->NewStringUTF(env, name));
    if (!check(env, "loadAppClass") || !k) return NULL;
    return (jclass)(*env)->NewGlobalRef(env, k);
}

JNIEXPORT void ANativeActivity_onCreate(ANativeActivity *activity,
                                        void *saved, size_t savedSize) {
    JNIEnv *env = activity->env;
    gVm = activity->vm;
    gActivity = (*env)->NewGlobalRef(env, activity->clazz);

    /* GIVE THE WINDOW BACK TO THE VIEWS.  NativeActivity.onCreate takes the window's surface
     * (takeSurface) and its input queue (takeInputQueue) for native code, then calls us.  This
     * backend draws with real Android views instead -- a UXDrawView per window and native widget
     * overlays -- so with the surface taken nothing was ever composited (the screen stayed black),
     * and with the input queue taken every key and touch went to a queue nothing reads: real taps
     * never reached a widget, and the system Back never reached an OnBackInvokedCallback.  The
     * gates did not notice because they inject clicks and read state programmatically.  Handing
     * both back (null) here, still inside onCreate and before the decor is attached, makes it an
     * ordinary view-based window; the format goes back to RGBA_8888 from NativeActivity's RGB_565. */
    {
        jclass aC = (*env)->GetObjectClass(env, gActivity);
        jmethodID getWin = (*env)->GetMethodID(env, aC, "getWindow", "()Landroid/view/Window;");
        jobject w = (*env)->CallObjectMethod(env, gActivity, getWin);
        jclass wC = (*env)->FindClass(env, "android/view/Window");
        jmethodID takeS = (*env)->GetMethodID(env, wC, "takeSurface", "(Landroid/view/SurfaceHolder$Callback2;)V");
        jmethodID takeQ = (*env)->GetMethodID(env, wC, "takeInputQueue", "(Landroid/view/InputQueue$Callback;)V");
        jmethodID fmt = (*env)->GetMethodID(env, wC, "setFormat", "(I)V");
        (*env)->CallVoidMethod(env, w, takeS, NULL);
        (*env)->CallVoidMethod(env, w, takeQ, NULL);
        (*env)->CallVoidMethod(env, w, fmt, 1 /* PixelFormat.RGBA_8888 */);
        check(env, "untake surface/input");
    }

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
    LOADC(gTableCls, "UXTable")
    LOADC(gMenuCls, "UXMenuButton")
    LOADC(gPickerCls, "UXBridge$Picker")

    static const JNINativeMethod nb[] = {
        { "nativeFire", "(I)V", (void *)n_fire },
        { "nativeValue", "(II)V", (void *)n_value },
        { "nativeText", "(ILjava/lang/String;)V", (void *)n_text },
        { "nativeSubmit", "(I)V", (void *)n_submit },
    };
    static const JNINativeMethod nr[] = { { "nativeRun", "(I)V", (void *)n_run } };
    static const JNINativeMethod nd[] = { { "nativeDraw", "(ILandroid/graphics/Canvas;II)V", (void *)n_draw },
                                          { "nativeTouch", "(IIFF)V", (void *)n_touch } };
    (*env)->RegisterNatives(env, gBridgeCls, nb, 4);
    (*env)->RegisterNatives(env, gRunCls, nr, 1);
    (*env)->RegisterNatives(env, gDrawCls, nd, 2);
    static const JNINativeMethod nt[] = {
        { "nativeRows", "(I)I", (void *)n_tbl_rows },
        { "nativeCell", "(III)Ljava/lang/String;", (void *)n_tbl_cell },
        { "nativeCols", "(I)I", (void *)n_tbl_cols },
        { "nativeTitle", "(II)Ljava/lang/String;", (void *)n_tbl_title },
        { "nativeColWidth", "(II)I", (void *)n_tbl_width },
        { "nativeSelect", "(I[I)V", (void *)n_tbl_select },
        { "nativeLevel", "(II)I", (void *)n_tbl_level },
        { "nativeDisclosure", "(II)I", (void *)n_tbl_disclosure },
        { "nativeToggle", "(II)V", (void *)n_tbl_toggle },
    };
    (*env)->RegisterNatives(env, gTableCls, nt, 9);
    static const JNINativeMethod nm[] = { { "nativeMenuPick", "(II)V", (void *)n_menu_pick } };
    (*env)->RegisterNatives(env, gMenuCls, nm, 1);
    static const JNINativeMethod np[] = { { "nativePicked", "(Ljava/lang/String;)V", (void *)n_picked } };
    (*env)->RegisterNatives(env, gPickerCls, np, 1);
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
