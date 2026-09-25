// Asc.xc — the App Store Connect half of xcc-sign (docs/mobile/signing.md,
// Route 1): turn an API key into a signing identity with no Mac involved.
//
// The key signs an ES256 JWT (Es256.xc) for each request, sent over HTTPS
// (Https.xc). --fetch-identity generates an RSA-2048 key (RsaKeygen.xc),
// builds a CSR over it, has Apple issue an Apple Development certificate,
// fetches the WWDR intermediate and optionally a provisioning profile, and
// writes the encrypted PEM bundle the signer reads. --list-certs and
// --revoke-cert manage the account's certificates, which Apple limits.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "CodeSign.xc"
#import "RsaKeygen.xc"
#import "Plist.xc"
#import "Es256.xc"
#import "Json.xc"
#import "Https.xc"

i64 time(pointer t);
i32 chmod(u8* path, u32 mode);

class AscApi
    {
    String* _issuer;
    String* _keyId;
    String* _p8Path;
    String* _why;
    void init(void)
        {
        }
    String* why(void)
        {
        return _why;
        }

    // Null, with `err` set, when there is no .p8 at the path.
    static AscApi* with(String* issuer, String* keyId, String* p8Path, String** err)
        {
        if (!Files.exists(p8Path))
            {
            String* m = String.withCString("no .p8 at ");
            m.append(p8Path);
            *err = m;
            return (AscApi*)0;
            }
        AscApi* a = new AscApi();
        a._issuer = issuer;
        a._keyId = keyId;
        a._p8Path = p8Path;
        return a;
        }

    static String* b64url(Array* bytes)
        {
        String* s = Pem.base64Encode(bytes);
        String* o = String.withCString("");
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if (c == (u8)'+')
                o.appendByte((u8)'-');
            else if (c == (u8)'/')
                o.appendByte((u8)'_');
            else if (c != (u8)'=')
                o.appendByte(c);
            }
        return o;
        }

    // The bearer token: an ES256 JWT, valid for twenty minutes.
    String* jwt(void)
        {
        String* pem = Files.readText(_p8Path);
        P256* ec = new P256();
        Array* d = pem == (String*)0 ? (Array*)0 : ec.privateKeyFromPEM(pem);
        if (d == (Array*)0)
            {
            _why = String.withCString("could not parse the .p8 key");
            return (String*)0;
            }
        i64 now = time((pointer)0);
        String* hdr = String.withCString("{\"alg\":\"ES256\",\"kid\":\"");
        hdr.append(_keyId);
        hdr.appendCString("\",\"typ\":\"JWT\"}");
        String* claims = String.withCString("{\"iss\":\"");
        claims.append(_issuer);
        claims.appendCString("\",\"iat\":");
        claims.append(String.withI64(now));
        claims.appendCString(",\"exp\":");
        claims.append(String.withI64(now + (i64)1200));
        claims.appendCString(",\"aud\":\"appstoreconnect-v1\"}");
        String* signing = AscApi.b64url(Bytes.fromString(hdr));
        signing.appendCString(".");
        signing.append(AscApi.b64url(Bytes.fromString(claims)));
        Array* sig = ec.sign(d, Bytes.fromString(signing));
        if (sig == (Array*)0)
            {
            _why = String.withCString("ES256 signing failed");
            return (String*)0;
            }
        signing.appendCString(".");
        signing.append(AscApi.b64url(sig));
        return signing;
        }

    HttpsResponse* call(string method, String* path, Data* body)
        {
        String* token = jwt();
        if (token == (String*)0)
            return (HttpsResponse*)0;
        String* h = String.withCString("Authorization: Bearer ");
        h.append(token);
        h.appendCString("\r\nAccept: application/json\r\n");
        if (body != (Data*)0)
            h.appendCString("Content-Type: application/json\r\n");
        HttpsResponse* r = Https.request(method, String.withCString("api.appstoreconnect.apple.com"), path, h, body);
        if (r.status() < (i32)0)
            {
            _why = r.why();
            return (HttpsResponse*)0;
            }
        return r;
        }
    String* httpError(string prefix, HttpsResponse* r)
        {
        String* m = String.withCString(prefix);
        m.append(String.withI32(r.status()));
        m.appendCString(": ");
        m.append(r.bodyText());
        return m;
        }

    // GET /v1/certificates: the raw JSON, or null.
    String* listCertificates(void)
        {
        HttpsResponse* r = call("GET", String.withCString("/v1/certificates?limit=200"), (Data*)0);
        if (r == (HttpsResponse*)0)
            return (String*)0;
        if (r.status() != (i32)200)
            {
            _why = httpError("HTTP ", r);
            return (String*)0;
            }
        return r.bodyText();
        }
    // DELETE /v1/certificates/{id}: frees a slot for a fresh --fetch-identity.
    bool revokeCertificate(String* certId)
        {
        String* path = String.withCString("/v1/certificates/");
        path.append(certId);
        HttpsResponse* r = call("DELETE", path, (Data*)0);
        if (r == (HttpsResponse*)0)
            return false;
        if (r.status() != (i32)204 && r.status() != (i32)200)
            {
            _why = httpError("revoke HTTP ", r);
            return false;
            }
        return true;
        }
    String* listProfiles(void)
        {
        HttpsResponse* r = call("GET", String.withCString("/v1/profiles?limit=200"), (Data*)0);
        if (r == (HttpsResponse*)0)
            return (String*)0;
        if (r.status() != (i32)200)
            {
            _why = httpError("HTTP ", r);
            return (String*)0;
            }
        return r.bodyText();
        }

    // POST /v1/certificates: a real Apple Development certificate for the CSR
    // (it takes one of the account's certificate slots). Its DER, or null.
    Array* createDevelopmentCertificate(String* csrPem)
        {
        String* payload = String.withCString("{\"data\":{\"type\":\"certificates\",\"attributes\":{\"certificateType\":\"DEVELOPMENT\",\"csrContent\":");
        payload.append(Json.quote(csrPem));
        payload.appendCString("}}}");
        HttpsResponse* r = call("POST", String.withCString("/v1/certificates"), Data.withString(payload));
        if (r == (HttpsResponse*)0)
            return (Array*)0;
        if (r.status() != (i32)201 && r.status() != (i32)200)
            {
            _why = httpError("create cert HTTP ", r);
            return (Array*)0;
            }
        JsonValue* j = Json.parse(r.bodyText());
        JsonValue* data = j == (JsonValue*)0 ? (JsonValue*)0 : j.get("data");
        String* content = JsonValue.path2(data, "attributes", "certificateContent");
        if (content == (String*)0)
            {
            _why = String.withCString("no certificateContent in response");
            return (Array*)0;
            }
        Array* der = Pem.base64Decode(content);
        if (der.count() == (u32)0)
            {
            _why = String.withCString("bad certificateContent base64");
            return (Array*)0;
            }
        return der;
        }

    // The first profile whose name contains `nameFilter` (null: the first
    // profile) as .mobileprovision bytes, or null.
    Array* fetchProfileMatching(String* nameFilter)
        {
        String* list = listProfiles();
        if (list == (String*)0)
            return (Array*)0;
        JsonValue* j = Json.parse(list);
        JsonValue* data = j == (JsonValue*)0 ? (JsonValue*)0 : j.get("data");
        u32 n = data == (JsonValue*)0 ? (u32)0 : data.count();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            JsonValue* a = data.at(i).get("attributes");
            if (a == (JsonValue*)0)
                continue;
            JsonValue* nm = a.get("name");
            String* name = nm == (JsonValue*)0 ? (String*)0 : nm.str();
            if (nameFilter != (String*)0 && (name == (String*)0 || !name.contains(nameFilter)))
                continue;
            JsonValue* pc = a.get("profileContent");
            String* content = pc == (JsonValue*)0 ? (String*)0 : pc.str();
            if (content != (String*)0)
                return Pem.base64Decode(content);
            }
        if (nameFilter != (String*)0)
            {
            _why = String.withCString("no profile matching '");
            _why.append(nameFilter);
            _why.appendCString("'");
            }
        else
            _why = String.withCString("no profiles found");
        return (Array*)0;
        }

    // A public Apple CA certificate (DER), e.g. AppleWWDRCAG3. The API returns
    // only the leaf, so the chain is assembled from these.
    static Array* fetchAppleCA(String* name, String** err)
        {
        String* path = String.withCString("/certificateauthority/");
        path.append(name);
        path.appendCString(".cer");
        HttpsResponse* r = Https.request("GET", String.withCString("www.apple.com"), path, (String*)0, (Data*)0);
        if (r.status() < (i32)0)
            {
            *err = r.why();
            return (Array*)0;
            }
        if (r.status() != (i32)200)
            {
            String* m = String.withCString("fetch ");
            m.append(name);
            m.appendCString(" HTTP ");
            m.append(String.withI32(r.status()));
            *err = m;
            return (Array*)0;
            }
        return Bytes.fromData(r.body());
        }
    }

class AscTool
    {
    void init(void)
        {
        }
    static void say(string a, String* b, string c)
        {
        String* m = String.withCString("xcc-sign: ");
        m.appendCString(a);
        if (b != (String*)0)
            m.append(b);
        m.appendCString(c);
        m.appendCString("\n");
        Stdio.error(m);
        }

    // A CSR (PEM) for a new RSA-2048 key, whose PKCS#1 DER goes to keyOut.
    static String* keyAndCsr(String* cn, Array** keyOut, String** err)
        {
        Array* k = Rsa.generate((u32)2048);
        if (k.count() < (u32)8)
            {
            *err = String.withCString("RSA keygen failed");
            return (String*)0;
            }
        Array* n = (Array*)k.get((u32)0);
        Array* e = (Array*)k.get((u32)1);
        Array* d = (Array*)k.get((u32)2);
        Array* fields = new Array();
        fields.add((Object*)Der.integerU32((u32)0));
        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            fields.add((Object*)Der.integer((Array*)k.get(i)));
        *keyOut = Der.sequence(fields);

        // CertificationRequestInfo { version 0, subject CN, SPKI, [0] {} }
        Array* subject = Der.sequence(Der.one(Der.setOf(Der.one(Der.sequence(Der.two(
                             Der.oid(String.withCString("2.5.4.3")), Der.stringOf((u32)$0c, cn)))))));
        Array* rsaPub = Der.sequence(Der.two(Der.integer(n), Der.integer(e)));
        Array* bits = new Array();
        Bytes.add(bits, (u32)0);
        for (u32 i = (u32)0; i < rsaPub.count(); i = i + (u32)1)
            bits.add(rsaPub.get(i));
        Array* spki = Der.sequence(Der.two(
            Der.sequence(Der.two(Der.oid(String.withCString("1.2.840.113549.1.1.1")), Der.null())),
            Der.tlv((u32)$03, bits)));
        Array* attrs = Der.tlv((u32)$A0, new Array());
        Array* cri = new Array();
        cri.add((Object*)Der.integerU32((u32)0));
        cri.add((Object*)subject);
        cri.add((Object*)spki);
        cri.add((Object*)attrs);
        Array* criDer = Der.sequence(cri);
        Array* sig = Cms.rsaSignPKCS1(Cms.sha256DigestInfo(Bytes.sha256(criDer)), n, d);
        if (sig == (Array*)0)
            {
            *err = String.withCString("CSR self-signature failed");
            return (String*)0;
            }
        Array* sigBits = new Array();
        Bytes.add(sigBits, (u32)0);
        for (u32 i = (u32)0; i < sig.count(); i = i + (u32)1)
            sigBits.add(sig.get(i));
        Array* csr = new Array();
        csr.add((Object*)criDer);
        csr.add((Object*)Der.sequence(Der.two(Der.oid(String.withCString("1.2.840.113549.1.1.11")), Der.null())));
        csr.add((Object*)Der.tlv((u32)$03, sigBits));
        String* pem = String.withCString("-----BEGIN CERTIFICATE REQUEST-----\n");
        pem.append(Pem.base64Lines(Der.sequence(csr)));
        pem.appendCString("\n-----END CERTIFICATE REQUEST-----\n");
        return pem;
        }

    // --list-certs / --revoke-cert. The exit code.
    static i32 admin(String* issuer, String* keyId, String* p8, bool list, String* revokeId)
        {
        String* err = (String*)0;
        AscApi* api = AscApi.with(issuer, keyId, p8, &err);
        if (api == (AscApi*)0)
            {
            AscTool.say("", err, "");
            return (i32)1;
            }
        if (revokeId != (String*)0)
            {
            if (!api.revokeCertificate(revokeId))
                {
                AscTool.say("", api.why(), "");
                return (i32)1;
                }
            AscTool.say("revoked certificate ", revokeId, "");
            return (i32)0;
            }
        String* body = api.listCertificates();
        if (body == (String*)0)
            {
            AscTool.say("", api.why(), "");
            return (i32)1;
            }
        JsonValue* j = Json.parse(body);
        JsonValue* data = j == (JsonValue*)0 ? (JsonValue*)0 : j.get("data");
        u32 n = data == (JsonValue*)0 ? (u32)0 : data.count();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            JsonValue* c = data.at(i);
            JsonValue* idv = c.get("id");
            String* id = idv == (JsonValue*)0 ? (String*)0 : idv.str();
            String* type = JsonValue.path2(c, "attributes", "certificateType");
            String* name = JsonValue.path2(c, "attributes", "displayName");
            String* line = String.withCString("");
            line.append(id == (String*)0 ? String.withCString("(null)") : id);
            line.appendCString("  ");
            String* t = type == (String*)0 ? String.withCString("(null)") : type;
            line.append(t);
            for (u32 k = t.byteLength(); k < (u32)28; k = k + (u32)1)
                line.appendCString(" ");
            line.appendCString("  ");
            line.append(name == (String*)0 ? String.withCString("(null)") : name);
            line.appendCString("\n");
            Stdio.printf("%s", line.cString());
            }
        return (i32)0;
        }

    // --fetch-identity. The exit code.
    static i32 fetchIdentity(String* issuer, String* keyId, String* p8, String* profileName, String* passphrase, String* out)
        {
        String* err = (String*)0;
        AscApi* api = AscApi.with(issuer, keyId, p8, &err);
        if (api == (AscApi*)0)
            {
            AscTool.say("", err, "");
            return (i32)1;
            }
        Array* keyDer = (Array*)0;
        String* csr = AscTool.keyAndCsr(String.withCString("xcc Route 1"), &keyDer, &err);
        if (csr == (String*)0)
            {
            AscTool.say("CSR: ", err, "");
            return (i32)1;
            }
        AscTool.say("creating an Apple Development certificate...", (String*)0, "");
        Array* cert = api.createDevelopmentCertificate(csr);
        if (cert == (Array*)0)
            {
            AscTool.say("create cert: ", api.why(), "");
            if (api.why().contains(String.withCString("already have")))
                AscTool.say("the account is at its Development-certificate limit; "
                            "revoke an unused one (developer.apple.com or the API) and retry.", (String*)0, "");
            return (i32)1;
            }
        Array* wwdr = AscApi.fetchAppleCA(String.withCString("AppleWWDRCAG3"), &err);
        if (wwdr == (Array*)0)
            {
            AscTool.say("fetch WWDR: ", err, "");
            return (i32)1;
            }
        Array* ent = (Array*)0;
        Array* profile = api.fetchProfileMatching(profileName);
        if (profile != (Array*)0)
            {
            ent = Profile.entitlements(profile);
            String* m = String.withCString("fetched provisioning profile (");
            m.append(String.withU32(profile.count()));
            m.appendCString(" bytes)");
            if (ent != (Array*)0)
                m.appendCString(", entitlements embedded");
            AscTool.say("", m, "");
            }
        Array* rnd = Rsa.randomBytes((u32)16);
        if (rnd.count() != (u32)16)
            {
            AscTool.say("key encrypt: no OS randomness (/dev/urandom)", (String*)0, "");
            return (i32)1;
            }
        // Wrapped as a PKCS#8 PrivateKeyInfo before encryption, so the result
        // is a standard encrypted key other tools (openssl pkcs8) can open too.
        Array* pki = new Array();
        pki.add((Object*)Der.integerU32((u32)0));
        pki.add((Object*)Der.sequence(Der.two(Der.oid(String.withCString("1.2.840.113549.1.1.1")), Der.null())));
        pki.add((Object*)Der.octetString(keyDer));
        keyDer = Der.sequence(pki);
        Array* encKey = Pkcs8.encrypt(keyDer, passphrase,Bytes.slice(rnd, (u32)0, (u32)8), Bytes.slice(rnd, (u32)8, (u32)8));
        if (encKey == (Array*)0)
            {
            AscTool.say("key encrypt: 3DES encrypt failed", (String*)0, "");
            return (i32)1;
            }
        Array* chain = new Array();
        chain.add((Object*)wwdr);
        String* pem = Identity.pemBundle(cert, chain, encKey, String.withCString("ENCRYPTED PRIVATE KEY"), ent);
        if (!Files.writeText(out, pem))
            {
            AscTool.say("cannot write '", out, "'");
            return (i32)1;
            }
        chmod(out.cString(), (u32)$180);
        AscTool.say("fetched identity -> '", out, "' (encrypted; sign with --passphrase)");
        return (i32)0;
        }
    }
