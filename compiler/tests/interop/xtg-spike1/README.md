# Spike 1 — the first native driver (Win32)

Spike 1 of the multi-host GUI design: prove the opaque-handle + per-platform-driver
model against a *real* host toolkit, beyond the `.so` mechanics (Spike 0). Win32
comes first: reachable under Wine, pure C ABI, no Objective-C bridge.

`spike1_win32.xc` is a self-contained miniature of the model:

- **Neutral layer** (would live in `generic/lib`): `XGView` with virtual
  `drawRect(XGContext)` / `mouseDown(x,y)`, and `XGContext` with a portable
  `fillRect` primitive over a native DC.
- **Win32 driver** (would live in `win64/lib`): one shared `WndProc`. The
  `HWND` is the opaque handle; `GWLP_USERDATA` is the reverse map that recovers
  the `XGView` front object; drawing flows backend→view (`WM_PAINT` → reverse map
  → `drawRect`), and input the same (`WM_LBUTTONDOWN` → `mouseDown`).
- **App** (would be portable source): `MyView : XGView` overriding `drawRect`
  (paint a green rect via `XGContext.fillRect`) and `mouseDown` (report the point).

`main` creates the window, installs the reverse map, forces a paint, and injects
a click, so it runs headless and deterministic. Output (`expected.out`):

```
register=1        window class registered
window=1          real HWND created
fill=10,10,50,30  WM_PAINT -> reverse map -> MyView.drawRect -> XGContext.fillRect (GDI FillRect)
mouseDown=30,40   WM_LBUTTONDOWN -> reverse map -> MyView.mouseDown
done              clean message-loop exit
```

Run: `sh tests/interop/xtg-spike1/run.sh`

Proves: xtc drives the real Win32 API + GDI, receives OS window-proc callbacks,
recovers the front object from a native handle, and dispatches through the
neutral virtual `XGView` path into an app override. That is the whole driver
seam, on a real toolkit.
