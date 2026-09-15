// UXBridge.java — the Android backend's ONE Java source (the bootstrap
// artifact; see spikes/android-bridge).  A handful of tiny classes: the
// listener bridge (grown to the full listener set the widget overlays
// need), the UI-thread runnable, and the custom-draw view — every one a
// funnel into a RegisterNatives-bound native.  Compiled once by a
// maintainer (javac + d8), committed as classes.dex, shipped in the APK.
//
// Regenerate:
//   javac --release 8 -cp $ANDROID_HOME/platforms/android-35/android.jar UXBridge.java
//   d8 UXBridge*.class UXRun.class UXDrawView.class --lib .../android.jar --output .
import android.content.Context;
import android.content.DialogInterface;
import android.graphics.Canvas;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.View;
import android.widget.AdapterView;
import android.widget.CompoundButton;
import android.widget.SeekBar;

public class UXBridge implements View.OnClickListener, SeekBar.OnSeekBarChangeListener,
        AdapterView.OnItemSelectedListener, TextWatcher,
        DialogInterface.OnClickListener, DialogInterface.OnCancelListener {
    private final int id;
    public UXBridge(int id) { this.id = id; }
    private static native void nativeFire(int id);
    private static native void nativeValue(int id, int value);
    private static native void nativeText(int id, String s);

    // buttons and toggles (a toggle's click reports its new state)
    @Override public void onClick(View v) {
        if (v instanceof CompoundButton) {
            nativeValue(id, ((CompoundButton)v).isChecked() ? 1 : 0);
        } else {
            nativeFire(id);
        }
    }
    // SeekBar (slider)
    @Override public void onProgressChanged(SeekBar s, int p, boolean fromUser) {
        if (fromUser) nativeValue(id, p);
    }
    @Override public void onStartTrackingTouch(SeekBar s) { }
    @Override public void onStopTrackingTouch(SeekBar s) { }
    // Spinner (popup)
    @Override public void onItemSelected(AdapterView<?> parent, View v, int pos, long rowId) {
        nativeValue(id, pos);
    }
    @Override public void onNothingSelected(AdapterView<?> parent) { }
    // EditText (field)
    @Override public void beforeTextChanged(CharSequence s, int a, int b, int c) { }
    @Override public void onTextChanged(CharSequence s, int a, int b, int c) { }
    @Override public void afterTextChanged(Editable e) { nativeText(id, e.toString()); }
    // AlertDialog buttons (which: -1 positive, -2 negative, -3 neutral) and its
    // cancel (back / outside tap) — the modal alert's whole listener surface
    @Override public void onClick(DialogInterface d, int which) { nativeValue(id, which); }
    @Override public void onCancel(DialogInterface d) { nativeFire(id); }
}

class UXRun implements Runnable {
    private final int id;
    public UXRun(int id) { this.id = id; }
    private static native void nativeRun(int id);
    @Override public void run() { nativeRun(id); }
}

class UXDrawView extends View {
    private final int id;
    public UXDrawView(Context c, int id) { super(c); this.id = id; }
    private static native void nativeDraw(int id, Canvas canvas, int w, int h);
    @Override protected void onDraw(Canvas canvas) {
        nativeDraw(id, canvas, getWidth(), getHeight());
    }
}
