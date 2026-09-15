// xcc runtime library.
//
// Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
//
// This file is part of the xcc runtime library: the code that is combined
// with a program when xcc compiles it. It is free software; you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// Under Section 7 of GPL version 3, you are granted additional permissions
// described in the GCC Runtime Library Exception, version 3.1, as published
// by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
// parent.
//
// The effect of that exception is the point: a program compiled by xcc
// contains parts of this file, and the exception is what leaves that program
// under whatever licence its author chooses, including a proprietary one.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

// Platform.xc — Windows (win64) platform prelude.
//
// Auto-included before every win64 compilation so the Win32 system bindings are
// present without the user's source naming them. This is where the GEM Windows
// backend reaches the native API — link the GUI system DLLs here, and declare
// the common Win32 signatures a program (or GEM) calls.
//
// The Win64 ABI matches xtc's native calling convention, so these are plain
// extern declarations: pointers are `pointer`, DWORD/UINT/BOOL/int are i32/u32.

#import <kernel32>
#import <user32>
#import <gdi32>

// ── A few load-bearing Win32 entry points (extend as GEM needs them) ─────────
// kernel32
i32 lstrlenA(u8* s);
u32 GetTickCount(void);
u32 GetLastError(void);

// user32 — windows, messages, metrics
i32 GetSystemMetrics(i32 index);
i32 MessageBoxA(pointer hwnd, u8* text, u8* caption, u32 type);
i32 EnumWindows(pointer proc, pointer lparam);

// The cross-platform surface (Url / Log / Platform — task #36): ambient on
// every target, defaults wired lazily in the classes themselves.
#import "PlatformCore.xc"
