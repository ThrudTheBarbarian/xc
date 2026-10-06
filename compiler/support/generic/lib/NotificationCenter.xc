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
// NotificationCenter.xc — a publish/subscribe bus (NSNotificationCenter in
// shape).
// ===========================================================================
//
// One object posts a named notification; any number of others, which need not
// know the poster, are called back. It is the one-to-many sibling of a direct
// call or a delegate: the poster does not know who listens, or whether anyone
// does.
//
//     String* DidSave = String.withCString("DocumentDidSave");
//     NotificationCenter.shared().addObserver(self, &self.onSave, DidSave, (Object*)0);
//     …
//     NotificationCenter.shared().post(DidSave, doc);
//
//     void onSave(Notification* note) { Document* d = (Document*)note.object; … }
//
// ── Lifetime ────────────────────────────────────────────────────────────────
//
// The centre does not keep an observer alive: a window that observes a
// centre that holds the window would be a cycle. The observer and the sender
// filter are held weakly, and a bound method does not own its receiver, so an
// observer that has gone is skipped when a notification is posted and dropped
// at the next add or remove. removeObserver is tidiness, not a crash guard.
//
// ── Delivery ────────────────────────────────────────────────────────────────
//
// post calls each matching observer at once, on the posting thread, in the
// order they were added. An observer added while a notification is being
// delivered is not called for that notification. Observers are matched by
// name (by value; a null name matches every notification) and by sender (by
// identity; a null sender matches every sender).
//
// A centre is for one thread, usually the run loop's: post and observe from
// that thread.
//
// ── Availability ────────────────────────────────────────────────────────────
//
// Every heap-capable target except xt6502.

#if ARCH_6502
#error "NotificationCenter: not available on xt6502"
#endif

#import "Foundation.xc"

// What an observer is called with. `object` is the sender (null if the post
// named none), held strongly: a notification lives only while it is
// delivered, so it cannot make a cycle.
class Notification
    {
    String* name;
    Object* object;
    Map* userInfo;  // anything else the poster sends; may be null

    void init(void)
        {
        name = (String*)0;
        object = (Object*)0;
        userInfo = (Map*)0;
        }

    static Notification* make(String* name, Object* object, Map* userInfo)
        {
        Notification* n = new Notification();
        n.name = name;
        n.object = object;
        n.userInfo = userInfo;
        return n;
        }
    }

// One registration.
class _NotificationObserver
    {
    weak : Object* observer;
    callback method void(Notification* note);
    String* name;            // null: every name
    weak : Object* sender;   // null: every sender
    bool anySender;          // registered with a null sender (a weak one that died is not "any")
    }

NotificationCenter* _gNotificationCenter;

class NotificationCenter
    {
    Array* _observers;

    void init(void)
        {
        _observers = new Array();
        }

    // The process's centre, made when first asked for.
    static NotificationCenter* shared(void)
        {
        if (_gNotificationCenter == (NotificationCenter*)0)
            _gNotificationCenter = new NotificationCenter();
        return _gNotificationCenter;
        }

    // Calls `method` (a method bound to `observer`) for each notification
    // named `name` from `sender`. A null name means every name; a null sender
    // means every sender.
    void addObserver(Object* observer, callback method void(Notification* note), String* name, Object* sender)
        {
        _prune();
        _NotificationObserver* o = new _NotificationObserver();
        o.observer = observer;
        o.method = method;
        o.name = name;
        o.sender = sender;
        o.anySender = sender == (Object*)0;
        _observers.add(o);
        }

    // Drops every registration of `observer`.
    void removeObserver(Object* observer)
        {
        removeObserver(observer, (String*)0, (Object*)0);
        }

    // Drops `observer`'s registrations for `name` (every name if null) from
    // `sender` (every sender if null).
    void removeObserver(Object* observer, String* name, Object* sender)
        {
        u32 i = (u32)0;
        while (i < _observers.count())
            {
            _NotificationObserver* o = (_NotificationObserver*)_observers.get(i);
            bool dead = o.observer == (Object*)0 || !o.method;
            bool match = o.observer == observer
                         && (name == 0 || (o.name != 0 && o.name.equals(name)))
                         && (sender == (Object*)0 || o.sender == sender);
            if (dead || match)
                _observers.removeAt(i);
            else
                i = i + (u32)1;
            }
        }

    // The number of live registrations.
    u32 observerCount(void)
        {
        _prune();
        return _observers.count();
        }

    // Posts `name` from `sender`, with no userInfo.
    void post(String* name, Object* sender)
        {
        postNotification(Notification.make(name, sender, (Map*)0));
        }

    void post(String* name, Object* sender, Map* userInfo)
        {
        postNotification(Notification.make(name, sender, userInfo));
        }

    void postNotification(Notification* n)
        {
        if (n == 0)
            return;
        u32 count = _observers.count();
        u32 i = (u32)0;
        while (i < count && i < _observers.count())
            {
            _NotificationObserver* o = (_NotificationObserver*)_observers.get(i);
            i = i + (u32)1;
            // A local, so the call is not read as a method of `o`.
            callback m void(Notification* note) = o.method;
            if (!m || o.observer == (Object*)0)
                continue;
            if (o.name != 0 && (n.name == 0 || !o.name.equals(n.name)))
                continue;
            if (!o.anySender && (o.sender == (Object*)0 || o.sender != n.object))
                continue;
            m(n);
            }
        }

    void _prune(void)
        {
        u32 i = (u32)0;
        while (i < _observers.count())
            {
            _NotificationObserver* o = (_NotificationObserver*)_observers.get(i);
            if (o.observer == (Object*)0 || !o.method)
                _observers.removeAt(i);
            else
                i = i + (u32)1;
            }
        }
    }
