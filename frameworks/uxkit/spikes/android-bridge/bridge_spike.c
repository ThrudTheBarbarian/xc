/* bridge_spike.c — the Android bridge-dex spike: from a NativeActivity's
 * onCreate (a Java frame, ON the UI thread), reach up into ART by pure JNI
 * name-lookup: create a REAL android.widget.Button, set it as the content
 * view, wire a UXBridge listener (the committed dex artifact), register the
 * native it forwards to, and performClick() — proving the whole
 * widget-shim mechanism with no Java toolchain anywhere near the USER's
 * build.  PASS/FAIL via logcat. */
#include <jni.h>
#include <android/log.h>
#include <android/native_activity.h>

#define LOG(...) __android_log_print(ANDROID_LOG_INFO, "UXSPIKE", __VA_ARGS__)

static void spike_fire(JNIEnv* env, jclass cls, jint id)
    {
    LOG("PASS: bridge fired, native heard id=%d", id);
    }

static int check(JNIEnv* env, const char* what)
    {
    if ((*env)->ExceptionCheck(env))
        {
        LOG("FAIL: exception at %s", what);
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        return 0;
        }
    return 1;
    }

JNIEXPORT void ANativeActivity_onCreate(ANativeActivity* activity,
                                        void* saved, size_t savedSize)
    {
    JNIEnv* env = activity->env;
    jobject act = activity->clazz;
    LOG("spike: onCreate, UI thread, Java frame below us");

    /* The bridge class.  FindClass's loader context from a native frame is
     * unreliable even under onCreate, so the PRODUCTION recipe is explicit:
     * activity.getClassLoader().loadClass("UXBridge"). */
    jclass bridgeCls = (*env)->FindClass(env, "UXBridge");
    if (!bridgeCls)
        {
        (*env)->ExceptionClear(env);
        jclass actC = (*env)->GetObjectClass(env, act);
        jmethodID getCl = (*env)->GetMethodID(env, actC, "getClassLoader",
                                              "()Ljava/lang/ClassLoader;");
        jobject loader = (*env)->CallObjectMethod(env, act, getCl);
        jclass clCls = (*env)->GetObjectClass(env, loader);
        jmethodID loadClass = (*env)->GetMethodID(env, clCls, "loadClass",
                                                  "(Ljava/lang/String;)Ljava/lang/Class;");
        bridgeCls = (jclass)(*env)->CallObjectMethod(env, loader, loadClass,
                                                     (*env)->NewStringUTF(env, "UXBridge"));
        if (!check(env, "loadClass UXBridge") || !bridgeCls)
            {
            LOG("FAIL: no UXBridge via app loader");
            return;
            }
        LOG("spike: UXBridge via activity.getClassLoader() (FindClass context was system loader)");
        }
    else
        {
        LOG("spike: UXBridge via FindClass");
        }

    static const JNINativeMethod natives[] = {
        {"nativeFire", "(I)V", (void*)spike_fire},
    };
    (*env)->RegisterNatives(env, bridgeCls, natives, 1);
    if (!check(env, "RegisterNatives"))
        return;

    /* A real android.widget.Button, by name. */
    jclass btnCls = (*env)->FindClass(env, "android/widget/Button");
    jmethodID btnInit = (*env)->GetMethodID(env, btnCls, "<init>",
                                            "(Landroid/content/Context;)V");
    jobject btn = (*env)->NewObject(env, btnCls, btnInit, act);
    if (!check(env, "new Button"))
        return;

    jmethodID setText = (*env)->GetMethodID(env, btnCls, "setText",
                                            "(Ljava/lang/CharSequence;)V");
    (*env)->CallVoidMethod(env, btn, setText, (*env)->NewStringUTF(env, "Tap"));
    if (!check(env, "setText"))
        return;

    jclass actCls = (*env)->GetObjectClass(env, act);
    jmethodID setContent = (*env)->GetMethodID(env, actCls, "setContentView",
                                               "(Landroid/view/View;)V");
    (*env)->CallVoidMethod(env, act, setContent, btn);
    if (!check(env, "setContentView"))
        return;
    LOG("spike: real Button is the content view");

    /* The bridge instance, wired as the listener. */
    jmethodID brInit = (*env)->GetMethodID(env, bridgeCls, "<init>", "(I)V");
    jobject bridge = (*env)->NewObject(env, bridgeCls, brInit, 42);
    jmethodID setL = (*env)->GetMethodID(env, btnCls, "setOnClickListener",
                                         "(Landroid/view/View$OnClickListener;)V");
    (*env)->CallVoidMethod(env, btn, setL, bridge);
    if (!check(env, "setOnClickListener"))
        return;

    /* The proof: the REAL click path — performClick runs the listener. */
    jmethodID perform = (*env)->GetMethodID(env, btnCls, "performClick", "()Z");
    (*env)->CallBooleanMethod(env, btn, perform);
    check(env, "performClick");
    LOG("spike: performClick dispatched");
    }
