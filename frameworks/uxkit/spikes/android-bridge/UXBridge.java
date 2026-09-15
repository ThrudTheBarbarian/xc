// UXBridge.java — THE bootstrap artifact for the Android backend (the spike's
// subject).  Compiled ONCE with real Java tooling (javac + d8) and committed
// as classes.dex — the way an ObjC compiler bootstraps xcc.  At runtime it is
// loaded by the app's own class loader (the dex rides in the APK beside the
// NativeActivity manifest), and it is the ONLY Java in the entire stack:
// every widget callback funnels through here into one registered native.
//
// Regenerate (maintainers only):
//   javac --release 8 UXBridge.java && d8 UXBridge.class && commit classes.dex
import android.view.View;

public class UXBridge implements View.OnClickListener {
    private final int id;
    public UXBridge(int id) { this.id = id; }

    private static native void nativeFire(int id);

    @Override public void onClick(View v) { nativeFire(id); }
}
