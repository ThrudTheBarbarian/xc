---
title: NotificationCenter
description: "A publish/subscribe bus: one object posts a named notification, any number of others are called back, and none is kept alive by it."
---

`NotificationCenter` is a publish/subscribe bus (`NSNotificationCenter` in
shape). One object posts a named notification, and any number of others, which
need not know the poster, are called back. It is the one-to-many sibling of a
direct call or a delegate: the poster does not know who listens, or whether
anyone does. **From 0.72.**

```c
#import "NotificationCenter.xc"   // not in the Foundation umbrella: import it by name
```

## Overview

```c
String* DidSave = String.withCString("DocumentDidSave");

// An observer, with a method taking a Notification*:
NotificationCenter.shared().addObserver(self, &self.onSave, DidSave, (Object*)0);

// Anywhere else:
NotificationCenter.shared().post(DidSave, doc);

void onSave(Notification* note)
    {
    Document* d = (Document*)note.object;
    …
    }
```

**Lifetime.** The centre does not keep an observer alive: a window that
observes a centre that holds the window would be a cycle. The observer and the
sender filter are held weakly, and a bound method does not own its receiver, so
an observer that has gone is skipped when a notification is posted and dropped
at the next add or remove. [`removeObserver`](#removeobserver) is tidiness, not
a crash guard. It also means something else must keep each observer alive.

**Delivery.** [`post`](#post) calls each matching observer at once, on the
posting thread, in the order they were added. An observer added while a
notification is being delivered is not called for that notification. Names are
matched by value, and a null name matches every notification; senders are
matched by identity, and a null sender matches every sender.

A centre is for one thread, usually the [run loop](/compiler/api/runloop/)'s:
post and observe from that thread.

:::note[Availability]
Every heap-capable target except xt6502.
:::

## Topics

**The centre** · [shared](#shared)

**Observing** · [addObserver](#addobserver) · [removeObserver](#removeobserver) · [observerCount](#observercount)

**Posting** · [post](#post) · [postNotification](#postnotification)

**The notification** · [Notification](#notification)

---

## The centre

### shared
```c
static NotificationCenter* shared(void)
```
The process's centre, made when first asked for. `new NotificationCenter()`
makes a private one.

[↑ Topics](#topics)

## Observing

### addObserver
```c
void addObserver(Object* observer, callback method void(Notification* note), String* name, Object* sender)
```
Calls `method`, a method bound to `observer` (`&observer.onSave`), for each
notification named `name` from `sender`. A null `name` means every name; a
null `sender` means every sender. A sender given here that later goes away
matches nothing.

### removeObserver
```c
void removeObserver(Object* observer)
void removeObserver(Object* observer, String* name, Object* sender)
```
Drops `observer`'s registrations: all of them, or those for `name` (every name
if null) from `sender` (every sender if null).

### observerCount
```c
u32 observerCount(void)
```
The number of registrations whose observer is still alive.

[↑ Topics](#topics)

## Posting

### post
```c
void post(String* name, Object* sender)
void post(String* name, Object* sender, Map* userInfo)
```
Posts a notification named `name` from `sender` (which may be null), with an
optional `userInfo` map of anything else the observers need.

### postNotification
```c
void postNotification(Notification* n)
```
Posts a notification already made.

[↑ Topics](#topics)

## The notification

### Notification
```c
class Notification
    {
    String* name;
    Object* object;     // the sender, or null
    Map* userInfo;      // or null
    static Notification* make(String* name, Object* object, Map* userInfo)
    }
```
What an observer is called with. It holds the sender strongly, but only while
it is delivered.

[↑ Topics](#topics)
