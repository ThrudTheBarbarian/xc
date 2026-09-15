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

// android-glue.c — the NativeActivity entry point for `-A android --emit-apk`.
//
// This is the WHOLE glue. The NDK ships android_native_app_glue.c for this job,
// and we deliberately do not use it: it is 1600 lines of event-loop and
// lifecycle plumbing for an app that draws, and an xtc program packaged this way
// runs `main` and finishes. Everything it would give us goes unused, and
// vendoring it would mean carrying AOSP-derived code — and, once the toolchain
// stopped needing clang, AOSP-derived generated ASSEMBLY — for no gain.
//
// Leaving `activity->callbacks` zeroed is safe: the framework null-checks every
// one before calling it (frameworks/base's android_view_NativeActivity.cpp).
//
// Two things this must get right. It has to RETURN promptly — onCreate runs on
// the UI thread, and running the program there would hang the activity — hence
// the detached thread. And the program's output has to become visible: stdout
// and stderr are dup'd onto a pipe that a second thread drains into logcat, so
// the runtime's printf works UNCHANGED and knows nothing about Android.
//
// ONE source for both link paths: the clang path compiles this file, and the
// in-house path assembles glue-android.s, which is generated FROM it by
// gen-glue-android.sh. A second, hand-kept copy of it would drift.
#include <android/native_activity.h>
#include <android/log.h>
#include <unistd.h>
#include <pthread.h>
#include <stdio.h>

extern int xt_main(void);

// Reassemble LINES before writing. A logcat entry is a record, not a byte
// range, so emitting whatever read() happened to return splits the output at
// arbitrary buffer boundaries — `line 65` arrives as `l` followed by `ine 65`,
// which is a difference from the program's real stdout.
static void* xt_log_pump(void* a)
    {
    int fd = (int)(long)a;
    char b[512], line[1024];
    size_t n = 0;
    ssize_t r;
    while ((r = read(fd, b, sizeof b)) > 0)
        {
        ssize_t i;
        for (i = 0; i < r; i++)
            {
            char c = b[i];
            if (c == '\n' || n == sizeof line - 1)
                {
                line[n] = 0;
                __android_log_write(ANDROID_LOG_INFO, "xcapp", line);
                n = 0;
                if (c != '\n')
                    line[n++] = c;
                }
            else
                {
                line[n++] = c;
                }
            }
        }
    if (n)
        {
        line[n] = 0;
        __android_log_write(ANDROID_LOG_INFO, "xcapp", line);
        }
    return 0;
    }

static void* xt_activity_main(void* a)
    {
    ANativeActivity* activity = (ANativeActivity*)a;
    int p[2];
    if (pipe(p) == 0)
        {
        dup2(p[1], 1);
        dup2(p[1], 2);
        setvbuf(stdout, 0, _IOLBF, 0);
        setvbuf(stderr, 0, _IONBF, 0);
        pthread_t pump;
        pthread_create(&pump, 0, xt_log_pump, (void*)(long)p[0]);
        }
    __android_log_write(ANDROID_LOG_INFO, "xcapp", "=== xc start ===");
    xt_main();
    fflush(NULL);
    usleep(200000); /* let the pump drain before the marker */
    __android_log_write(ANDROID_LOG_INFO, "xcapp", "=== xc finished ===");
    ANativeActivity_finish(activity);
    return 0;
    }

void ANativeActivity_onCreate(ANativeActivity* activity, void* saved, size_t savedSize)
    {
    (void)saved;
    (void)savedSize;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t t;
    pthread_create(&t, &attr, xt_activity_main, activity);
    pthread_attr_destroy(&attr);
    }
