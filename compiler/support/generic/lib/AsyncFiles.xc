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

// AsyncFiles.xc — Files, off the calling thread.
//
//     AsyncFiles.readText(path, block void(String* text) { … });
//     AsyncFiles.writeText(path, text, block void(bool ok) { … });
//     AsyncFiles.drain();            // wait for everything queued so far
//
// Each call queues the Files operation of the same name and returns at once.
// One worker thread runs the queue IN ORDER, so a write followed by a read of
// the same file reads what was written, and two appends land in the order
// they were made. The completion block runs on that worker thread: anything
// it shares with the rest of the program needs a Mutex, and a UI toolkit's
// objects should only be touched from the toolkit's own thread.
//
// A completion may be null when the caller does not need to know. Results
// are those of Files: a missing file reads as null, a failed write is false.
//
// Hosted targets only (arm64, android, x86_64, win64): the worker is a Thread.

#import "Files.xc"

#if ARCH_6502 || ARCH_m68k || ARCH_wasm32
#error "AsyncFiles: needs threads (arm64, android, x86_64, win64 or arm9)"
#endif

#import "Thread.xc"
#import "Mutex.xc"
#import "Cond.xc"

#define _AF_READ_TEXT 1
#define _AF_READ_DATA 2
#define _AF_WRITE_TEXT 3
#define _AF_WRITE_DATA 4
#define _AF_APPEND_TEXT 5

// One queued operation and whichever completion fits its result.
class _AsyncFileOp
    {
    u32 kind;
    String* path;
    String* text;
    Data* data;
    block onText void(String*);
    block onData void(Data*);
    block onDone void(bool);
    bool hasText;
    bool hasData;
    bool hasDone;

    void run(void)
        {
        if (kind == (u32)_AF_READ_TEXT)
            {
            String* t = Files.readText(path);
            if (hasText)
                onText(t);
            }
        else if (kind == (u32)_AF_READ_DATA)
            {
            Data* d = Files.readData(path);
            if (hasData)
                onData(d);
            }
        else
            {
            bool ok = false;
            if (kind == (u32)_AF_WRITE_TEXT)
                ok = Files.writeText(path, text);
            else if (kind == (u32)_AF_WRITE_DATA)
                ok = Files.writeData(path, data);
            else if (kind == (u32)_AF_APPEND_TEXT)
                ok = Files.appendText(path, text);
            if (hasDone)
                onDone(ok);
            }
        }
    }

// The queue and its one worker. `_busy` counts the operation being run, so
// drain() waits for it too and not only for an empty list.
class _AsyncFileQueue
    {
    Mutex* _lock;
    Cond* _ready;
    Cond* _idle;
    Array* _ops;
    u32 _busy;
    Thread* _worker;

    void init(void)
        {
        _lock = new Mutex();
        _ready = new Cond();
        _idle = new Cond();
        _ops = new Array();
        _busy = (u32)0;
        }

    void add(_AsyncFileOp* op)
        {
        _lock.lock();
        _ops.add((Object*)op);
        if (_worker == (Thread*)0)
            {
            _worker = Thread.spawn(&self.work);
            _worker.detach();
            }
        _ready.signal();
        _lock.unlock();
        }

    void drain(void)
        {
        _lock.lock();
        while (_ops.count() > (u32)0 || _busy > (u32)0)
            _idle.wait(_lock);
        _lock.unlock();
        }

    // The worker: take the oldest operation, run it outside the lock, repeat.
    void work(void)
        {
        while (true)
            {
            _lock.lock();
            while (_ops.count() == (u32)0)
                _ready.wait(_lock);
            _AsyncFileOp* op = (_AsyncFileOp*)_ops.get((u32)0);
            _ops.removeAt((u32)0);
            _busy = (u32)1;
            _lock.unlock();

            op.run();

            _lock.lock();
            _busy = (u32)0;
            if (_ops.count() == (u32)0)
                _idle.broadcast();
            _lock.unlock();
            }
        }
    }

// Created on first use and never released: its worker holds `self` for the
// life of the process. The first AsyncFiles call should not race another
// thread's first call; after that any thread may queue.
_AsyncFileQueue* _async_files = (_AsyncFileQueue*)0;

class AsyncFiles
    {
    static _AsyncFileQueue* _queue(void)
        {
        if (_async_files == (_AsyncFileQueue*)0)
            _async_files = new _AsyncFileQueue();
        return _async_files;
        }

    // Files.readText on the worker; `cb` gets the text, or null.
    static void readText(String* path, block cb void(String*))
        {
        _AsyncFileOp* op = new _AsyncFileOp();
        op.kind = (u32)_AF_READ_TEXT;
        op.path = path;
        op.onText = cb;
        op.hasText = cb != (block void(String*))0;
        AsyncFiles._queue().add(op);
        }

    // Files.readData on the worker; `cb` gets the bytes, or null.
    static void readData(String* path, block cb void(Data*))
        {
        _AsyncFileOp* op = new _AsyncFileOp();
        op.kind = (u32)_AF_READ_DATA;
        op.path = path;
        op.onData = cb;
        op.hasData = cb != (block void(Data*))0;
        AsyncFiles._queue().add(op);
        }

    // Files.writeText on the worker; `cb` (may be null) gets whether it worked.
    static void writeText(String* path, String* text, block cb void(bool))
        {
        AsyncFiles._write((u32)_AF_WRITE_TEXT, path, text, (Data*)0, cb);
        }

    // Files.writeData on the worker; `cb` (may be null) gets whether it worked.
    static void writeData(String* path, Data* data, block cb void(bool))
        {
        AsyncFiles._write((u32)_AF_WRITE_DATA, path, (String*)0, data, cb);
        }

    // Files.appendText on the worker; `cb` (may be null) gets whether it worked.
    static void appendText(String* path, String* text, block cb void(bool))
        {
        AsyncFiles._write((u32)_AF_APPEND_TEXT, path, text, (Data*)0, cb);
        }

    // Block until every operation queued before this call has run and its
    // completion has returned. Not to be called from a completion block.
    static void drain(void)
        {
        AsyncFiles._queue().drain();
        }

    static void _write(u32 kind, String* path, String* text, Data* data, block cb void(bool))
        {
        _AsyncFileOp* op = new _AsyncFileOp();
        op.kind = kind;
        op.path = path;
        op.text = text;
        op.data = data;
        op.onDone = cb;
        op.hasDone = cb != (block void(bool))0;
        AsyncFiles._queue().add(op);
        }
    }
