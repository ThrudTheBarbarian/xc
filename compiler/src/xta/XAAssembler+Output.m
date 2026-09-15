/****************************************************************************\
|* XAAssembler+Output.m
\****************************************************************************/
#import "XAAssembler+Private.h"

/****************************************************************************\
|* Encode a `STA <addr>` 6502 instruction into `out`, picking zero-page
|* (0x85, 1-byte operand, 2 bytes total) when the address fits ZP and
|* absolute (0x8D, 2-byte little-endian operand, 3 bytes total) otherwise.
|* Returns the number of bytes written.
|*
|* Used by the preload-stub generator so layouts that put the bank
|* register outside zero page (e.g. cart-mapped at $C300) get the
|* correct opcode encoding without xta dispatching through the
|* assembler proper.
\****************************************************************************/
static unsigned emitBankRegStore(uint8_t* out, uint16_t addr)
    {
    if (addr <= 0xFF)
        {
        out[0] = 0x85;
        out[1] = (uint8_t)addr;
        return 2;
        }
    out[0] = 0x8D;
    out[1] = (uint8_t)(addr & 0xFF);
    out[2] = (uint8_t)((addr >> 8) & 0xFF);
    return 3;
    }

@implementation XAAssembler (Output)

#pragma mark - XEX Output

/****************************************************************************\
|* Write segments to an Atari XEX binary file. Emits the $FFFF header,
|* each segment with a 4-byte address header, and a RUNAD segment.
|* @param segments  The assembled segments to write.
|* @param entry     The run address (written to RUNAD at $02E0).
|* @param path      The output file path.
|* @return  YES on success, NO if the file could not be written.
\****************************************************************************/
- (BOOL)writeXEX:(NSArray<XASegment*>*)segments
      entryPoint:(uint16_t)entry
          toFile:(NSString*)path
    {
    NSMutableData* xex = [NSMutableData data];

    // $FFFF header
    uint8_t header[] = {0xFF, 0xFF};
    [xex appendBytes:header length:2];

    // Split each segment around shadow ranges so RAM-under-ROM bytes
    // get routed through the staging area + INITAD copy stub. Targets
    // without `.shadow_ranges` / `.shadow_stage` directives fall
    // through unchanged (mainPieces gets one entry per segment).
    NSMutableArray<NSDictionary*>* mainPieces = [NSMutableArray array];
    NSMutableArray<NSDictionary*>* shadowPieces = [NSMutableArray array];
    for (XASegment* seg in segments)
        {
        if (seg.data.length == 0)
            continue;
        [self splitMainSegment:seg
                  shadowRanges:self.shadowRanges
                    mainPieces:mainPieces
                  shadowPieces:shadowPieces];
        }

    for (NSDictionary* piece in mainPieces)
        {
        uint16_t start = [piece[@"start"] unsignedShortValue];
        NSData* data = piece[@"data"];
        uint16_t end = start + (uint16_t)data.length - 1;
        uint8_t segHeader[] = {start & 0xFF, (start >> 8) & 0xFF,
                               end & 0xFF, (end >> 8) & 0xFF};
        [xex appendBytes:segHeader length:4];
        [xex appendData:data];
        }

    if (shadowPieces.count > 0)
        {
        if (![self appendShadowStagingTo:xex pieces:shadowPieces])
            {
            return NO;
            }
        }

    // RUNAD segment: write entry point to $02E0
    uint8_t runad[] = {0xE0, 0x02, 0xE1, 0x02, entry & 0xFF, (entry >> 8) & 0xFF};
    [xex appendBytes:runad length:6];

    return [xex writeToFile:path atomically:YES];
    }

/****************************************************************************\
|* Write segments to a C64 PRG binary file. PRG format: 2-byte little-endian
|* load address followed by flat binary, with gaps zero-filled.
|* @param segments  The assembled segments to write.
|* @param entry     The entry point address (unused in PRG format).
|* @param path      The output file path.
|* @return  YES on success, NO if there are no segments or write fails.
\****************************************************************************/
- (BOOL)writePRG:(NSArray<XASegment*>*)segments
      entryPoint:(uint16_t)entry
          toFile:(NSString*)path
    {
    // Collect non-empty segments sorted by origin.
    NSMutableArray<XASegment*>* sorted = [NSMutableArray array];
    for (XASegment* seg in segments)
        {
        if (seg.data.length > 0)
            [sorted addObject:seg];
        }
    [sorted sortUsingComparator:^NSComparisonResult(XASegment* a, XASegment* b) {
      return a.origin < b.origin ? NSOrderedAscending : a.origin > b.origin ? NSOrderedDescending
                                                                            : NSOrderedSame;
    }];
    if (sorted.count == 0)
        return NO;

    uint16_t loadAddr = sorted[0].origin;
    uint16_t cursor = loadAddr;
    NSMutableData* prg = [NSMutableData data];

    // 2-byte load address (little-endian)
    uint8_t hdr[] = {loadAddr & 0xFF, (loadAddr >> 8) & 0xFF};
    [prg appendBytes:hdr length:2];

    // Flatten segments into a contiguous image, zero-filling gaps.
    for (XASegment* seg in sorted)
        {
        if (seg.origin > cursor)
            {
            NSUInteger gap = seg.origin - cursor;
            uint8_t* zeros = calloc(gap, 1);
            [prg appendBytes:zeros length:gap];
            free(zeros);
            }
        [prg appendData:seg.data];
        cursor = seg.origin + (uint16_t)seg.data.length;
        }

    return [prg writeToFile:path atomically:YES];
    }

/****************************************************************************\
|* Write segments to XEX with banked output mode. Banked segments (inside
|* the bank window) are loaded via INITAD preload stubs that set the bank
|* register before the data streams into the window. Supports both xt
|* ($82/$83 ZP pair) and xe (PORTB) bank-switching protocols.
|* @param segments  The assembled segments (both main and banked).
|* @param entry     The run address (written to RUNAD).
|* @param path      The output file path.
|* @return  YES on success, NO on overflow or write failure.
\****************************************************************************/
- (BOOL)writeBankedXEX:(NSArray<XASegment*>*)segments
            entryPoint:(uint16_t)entry
                toFile:(NSString*)path
    {
    NSMutableData* xex = [NSMutableData data];
    uint8_t header[] = {0xFF, 0xFF};
    [xex appendBytes:header length:2];

    // Separate banked segments (inside the bank window) from main segments
    uint16_t bwStart = self.bankWindowStart ?: 0x4000;
    uint16_t bwEnd = self.bankWindowEnd ?: 0x7FFF;
    NSMutableArray<XASegment*>* mainSegments = [NSMutableArray array];
    NSMutableArray<XASegment*>* bankedSegments = [NSMutableArray array];
    NSMutableArray<XASegment*>* cloakedSegments = [NSMutableArray array];

    for (XASegment* seg in segments)
        {
        if (seg.isCloaked)
            {
            [cloakedSegments addObject:seg];
            }
        else if (seg.origin >= bwStart && seg.origin <= bwEnd)
            {
            [bankedSegments addObject:seg];
            }
        else
            {
            [mainSegments addObject:seg];
            }
        }

    // Pre-split the main segments around shadow ranges NOW (rather
    // than at stage 6 below) so we know whether shadow staging
    // exists before the cloaked emission decides where to go.
    // shadowPieces feed the staging area at $stage_base; mainPieces
    // are the bytes that land in non-shadow main RAM ($A000+).
    NSMutableArray<NSDictionary*>* mainPieces = [NSMutableArray array];
    NSMutableArray<NSDictionary*>* shadowPieces = [NSMutableArray array];
    for (XASegment* seg in mainSegments)
        {
        if (seg.data.length == 0)
            continue;
        [self splitMainSegment:seg
                  shadowRanges:self.shadowRanges
                    mainPieces:mainPieces
                  shadowPieces:shadowPieces];
        }

    // Partition cloaked segments by region: banking-off (bankIndex
    // < 0) goes through the existing main-RAM-at-$4000 path;
    // numbered-bank segments load via their own PORTB-on preload
    // stub straight into the named bank.
    NSMutableArray<XASegment*>* cloakedBankNone = [NSMutableArray array];
    NSMutableArray<XASegment*>* cloakedBankNumbered = [NSMutableArray array];
    for (XASegment* cseg in cloakedSegments)
        {
        if (cseg.cloakedBankIndex < 0)
            [cloakedBankNone addObject:cseg];
        else
            [cloakedBankNumbered addObject:cseg];
        }
    BOOL hasCloakedHere = (cloakedBankNone.count > 0 && self.xeBankMask != 0);
    BOOL hasNumberedCloakedHere =
        (cloakedBankNumbered.count > 0 && self.xeBankMask != 0);
    BOOL hasShadowHere = (shadowPieces.count > 0);

    // Stage 4: emit cloaked + shadow-staging in an order that keeps
    // both intact in main RAM at $4000+. Both want to land in the
    // bank-window backing (banking off, PORTB bit 4 = 1). If we
    // emitted cloaked first and shadow second, shadow staging would
    // overwrite the first 1.9 KB or so of cloaked code — every
    // entry point at $4000-$478F vanishes and a `:cloaked` call
    // JSRs into garbage. Pre-fix symptom on xe-shadow + Gfx8 was
    // BRK at $4604 from cloaked-bank routines that no longer
    // existed. The shadow staging area is ephemeral (the INITAD
    // copy stub consumes it on the first fire), so emit shadow
    // first — it overwrites nothing, the stub copies it out to
    // $C000+/$D800+ shadow RAM, then the cloaked code segments
    // load on top of the now-unneeded staging buffer.
    //
    // Cloaked segments hold :cloaked library code that needs to
    // land in the main-RAM backing of the $4000-$7FFF window (so a
    // later `:cloaked` call with PORTB = $30 sees the library image
    // there). The trick: load them as ordinary XEX segments
    // targeting $4000, but first fire an INITAD stub that sets bit
    // 4 of PORTB (banking off). With banking off, writes to
    // $4000-$7FFF go to the underlying main RAM instead of a
    // selected bank. No copy loop needed — the XEX loader's own
    // write path puts the bytes exactly where the library needs
    // to live at runtime. The startup template's PORTB=$33 prime
    // overwrites any state we left, so we don't need a matching
    // "restore" stub on the tail end.
    //
    // 9-byte banking-off stub at CASBUF:
    //   LDA $D301 / ORA #$10 / STA $D301 / RTS
    uint8_t offStub[] = {
        0xAD,
        0x01,
        0xD3, // LDA $D301
        0x09,
        0x10, // ORA #$10  (bit 4 set = banking off)
        0x8D,
        0x01,
        0xD3, // STA $D301
        0x60, // RTS
    };
    const size_t offLen = sizeof(offStub);
    uint16_t offAddr = 0x03FD;
    uint16_t offEnd = (uint16_t)(offAddr + offLen - 1);
    uint8_t offHdr[] = {offAddr & 0xFF, (offAddr >> 8) & 0xFF,
                        offEnd & 0xFF, (offEnd >> 8) & 0xFF};
    uint8_t initadOff[] = {0xE2, 0x02, 0xE3, 0x02, 0xFD, 0x03};

    if (hasCloakedHere || hasShadowHere || hasNumberedCloakedHere)
        {
        // Prime the banking-off stub: install at $03FD, set INITAD
        // to it, trigger by re-loading the same bytes. After this
        // the bank window is plain main RAM for the rest of
        // loading (subsequent banked-segment preload stubs will
        // toggle banking back on per-segment).
        [xex appendBytes:offHdr length:4];
        [xex appendBytes:offStub length:offLen];
        [xex appendBytes:initadOff length:6];
        [xex appendBytes:offHdr length:4];
        [xex appendBytes:offStub length:offLen];
        }

    if (hasShadowHere)
        {
        // Append the shadow staging payload + the INITAD pointer
        // that points at its copy stub. After this segment the
        // loader will fire the stub on the *next* segment; we
        // follow with a trigger segment plus a reset of INITAD
        // back to $03FD so the shadow stub doesn't re-fire after
        // every cloaked / banked / main segment that follows
        // (re-firing would re-read the table — whose bytes are
        // about to be overwritten by cloaked code at $4000+ — and
        // copy bogus data to bogus shadow addresses).
        if (![self appendShadowStagingTo:xex pieces:shadowPieces])
            {
            return NO;
            }
        // Trigger: re-load the banking-off stub bytes. INITAD
        // currently points at the shadow copy stub — this segment's
        // load fires it once. The stub itself doesn't change PORTB
        // bit 4 (it only toggles bit 0 to flip ROM on), so banking
        // stays off after the copy completes.
        [xex appendBytes:offHdr length:4];
        [xex appendBytes:offStub length:offLen];
        // Now reset INITAD back to the banking-off stub so any
        // subsequent segment's INITAD fire is harmless. Without
        // this, the cloaked code we're about to emit clobbers the
        // shadow stub at $4000-$406D and its table at $406D+, so
        // the next INITAD fire would jump into cloaked code
        // mid-routine — undefined behaviour.
        [xex appendBytes:initadOff length:6];
        // Trigger the reset by re-loading the banking-off stub
        // bytes. Idempotent.
        [xex appendBytes:offHdr length:4];
        [xex appendBytes:offStub length:offLen];
        }

    if (hasCloakedHere)
        {
        // Cloaked segment payloads. They land at $4000+ as main
        // RAM (banking off has been active since the stub primed
        // it above). On xe-shadow this overwrites the staging
        // bytes at $4000-$stage_end, but those bytes have already
        // been copied to their shadow targets by the trigger
        // above, so we're free to reuse the address range.
        for (XASegment* cseg in cloakedBankNone)
            {
            if (cseg.data.length == 0)
                continue;
            uint16_t loadStart = cseg.origin;
            uint32_t loadEnd32 = (uint32_t)loadStart + cseg.data.length - 1;
            // Cloaked image must fit inside the bank window. Bytes
            // past $7FFF land in screen RAM ($8000-$9FFF) which
            // ANTIC overwrites continuously — at runtime any code
            // or data the cloaked image had stashed up there is
            // unreliable. Diagnose this clearly here rather than
            // letting the program crash later with a garbage JSR
            // target. The user can either reduce auto-cloak's
            // appetite (`-fauto-cloak=auto` instead of `always`),
            // mark fewer routines as `:cloaked` by hand, or add a
            // banked-spill fallback (future work).
            if (loadEnd32 > bwEnd)
                {
                NSUInteger overflow = (NSUInteger)(loadEnd32 - bwEnd);
                fprintf(stderr,
                        "xcc-as: cloaked image at $%04X is %lu bytes — "
                        "overflows the cloaked bank window "
                        "($%04X-$%04X) by %lu bytes into screen RAM. "
                        "Reduce -fauto-cloak appetite or shrink the "
                        ":cloaked surface.\n",
                        loadStart, (unsigned long)cseg.data.length,
                        bwStart, bwEnd,
                        (unsigned long)overflow);
                return NO;
                }
            uint16_t loadEnd = (uint16_t)loadEnd32;
            uint8_t sh[] = {loadStart & 0xFF, (loadStart >> 8) & 0xFF,
                            loadEnd & 0xFF, (loadEnd >> 8) & 0xFF};
            [xex appendBytes:sh length:4];
            [xex appendData:cseg.data];
            }
        // INITAD keeps firing after each segment but that's fine —
        // the stub at $03FD is idempotent (re-applies banking off).
        // When banked segments start below they install their own
        // preload stubs, which overwrite $03FD and restore banking
        // on for their bank-select writes.
        }
    else if (cloakedBankNone.count > 0)
        {
        fprintf(stderr,
                "xcc-as: cloaked segments are only supported on xe-family "
                "targets (xeBankMask = 0); ignoring %lu segment(s)\n",
                (unsigned long)cloakedBankNone.count);
        }

    if (hasNumberedCloakedHere)
        {
        // Numbered-bank cloaked regions: each segment loads into its
        // declared hardware bank with banking ON. Same wire protocol
        // as a regular banked segment, but with a fixed bank index
        // baked in by the layout (not assigned by the bank counter)
        // and not advancing the runtime counter — these regions sit
        // outside the data/code/regC pools and the codegen doesn't
        // pack other content into them.
        //
        // After each segment loads, banking stays ON with the named
        // bank still selected. That's harmless: the next segment
        // (another numbered-bank cloaked, a regular banked segment,
        // or a main segment) will install its own preload stub at
        // $03FD on entry, overwriting whatever PORTB state we left.
        for (XASegment* cseg in cloakedBankNumbered)
            {
            if (cseg.data.length == 0)
                continue;
            uint16_t loadStart = cseg.origin;
            uint32_t loadEnd32 = (uint32_t)loadStart + cseg.data.length - 1;
            if (loadEnd32 > bwEnd)
                {
                NSUInteger overflow = (NSUInteger)(loadEnd32 - bwEnd);
                fprintf(stderr,
                        "xcc-as: cloaked bank-%d image at $%04X is %lu bytes — "
                        "overflows the cloaked bank window "
                        "($%04X-$%04X) by %lu bytes into screen RAM.\n",
                        cseg.cloakedBankIndex,
                        loadStart, (unsigned long)cseg.data.length,
                        bwStart, bwEnd,
                        (unsigned long)overflow);
                return NO;
                }
            // Build a 13-byte read-modify-write PORTB stub that
            // selects the segment's named bank with banking ON.
            // Same shape as the regular banked-segment preload (see
            // below), but the bank id is fixed by the layout rather
            // than allocated by the counter.
            uint16_t bankIdx = (uint16_t)cseg.cloakedBankIndex;
            uint8_t bankBits = 0;
            uint16_t outBit = 1;
            for (int i = 0; i < 8; i++)
                {
                if (self.xeBankMask & (1u << i))
                    {
                    if (bankIdx & outBit)
                        bankBits |= (uint8_t)(1u << i);
                    outBit <<= 1;
                    }
                }
            uint8_t preserve = (uint8_t)(~(self.xeBankMask | 0x10));
            uint8_t stub[13];
            size_t stubLen = 0;
            stub[stubLen++] = 0xAD;
            stub[stubLen++] = 0x01;
            stub[stubLen++] = 0xD3; // LDA $D301
            stub[stubLen++] = 0x29;
            stub[stubLen++] = preserve; // AND #preserve
            stub[stubLen++] = 0x09;
            stub[stubLen++] = bankBits; // ORA #bankBits
            stub[stubLen++] = 0x8D;
            stub[stubLen++] = 0x01;
            stub[stubLen++] = 0xD3; // STA $D301
            stub[stubLen++] = 0x60; // RTS
            uint16_t stubAddr = 0x03FD;
            uint16_t stubEnd = (uint16_t)(stubAddr + stubLen - 1);
            uint8_t stubHdr[] = {stubAddr & 0xFF, (stubAddr >> 8) & 0xFF,
                                 stubEnd & 0xFF, (stubEnd >> 8) & 0xFF};
            uint8_t initad[] = {0xE2, 0x02, 0xE3, 0x02, 0xFD, 0x03};
            // Install stub, point INITAD at it, trigger by re-load.
            [xex appendBytes:stubHdr length:4];
            [xex appendBytes:stub length:stubLen];
            [xex appendBytes:initad length:6];
            [xex appendBytes:stubHdr length:4];
            [xex appendBytes:stub length:stubLen];
            // Real segment payload — banking ON with bankIdx selected,
            // bytes route into bank[bankIdx] for the $4000-$7FFF
            // window.
            uint16_t loadEnd = (uint16_t)loadEnd32;
            uint8_t sh[] = {loadStart & 0xFF, (loadStart >> 8) & 0xFF,
                            loadEnd & 0xFF, (loadEnd >> 8) & 0xFF};
            [xex appendBytes:sh length:4];
            [xex appendData:cseg.data];
            }
        }
    else if (cloakedBankNumbered.count > 0)
        {
        fprintf(stderr,
                "xcc-as: numbered-bank cloaked segments are only supported "
                "on xe-family targets (xeBankMask = 0); ignoring %lu "
                "segment(s)\n",
                (unsigned long)cloakedBankNumbered.count);
        }

    // Emit every xt banked segment via the same preload-stub
    // protocol. A tiny stub in CASBUF ($03FD) sets $82/$83 to the target
    // bank id, INITAD fires it, and then the real segment data
    // streams directly into the $4000-$7FFF window. Because
    // mem_write in the sim routes bytes to bank[current_bank()]
    // once banked_mode is on, the segment lands in the right
    // bank page without any staging buffer. (The old dual-bank
    // scheme used a $8000 staging area + a custom 6502 copier,
    // which is now impossible because $8000 is screen RAM. The
    // old "large class" path already used this preload-stub
    // scheme — we've just promoted it to be the only path.)
    // Stub-size optimisation: tracking $83 across iterations lets
    // us skip the `LDA #hi / STA $83` pair whenever the target
    // bank's high byte already matches what the register holds.
    // For any program with ≤256 bank pages (≥99.99% of real use)
    // every bank id has high byte 0, so after the very first
    // iteration the preload and reset stubs drop to 5 bytes each.
    // `hiState = -1` sentinel forces the first iteration to emit
    // the full 9-byte preload so we don't depend on the Atari
    // cold-start having zeroed $83.
    uint16_t stubAddr = 0x03FD;
    uint8_t initad[] = {0xE2, 0x02, 0xE3, 0x02, 0xFD, 0x03};
    int hiState = -1;
    // Collapsed-xt / xe path: single flat counter across all banked
    // segments. Under split xt (Option B) we maintain independent
    // code-side and data-side counters instead, so xta's bank id
    // assignment matches the xtc codegen's per-pool numbering (which
    // likewise tracks two independent 1-based counters via
    // XTBankPageTracker's split-pool mode).
    uint16_t bankPage = 1;
    uint16_t codeBankPage = 1;
    uint16_t dataBankPage = 1;
    uint16_t regCBankPage = 1; // PR3: counter for region-C segments
    // No $82/$83 fallback — the bank registers come from the layout. A
    // non-xe banked image that reaches here without them is a layout bug;
    // fail loudly rather than emit preload stubs against $82/$83.
    uint16_t codeReg = self.codeBankReg;
    uint16_t dataReg = self.dataBankReg;
    if (bankedSegments.count > 0 && self.xeBankMask == 0 && codeReg == 0)
        {
        fprintf(stderr, "xcc-as: banked output requires a code bank register "
                        "from the layout (registers = <code>, <data>); none set — there "
                        "is no $82 default\n");
        return NO;
        }
    BOOL hasRegCWindow =
        self.regCWindowStart != 0 && self.regCBankRegLo != 0;
    for (XASegment* bseg in bankedSegments)
        {
        // Segment classification: under split mode a segment whose
        // origin falls inside the data window routes through
        // $dataReg (its preload stub writes $83, its payload lands
        // in data_bank[N]); all other banked segments route through
        // $codeReg via the existing $82 path.
        // An additional region-C window (xt $7000-$7FFF, $84/$85)
        // routes through regCBankRegLo[/Hi] for the 16-bit-pair
        // case and gets its own bank-page counter.
        BOOL isRegCSeg = hasRegCWindow && bseg.origin >= self.regCWindowStart && bseg.origin <= self.regCWindowEnd;
        BOOL isDataSeg = !isRegCSeg && self.hasSplitBanking && bseg.origin >= self.dataWindowStart && bseg.origin <= self.dataWindowEnd;
        // Empty banked segments are placeholder bank-page anchors
        // (see the .org handler in pass 2: at -O3 the optimiser
        // can inline-and-delete every function on a bank page but
        // the preserved `.org $4000` still parses into a zero-byte
        // segment). Don't emit any XEX bytes for them, but DO burn
        // a bankPage slot so later classes stay on the bank number
        // their call sites were compiled against.
        if (bseg.data.length == 0)
            {
            if (isRegCSeg)
                {
                regCBankPage++;
                }
            else if (self.hasSplitBanking)
                {
                if (isDataSeg)
                    dataBankPage++;
                else
                    codeBankPage++;
                }
            else
                {
                bankPage++;
                }
            continue;
            }

        NSUInteger bankPageSz = (bwEnd - bwStart + 1);
        if (bseg.data.length > bankPageSz)
            {
            fprintf(stderr,
                    "xcc-as: banked segment at $%04X is %lu bytes — "
                    "exceeds the %luB bank page size\n",
                    bseg.origin, (unsigned long)bseg.data.length,
                    (unsigned long)bankPageSz);
            return NO;
            }
        // Split-bank xt: code-bank ($82-selected) and data-bank
        // ($83-selected) windows have separate page sizes and a
        // segment that originated in the code window must fit
        // entirely inside it. The full-window check above only
        // catches the rare case of a >16 KB blob; split-bank-aware
        // enforcement catches the common case of code overflowing
        // the 8 KB code half into the data window, where the
        // data-bank preload would put unrelated bytes at runtime
        // and any JMP/JSR/branch into the overflow BRKs. Without
        // this check the codegen's per-page packer is the only
        // defence; an estimator drift like the one that surfaced on
        // foundation_autobox/xt-no-regC silently produced an 8229-
        // byte code segment.
        if (self.hasSplitBanking)
            {
            uint16_t codeStart = self.bankWindowStart ?: bwStart;
            uint16_t codeEnd = self.dataWindowStart
                                   ? (self.dataWindowStart - 1)
                                   : bwEnd;
            uint16_t dataStart = self.dataWindowStart;
            uint16_t dataEnd = self.dataWindowEnd;
            if (isDataSeg)
                {
                NSUInteger half = (NSUInteger)(dataEnd - dataStart + 1);
                if (bseg.data.length > half)
                    {
                    fprintf(stderr,
                            "xcc-as: banked data segment at $%04X is %lu bytes "
                            "— exceeds the %luB split-bank data half "
                            "($%04X-$%04X). Code likely overflowed the "
                            "code half and bled into the data window; "
                            "rebuild with -O3 (smaller main) or split the "
                            "function across banks.\n",
                            bseg.origin, (unsigned long)bseg.data.length,
                            (unsigned long)half,
                            dataStart, dataEnd);
                    return NO;
                    }
                }
            else if (!isRegCSeg)
                {
                NSUInteger half = (NSUInteger)(codeEnd - codeStart + 1);
                if (bseg.data.length > half)
                    {
                    fprintf(stderr,
                            "xcc-as: banked code segment at $%04X is %lu bytes "
                            "— exceeds the %luB split-bank code half "
                            "($%04X-$%04X). The packer's size estimate "
                            "drifted from xta's actual emit (often a long-"
                            "branch rewrite inside a function); the "
                            "segment overflows into the $83-selected data "
                            "window where the per-bank XEX preload would "
                            "put unrelated bytes at runtime, and JMP/JSR/"
                            "branch into the overflow BRKs.\n",
                            bseg.origin, (unsigned long)bseg.data.length,
                            (unsigned long)half,
                            codeStart, codeEnd);
                    return NO;
                    }
                }
            }

        // Bank id for this segment's preload / reset stub. A `.bank <id>`
        // segment carries an explicit bankNumber (task #121) allocated to
        // not clash with the encounter-order user banks; everything else
        // uses the running counter. The counter still advances below so
        // any later auto-numbered segment stays correctly numbered.
        uint16_t effBankPage = (bseg.bankNumber >= 0)
                                   ? (uint16_t)bseg.bankNumber
                                   : bankPage;
        uint16_t thisPage = isRegCSeg
                                ? regCBankPage
                                : (self.hasSplitBanking
                                       ? (isDataSeg ? dataBankPage : codeBankPage)
                                       : effBankPage);

        // Preload stub in CASBUF ($03FD-$047F, the cassette buffer
        // that's free once we're not loading from tape).
        // xt form:                       xe form:
        //   LDA #<bankPage / STA $82       LDA #portBVal / STA $D301
        //   LDA #>bankPage / STA $83       RTS                (5 bytes)
        //   RTS                (5-9 b)
        // xe compresses the bank index through xeBankMask and ORs in
        // $20 (bit 5 set, bit 4 clear = banking enabled).
        uint8_t stub[16];
        size_t stubLen = 0;
        if (self.xeBankMask != 0)
            {
            // xe: read-modify-write stub. A plain `LDA #portB /
            // STA $D301` would clobber PORTB bits 0 and 1 — which
            // on a real Atari XE means disabling OS ROM and
            // re-enabling BASIC ROM (which maps over $A000-$BFFF,
            // exactly where our main code lives). The loader
            // needs to preserve those bits and only touch the
            // banking window + bit 4.
            // Layout (13 bytes):
            //   LDA $D301                  ; current PORTB
            //   AND #~(mask | $10)         ; preserve non-banking
            //   ORA #depositBits(idx,mask) ; new bank bits, bit 4 clear
            //   STA $D301
            //   RTS
            // Bank page id deposits straight into the PORTB mask:
            // page N → extended bank N. Same convention as
            // heapBank.portBBits in the codegen and the runtime
            // _heap_select_bank / _banked_load_byte / _banked_store_byte
            // helpers (see XTCodeGenerator.m). An earlier revision
            // subtracted 1 here and matched it in those four sites
            // — internally consistent but collapsed page 1 (the
            // first heap bank) onto extended bank 0 = the stack
            // bank, so xtc-stack pushes silently corrupted the
            // free-list size field at $4000-$4002.
            uint16_t bankIdx = effBankPage;
            uint8_t bankBits = 0;
            uint16_t outBit = 1;
            for (int i = 0; i < 8; i++)
                {
                if (self.xeBankMask & (1u << i))
                    {
                    if (bankIdx & outBit)
                        bankBits |= (uint8_t)(1u << i);
                    outBit <<= 1;
                    }
                }
            uint8_t preserve = (uint8_t)(~(self.xeBankMask | 0x10));
            stub[stubLen++] = 0xAD;
            stub[stubLen++] = 0x01;
            stub[stubLen++] = 0xD3; // LDA $D301
            stub[stubLen++] = 0x29;
            stub[stubLen++] = preserve; // AND #preserve
            stub[stubLen++] = 0x09;
            stub[stubLen++] = bankBits; // ORA #bankBits
            stub[stubLen++] = 0x8D;
            stub[stubLen++] = 0x01;
            stub[stubLen++] = 0xD3; // STA $D301
            stub[stubLen++] = 0x60; // RTS
            }
        else if (isRegCSeg)
            {
            // Region C — selector at regCBankRegLo (8-bit) or
            // regCBankRegLo + regCBankRegHi (16-bit pair).
            //   8-bit  (5 bytes): LDA #thisPageLo / STA <regLo> / RTS
            //   16-bit (10 bytes):
            //     LDA #thisPageLo / STA <regLo>
            //     LDA #thisPageHi / STA <regHi>
            //     RTS
            // STA encoded as zero-page (0x85, 1-byte operand) when the
            // address fits ZP, absolute (0x8D, 2-byte operand) otherwise
            // — supports cart-mapped bank registers outside ZP.
            stub[stubLen++] = 0xA9;
            stub[stubLen++] = (uint8_t)(thisPage & 0xFF);
            stubLen += emitBankRegStore(stub + stubLen, self.regCBankRegLo);
            if (self.regCBankRegHi != 0)
                {
                stub[stubLen++] = 0xA9;
                stub[stubLen++] = (uint8_t)((thisPage >> 8) & 0xFF);
                stubLen += emitBankRegStore(stub + stubLen, self.regCBankRegHi);
                }
            stub[stubLen++] = 0x60;
            }
        else if (self.hasSplitBanking)
            {
            // xt Option B split: write only the selector for this
            // segment's window half. Code-side stub touches $codeReg
            // ($82), data-side stub touches $dataReg ($83). Each
            // selector is an independent 8-bit bank id under split.
            uint16_t reg = isDataSeg ? dataReg : codeReg;
            stub[stubLen++] = 0xA9;
            stub[stubLen++] = (uint8_t)(thisPage & 0xFF);
            stubLen += emitBankRegStore(stub + stubLen, reg);
            stub[stubLen++] = 0x60;
            }
        else
            {
            // Joint selector: low byte → codeReg, high byte → dataReg
            // (matches the sim's collapsed `current_bank()` =
            // mem[codeReg] | mem[dataReg]<<8). codeReg/dataReg default to
            // $82/$83 but a layout can relocate them (xt: $D5C0/$D5C1).
            // A xt 8-bit page never sets bankHi, so the dataReg write
            // stays dormant there.
            uint8_t bankLo = (uint8_t)(effBankPage & 0xFF);
            uint8_t bankHi = (uint8_t)((effBankPage >> 8) & 0xFF);
            stub[stubLen++] = 0xA9;
            stub[stubLen++] = bankLo;
            stubLen += emitBankRegStore(stub + stubLen, codeReg);
            if ((int)bankHi != hiState)
                {
                stub[stubLen++] = 0xA9;
                stub[stubLen++] = bankHi;
                stubLen += emitBankRegStore(stub + stubLen, dataReg);
                hiState = bankHi;
                }
            stub[stubLen++] = 0x60;
            }

        uint16_t stubEnd = (uint16_t)(stubAddr + stubLen - 1);
        uint8_t sh1[] = {stubAddr & 0xFF, (stubAddr >> 8) & 0xFF,
                         stubEnd & 0xFF, (stubEnd >> 8) & 0xFF};
        [xex appendBytes:sh1 length:4];
        [xex appendBytes:stub length:stubLen];

        // INITAD → $03FD (CASBUF)
        [xex appendBytes:initad length:6];

        // Trigger segment: reload the stub to fire INITAD. The
        // stub's bytes are idempotent, so the overwrite is
        // harmless and the ensuing INITAD fire leaves $82/$83
        // pointing at bankPage.
        [xex appendBytes:sh1 length:4];
        [xex appendBytes:stub length:stubLen];

        // Real segment payload — loaded directly into
        // $4000-$7FFF. With $82/$83 already pointing at bankPage,
        // the sim's mem_write routes every byte into bank[bankPage].
        uint16_t loadStart = bseg.origin;
        uint16_t loadEnd = loadStart + (uint16_t)bseg.data.length - 1;
        uint8_t sh2[] = {loadStart & 0xFF, (loadStart >> 8) & 0xFF,
                         loadEnd & 0xFF, (loadEnd >> 8) & 0xFF};
        [xex appendBytes:sh2 length:4];
        [xex appendData:bseg.data];

        // Reset $82 to 0 before whatever loads next — otherwise
        // subsequent main-region segments at $A000+ would still see
        // bank[bankPage] selected (harmless, but tidier) and, more
        // importantly, a later banked segment's preload stub would
        // run against a random previous bank. Only bother zeroing
        // $83 if the preload stub above actually wrote a nonzero
        // value there; otherwise $83 is already 0 and we save 4
        // bytes per reset.
        uint8_t resetStub[16];
        size_t resetLen = 0;
        if (self.xeBankMask != 0)
            {
            // xe reset: force banking off while preserving every
            // other PORTB bit. `LDA / ORA #$10 / STA` is enough —
            // we only need bit 4 set; the mask bits can stay
            // wherever the last preload stub left them because
            // banking is off now, so the CPU won't see them.
            //   LDA $D301
            //   ORA #$10
            //   STA $D301
            //   RTS
            resetStub[resetLen++] = 0xAD;
            resetStub[resetLen++] = 0x01;
            resetStub[resetLen++] = 0xD3;
            resetStub[resetLen++] = 0x09;
            resetStub[resetLen++] = 0x10;
            resetStub[resetLen++] = 0x8D;
            resetStub[resetLen++] = 0x01;
            resetStub[resetLen++] = 0xD3;
            resetStub[resetLen++] = 0x60;
            }
        else if (isRegCSeg)
            {
            // Region C reset. Zero only the selector(s) we wrote
            // in the preload above. STA encoded as zero-page or
            // absolute based on each register's address.
            resetStub[resetLen++] = 0xA9;
            resetStub[resetLen++] = 0x00;
            resetLen += emitBankRegStore(resetStub + resetLen,
                                         self.regCBankRegLo);
            if (self.regCBankRegHi != 0)
                {
                resetLen += emitBankRegStore(resetStub + resetLen,
                                             self.regCBankRegHi);
                }
            resetStub[resetLen++] = 0x60;
            }
        else if (self.hasSplitBanking)
            {
            // xt Option B split reset: zero only the selector this
            // segment wrote. The other selector keeps whatever value
            // the previous same-side segment left — correct, since
            // under split mode code and data are fully independent
            // and we don't want a code-side reset to disturb the
            // data bank currently paged in.
            uint16_t reg = isDataSeg ? dataReg : codeReg;
            resetStub[resetLen++] = 0xA9;
            resetStub[resetLen++] = 0x00;
            resetLen += emitBankRegStore(resetStub + resetLen, reg);
            resetStub[resetLen++] = 0x60;
            }
        else
            {
            resetStub[resetLen++] = 0xA9;
            resetStub[resetLen++] = 0x00;
            resetLen += emitBankRegStore(resetStub + resetLen, codeReg);
            if (hiState != 0)
                {
                resetLen += emitBankRegStore(resetStub + resetLen, dataReg);
                hiState = 0;
                }
            resetStub[resetLen++] = 0x60;
            }
        uint16_t rsEnd = (uint16_t)(stubAddr + resetLen - 1);
        uint8_t rs1[] = {stubAddr & 0xFF, (stubAddr >> 8) & 0xFF,
                         rsEnd & 0xFF, (rsEnd >> 8) & 0xFF};
        [xex appendBytes:rs1 length:4];
        [xex appendBytes:resetStub length:resetLen];
        [xex appendBytes:initad length:6];
        [xex appendBytes:rs1 length:4];
        [xex appendBytes:resetStub length:resetLen];

        if (isRegCSeg)
            {
            regCBankPage++;
            }
        else if (self.hasSplitBanking)
            {
            if (isDataSeg)
                dataBankPage++;
            else
                codeBankPage++;
            }
        else
            {
            bankPage++;
            }
        }

    // mainPieces and shadowPieces were split off the mainSegments
    // earlier (before the cloaked/shadow staging emit) so the
    // staging area at $stage_base could be loaded ahead of the
    // cloaked payload. Now emit the main pieces — those that
    // don't overlap any shadow range.
    for (NSDictionary* piece in mainPieces)
        {
        uint16_t start = [piece[@"start"] unsignedShortValue];
        NSData* data = piece[@"data"];
        uint32_t end32 = (uint32_t)start + data.length - 1;
        uint16_t mrStart = self.mainRegionStart ?: 0xA000;
        uint16_t mrEnd = self.mainRegionEnd ?: 0xBFFF;
        if (start >= mrStart && start <= mrEnd && end32 > mrEnd)
            {
            NSUInteger overflow = (NSUInteger)(end32 - mrEnd);
            fprintf(stderr,
                    "xcc-as: main code segment at $%04X is %lu bytes — "
                    "overflows the %luB main region ($%04X-$%04X) by "
                    "%lu bytes. The program will load under xts "
                    "(flat 64 KB) but crash on real hardware.\n",
                    start, (unsigned long)data.length,
                    (unsigned long)(mrEnd - mrStart + 1),
                    mrStart, mrEnd,
                    (unsigned long)overflow);
            return NO;
            }
        uint16_t end = (uint16_t)end32;
        uint8_t sh[] = {start & 0xFF, (start >> 8) & 0xFF, end & 0xFF, (end >> 8) & 0xFF};
        [xex appendBytes:sh length:4];
        [xex appendData:data];
        }

    // Shadow staging is emitted up at the cloaked stage now.

    // RUNAD
    uint8_t runad[] = {0xE0, 0x02, 0xE1, 0x02, entry & 0xFF, (entry >> 8) & 0xFF};
    [xex appendBytes:runad length:6];

    return [xex writeToFile:path atomically:YES];
    }

#pragma mark - Shadow staging

/****************************************************************************\
|* Split a main segment around `_shadowRanges`. Bytes outside any shadow
|* range go to `mainPieces` (as @{ @"start", @"data" } dicts); bytes inside
|* a shadow range go to `shadowPieces` with the same shape. A segment that
|* doesn't overlap any shadow range yields one main piece (the whole thing).
|* When `shadowRanges` is nil/empty the segment is forwarded as one main
|* piece — caller behaves identically to the pre-staging path.
\****************************************************************************/
- (void)splitMainSegment:(XASegment*)seg
            shadowRanges:(nullable NSArray<NSArray<NSNumber*>*>*)ranges
              mainPieces:(NSMutableArray<NSDictionary*>*)mainPieces
            shadowPieces:(NSMutableArray<NSDictionary*>*)shadowPieces
    {
    NSData* segData = seg.data;
    uint32_t segStart = seg.origin;
    uint32_t segEnd = segStart + (uint32_t)segData.length - 1;

    if (ranges.count == 0 || self.shadowStageBase == 0)
        {
        [mainPieces addObject:@{@"start" : @(seg.origin), @"data" : segData}];
        return;
        }

    // Collect overlap windows (intersection of segment with each shadow
    // range), sorted by start address.
    NSMutableArray<NSArray<NSNumber*>*>* overlaps = [NSMutableArray array];
    for (NSArray<NSNumber*>* r in ranges)
        {
        uint16_t rStart = [r[0] unsignedShortValue];
        uint16_t rEnd = [r[1] unsignedShortValue];
        if (rEnd < segStart || rStart > segEnd)
            continue;
        uint32_t ovStart = MAX((uint32_t)rStart, segStart);
        uint32_t ovEnd = MIN((uint32_t)rEnd, segEnd);
        [overlaps addObject:@[ @(ovStart), @(ovEnd) ]];
        }
    [overlaps sortUsingComparator:^NSComparisonResult(NSArray<NSNumber*>* a,
                                                      NSArray<NSNumber*>* b) {
      return [a[0] compare:b[0]];
    }];

    if (overlaps.count == 0)
        {
        [mainPieces addObject:@{@"start" : @(seg.origin), @"data" : segData}];
        return;
        }

    uint32_t cursor = segStart;
    for (NSArray<NSNumber*>* ov in overlaps)
        {
        uint32_t ovStart = [ov[0] unsignedIntValue];
        uint32_t ovEnd = [ov[1] unsignedIntValue];
        if (cursor < ovStart)
            {
            NSUInteger off = cursor - segStart;
            NSUInteger len = ovStart - cursor;
            NSData* sub = [segData subdataWithRange:NSMakeRange(off, len)];
            [mainPieces addObject:@{@"start" : @((uint16_t)cursor), @"data" : sub}];
            }
        NSUInteger off = ovStart - segStart;
        NSUInteger len = ovEnd - ovStart + 1;
        NSData* sub = [segData subdataWithRange:NSMakeRange(off, len)];
        [shadowPieces addObject:@{@"target" : @((uint16_t)ovStart), @"data" : sub}];
        cursor = ovEnd + 1;
        }
    if (cursor <= segEnd)
        {
        NSUInteger off = cursor - segStart;
        NSUInteger len = segEnd - cursor + 1;
        NSData* sub = [segData subdataWithRange:NSMakeRange(off, len)];
        [mainPieces addObject:@{@"start" : @((uint16_t)cursor), @"data" : sub}];
        }
    }

/****************************************************************************\
|* Append the shadow staging segment + INITAD trigger to the XEX. Layout
|* of the segment loaded at `_shadowStageBase`:
|*   $00-$5F  copy stub (96 bytes): disables ROM, walks (src,dst,len)
|*            entries copying each, restores ROM, RTS.
|*   $60-…    table of 6-byte (src_lo, src_hi, dst_lo, dst_hi, len_lo,
|*            len_hi) entries, terminated by 6 zero bytes.
|*   …-end    concatenated shadow data, packed in entry order.
|* INITAD = `_shadowStageBase` so the loader fires the stub after the
|* segment lands. Returns NO if the payload would extend past $FFFF.
\****************************************************************************/
- (BOOL)appendShadowStagingTo:(NSMutableData*)xex
                       pieces:(NSArray<NSDictionary*>*)shadowPieces
    {
    uint16_t stageBase = self.shadowStageBase;
    NSUInteger numEntries = shadowPieces.count;
    NSUInteger stubSize = 0x6D;
    NSUInteger tableSize = (numEntries + 1) * 6; // +1 sentinel
    NSUInteger dataStart = stubSize + tableSize;

    // Pre-compute the total payload size and check that the entire
    // staging segment (stub + table + payload) fits BELOW the
    // Atari screen RAM region at $8000-$9FFF. Bytes loaded into
    // screen RAM during XEX-load time get displayed by ANTIC
    // immediately — fine while the loader is running, but the
    // bytes also persist past the staging stub's copy step, and
    // when the user program later relocates SAVMSC to $8000 (xl-
    // shadow's standard layout) ANTIC keeps reading those stale
    // staging bytes as character codes. The OS hands its DLI/
    // VBI vectors to indirect dispatch through ROM-shadowed RAM;
    // with screen RAM full of staging-derived shadow code
    // bytes, the indirect dispatch reaches places it shouldn't,
    // PC ends up in ZP, and the CPU CIMs after a runaway BRK
    // chain. gfx8_oval at -O0 reproduced this; the same fixture
    // at -O3 (smaller shadow payload, no overflow) ran cleanly.
    NSUInteger totalPayload = 0;
    for (NSDictionary* piece in shadowPieces)
        {
        totalPayload += [piece[@"data"] length];
        }
    uint32_t stageEnd32 = (uint32_t)stageBase + dataStart + totalPayload;
    const uint32_t SCREEN_RAM_START = 0x8000;
    if (stageEnd32 > SCREEN_RAM_START)
        {
        fprintf(stderr,
                "xcc-as: warning: shadow staging segment $%04X-$%04X "
                "extends %lu bytes into screen RAM at $8000. The XEX "
                "loader writes staging bytes there during load. The "
                "xl-shadow startup template clears screen RAM at boot "
                "after the staging stub finishes, so ANTIC won't read "
                "stale bytes — but tighter shadow code (`-O2` / `-O3`) "
                "would avoid the overlap entirely.\n",
                (unsigned)stageBase, (unsigned)(stageEnd32 - 1),
                (unsigned long)(stageEnd32 - SCREEN_RAM_START));
        }

    // Build the table with src addresses pointing into the data section.
    NSMutableData* table = [NSMutableData data];
    NSUInteger dataOffset = 0;
    for (NSDictionary* piece in shadowPieces)
        {
        uint16_t target = [piece[@"target"] unsignedShortValue];
        NSData* data = piece[@"data"];
        uint16_t len = (uint16_t)data.length;
        uint32_t src32 = (uint32_t)stageBase + dataStart + dataOffset;
        if (src32 > 0xFFFF)
            {
            fprintf(stderr,
                    "xcc-as: shadow staging payload at $%04X overflows 64 KB "
                    "(would extend past $FFFF). Reduce shadow-region code "
                    "size or move .shadow_stage lower.\n",
                    stageBase);
            return NO;
            }
        uint16_t src = (uint16_t)src32;
        uint8_t entry[] = {
            src & 0xFF,
            (src >> 8) & 0xFF,
            target & 0xFF,
            (target >> 8) & 0xFF,
            len & 0xFF,
            (len >> 8) & 0xFF,
        };
        [table appendBytes:entry length:6];
        dataOffset += data.length;
        }
    uint8_t sentinel[6] = {0, 0, 0, 0, 0, 0};
    [table appendBytes:sentinel length:6];

    // Build the copy stub. While ROM is off, $FFFA-$FFFF in RAM is
    // uninitialised — any NMI (VBI fires every frame) or IRQ would
    // dispatch through there and jump to $0000, BRK-looping us into
    // garbage. So:
    //   • PHP/SEI mask IRQs and BRK vectoring through $FFFE
    //   • STA $D40E with $00 disables NMIEN (VBI / DLI / SYS reset)
    //   • Re-enable NMIEN ($40 = VBI) and restore the saved P at end
    // The OS sets NMIEN to $40 during coldstart and the boot stub
    // re-asserts it later — writing $40 here matches both. Branch
    // offsets are precomputed for the fixed 109-byte layout:
    //   $00 PHP / $01 SEI                                       (2 B)
    //   $02 LDA #$00 / $04 STA $D40E                            (5 B)
    //   $07 LDA $D301 / $0A AND #$FE / $0C STA $D301           (8 B)
    //   $0F LDX #$00                                            (2 B)
    //   $11 next_entry: 6× (LDA table,X / STA $Cn / INX)       (36 B)
    //   $35 LDA $C4 / $37 ORA $C5 / $39 BEQ done (+35)          (6 B)
    //   $3B copy_loop: 32 bytes copy + counter decrement
    //   $5B JMP next_entry                                      (3 B)
    //   $5E done: LDA $D301 / ORA #$01 / STA $D301             (8 B)
    //   $66 LDA #$40 / $68 STA $D40E                            (5 B)
    //   $6B PLP / $6C RTS                                       (2 B)
    uint16_t tableAddr = stageBase + (uint16_t)stubSize; // = stageBase + $6D
    uint16_t nextEntry = stageBase + 0x11;               // entry-load loop
    uint8_t tlo = tableAddr & 0xFF, thi = (tableAddr >> 8) & 0xFF;
    uint8_t nelo = nextEntry & 0xFF, nehi = (nextEntry >> 8) & 0xFF;
    uint8_t stubBytes[] = {
        0x08, // PHP
        0x78, // SEI
        0xA9,
        0x00, // LDA #$00
        0x8D,
        0x0E,
        0xD4, // STA NMIEN ($D40E)
        // prelude: ROM off, X = 0
        0xAD,
        0x01,
        0xD3, // LDA $D301
        0x29,
        0xFE, // AND #$FE
        0x8D,
        0x01,
        0xD3, // STA $D301
        0xA2,
        0x00, // LDX #$00
        // next_entry ($0011): load 6 bytes from table[X..X+5] -> $C0..$C5
        0xBD,
        tlo,
        thi,
        0x85,
        0xC0,
        0xE8, // LDA table,X / STA $C0 / INX
        0xBD,
        tlo,
        thi,
        0x85,
        0xC1,
        0xE8,
        0xBD,
        tlo,
        thi,
        0x85,
        0xC2,
        0xE8,
        0xBD,
        tlo,
        thi,
        0x85,
        0xC3,
        0xE8,
        0xBD,
        tlo,
        thi,
        0x85,
        0xC4,
        0xE8,
        0xBD,
        tlo,
        thi,
        0x85,
        0xC5,
        0xE8,
        // end-of-table check: len == 0 → done
        0xA5,
        0xC4, // LDA $C4
        0x05,
        0xC5, // ORA $C5
        0xF0,
        0x23, // BEQ done (+35 → $005E)
        // copy_loop ($003B): copy one byte at a time, decrement len
        0xA0,
        0x00, // LDY #$00
        0xB1,
        0xC0, // LDA ($C0),Y
        0x91,
        0xC2, // STA ($C2),Y
        0xE6,
        0xC0,
        0xD0,
        0x02,
        0xE6,
        0xC1, // INC src
        0xE6,
        0xC2,
        0xD0,
        0x02,
        0xE6,
        0xC3, // INC dst
        0xA5,
        0xC4,
        0xD0,
        0x02,
        0xC6,
        0xC5, // if len_lo==0, dec len_hi
        0xC6,
        0xC4, // DEC len_lo
        0xA5,
        0xC4,
        0x05,
        0xC5, // LDA len_lo / ORA len_hi
        0xD0,
        0xE0, // BNE copy_loop (-32 → $003B)
        0x4C,
        nelo,
        nehi, // JMP next_entry
        // done ($005E): ROM on, NMIs back on (VBI), restore P, return
        0xAD,
        0x01,
        0xD3, // LDA $D301
        0x09,
        0x01, // ORA #$01
        0x8D,
        0x01,
        0xD3, // STA $D301
        0xA9,
        0x40, // LDA #$40
        0x8D,
        0x0E,
        0xD4, // STA NMIEN
        0x28, // PLP
        0x60, // RTS
    };
    if (sizeof(stubBytes) != stubSize)
        {
        fprintf(stderr,
                "xcc-as: internal: shadow copy stub size mismatch (got %lu, expected %lu)\n",
                (unsigned long)sizeof(stubBytes), (unsigned long)stubSize);
        return NO;
        }

    // Compose the full payload: stub + table + concatenated data.
    NSMutableData* payload = [NSMutableData data];
    [payload appendBytes:stubBytes length:sizeof(stubBytes)];
    [payload appendData:table];
    for (NSDictionary* piece in shadowPieces)
        {
        [payload appendData:piece[@"data"]];
        }

    uint32_t stageEnd = (uint32_t)stageBase + payload.length - 1;
    if (stageEnd > 0xFFFF)
        {
        fprintf(stderr,
                "xcc-as: shadow staging payload at $%04X is %lu bytes, runs "
                "past $FFFF. Reduce shadow-region code size or pick a "
                "lower stage address.\n",
                stageBase, (unsigned long)payload.length);
        return NO;
        }

    // Emit segment header + payload.
    uint16_t end = (uint16_t)stageEnd;
    uint8_t sh[] = {stageBase & 0xFF, (stageBase >> 8) & 0xFF,
                    end & 0xFF, (end >> 8) & 0xFF};
    [xex appendBytes:sh length:4];
    [xex appendData:payload];

    // INITAD: when the loader finishes writing the segment above it
    // checks $02E2/$02E3, and if non-zero JSRs that address. Pointing
    // it at the stub fires the copy + ROM-toggle dance immediately.
    uint8_t initad[] = {0xE2, 0x02, 0xE3, 0x02,
                        stageBase & 0xFF, (stageBase >> 8) & 0xFF};
    [xex appendBytes:initad length:6];

    return YES;
    }

#pragma mark - Listing

/****************************************************************************\
|* Generate a listing string from the last assembly. Shows PC addresses
|* alongside source lines for instructions, directives, and labels.
|* @return  A multi-line listing string, or nil if no assembly has been run.
\****************************************************************************/
- (nullable NSString*)generateListing
    {
    NSMutableString* listing = [NSMutableString string];
    uint16_t pc = 0;

    for (XAParsedLine* pl in self.parsedLines)
        {
        if (pl.type == XALineDirectiveOrg)
            {
            pc = (uint16_t)[self evaluateExpression:pl.operand];
            [listing appendFormat:@"       %04X          %@\n", pc, pl.rawText ?: @""];
            }
        else if (pl.type == XALineInstruction)
            {
            [listing appendFormat:@"  %04X               %@\n", pc, pl.rawText ?: @""];
            pc += pl.byteSize;
            }
        else if (pl.type == XALineDirectiveByte || pl.type == XALineDirectiveWord ||
                 pl.type == XALineDirectiveLong || pl.type == XALineDirectiveString ||
                 pl.type == XALineDirectiveSpace)
            {
            [listing appendFormat:@"  %04X               %@\n", pc, pl.rawText ?: @""];
            pc += pl.byteSize;
            }
        else
            {
            [listing appendFormat:@"                     %@\n", pl.rawText ?: @""];
            }
        }

    return listing;
    }

@end
