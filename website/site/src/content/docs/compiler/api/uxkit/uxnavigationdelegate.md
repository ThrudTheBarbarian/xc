---
title: UXNavigationDelegate
description: "Hear when a form reaches the top of the navigation stack or leaves it, including when a pop re-reveals one underneath."
---

`UXNavigationDelegate` tells you when a form becomes visible in a
[`UXNavigationController`](/compiler/api/uxkit/uxnavigationcontroller/) and when
it stops being visible. Both methods are optional.

```c
#use <UXKit>            // or #import "UXNavigationController.xc"
```

## Overview

```c
protocol UXNavigationDelegate {
    optional void formWillShow(UXNavigationController* n, UXView* content, i32 depth);
    optional void formDidHide(UXNavigationController* n, UXView* content, i32 depth);
}
```

```c
nav.setDelegate((UXNavigationDelegate*)self);
```

The delegate is held **weakly**, like other delegates, so the controller never
keeps its owner alive.

## Both directions, both ways

Implement the two methods as a pair. Each fires in **two** situations, and it is
easy to handle only one:

| | |
| --- | --- |
| `formWillShow` | a form is pushed **and** a form is re-revealed when the one above it pops |
| `formDidHide` | a form is covered by a push **and** a form is popped off |

A detail screen that starts a timer in `formWillShow` and stops it in
`formDidHide` behaves correctly whether the user navigates forward, comes back,
or goes deeper and returns. If you handle only the push and pop cases, a covered
screen keeps working while invisible, a common cause of a mobile app doing
hidden work.

```c
void formWillShow(UXNavigationController* n, UXView* content, i32 depth) {
    if (content == (UXView*)detail) { self.startPolling(); }
}
void formDidHide(UXNavigationController* n, UXView* content, i32 depth) {
    if (content == (UXView*)detail) { self.stopPolling(); }
}
```

## Topics

[formWillShow](#formwillshow) · [formDidHide](#formdidhide)

### formWillShow

```c
optional void formWillShow(UXNavigationController* n, UXView* content, i32 depth)
```

`content` is about to become the visible top. `depth` is the stack depth it will
occupy, counting from 1.

On a first push it fires **before** the view is added to the tree, so populate
the view here: the content is yours and is not on screen yet.

### formDidHide

```c
optional void formDidHide(UXNavigationController* n, UXView* content, i32 depth)
```

`content` has stopped being the top.

A pop does not destroy the view. It stays attached and hidden, so pushing the
same form again re-reveals it instead of rebuilding it. Do not use this method
for teardown; release nothing you would need if the form comes back.

## A back button is a pop

A platform's own back affordance (a swipe, a hardware key, a navigation bar
button) surfaces as an ordinary
[`pop`](/compiler/api/uxkit/uxnavigationcontroller/), reported through the same
two methods. There is no separate "the user went back" notification.

## See also

- [`UXNavigationController`](/compiler/api/uxkit/uxnavigationcontroller/): the
  stack, `push`/`pop`, and the bar
- [`UXNavItem`](/compiler/api/uxkit/uxnavitem/): one entry on it
- [`UXMetrics`](/compiler/api/uxkit/uxmetrics/): the bar height per form factor
