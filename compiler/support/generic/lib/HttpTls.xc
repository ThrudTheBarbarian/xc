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

// HttpTls.xc — https for Http, over the optional TLS library.
//
//     #import "HttpTls.xc"
//     if (!HttpTls.install())  … no CA bundle found; https stays off …
//
// Importing this file links the TLS library (`#use <tls>`), so only a
// program that wants https pays for it. Certificates are always verified,
// against a PEM bundle: `install()` looks in the places macOS and the common
// Linux distributions keep one, and `installWithBundle(path)` takes one
// explicitly (Android keeps its CAs as a directory and Windows in its
// certificate store, so neither has a default). There is no mode that
// accepts any certificate.

#import "Http.xc"
#import "Files.xc"
#use <tls>
#import "TlsAbi.xc"

// A TLS connection as Http's secure connection.
class _HttpTlsConn<HttpSecureConnection>
    {
    TlsConn* _c;

    bool write(u8* p, u32 n)
        {
        return _c.write(p, (i32)n) == (i32)n;
        }

    i32 read(u8* p, u32 n)
        {
        return _c.read(p, (i32)n);
        }

    void close(void)
        {
        _c.close();
        }
    }

// One verified client context, shared by every https request.
class _HttpTlsLayer<HttpSecureLayer>
    {
    TlsClient* _client;

    HttpSecureConnection* connect(i64 fd, String* host)
        {
        TlsConn* c = _client.connect((i32)fd, host.cString());
        if (c == (TlsConn*)0)
            return (HttpSecureConnection*)0;
        _HttpTlsConn* w = new _HttpTlsConn();
        w._c = c;
        return w;
        }
    }

class HttpTls
    {
    // Register https with Http, verifying against the first CA bundle found
    // in the usual places. False when there is none (https stays off).
    static bool install(void)
        {
        u8* paths[4];
        paths[0] = (u8*)"/etc/ssl/cert.pem";                       // macOS, Alpine
        paths[1] = (u8*)"/etc/ssl/certs/ca-certificates.crt";      // Debian, Ubuntu, Arch
        paths[2] = (u8*)"/etc/pki/tls/certs/ca-bundle.crt";        // Fedora, RHEL
        paths[3] = (u8*)"/etc/ssl/ca-bundle.pem";                  // openSUSE
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            {
            String* p = String.withCString(paths[i]);
            if (Files.exists(p))
                return HttpTls.installWithBundle(p);
            }
        return false;
        }

    // Register https with Http, verifying against the PEM bundle at `path`.
    static bool installWithBundle(String* path)
        {
        tls_require((i32)0);
        TlsClient* c = new TlsClient();
        if (!c.init(path.cString()))
            return false;
        _HttpTlsLayer* layer = new _HttpTlsLayer();
        layer._client = c;
        Http.setSecureLayer(layer);
        return true;
        }
    }
