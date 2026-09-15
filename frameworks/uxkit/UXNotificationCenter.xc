// UXNotificationCenter.xc — a neutral publish/subscribe bus, AppKit's NSNotificationCenter in shape.
//
// One object posts a named notification; any number of others, which need not know the poster, are
// called back.  It is the decoupled sibling of target/action: target/action is one sender to one
// known receiver, a notification is one sender to N unknown receivers.  The toolkit posts a handful
// of its own (a window resized, a table selection changed); an app posts and observes its own too.
//
//     UXNotificationCenter.shared().addObserver(self, &self.onResize, UXWindowDidResizeNotification, win);
//     UXNotificationCenter.shared().postWith(UXWindowDidResizeNotification, win, w, h);
//
// LIFETIME (the whole reason this is not a naive callback list): the centre must NOT keep an observer
// alive — window -> centre -> observer -> window would be a retain cycle.  So both the observer and
// its callback do not own it (the observer `weak:`, the callback by its nature): a dead
// observer's method reads false, so
// dispatch skips it and the next sweep prunes it.  removeObserver is good hygiene, not a crash guard.
#import "Array.xc"

// What a subscriber's callback receives.  `object` is who posted it (0 if anonymous); a/b carry a
// small generic payload so common notifications need no allocated userInfo (resize: a=w, b=h).
//
// `object` is a STRONG ref, like NSNotification's: a notification is transient (created, delivered,
// discarded in one post), so it cannot form a cycle, and there is nothing to keep alive beyond the
// call.  It must NOT be weak — a fresh weak register+unregister on the sender for every post churns
// the sender's weak list, which accumulates and corrupts it (a crash in _xtc_weak_register).
class UXNotification
    {
    u8* name;
    Object* object;
    i32 a;
    i32 b;
    void init(void)
        {
        name = (u8*)"";
        object = (Object*)0;
        a = (i32)0;
        b = (i32)0;
        }
    }

    // One registration.  weak on both the observer (identity for removeObserver) and the method (the
    // callback) — see the lifetime note above.
    class UXNotificationObs
    {
    weak : Object* observer;
    callback method void(UXNotification* note);
    u8* name;              // 0 = match any name
    weak : Object* object; // 0 = match any sender
    void init(void)
        {
        observer = (Object*)0;
        method = (callback void(UXNotification * note))0;
        name = (u8*)0;
        object = (Object*)0;
        }
    }

    // The process-wide default centre (lazily made), reached like gDriver — most apps never make another.
    UXNotificationCenter* gDefaultCenter;

class UXNotificationCenter
    {
    Array<UXNotificationObs>* observers;
    void init(void)
        {
        observers = new Array();
        }

    static UXNotificationCenter* shared(void)
        {
        if (gDefaultCenter == (UXNotificationCenter*)0)
            {
            gDefaultCenter = new UXNotificationCenter();
            }
        return gDefaultCenter;
        }

    // Byte-equal, tolerating either being 0.  Notification names are usually the same literal, but we
    // compare contents so two copies of the same name still match.
    bool streq(u8* a, u8* b)
        {
        if (a == b)
            {
            return true;
            }
        if (a == (u8*)0 || b == (u8*)0)
            {
            return false;
            }
        u32 i = (u32)0;
        while (a[i] != (u8)0 && a[i] == b[i])
            {
            i = i + (u32)1;
            }
        return a[i] == b[i];
        }

    // Subscribe `observer` (via its bound method) to `name` from `object`.  name 0 = any name,
    // object 0 = any sender.
    void addObserver(Object* observer, callback method void(UXNotification* note), u8* name, Object* object)
        {
        UXNotificationObs* o = new UXNotificationObs();
        o.observer = observer;
        o.method = method;
        o.name = name;
        o.object = object;
        observers.add(o);
        }

    // Drop every registration for `observer` (and sweep any whose observer already died).
    void removeObserver(Object* observer)
        {
        u32 i = (u32)0;
        while (i < observers.count())
            {
            UXNotificationObs* o = (UXNotificationObs* ?)observers.get(i);
            if (o.observer == observer || o.observer == (Object*)0 || !o.method)
                {
                observers.removeAt(i);
                }
            else
                {
                i = i + (u32)1;
                }
            }
        }

    void post(u8* name, Object* object)
        {
        self.postWith(name, object, (i32)0, (i32)0);
        }

    void postWith(u8* name, Object* object, i32 a, i32 b)
        {
        UXNotification* n = new UXNotification();
        n.name = name;
        n.object = object;
        n.a = a;
        n.b = b;
        self.postNotification(n);
        }

    // Deliver to every live observer whose name + sender filters match.  The count is snapshotted so
    // an observer that subscribes DURING dispatch is not called for this same post (AppKit's rule);
    // dead observers are skipped here and pruned by the next add/removeObserver.
    void postNotification(UXNotification* n)
        {
        u32 n0 = observers.count();
        u32 i = (u32)0;
        while (i < n0 && i < observers.count())
            {
            UXNotificationObs* o = (UXNotificationObs* ?)observers.get(i);
            i = i + (u32)1;
            callback m void(UXNotification * note) = o.method; // a local, so the call is not read as `o.method(...)`
            // observer died
            if (!m)
                {
                continue;
                }
            bool nameOk = o.name == (u8*)0 || self.streq(o.name, n.name); // 0 = any name
            bool objOk = o.object == (Object*)0 || o.object == n.object;  // 0 = any sender
            if (nameOk && objOk)
                {
                m(n);
                }
            }
        }
    }
