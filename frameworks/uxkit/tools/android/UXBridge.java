// UXBridge.java — the Android backend's ONE Java source (the bootstrap
// artifact; see spikes/android-bridge).  A handful of tiny classes: the
// listener bridge (grown to the full listener set the widget overlays
// need), the UI-thread runnable, and the custom-draw view — every one a
// funnel into a RegisterNatives-bound native.  Compiled once by a
// maintainer (javac + d8), committed as classes.dex, shipped in the APK.
//
// Regenerate:
//   javac --release 8 -cp $ANDROID_HOME/platforms/android-35/android.jar UXBridge.java
//   d8 *.class --lib .../android.jar --min-api 26 --output .
import android.content.Context;
import android.content.DialogInterface;
import android.graphics.Canvas;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.KeyEvent;
import android.view.View;
import android.view.inputmethod.EditorInfo;
import android.widget.AdapterView;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.TextView;
import android.widget.SeekBar;

public class UXBridge implements View.OnClickListener, SeekBar.OnSeekBarChangeListener,
        AdapterView.OnItemSelectedListener, TextWatcher, TextView.OnEditorActionListener,
        DialogInterface.OnClickListener, DialogInterface.OnCancelListener {
    private final int id;
    public UXBridge(int id) { this.id = id; }
    private static native void nativeFire(int id);
    private static native void nativeValue(int id, int value);
    private static native void nativeText(int id, String s);
    private static native void nativeSubmit(int id);

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
    // Return / the soft keyboard's done key: "the line is done", not a character.  The key can
    // arrive as a real ENTER key event (a hardware keyboard) or as the IME's action id (the soft
    // keyboard), and the two never come together, so both are tested.
    @Override public boolean onEditorAction(TextView v, int actionId, KeyEvent ev) {
        boolean done = (ev != null && ev.getKeyCode() == KeyEvent.KEYCODE_ENTER
                        && ev.getAction() == KeyEvent.ACTION_DOWN)
                    || actionId == EditorInfo.IME_ACTION_DONE
                    || actionId == EditorInfo.IME_ACTION_GO
                    || actionId == EditorInfo.IME_ACTION_SEND
                    || actionId == EditorInfo.IME_ACTION_SEARCH;
        if (done) { nativeSubmit(id); return true; }
        return false;
    }
    // AlertDialog buttons (which: -1 positive, -2 negative, -3 neutral) and its
    // cancel (back / outside tap) — the modal alert's whole listener surface
    @Override public void onClick(DialogInterface d, int which) { nativeValue(id, which); }
    @Override public void onCancel(DialogInterface d) { nativeFire(id); }

    // UXScrollView: a real android.widget.ScrollView, which owns the offset, the fling and the edge
    // effect.  Its child is a FrameLayout DOCUMENT, the content's height, holding the draw view that
    // paints the scroll view's document subtree (a UXDrawView whose id names the scroll node) and
    // any native control inside the scroll view, placed by translation as the window's are.
    public static View scroller(android.app.Activity a, View draw, int w, int h, int docH) {
        UXScroller sv = new UXScroller(a);
        sv.setFillViewport(false);
        android.widget.FrameLayout doc = new android.widget.FrameLayout(a);
        doc.addView(draw, w, Math.max(docH, h));
        sv.addView(doc, new android.widget.FrameLayout.LayoutParams(w, Math.max(docH, h)));
        return sv;
    }
    public static void scrollerReload(View sv, int w, int h, int docH) {
        android.view.ViewGroup doc = (android.view.ViewGroup) ((android.view.ViewGroup) sv).getChildAt(0);
        View draw = doc.getChildAt(0);
        android.view.ViewGroup.LayoutParams lp = doc.getLayoutParams();
        lp.width = w;
        lp.height = Math.max(docH, h);
        doc.setLayoutParams(lp);
        android.view.ViewGroup.LayoutParams dp = draw.getLayoutParams();
        dp.width = w;
        dp.height = Math.max(docH, h);
        draw.setLayoutParams(dp);
        draw.invalidate();
    }
    public static void scrollerInvalidate(View sv) {
        ((android.view.ViewGroup) ((android.view.ViewGroup) sv).getChildAt(0)).getChildAt(0).invalidate();
    }
    public static void scrollerSet(View sv, int px) { ((android.widget.ScrollView) sv).scrollTo(0, px); }
    public static int scrollerGet(View sv) { return sv.getScrollY(); }
    // A rounded panel: the scroller clips its content to the rounded rect and strokes the edge over it
    // (UXScroller.dispatchDraw), which holds on a software canvas as on the screen's.
    public static void scrollerStyle(View sv, float radius, int rgb, float border) {
        UXScroller s = (UXScroller) sv;
        s.radius = radius;
        s.edgeRGB = rgb;
        s.edgeW = Math.max(1f, border);
        s.invalidate();
    }
    // a native control into the document, at (x, y) in it
    public static void scrollerAdopt(View sv, View child, int x, int y, int w, int h) {
        android.view.ViewGroup doc = (android.view.ViewGroup) ((android.view.ViewGroup) sv).getChildAt(0);
        if (child.getParent() != doc) {
            if (child.getParent() instanceof android.view.ViewGroup) ((android.view.ViewGroup) child.getParent()).removeView(child);
            doc.addView(child, w, h);
        }
        child.setTranslationX(x);
        child.setTranslationY(y);
    }
    public static boolean scrollerHolds(View sv, View child) {
        return child.getParent() == ((android.view.ViewGroup) sv).getChildAt(0);
    }

    // UXToolbar: a real android.widget.Toolbar.  Its buttons are action items of its menu, shown as
    // room allows, with the rest under the platform's own overflow (UXToolbar's overflow, natively);
    // a tap reports the item's tag through nativeValue.  A Toolbar lays its actions out at the end, so
    // UXToolbar's spaces have no counterpart here and are not added.
    public static View toolbar(android.app.Activity a, final int id) {
        android.widget.Toolbar t = new android.widget.Toolbar(a);
        t.setOnMenuItemClickListener(new android.widget.Toolbar.OnMenuItemClickListener() {
            @Override public boolean onMenuItemClick(android.view.MenuItem item) { nativeValue(id, item.getItemId()); return true; }
        });
        return t;
    }
    public static void toolbarAdd(View t, String label, int tag) {
        android.view.Menu m = ((android.widget.Toolbar) t).getMenu();
        android.view.MenuItem it = m.add(0, tag, m.size(), label);
        it.setShowAsAction(android.view.MenuItem.SHOW_AS_ACTION_IF_ROOM | android.view.MenuItem.SHOW_AS_ACTION_WITH_TEXT);
    }
    // tests: the menu's items, and an item's title
    public static int toolbarCount(View t) {
        return t instanceof android.widget.Toolbar ? ((android.widget.Toolbar) t).getMenu().size() : -1;
    }
    public static String toolbarTitle(View t, int i) {
        android.view.Menu m = ((android.widget.Toolbar) t).getMenu();
        return i >= 0 && i < m.size() ? String.valueOf(m.getItem(i).getTitle()) : "";
    }

    // UXSegmentedControl: Android has no platform segmented control, so it is composed of native
    // ToggleButtons in a row (Material's segmented button is the same shape).  A tap reports the
    // segment's index through nativeValue, as a slider reports its value; in a single-selection control
    // it also checks that one and unchecks the rest, in a multiple-selection one it toggles only itself.
    public static View segmented(android.app.Activity a, final int id, int n, int w, int h, final boolean multi) {
        final android.widget.LinearLayout box = new android.widget.LinearLayout(a);
        box.setOrientation(android.widget.LinearLayout.HORIZONTAL);
        int each = n > 0 ? w / n : w;
        for (int i = 0; i < n; i++) {
            final android.widget.ToggleButton b = new android.widget.ToggleButton(a);
            final int seg = i;
            b.setTextOn("");
            b.setTextOff("");
            b.setText("");
            b.setMinHeight(0); b.setMinimumHeight(0); b.setMinWidth(0); b.setMinimumWidth(0);
            b.setPadding(0, 0, 0, 0);
            b.setOnClickListener(new View.OnClickListener() {
                @Override public void onClick(View v) { if (!multi) segSelect(box, seg); nativeValue(id, seg); }
            });
            box.addView(b, i == n - 1 ? w - each * (n - 1) : each, h);
        }
        return box;
    }
    public static void segLabel(View box, int i, String label) {
        android.view.ViewGroup g = (android.view.ViewGroup) box;
        if (i < 0 || i >= g.getChildCount()) return;
        android.widget.ToggleButton b = (android.widget.ToggleButton) g.getChildAt(i);
        b.setTextOn(label);
        b.setTextOff(label);
        b.setText(label);
    }
    public static void segSet(View box, int i, boolean on) {
        android.view.ViewGroup g = (android.view.ViewGroup) box;
        if (i >= 0 && i < g.getChildCount()) ((android.widget.ToggleButton) g.getChildAt(i)).setChecked(on);
    }
    public static void segSelect(View box, int sel) {
        android.view.ViewGroup g = (android.view.ViewGroup) box;
        for (int i = 0; i < g.getChildCount(); i++)
            ((android.widget.ToggleButton) g.getChildAt(i)).setChecked(i == sel);
    }
    // tests: which segment is checked (-1 none), and a segment's centre on the screen
    public static int segSelected(View box) {
        android.view.ViewGroup g = (android.view.ViewGroup) box;
        for (int i = 0; i < g.getChildCount(); i++)
            if (((android.widget.ToggleButton) g.getChildAt(i)).isChecked()) return i;
        return -1;
    }
    public static int segCount(View box) {
        return box instanceof android.view.ViewGroup ? ((android.view.ViewGroup) box).getChildCount() : 0;
    }
    public static String segText(View box, int i) {
        android.view.ViewGroup g = (android.view.ViewGroup) box;
        return i >= 0 && i < g.getChildCount() ? String.valueOf(((android.widget.ToggleButton) g.getChildAt(i)).getText()) : "";
    }
    public static int[] segCentre(View box, int i) {
        android.view.ViewGroup g = (android.view.ViewGroup) box;
        int[] at = new int[2];
        View b = g.getChildAt(i);
        b.getLocationOnScreen(at);
        return new int[] { at[0] + b.getWidth() / 2, at[1] + b.getHeight() / 2 };
    }

    // UXWindow.snapshot: the window's FrameLayout and every view on it (the draw view, with the GL frame
    // painted into it, and the native widgets) drawn into a bitmap at the toolkit's scale, one pixel a
    // dp, over the window's white: w * h 0xAARRGGBB ints, top row first, for the region (x, y, w, h).
    public static int[] snapshot(View v, int x, int y, int w, int h, float density) {
        android.graphics.Bitmap b = android.graphics.Bitmap.createBitmap(w, h, android.graphics.Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(b);
        c.drawColor(0xFFFFFFFF);
        c.translate(-x, -y);
        c.scale(1f / density, 1f / density);
        v.draw(c);
        int[] px = new int[w * h];
        b.getPixels(px, 0, w, 0, 0, w, h);
        b.recycle();
        return px;
    }

    // The system's document picker (ACTION_OPEN_DOCUMENT) for UXOpenPanel.  A NativeActivity cannot be
    // handed an activity result, so a headless Fragment starts the picker and receives it.  The picked
    // document (a content: URI, possibly from a cloud provider) is copied into the app's cache under its
    // display name, so that UXFileIO's plain fopen reads it; the path, or null if the user backed out,
    // goes back through nativePicked, which unwinds the shim's nested loop.  It is a PUBLIC static
    // nested class (UXBridge$Picker) because Android insists a Fragment be public, to recreate it, and a
    // source file may hold only one public top-level class.
    public static class Picker extends android.app.Fragment {
        private static native void nativePicked(String path);
        static void open(android.app.Activity a) {
            Picker f = new Picker();
            a.getFragmentManager().beginTransaction().add(f, "uxpick").commitNow();
            android.content.Intent i = new android.content.Intent(android.content.Intent.ACTION_OPEN_DOCUMENT);
            i.addCategory(android.content.Intent.CATEGORY_OPENABLE);
            i.setType("*/*");
            f.startActivityForResult(i, 7);
        }
        // UXSavePanel: ACTION_CREATE_DOCUMENT asks where the document goes, and under what name, before
        // anything is written.  The path given back is a staging file in the cache under the name the
        // provider settled on; export() copies each write of it on to the document.
        private static final java.util.HashMap<String, android.net.Uri> exports = new java.util.HashMap<>();
        static void create(android.app.Activity a, String name) {
            Picker f = new Picker();
            a.getFragmentManager().beginTransaction().add(f, "uxpick").commitNow();
            android.content.Intent i = new android.content.Intent(android.content.Intent.ACTION_CREATE_DOCUMENT);
            i.addCategory(android.content.Intent.CATEGORY_OPENABLE);
            i.setType("application/octet-stream");
            i.putExtra(android.content.Intent.EXTRA_TITLE, name);
            f.startActivityForResult(i, 8);
        }
        // after a write of a staging file lands: copy it on to its document (true if there is none)
        static boolean export(android.app.Activity a, String path) {
            android.net.Uri uri = exports.get(path);
            if (uri == null) return true;
            try (java.io.InputStream in = new java.io.FileInputStream(path);
                 java.io.OutputStream os = a.getContentResolver().openOutputStream(uri, "wt")) {
                byte[] buf = new byte[65536];
                for (int n; (n = in.read(buf)) > 0; ) os.write(buf, 0, n);
                return true;
            } catch (Exception e) { return false; }
        }
        private static String displayName(android.app.Activity a, android.net.Uri uri, String dflt) {
            try (android.database.Cursor c = a.getContentResolver().query(uri,
                    new String[] { android.provider.OpenableColumns.DISPLAY_NAME }, null, null, null)) {
                if (c != null && c.moveToFirst() && c.getString(0) != null) return c.getString(0);
            } catch (Exception e) { }
            return dflt;
        }
        @Override public void onActivityResult(int req, int res, android.content.Intent data) {
            String path = null;
            android.app.Activity a = getActivity();
            if (req == 8) {
                if (res == android.app.Activity.RESULT_OK && data != null && data.getData() != null && a != null) {
                    android.net.Uri uri = data.getData();
                    java.io.File dir = new java.io.File(a.getCacheDir(), "saved");
                    dir.mkdirs();
                    java.io.File f = new java.io.File(dir, displayName(a, uri, "untitled").replace('/', '_'));
                    try { f.createNewFile(); path = f.getAbsolutePath(); exports.put(path, uri); }
                    catch (Exception e) { path = null; }
                }
                if (a != null) a.getFragmentManager().beginTransaction().remove(this).commitAllowingStateLoss();
                nativePicked(path);
                return;
            }
            if (res == android.app.Activity.RESULT_OK && data != null && data.getData() != null && a != null) {
                android.net.Uri uri = data.getData();
                String name = displayName(a, uri, "picked");
                java.io.File dir = new java.io.File(a.getCacheDir(), "picked");
                dir.mkdirs();
                java.io.File out = new java.io.File(dir, name.replace('/', '_'));
                try (java.io.InputStream in = a.getContentResolver().openInputStream(uri);
                     java.io.OutputStream os = new java.io.FileOutputStream(out)) {
                    byte[] buf = new byte[65536];
                    for (int n; (n = in.read(buf)) > 0; ) os.write(buf, 0, n);
                    path = out.getAbsolutePath();
                } catch (Exception e) { path = null; }
            }
            if (a != null) a.getFragmentManager().beginTransaction().remove(this).commitAllowingStateLoss();
            nativePicked(path);
        }
    }
}

// Back (gesture or button) while a navigation stack has something to pop -- registered with the
// window's OnBackInvokedDispatcher only then, so Back at the root still leaves the app.  Its own
// class because the interface is API 33+: UXBridge has to load on every supported version, and a
// class implementing a missing interface does not.  Only loaded when SDK_INT >= 33.
class UXBack implements android.window.OnBackInvokedCallback {
    private final int id;
    public UXBack(int id) { this.id = id; }
    private static native void nativeBack(int id);
    @Override public void onBackInvoked() { nativeBack(id); }
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
    private static native void nativeTouch(int id, int action, float x, float y);
    @Override protected void onDraw(Canvas canvas) {
        nativeDraw(id, canvas, getWidth(), getHeight());
    }
    // the drawn content's touches -> UXKit's mouse events (UXTouch.xc); native widgets on top
    // take their own
    @Override public boolean onTouchEvent(android.view.MotionEvent e) {
        nativeTouch(id, e.getActionMasked(), e.getX(), e.getY());
        return true;
    }
}

// The native table: a UXTableView as a real ListView (with a header row of the column titles above
// it).  Like the other platforms' native tables it holds no data: the row count, each cell's text
// and the columns come from the peer UXTableView through natives, by the table's id.  A row the
// user taps goes back as the list's whole checked set; one the app selects is pushed in, muted.
class UXTable extends android.widget.LinearLayout implements AdapterView.OnItemClickListener {
    private final int id;
    private final float dp;
    private final android.widget.ListView list;
    private final android.widget.LinearLayout header;
    private final android.widget.BaseAdapter adapter;
    private boolean muted;
    private static native int nativeRows(int id);
    private static native String nativeCell(int id, int row, int col);
    private static native int nativeCols(int id);
    private static native String nativeTitle(int id, int col);
    private static native int nativeColWidth(int id, int col);
    private static native void nativeSelect(int id, int[] rows);
    // an OUTLINE is the same list: its flattened rows, indented by depth, with a disclosure arrow
    // in front of an item that can open; tapping the arrow opens or shuts it in the model
    private static native int nativeLevel(int id, int row);
    private static native int nativeDisclosure(int id, int row);
    private static native void nativeToggle(int id, int row);
    private final boolean outline;
    static final int INDENT = 16, ARROW = 24;
    static final int ROW_H = 32, HEAD_H = 28;
    public UXTable(Context c, int id, boolean multi, boolean outline) {
        super(c);
        this.id = id;
        this.outline = outline;
        this.dp = c.getResources().getDisplayMetrics().density;
        setOrientation(VERTICAL);
        setBackgroundColor(0xFFFFFFFF);
        header = new android.widget.LinearLayout(c);
        header.setBackgroundColor(0xFFF0F0F2);
        addView(header, new LayoutParams(LayoutParams.MATCH_PARENT, (int)(HEAD_H * dp)));
        list = new android.widget.ListView(c);
        list.setChoiceMode(multi ? android.widget.ListView.CHOICE_MODE_MULTIPLE
                                 : android.widget.ListView.CHOICE_MODE_SINGLE);
        list.setOnItemClickListener(this);
        adapter = new android.widget.BaseAdapter() {
            public int getCount() { return nativeRows(UXTable.this.id); }
            public Object getItem(int r) { return null; }
            public long getItemId(int r) { return r; }
            public View getView(int r, View old, android.view.ViewGroup parent) { return row(r, old); }
        };
        list.setAdapter(adapter);
        addView(list, new LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f));
        titles();
    }
    private int colW(int c) { return (int)(nativeColWidth(id, c) * dp); }
    private void titles() {
        header.removeAllViews();
        int n = nativeCols(id);
        boolean any = false;
        for (int c = 0; c < n; c++) {
            String t = nativeTitle(id, c);
            if (t != null && !t.isEmpty()) any = true;
            TextView l = new TextView(getContext());
            l.setText(t == null ? "" : t);
            l.setTextColor(0xFF6E6E73);
            l.setTextSize(13);
            l.setTypeface(android.graphics.Typeface.DEFAULT_BOLD);
            l.setGravity(android.view.Gravity.CENTER_VERTICAL);
            l.setPadding(c == 0 ? (int)(16 * dp) : 0, 0, 0, 0);
            header.addView(l, new LayoutParams(colW(c) + (c == 0 ? (int)(16 * dp) : 0), LayoutParams.MATCH_PARENT));
        }
        header.setVisibility(any ? View.VISIBLE : View.GONE);
    }
    private View row(int r, View old) {
        int n = Math.max(1, nativeCols(id));
        int first = outline ? 1 : 0; // an outline row's child 0 is its arrow
        android.widget.LinearLayout v = old instanceof android.widget.LinearLayout
                && ((android.widget.LinearLayout)old).getChildCount() == n + first ? (android.widget.LinearLayout)old : null;
        if (v == null) {
            v = new android.widget.LinearLayout(getContext());
            v.setMinimumHeight((int)(ROW_H * dp));
            // the checked row shows as activated (ListView activates a choice-mode row's view)
            android.graphics.drawable.StateListDrawable bg = new android.graphics.drawable.StateListDrawable();
            bg.addState(new int[] { android.R.attr.state_activated },
                        new android.graphics.drawable.ColorDrawable(0xFFD3E3FD));
            v.setBackground(bg);
            if (outline) {
                TextView a = new TextView(getContext());
                a.setTextColor(0xFF49454F);
                a.setTextSize(18);
                a.setGravity(android.view.Gravity.CENTER);
                // the arrow takes its own tap (the row's click is selection); the row it belongs to
                // is set at each bind, in the tag
                a.setOnClickListener(new View.OnClickListener() {
                    public void onClick(View av) { nativeToggle(UXTable.this.id, (Integer)av.getTag()); }
                });
                v.addView(a, new LayoutParams((int)(ARROW * dp), (int)(ROW_H * dp)));
            }
            for (int c = 0; c < n; c++) {
                TextView l = new TextView(getContext());
                l.setTextColor(0xFF1C1B1F);
                l.setTextSize(15);
                l.setSingleLine(true);
                l.setGravity(android.view.Gravity.CENTER_VERTICAL);
                l.setPadding(c == 0 && !outline ? (int)(16 * dp) : 0, 0, 0, 0);
                int w = c == n - 1 ? 0 : colW(c) + (c == 0 && !outline ? (int)(16 * dp) : 0);
                v.addView(l, new LayoutParams(w, (int)(ROW_H * dp), c == n - 1 ? 1f : 0f));
            }
        }
        if (outline) {
            int disc = nativeDisclosure(id, r);
            TextView a = (TextView)v.getChildAt(0);
            a.setTag(r);
            a.setText((disc & 1) == 0 ? "" : ((disc & 2) != 0 ? "\u25BE" : "\u25B8"));
            a.setClickable((disc & 1) != 0);
            v.setPadding((int)((8 + nativeLevel(id, r) * INDENT) * dp), 0, 0, 0);
        }
        for (int c = 0; c < n; c++) {
            String t = nativeCell(id, r, c);
            ((TextView)v.getChildAt(c + first)).setText(t == null ? "" : t);
        }
        return v;
    }
    public void onItemClick(AdapterView<?> p, View v, int pos, long rid) {
        if (muted) return;
        android.util.SparseBooleanArray ch = list.getCheckedItemPositions();
        int k = 0;
        int[] rows = new int[ch == null ? 0 : ch.size()];
        for (int i = 0; ch != null && i < ch.size(); i++)
            if (ch.valueAt(i)) rows[k++] = ch.keyAt(i);
        nativeSelect(id, java.util.Arrays.copyOf(rows, k));
    }
    public void reload() {
        muted = true;
        titles();
        adapter.notifyDataSetChanged();
        muted = false;
    }
    public void select(int[] rows) {
        muted = true;
        list.clearChoices();
        for (int r : rows) if (r < adapter.getCount()) list.setItemChecked(r, true);
        adapter.notifyDataSetChanged();
        muted = false;
    }
    // tests: the list's rows, a row's checked state, a cell's text as its view shows it, and a
    // USER's tap (performItemClick: the list's own choice handling, then the click listener)
    public int rowCount() { return adapter.getCount(); }
    public boolean isSelected(int r) { return list.isItemChecked(r); }
    public String cellText(int r, int c) {
        android.widget.LinearLayout v = (android.widget.LinearLayout)adapter.getView(r, null, list);
        return ((TextView)v.getChildAt(c + (outline ? 1 : 0))).getText().toString();
    }
    // tests: an outline row's arrow as shown ("" none, \u25B8 closed, \u25BE open), its indent
    // (the row's left padding, in dp), and where its arrow is on the screen, for a REAL tap
    public String arrowText(int r) {
        android.widget.LinearLayout v = (android.widget.LinearLayout)adapter.getView(r, null, list);
        return outline ? ((TextView)v.getChildAt(0)).getText().toString() : "";
    }
    public int indentDp(int r) {
        android.widget.LinearLayout v = (android.widget.LinearLayout)adapter.getView(r, null, list);
        return (int)(v.getPaddingLeft() / dp + 0.5f);
    }
    public int arrowScreenX(int r) { int[] p = new int[2]; View a = ((android.widget.LinearLayout)list.getChildAt(r)).getChildAt(0); a.getLocationOnScreen(p); return p[0] + a.getWidth() / 2; }
    public int arrowScreenY(int r) { int[] p = new int[2]; View a = ((android.widget.LinearLayout)list.getChildAt(r)).getChildAt(0); a.getLocationOnScreen(p); return p[1] + a.getHeight() / 2; }
    public void tap(int r) { list.performItemClick(adapter.getView(r, null, list), r, r); }
    // rows the list has really laid out (an empty data source shows none), and where row r is on
    // the screen in px, for a REAL tap from the gate (adb input tap)
    public int shownRows() { return list.getChildCount(); }
    public int rowScreenX(int r) { int[] p = new int[2]; list.getChildAt(r).getLocationOnScreen(p); return p[0] + list.getChildAt(r).getWidth() / 4; }
    public int rowScreenY(int r) { int[] p = new int[2]; list.getChildAt(r).getLocationOnScreen(p); return p[1] + list.getChildAt(r).getHeight() / 2; }
}

// The app's menus: a phone has no menu bar, so they hang from an overflow button (the platform's
// "more options" mark, at the top right) as a PopupMenu with a submenu per title.  The driver hands
// them over as one string (UXMenuEncode.xc): a title, its items after US (0x1f), RS (0x1e) closing
// it; an item "-" is a separator, a leading 0x01 checked, a leading 0x02 disabled.  A pick goes
// back as (title, item) through nativeMenuPick; check and enable changes come in through state().
class UXMenuButton extends TextView implements View.OnClickListener,
        android.widget.PopupMenu.OnMenuItemClickListener {
    private static native void nativeMenuPick(int title, int item);
    private final java.util.ArrayList<String> titles = new java.util.ArrayList<>();
    private final java.util.ArrayList<java.util.ArrayList<String[]>> items = new java.util.ArrayList<>(); // {text, checked, disabled, sep}
    android.widget.PopupMenu shown;
    public UXMenuButton(Context c) {
        super(c);
        setText("\u22EE");
        setTextSize(24);
        setTextColor(0xFF1C1B1F);
        setGravity(android.view.Gravity.CENTER);
        setContentDescription("Menu");
        setOnClickListener(this);
    }
    public void set(String enc) {
        titles.clear();
        items.clear();
        for (String group : enc.split("\u001e")) {
            if (group.isEmpty()) continue;
            String[] parts = group.split("\u001f", -1);
            titles.add(parts[0]);
            java.util.ArrayList<String[]> its = new java.util.ArrayList<>();
            for (int k = 1; k < parts.length; k++) {
                String p = parts[k];
                if (p.equals("-")) its.add(new String[] { "", "0", "0", "1" });
                else if (p.length() > 0 && p.charAt(0) == 1) its.add(new String[] { p.substring(1), "1", "0", "0" });
                else if (p.length() > 0 && p.charAt(0) == 2) its.add(new String[] { p.substring(1), "0", "1", "0" });
                else its.add(new String[] { p, "0", "0", "0" });
            }
            items.add(its);
        }
        setVisibility(titles.isEmpty() ? View.GONE : View.VISIBLE);
    }
    // what: 0 checked, 1 enabled
    public void state(int t, int j, int what, boolean on) {
        if (t < 0 || t >= items.size() || j < 0 || j >= items.get(t).size()) return;
        String[] it = items.get(t).get(j);
        if (what == 0) it[1] = on ? "1" : "0"; else it[2] = on ? "0" : "1";
    }
    public void onClick(View v) {
        android.widget.PopupMenu pm = new android.widget.PopupMenu(getContext(), this);
        for (int t = 0; t < titles.size(); t++) {
            android.view.SubMenu sm = pm.getMenu().addSubMenu(0, 0x10000 + t, t, titles.get(t));
            java.util.ArrayList<String[]> its = items.get(t);
            int group = 0;
            for (int j = 0; j < its.size(); j++) {
                String[] it = its.get(j);
                if (it[3].equals("1")) { group++; continue; } // a separator starts a new group
                android.view.MenuItem mi = sm.add(group, (t << 8) | j, j, it[0]);
                if (it[1].equals("1")) { mi.setCheckable(true); mi.setChecked(true); }
                mi.setEnabled(!it[2].equals("1"));
            }
            if (android.os.Build.VERSION.SDK_INT >= 28) sm.setGroupDividerEnabled(true);
        }
        pm.setOnMenuItemClickListener(this);
        shown = pm;
        pm.show();
    }
    public boolean onMenuItemClick(android.view.MenuItem mi) {
        int id = mi.getItemId();
        if (id >= 0x10000) return false; // a title: its submenu opens
        nativeMenuPick(id >> 8, id & 0xFF);
        return true;
    }
    // tests: the titles shown, an item as the menu would show it (1 there, 2 checked, 4 disabled)
    public int titleCount() { return getVisibility() == View.VISIBLE ? titles.size() : 0; }
    public String title(int t) { return t < titles.size() ? titles.get(t) : ""; }
    public int item(int t, int j) {
        if (t < 0 || t >= items.size() || j < 0 || j >= items.get(t).size()) return 0;
        String[] it = items.get(t).get(j);
        return it[3].equals("1") ? 0 : 1 | (it[1].equals("1") ? 2 : 0) | (it[2].equals("1") ? 4 : 0);
    }
}

// UXScrollView's container (UXBridge.scroller): a ScrollView that clips what it scrolls to a rounded
// rect, when it has a radius, and strokes its edge OVER the content.  Clipping to the outline would
// not do: a software canvas (a snapshot, View.draw onto a Bitmap) ignores it, and a background is drawn
// beneath the children, which would cover the edge.
class UXScroller extends android.widget.ScrollView {
    float radius, edgeW = 1f;
    int edgeRGB = -1;
    private final android.graphics.Path clip = new android.graphics.Path();
    private final android.graphics.Paint edge = new android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG);
    private final android.graphics.RectF box = new android.graphics.RectF();
    UXScroller(Context c) { super(c); }
    @Override protected void dispatchDraw(Canvas canvas) {
        // the visible rect, in the scrolled coordinates the children draw in
        box.set(getScrollX(), getScrollY(), getScrollX() + getWidth(), getScrollY() + getHeight());
        if (radius > 0) {
            clip.reset();
            clip.addRoundRect(box, radius, radius, android.graphics.Path.Direction.CW);
            canvas.save();
            canvas.clipPath(clip);
            super.dispatchDraw(canvas);
            canvas.restore();
        } else {
            super.dispatchDraw(canvas);
        }
        if (edgeRGB >= 0) {
            edge.setStyle(android.graphics.Paint.Style.STROKE);
            edge.setStrokeWidth(edgeW);
            edge.setColor(0xFF000000 | edgeRGB);
            float h = edgeW / 2f;
            box.inset(h, h);
            canvas.drawRoundRect(box, Math.max(0f, radius - h), Math.max(0f, radius - h), edge);
        }
    }
}

// The native text view (UXTextView): a multi-line EditText whose styles are spans.  The text crosses as
// UTF-8 bytes (not JNI's modified UTF-8, which splits an emoji in two) and style runs of five ints:
// byte start, byte length, flags (1 bold, 2 italic, 4 underline, 8 monospace, the paragraph's
// alignment in bits 4-5), colour (0, or 0x01RRGGBB) and size (0 = default, else dp).  A span is set
// EXCLUSIVE_INCLUSIVE, so text typed after a styled run takes its style; a style chosen at an empty
// selection is applied to the next insert.  The undo is the toolkit's: Control-Z and Control-Y go to it,
// and a caret moving because the text changed is not reported as the user moving it.
class UXTextEdit extends EditText implements TextWatcher {
    private static native void nativeTvChanged(int id);
    private static native void nativeTvSelected(int id);
    private static native void nativeTvUndo(int id, int redo);
    static final java.nio.charset.Charset U8 = java.nio.charset.StandardCharsets.UTF_8;
    static final int SPAN = android.text.Spanned.SPAN_EXCLUSIVE_INCLUSIVE;
    final int id;
    int quiet;
    int lastLen;
    int[] typing;          // flags, colour, size for the next insert, or null
    int insAt = -1, insN;  // the insert in flight
    // the spans this view sets, told apart from any a paste brings
    static class Bold extends android.text.style.StyleSpan { Bold() { super(android.graphics.Typeface.BOLD); } }
    static class Italic extends android.text.style.StyleSpan { Italic() { super(android.graphics.Typeface.ITALIC); } }
    static class Under extends android.text.style.UnderlineSpan { }
    static class Mono extends android.text.style.TypefaceSpan { Mono() { super("monospace"); } }
    static class Colour extends android.text.style.ForegroundColorSpan { Colour(int c) { super(c); } }
    static class Size extends android.text.style.AbsoluteSizeSpan { final int dp; Size(int dp) { super(dp, true); this.dp = dp; } }
    static class Align extends android.text.style.AlignmentSpan.Standard {
        final int code;
        Align(int code) {
            super(code == 1 ? android.text.Layout.Alignment.ALIGN_OPPOSITE
                  : code == 2 ? android.text.Layout.Alignment.ALIGN_CENTER : android.text.Layout.Alignment.ALIGN_NORMAL);
            this.code = code;
        }
    }

    UXTextEdit(Context c, int id) {
        super(c);
        this.id = id;
        setGravity(android.view.Gravity.TOP | android.view.Gravity.START);
        setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE |
                     android.text.InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        setSingleLine(false);
        setHorizontallyScrolling(false);
        setTextSize(android.util.TypedValue.COMPLEX_UNIT_DIP, 14);
        setText("", BufferType.EDITABLE);
        addTextChangedListener(this);
    }

    // ---- offsets: UTF-8 bytes <-> chars ----
    static int charOf(byte[] u, int bytes) {
        if (bytes <= 0) return 0;
        if (bytes > u.length) bytes = u.length;
        while (bytes > 0 && bytes < u.length && (u[bytes] & 0xC0) == 0x80) bytes--;
        return new String(u, 0, bytes, U8).length();
    }
    static int byteOf(String s, int chars) {
        if (chars <= 0) return 0;
        if (chars >= s.length()) return s.getBytes(U8).length;
        if (Character.isLowSurrogate(s.charAt(chars))) chars--;
        return s.substring(0, chars).getBytes(U8).length;
    }

    // ---- styles ----
    static boolean ours(Object sp) {
        return sp instanceof android.text.style.StyleSpan || sp instanceof android.text.style.UnderlineSpan ||
               sp instanceof android.text.style.TypefaceSpan || sp instanceof android.text.style.ForegroundColorSpan ||
               sp instanceof android.text.style.AbsoluteSizeSpan || sp instanceof android.text.style.AlignmentSpan;
    }
    // chars [a, b) in this style: every style span cut back out of the range, then the new ones on
    static void style(Editable e, int a, int b, int flags, int colour, int size) {
        if (b <= a) return;
        for (Object sp : e.getSpans(a, b, Object.class)) {
            if (!ours(sp)) continue;
            int s = e.getSpanStart(sp), t = e.getSpanEnd(sp);
            if (t <= a || s >= b) continue;
            e.removeSpan(sp);
            if (s < a) e.setSpan(clone(sp), s, a, SPAN);
            if (t > b) e.setSpan(clone(sp), b, t, SPAN);
        }
        if ((flags & 1) != 0) e.setSpan(new Bold(), a, b, SPAN);
        if ((flags & 2) != 0) e.setSpan(new Italic(), a, b, SPAN);
        if ((flags & 4) != 0) e.setSpan(new Under(), a, b, SPAN);
        if ((flags & 8) != 0) e.setSpan(new Mono(), a, b, SPAN);
        if ((colour & 0x1000000) != 0) e.setSpan(new Colour(0xFF000000 | (colour & 0xFFFFFF)), a, b, SPAN);
        if (size > 0) e.setSpan(new Size(size), a, b, SPAN);
        int al = (flags >> 4) & 3;
        if (al != 0) e.setSpan(new Align(al), a, b, SPAN);
    }
    static Object clone(Object sp) {
        if (sp instanceof Size) return new Size(((Size)sp).dp);
        if (sp instanceof Align) return new Align(((Align)sp).code);
        if (sp instanceof android.text.style.AbsoluteSizeSpan) return new android.text.style.AbsoluteSizeSpan(((android.text.style.AbsoluteSizeSpan)sp).getSize(), ((android.text.style.AbsoluteSizeSpan)sp).getDip());
        if (sp instanceof android.text.style.ForegroundColorSpan) return new Colour(((android.text.style.ForegroundColorSpan)sp).getForegroundColor());
        if (sp instanceof android.text.style.TypefaceSpan) return new Mono();
        if (sp instanceof android.text.style.UnderlineSpan) return new Under();
        if (sp instanceof android.text.style.StyleSpan) {
            int st = ((android.text.style.StyleSpan)sp).getStyle();
            return st == android.graphics.Typeface.ITALIC ? new Italic() : st == android.graphics.Typeface.BOLD_ITALIC
                   ? new android.text.style.StyleSpan(st) : new Bold();
        }
        if (sp instanceof android.text.style.AlignmentSpan) {
            android.text.Layout.Alignment a = ((android.text.style.AlignmentSpan)sp).getAlignment();
            return new Align(a == android.text.Layout.Alignment.ALIGN_OPPOSITE ? 1 : a == android.text.Layout.Alignment.ALIGN_CENTER ? 2 : 0);
        }
        return sp;
    }
    // the style of char i: flags, colour, size
    static int[] styleAt(android.text.Spanned e, int i) {
        int f = 0, c = 0, z = 0;
        for (Object sp : e.getSpans(i, i + 1, Object.class)) {
            int s = e.getSpanStart(sp), t = e.getSpanEnd(sp);
            if (s > i || t <= i) continue;
            if (sp instanceof android.text.style.StyleSpan) {
                int st = ((android.text.style.StyleSpan)sp).getStyle();
                if ((st & android.graphics.Typeface.BOLD) != 0) f |= 1;
                if ((st & android.graphics.Typeface.ITALIC) != 0) f |= 2;
            } else if (sp instanceof android.text.style.UnderlineSpan) f |= 4;
            else if (sp instanceof android.text.style.TypefaceSpan) {
                if ("monospace".equals(((android.text.style.TypefaceSpan)sp).getFamily())) f |= 8;
            } else if (sp instanceof android.text.style.ForegroundColorSpan)
                c = 0x1000000 | (((android.text.style.ForegroundColorSpan)sp).getForegroundColor() & 0xFFFFFF);
            else if (sp instanceof Size) z = ((Size)sp).dp;
            else if (sp instanceof Align) f |= (((Align)sp).code & 3) << 4;
            else if (sp instanceof android.text.style.AlignmentSpan) {
                android.text.Layout.Alignment a = ((android.text.style.AlignmentSpan)sp).getAlignment();
                f |= (a == android.text.Layout.Alignment.ALIGN_OPPOSITE ? 1 : a == android.text.Layout.Alignment.ALIGN_CENTER ? 2 : 0) << 4;
            }
        }
        return new int[] { f, c, z };
    }
    void applyRuns(Editable e, byte[] u, int base, int[] runs) {
        for (int k = 0; k + 4 < runs.length; k += 5) {
            int a = base + charOf(u, runs[k]), b = base + charOf(u, runs[k] + runs[k + 1]);
            style(e, a, b, runs[k + 2], runs[k + 3], runs[k + 4]);
        }
    }

    // ---- the seam ----
    void setAll(byte[] text, int[] runs) {
        quiet++;
        android.text.SpannableStringBuilder b = new android.text.SpannableStringBuilder(new String(text, U8));
        setText(b, BufferType.EDITABLE);
        Editable e = getText();
        applyRuns(e, text, 0, runs);
        lastLen = e.length();
        typing = null;
        setSelection(0);
        quiet--;
    }
    void replace(int start, int len, byte[] text, int[] runs, boolean attrsOnly) {
        quiet++;
        Editable e = getText();
        byte[] cur = e.toString().getBytes(U8);
        int a = charOf(cur, start), b = charOf(cur, start + len);
        int s0 = getSelectionStart(), s1 = getSelectionEnd();
        if (!attrsOnly) e.replace(a, b, new String(text, U8));
        int end = a + new String(text, U8).length();
        style(e, a, end, 0, 0, 0);
        applyRuns(e, text, a, runs);
        if (attrsOnly && s0 >= 0) setSelection(Math.min(s0, e.length()), Math.min(s1, e.length()));
        lastLen = e.length();
        quiet--;
    }
    byte[] textBytes() { return getText().toString().getBytes(U8); }
    int[] runs() {
        Editable e = getText();
        String s = e.toString();
        java.util.ArrayList<Integer> out = new java.util.ArrayList<>();
        int i = 0, n = s.length(), at = 0;
        while (i < n) {
            int j = e.nextSpanTransition(i, n, Object.class);
            if (j <= i) j = n;
            int[] st = styleAt(e, i);
            int nb = s.substring(i, j).getBytes(U8).length;
            int k = out.size();
            if (k >= 5 && out.get(k - 3) == st[0] && out.get(k - 2) == st[1] && out.get(k - 1) == st[2]) {
                out.set(k - 4, out.get(k - 4) + nb);
            } else {
                out.add(at); out.add(nb); out.add(st[0]); out.add(st[1]); out.add(st[2]);
            }
            at += nb;
            i = j;
        }
        int[] r = new int[out.size()];
        for (int k = 0; k < r.length; k++) r[k] = out.get(k);
        return r;
    }
    int[] selectionBytes() {
        String s = getText().toString();
        int a = Math.max(0, getSelectionStart()), b = Math.max(0, getSelectionEnd());
        int x = byteOf(s, Math.min(a, b)), y = byteOf(s, Math.max(a, b));
        return new int[] { x, y - x };
    }
    void setSelectionBytes(int start, int len) {
        byte[] u = textBytes();
        quiet++;
        setSelection(charOf(u, start), charOf(u, start + len));
        quiet--;
    }
    void setTyping(int flags, int colour, int size) { typing = new int[] { flags, colour, size }; }

    // ---- from the user ----
    @Override protected void onSelectionChanged(int s, int e) {
        super.onSelectionChanged(s, e);
        if (quiet > 0 || id == 0) return;
        int len = length();
        if (len != lastLen) { lastLen = len; return; } // the caret moving with an edit
        typing = null;
        nativeTvSelected(id);
    }
    @Override public void beforeTextChanged(CharSequence s, int a, int b, int c) { }
    @Override public void onTextChanged(CharSequence s, int start, int before, int count) {
        if (quiet == 0 && count > 0) { insAt = start; insN = count; }
    }
    @Override public void afterTextChanged(Editable e) {
        if (quiet > 0) return;
        if (insAt >= 0 && typing != null) {
            quiet++;
            style(e, insAt, Math.min(e.length(), insAt + insN), typing[0], typing[1], typing[2]);
            quiet--;
            typing = null;
        }
        insAt = -1;
        nativeTvChanged(id);
    }
    @Override public boolean onKeyDown(int code, KeyEvent ev) {
        if (ev.isCtrlPressed() && (code == KeyEvent.KEYCODE_Z || code == KeyEvent.KEYCODE_Y)) {
            nativeTvUndo(id, (code == KeyEvent.KEYCODE_Y || ev.isShiftPressed()) ? 1 : 0);
            return true;
        }
        return super.onKeyDown(code, ev);
    }
    // the rigs': text typed at the caret, as the keyboard commits it
    void testType(byte[] text) {
        Editable e = getText();
        int a = Math.max(0, getSelectionStart()), b = Math.max(0, getSelectionEnd());
        e.replace(Math.min(a, b), Math.max(a, b), new String(text, U8));
    }
}
