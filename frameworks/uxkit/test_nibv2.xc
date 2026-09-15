// test_nibv2.xc — the UXNB v2 gates (docs/UXNB-V2.md §9), headless and neutral.
//
// Builds v2 (and one v1) nib images in memory — a writer mirroring the parser,
// byte for byte per the spec — and proves: variant selection per forced class,
// the fallback chain, a connection binding through RE-PARENTED containment (the
// §6 button-row shape literally: the same logical buttons at different object
// indices because the phone tree nests them one level deeper), a dropped
// control skipping cleanly, and a v1 chunk reading as single-variant `any`.
// No driver, no libGEM, no host: this is the neutral half the wasm32 leg runs.
#import <Stdio.xc>
#import "UXNibV2.xc"

i32 gFails;
void ck(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, got, want);
        gFails = gFails + (i32)1;
        }
    }

// ---- a tiny big-endian writer ------------------------------------------------
u32 gAt;
void w8(u8* b, i32 v)
    {
    b[gAt] = (u8)v;
    gAt = gAt + (u32)1;
    }
void w16(u8* b, i32 v)
    {
    b[gAt] = (u8)(v >> (i32)8);
    b[gAt + (u32)1] = (u8)v;
    gAt = gAt + (u32)2;
    }
void w32(u8* b, u32 v)
    {
    b[gAt] = (u8)(v >> (u32)24);
    b[gAt + (u32)1] = (u8)(v >> (u32)16);
    b[gAt + (u32)2] = (u8)(v >> (u32)8);
    b[gAt + (u32)3] = (u8)v;
    gAt = gAt + (u32)4;
    }
void wRef(u8* b, i32 space, i32 a, i32 vv)
    {
    w8(b, space);
    w16(b, a);
    w16(b, vv);
    w8(b, (i32)0);
    }
// append to the blob, return its offset
u32 wStr(u8* blob, u32* blobAt, u8* s)
    {
    u32 off = blobAt[0];
    i32 i = (i32)0;
    while (s[i] != (u8)0)
        {
        blob[off + (u32)i] = s[i];
        i = i + (i32)1;
        }
    blob[off + (u32)i] = (u8)0;
    blobAt[0] = off + (u32)i + (u32)1;
    return off;
    }

// The §6 document: one form ("Transport", id 7), two variants — desktop tree 0
// (five buttons as objs 1..5 under the root box) and phone tree 1 (the same five
// logical buttons as objs 2..6, one level deeper inside a phone-only scroll
// container).  One ACTION connection, logical button L2 -> owner's "onPlay".
// A second connection targets L9 — present ONLY in the desktop map (the phone
// layout dropped it): the §3 skip rule, and validate()'s one warning.
u32 buildV2(u8* b)
    {
    gAt = (u32)0;
    // classic part: an RSHDR of 18 zero words with rsh_rssize (word 17) = 36.
    for (i32 i = (i32)0; i < (i32)17; i = i + (i32)1)
        {
        w16(b, (i32)0);
        }
    w16(b, (i32)36);
    // shell at 36
    w32(b, (u32)$55584E42); // 'UXNB'
    w16(b, (i32)2);
    w16(b, (i32)0); // version, flags
    u32 sizeAt = gAt;
    w32(b, (u32)0); // size, patched at the end
    // counts: nClasses nObjects nConns nForms nMaps nPres
    w16(b, (i32)0);
    w16(b, (i32)1);
    w16(b, (i32)2);
    w16(b, (i32)1);
    w16(b, (i32)2);
    w16(b, (i32)0);
    // the string blob is assembled on the side and appended after the sections
    u8 blob[64];
    u32 blobAt = (u32)1;
    blob[0] = (u8)0; // offset 0 = ""
    u32 sOwner = wStr(&blob[0], &blobAt, (u8*)"Controller");
    u32 sPlay = wStr(&blob[0], &blobAt, (u8*)"onPlay");
    u32 sGhost = wStr(&blob[0], &blobAt, (u8*)"onGhost");
    u32 sName = wStr(&blob[0], &blobAt, (u8*)"Transport");
    // forms[1]: {formId 7, name, nVar 2, _pad} + {desktop, tree 0} {phone, tree 1}
    w16(b, (i32)7);
    w32(b, sName);
    w16(b, (i32)2);
    w16(b, (i32)0);
    w16(b, (i32)UX_FORM_DESKTOP);
    w16(b, (i32)0);
    w16(b, (i32)UX_FORM_PHONE);
    w16(b, (i32)1);
    // maps[2]: tree 0 {1..5 -> L1..L5, 7 -> L9}; tree 1 {2..6 -> L1..L5} (no L9)
    w16(b, (i32)0);
    w16(b, (i32)6);
    for (i32 i = (i32)0; i < (i32)5; i = i + (i32)1)
        {
        w16(b, i + (i32)1);
        w16(b, i + (i32)1);
        }
    w16(b, (i32)7);
    w16(b, (i32)9);
    w16(b, (i32)1);
    w16(b, (i32)5);
    for (i32 i = (i32)0; i < (i32)5; i = i + (i32)1)
        {
        w16(b, i + (i32)2);
        w16(b, i + (i32)1);
        }
    // topObjects[1]: {id 1, "Controller"}
    w16(b, (i32)1);
    w32(b, sOwner);
    // connections[2]: ACTION L2 -> top 1 "onPlay"; ACTION L9 -> top 1 "onGhost"
    w8(b, (i32)UXNB_CONN_ACTION);
    w8(b, (i32)0);
    wRef(b, (i32)UXNB_REF_LOGICAL, (i32)7, (i32)2);
    wRef(b, (i32)UXNB_REF_TOP, (i32)1, (i32)0);
    w32(b, sPlay);
    w8(b, (i32)UXNB_CONN_ACTION);
    w8(b, (i32)0);
    wRef(b, (i32)UXNB_REF_LOGICAL, (i32)7, (i32)9);
    wRef(b, (i32)UXNB_REF_TOP, (i32)1, (i32)0);
    w32(b, sGhost);
    // the blob, then patch the shell size
    for (u32 i = (u32)0; i < blobAt; i = i + (u32)1)
        {
        b[gAt + i] = blob[i];
        }
    gAt = gAt + blobAt;
    u32 total = gAt;
    u32 save = gAt;
    gAt = sizeAt;
    w32(b, total - (u32)36);
    gAt = save;
    return total;
    }

// A v1 chunk ('XGNB'): one connection in v1's fixed layout — the regression gate.
u32 buildV1(u8* b)
    {
    gAt = (u32)0;
    for (i32 i = (i32)0; i < (i32)17; i = i + (i32)1)
        {
        w16(b, (i32)0);
        }
    w16(b, (i32)36);
    w32(b, (u32)$58474E42); // 'XGNB'
    w16(b, (i32)1);
    w16(b, (i32)0);
    u32 sizeAt = gAt;
    w32(b, (u32)0);
    w16(b, (i32)0);
    w16(b, (i32)1);
    w16(b, (i32)1);
    w16(b, (i32)0); // nCl nObj nConn _pad
    u8 blob[32];
    u32 blobAt = (u32)1;
    blob[0] = (u8)0;
    u32 sOwner = wStr(&blob[0], &blobAt, (u8*)"Controller");
    u32 sTap = wStr(&blob[0], &blobAt, (u8*)"onTap");
    w16(b, (i32)1);
    w32(b, sOwner); // topObjects[1]
    w8(b, (i32)UXNB_CONN_ACTION);
    w8(b, (i32)0); // conn: view (0,0,3) -> top 1
    wRef(b, (i32)UXNB_REF_VIEW, (i32)0, (i32)3);
    wRef(b, (i32)UXNB_REF_TOP, (i32)1, (i32)0);
    w32(b, sTap);
    for (u32 i = (u32)0; i < blobAt; i = i + (u32)1)
        {
        b[gAt + i] = blob[i];
        }
    gAt = gAt + blobAt;
    u32 total = gAt;
    u32 save = gAt;
    gAt = sizeAt;
    w32(b, total - (u32)36);
    gAt = save;
    return total;
    }

void main(void)
    {
    gFails = (i32)0;
    u8 img[512];
    u32 n = buildV2(&img[0]);
    UXNibV2* nib = UXNibV2.open(&img[0], n);
    if (nib == (UXNibV2*)0)
        {
        Stdio.printf("FAIL: open\n");
        return;
        }
    ck((u8*)"version", nib.version(), (i32)2);
    ck((u8*)"formCount", nib.formCount(), (i32)1);

    // Gate 1: the right tree per forced class.
    i32 chosen = (i32)0;
    ck((u8*)"desktop tree", nib.selectTree((i32)7, (i32)UX_FORM_DESKTOP, &chosen), (i32)0);
    ck((u8*)"desktop chose", chosen, (i32)UX_FORM_DESKTOP);
    ck((u8*)"phone tree", nib.selectTree((i32)7, (i32)UX_FORM_PHONE, &chosen), (i32)1);
    ck((u8*)"phone chose", chosen, (i32)UX_FORM_PHONE);

    // Gate 2: the fallback chain — tablet has no variant; nearest-larger wins.
    ck((u8*)"tablet tree (falls to desktop)", nib.selectTree((i32)7, (i32)UX_FORM_TABLET, &chosen), (i32)0);
    ck((u8*)"tablet chose", chosen, (i32)UX_FORM_DESKTOP);

    // Gate 3: the §6 shape — one connection, resolved through re-parented
    // containment: L2 is obj 2 in the desktop tree and obj 3 in the phone tree.
    ck((u8*)"conn count", nib.connCount(), (i32)2);
    ck((u8*)"L2 on desktop", nib.resolveView(nib.connSrc((i32)0), (i32)0), (i32)2);
    ck((u8*)"L2 on phone", nib.resolveView(nib.connSrc((i32)0), (i32)1), (i32)3);

    // Gate 4: the dropped control — L9 binds on desktop, skips on phone; the
    // validator reports exactly the one connection, by index.
    ck((u8*)"L9 on desktop", nib.resolveView(nib.connSrc((i32)1), (i32)0), (i32)7);
    ck((u8*)"L9 on phone (dropped)", nib.resolveView(nib.connSrc((i32)1), (i32)1), (i32)-1);
    i32 bad[4];
    ck((u8*)"validate desktop", nib.validate((i32)7, (i32)UX_FORM_DESKTOP, &bad[0], (i32)4), (i32)0);
    ck((u8*)"validate phone", nib.validate((i32)7, (i32)UX_FORM_PHONE, &bad[0], (i32)4), (i32)1);
    ck((u8*)"validate phone names conn 1", bad[0], (i32)1);

    // Gate 5: a v1 chunk — version 1, single-variant `any`, conns readable.
    u32 n1 = buildV1(&img[0]);
    UXNibV2* v1 = UXNibV2.open(&img[0], n1);
    if (v1 == (UXNibV2*)0)
        {
        Stdio.printf("FAIL: v1 open\n");
        return;
        }
    ck((u8*)"v1 version", v1.version(), (i32)1);
    ck((u8*)"v1 selectTree is identity", v1.selectTree((i32)0, (i32)UX_FORM_PHONE, &chosen), (i32)0);
    ck((u8*)"v1 chose any", chosen, (i32)UX_FORM_ANY);
    ck((u8*)"v1 conn count", v1.connCount(), (i32)1);
    ck((u8*)"v1 view ref resolves", v1.resolveView(v1.connSrc((i32)0), (i32)0), (i32)3);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXNB v2 — selection, fallback, re-parented binding, drop, v1\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    }
