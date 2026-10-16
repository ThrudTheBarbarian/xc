// xttls.xc — reusable xtc TLS module (Mbed TLS via the tlsshim C glue).
//
// #import this file and link tlsshim.o + the mbedtls static libs (see build.sh).
// It hands out three small classes over opaque C handles, usable by any xtc
// program — a server (blewit) or a client (the XG web-widget, outbound fetches):
//
//     TlsServer s; s.listen("cert.pem", "key.pem");
//     TlsConn* c = s.accept(fd);           // wraps an accepted socket + handshakes
//     c.write(buf, n); c.read(buf, cap); c.close();
//
//     TlsClient cl; cl.init((string)0);    // ca path or null (null = accept any — spike)
//     TlsConn* c = cl.connect(fd, "example.com");
//
// The C shim owns all Mbed TLS state; xtc only ever sees the handles.

// ── tlsshim C interface ─────────────────────────────────────────────────────
pointer xt_tls_server_new(u8* certPath, u8* keyPath);
pointer xt_tls_client_new(u8* caPath);
pointer xt_tls_client_new_system();                         // the OS trust store, or null
pointer xt_tls_accept(pointer server, i32 fd);              // blocking
pointer xt_tls_connect(pointer client, i32 fd, u8* hostname);
i32     xt_tls_read(pointer conn, u8* buf, i32 len);        // blocking
i32     xt_tls_write(pointer conn, u8* buf, i32 len);
void    xt_tls_close(pointer conn);
pointer xt_tls_wrap_server(pointer server, i32 fd);         // non-blocking: no handshake yet
pointer xt_tls_wrap_client(pointer client, i32 fd, u8* hostname);
i32     xt_tls_handshake(pointer conn);                     // 0 done / 1 want-read / 2 want-write / -1 err
i32     xt_tls_recv(pointer conn, u8* buf, i32 len);        // >0 / 0 close / -1 err / -2 wr / -3 ww
i32     xt_tls_send(pointer conn, u8* buf, i32 len);        // >0 / -1 err / -2 wr / -3 ww
i32     xt_tls_make_self_signed(u8* certPath, u8* keyPath, u8* cn);  // 0 ok
i32     xt_tls_peer_fingerprint(pointer conn, u8* out32);              // 0 ok / -1 none
i32     xt_tls_pending(pointer conn);                                  // decrypted bytes waiting

// ── C-ABI entry points for a lazy loader (ABI 1.0.2) ───────────────────────
// A program that may or may not need TLS — every par program, for the worker
// daemon across the room — loads this library at run time (dlopen /
// LoadLibrary) and resolves these by name, so it links nothing and needs the
// library only when it talks to a daemon. Plain functions, never removed or
// renamed; new ones are appended with a patch bump.
i32 xctls_make_self_signed(u8* certPath, u8* keyPath, u8* cn) { return xt_tls_make_self_signed(certPath, keyPath, cn); }
pointer xctls_server(u8* certPath, u8* keyPath) { return xt_tls_server_new(certPath, keyPath); }
pointer xctls_client_pinning(void) { return xt_tls_client_new((u8*)0); }   // verifies no chain: the caller pins the fingerprint
pointer xctls_accept(pointer server, i32 fd) { return xt_tls_accept(server, fd); }
pointer xctls_connect(pointer client, i32 fd, u8* hostname) { return xt_tls_connect(client, fd, hostname); }
i32 xctls_fingerprint(pointer conn, u8* out32) { return xt_tls_peer_fingerprint(conn, out32); }
i32 xctls_pending(pointer conn) { return xt_tls_pending(conn); }
i32 xctls_read(pointer conn, u8* buf, i32 len) { return xt_tls_read(conn, buf, len); }
i32 xctls_write(pointer conn, u8* buf, i32 len) { return xt_tls_write(conn, buf, len); }
void xctls_close(pointer conn) { xt_tls_close(conn); }

// A live TLS connection (server- or client-side). Wraps an fd whose handshake
// has already completed; read/write move plaintext, the module does the crypto.
class TlsConn : Object
{
    pointer h;      // xt_tls_conn* (null once closed)

    void init(void) { h = (pointer)0; }

    // ---- blocking (blocking socket) ----
    // >0 = bytes read; 0 = peer closed cleanly; <0 = TLS/socket error.
    i32 read(u8* buf, i32 len)  { return (h != (pointer)0) ? xt_tls_read(h, buf, len) : (i32)(-1); }
    // Writes all `len` bytes (blocking). Returns len, or <0 on error.
    i32 write(u8* buf, i32 len) { return (h != (pointer)0) ? xt_tls_write(h, buf, len) : (i32)(-1); }

    // ---- non-blocking (O_NONBLOCK socket, driven from an event loop) ----
    // 0 = handshake done; 1 = want read; 2 = want write; -1 = error. Call on each
    // readable/writable event until it returns 0, then read/recv/send.
    i32 handshake(void) { return (h != (pointer)0) ? xt_tls_handshake(h) : (i32)(-1); }
    // >0 = bytes; 0 = clean close; -1 = error; -2 = want read; -3 = want write.
    i32 recv(u8* buf, i32 len) { return (h != (pointer)0) ? xt_tls_recv(h, buf, len) : (i32)(-1); }
    // >0 = bytes accepted; -1 = error; -2 = want read; -3 = want write.
    i32 send(u8* buf, i32 len) { return (h != (pointer)0) ? xt_tls_send(h, buf, len) : (i32)(-1); }

    void close(void) { if (h != (pointer)0) { xt_tls_close(h); h = (pointer)0; } }
    bool live(void)  { return h != (pointer)0; }
}

// A TLS listener context: load a cert+key once, then wrap accepted sockets.
class TlsServer : Object
{
    pointer h;      // xt_tls_server*

    void init(void) { h = (pointer)0; }

    bool listen(string certPath, string keyPath)
    {
        h = xt_tls_server_new(certPath, keyPath);
        return h != (pointer)0;
    }

    // Take an accepted socket fd, run the TLS handshake, return the connection
    // (or null if the handshake failed — the caller still owns/closes the fd).
    TlsConn* accept(i32 fd)
    {
        if (h == (pointer)0) return (TlsConn*)0;
        pointer c = xt_tls_accept(h, fd);
        if (c == (pointer)0) return (TlsConn*)0;
        TlsConn* t = new TlsConn();
        t.h = c;
        return t;
    }

    // Non-blocking: wrap an O_NONBLOCK fd WITHOUT handshaking. The caller drives
    // conn.handshake() from its event loop. null on allocation failure.
    TlsConn* wrap(i32 fd)
    {
        if (h == (pointer)0) return (TlsConn*)0;
        pointer c = xt_tls_wrap_server(h, fd);
        if (c == (pointer)0) return (TlsConn*)0;
        TlsConn* t = new TlsConn();
        t.h = c;
        return t;
    }
}

// A TLS client context: reusable across outbound connections.
class TlsClient : Object
{
    pointer h;      // xt_tls_client*

    void init(void) { h = (pointer)0; }

    // caPath: a PEM CA bundle to verify against, or null to accept any cert
    // (spike/dev only — a real client MUST pass a CA bundle).
    bool init(string caPath) { h = xt_tls_client_new(caPath); return h != (pointer)0; }

    // Connect over an already-connected socket fd; `hostname` drives SNI + (when
    // a CA is set) certificate hostname verification. null on handshake failure.
    TlsConn* connect(i32 fd, string hostname)
    {
        if (h == (pointer)0) return (TlsConn*)0;
        pointer c = xt_tls_connect(h, fd, hostname);
        if (c == (pointer)0) return (TlsConn*)0;
        TlsConn* t = new TlsConn();
        t.h = c;
        return t;
    }

    // Verify against the operating system's trusted roots where they are not a
    // PEM file: the Windows certificate store. False on other systems, or when
    // the store holds no certificate. Appended last, so no offset moves (1.0.1).
    bool initSystem(void) { h = xt_tls_client_new_system(); return h != (pointer)0; }
}
