// UXBridge.java — the Android backend's ONE Java source (the bootstrap
// artifact; see spikes/android-bridge).  A handful of tiny classes: the
// listener bridge (grown to the full listener set the widget overlays
// need), the UI-thread runnable, and the custom-draw view — every one a
// funnel into a RegisterNatives-bound native.  Compiled once by a
// maintainer (javac + d8), committed as classes.dex, shipped in the APK.
//
// Regenerate:
//   javac --release 8 -cp $ANDROID_HOME/platforms/android-35/android.jar UXBridge.java
//   d8 UXBridge*.class UXBack.class UXRun.class UXDrawView.class UXTable*.class UXMenuButton*.class --lib .../android.jar --min-api 26 --output .
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
