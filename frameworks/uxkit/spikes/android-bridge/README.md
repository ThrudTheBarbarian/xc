# android-bridge — the bridge-dex spike (the Java-widget shim mechanism)

**Result: PASS on the emulator:**

    spike: UXBridge via activity.getClassLoader() (FindClass context was system loader)
    spike: real Button is the content view
    PASS: bridge fired, native heard id=42

**The mechanism.** A NativeActivity app already hosts a full ART VM, so the
widget toolkit is in the process, unreached. The shim reaches it by pure JNI
name-lookup (`new android.widget.Button`, `setContentView`, `setText`), with no
Java source and no JDK in any user build. The one thing JNI cannot do is define
a Java class, which callbacks need (`OnClickListener` is an interface). That
class is **UXBridge, the bootstrap artifact**. It is compiled once with real
tooling (javac 25 + d8, as the Objective-C compiler bootstraps xcc) and
committed as a **900-byte classes.dex** that rides in the APK. Every widget
callback funnels through it into one `RegisterNatives`-bound native.

**Findings, each relevant to production:**

1. `android:hasCode="false"` (the native-APK default) makes ART SKIP
   classes.dex entirely, so the dex needs `hasCode="true"`. The compiler's
   ApkWriter needs a flag and a classes.dex entry (a one-line toggle and a zip
   member; it already writes the manifest).
2. `FindClass` from a native frame resolves against the SYSTEM loader even
   under onCreate. The robust recipe is
   `activity.getClassLoader().loadClass("UXBridge")`, done here with
   FindClass kept as the fast path.
3. R+ install rules: if a `resources.arsc` is included (aapt2-linked manifests
   bring one), it must be STORED uncompressed and 4-aligned. Re-zipping an APK
   naively breaks installs with a -124.
4. onCreate runs on the UI thread in a Java frame. That is the right moment to
   wire everything, and matches the B+A shape the iOS driver uses.

**Files:** `UXBridge.java` (the one Java file in the stack; regen:
`javac --release 8 -cp android.jar UXBridge.java && d8 UXBridge.class --lib
android.jar`), `classes.dex` (the committed artifact), `bridge_spike.c`
(the proof), `AndroidManifest.xml` (the hasCode=true variant),
`run.sh` (repack + install + logcat gate).

**Production shape:** `UXAndroidDriver` + `libUXAndroid.c` in the established
pattern. realizeTree works by JNI (`FrameLayout` + `setTranslationX/Y` for
absolute layout, no subclassing), UXBridge grows to the listener set (click,
text, value), the fire/value/field seams are identical to the other five
backends, and `formFactorClass` comes from screen size.
