; heap.asm — coalescing free-list heap allocator
;
; Replaces the bump allocator when -falloc=heap is selected. Preserves
; the _heap_alloc calling convention (A = size in bytes, returns A=lo
; / X=hi of payload pointer) and adds _heap_free (A=lo / X=hi of payload
; pointer, void return) for reclamation.
;
; Multi-bank notes (banked-heap targets, heap_bank_first <= heap_bank_last):
;   The heap is laid out across one or more identical banks. Each bank
;   has its own [heap_low, heap_end) range — the same address window
;   in the bank-window slot, but a different physical bank selected
;   via _heap_select_bank. Block sizes are stored as 15 bits (32 KB
;   max), so a single block never crosses a bank boundary; coalesce
;   stays within whichever bank it started in.
;
;   Allocator: walks bank N starting at heap_bank_first, falling through
;   to bank N+1 on OOM until heap_bank_last is exhausted. On success the
;   bank that satisfied the request is returned in Y so the caller can
;   build a 3-byte banked pointer (A=lo, X=hi, Y=bank).
;
;   Free: takes the bank in Y and switches to it before walking. After
;   any allocator/free call, the helpers restore heap_bank_first as
;   the selected bank — that's the bank main code expects to see in
;   the bank window between calls (matches the boot state established
;   by the startup template).
;
;   Single-bank targets (heap_bank_first == heap_bank_last) traverse
;   the bank loop exactly once and the runtime is observably identical
;   to the prior single-bank implementation.
;
; Template substitutions (resolved by the codegen at emission time):
;   {{zp.hp}}  ZP pair reused as walker pointer (free-list mode
;              repurposes the bump-allocator HP slot)
;   {{zp.tmp}} ZP pair used as a secondary pointer during coalesce
;
; Linker symbols (emitted by the codegen from the [heap] layout):
;   heap_low         first byte of heap region (inclusive)
;   heap_top         last byte of heap region (inclusive)
;   heap_end         one past heap_top (exclusive upper bound)
;   heap_bank_first  first reserved heap bank (1-based; absent on flat-
;                    heap targets which never call _heap_select_bank)
;   heap_bank_last   last reserved heap bank (== heap_bank_first when
;                    only one bank is reserved)
;
; Per-target helper (emitted by the codegen alongside this template on
; banked-heap targets):
;   _heap_select_bank  entry A = 1-based bank id; switches the bank
;                      window to that bank. Clobbers A and the bank
;                      register (xt: $82/$83; xe: PORTB).
;
; Block layout (each block is contiguous in the heap range):
;   byte 0      = size low
;   byte 1      = size high (bit 7 = 1 if free, 0 if allocated)
;   bytes 2..4  = weak_head: head of this object's intrusive weak-slot
;                 chain, as a 3-byte banked pointer (lo, hi, bank).
;                 Zero when nothing weakly references the object —
;                 which is the overwhelmingly common case, and is why
;                 dealloc costs ONE null test rather than a table scan.
;                 (allocated blocks only; unused on free)
;   byte 5      = retain count low  (allocated blocks only; unused on free)
;   byte 6      = retain count high (allocated blocks only; unused on free)
;   bytes 7..n  = payload (n = total size − 7)
;
; weak_head sits BEFORE the retain count deliberately: the retain count
; must stay at payload−2 because the inline ARC hot path reads it there.
; Growing the header in front of it means not one line of ARC codegen
; changes — only this file and weak.asm move.
;
; The stored size is the TOTAL block size (header + payload). That way
; the walker advances by `size` and lands exactly on the next header.
; The free flag packs into bit 7 of byte 1, leaving 15 bits for size —
; 32 KB per block, more than any heap region we currently emit.
;
; The retain count is 2 bytes (16-bit little-endian), set to 1 by the
; allocator. _obj_retain (in retain.asm) increments it, saturating at
; $FFFF; _obj_decref decrements and returns carry-set when the count
; reaches 0 (signalling the caller to invoke the dealloc path and
; _heap_free the block).
;
; Allocator (_heap_alloc):
;   req = A + 7
;   walk from heap_low; for each block:
;       if free and size >= req:
;           if (size - req) >= 4 → split (new free block at walker+req)
;           else                 → consume whole block
;           write retain count = 1 at walker+2 / walker+3 (lo, hi)
;           return walker + 7
;       else advance walker by size
;   if walker reaches heap_end → advance to next bank, or OOM if none
;
; Free (_heap_free):
;   if null → return
;   block = ptr - 4; mark free
;   walk from heap_low tracking the previous block; when we reach
;   `block`, if prev is free, merge (prev.size += block.size).
;   then check the right neighbour at (current + current.size); if
;   it's free, merge it into current too.
;
; Non-reentrant. The static scratch slots below are shared between
; alloc and free.

; ─────────────────────────────────────────────────────────────────────
; _heap_advance_bank — advance _heap_bank_cur to the next bank in the
; walk. Returns C=0 on success (cur is the new bank), C=1 on OOM (every
; bank exhausted). Caller branches: BCS <local_done_label>.
;
; Bank id encoding (PR4b option a): data-pool banks are 1..heap_bank_last
; (bit 7 clear). Region-C heap banks live at $81..regC_heap_bank_last
; (bit 7 set). The walk goes data-pool first, then transitions into
; region-C when data is exhausted iff regC_heap_bank_first != 0.
; Programs without region-C declared see regC_heap_bank_first = 0 and
; the transition path collapses straight into OOM, so the call adds
; one extra JSR/RTS pair vs the previous inline pattern but the same
; observable behaviour.
; ─────────────────────────────────────────────────────────────────────
_heap_advance_bank:
    LDA #heap_bank_dynamic
    BEQ _hab_fixed
    ; Dynamic: the heap owns banks heap_bank_first.._heap_hiwater
    ; (contiguous — claimed lowest-fit, grown only at the top). Advance
    ; within that range; at the top return C=1 so the caller (alloc) can
    ; decide whether to claim another bank.
    LDA _heap_bank_cur
    CMP _heap_hiwater
    BCS _hab_oom              ; cur >= hiwater → no more owned banks
    INC _heap_bank_cur
    CLC
    RTS
_hab_fixed:
    LDA _heap_bank_cur
    BMI _hab_regC
    ; Data-pool: are we at the last data bank?
    CMP #heap_bank_last
    BCC _hab_inc_data
    ; Past the data pool — transition into region-C if any.
    LDA #regC_heap_bank_first
    BEQ _hab_oom
    STA _heap_bank_cur
    CLC
    RTS
_hab_inc_data:
    INC _heap_bank_cur
    CLC
    RTS
_hab_regC:
    CMP #regC_heap_bank_last
    BCS _hab_oom
    INC _heap_bank_cur
    CLC
    RTS
_hab_oom:
    SEC
    RTS

; ─────────────────────────────────────────────────────────────────────
; _heap_setup_window — populate the four window-cache bytes from the
; current bank in _heap_bank_cur. Walker code reads those statics
; instead of `#<heap_low` / `#>heap_low` / `#<heap_end` / `#>heap_end`
; so it transparently picks up the region-C window addresses when bit
; 7 of the bank id is set. Flat-heap layouts (xl-shadow / xe-nobank)
; have non-page-aligned heap_low, so the low bytes have to be cached
; too — every walker uses the same template regardless of layout.
; ─────────────────────────────────────────────────────────────────────
_heap_setup_window:
    ; Bit 7 of the bank id marks a region-C bank — but ONLY when the
    ; layout actually declares region C. With no region C (xt's on-demand
    ; data heap, which spans data banks 1..$FF), $80-$FF are ordinary data
    ; banks and must use the data window, not the absent region-C window.
    LDA #regC_heap_bank_first
    BEQ _hsw_data
    LDA _heap_bank_cur
    BMI _hsw_regC
_hsw_data:
    LDA #<heap_low
    STA _hp_win_lo_lo
    LDA #>heap_low
    STA _hp_win_lo_hi
    LDA #<heap_end
    STA _hp_win_end_lo
    LDA #>heap_end
    STA _hp_win_end_hi
    RTS
_hsw_regC:
    LDA #<regC_heap_low
    STA _hp_win_lo_lo
    LDA #>regC_heap_low
    STA _hp_win_lo_hi
    LDA #<regC_heap_end
    STA _hp_win_end_lo
    LDA #>regC_heap_end
    STA _hp_win_end_hi
    RTS

_heap_init:
    JSR _heap_save_caller_bank
    LDA #heap_bank_dynamic
    BNE _hi_dynamic
    ; ── Fixed reservation: init every bank heap_bank_first..last ──
    LDA #heap_bank_first
    STA _heap_bank_cur
_hi_bank_loop:
    JSR _heap_init_bank            ; init _heap_bank_cur's free-list
    JSR _heap_advance_bank
    BCS _hi_done
    JMP _hi_bank_loop
_hi_dynamic:
    ; ── On-demand: clear the shared bitmap, claim one bank, init it ──
    JSR _bank_init
    JSR _bank_claim                ; A = first heap bank (lowest free)
    STA _heap_bank_cur
    STA _heap_hiwater
    JSR _heap_init_bank
_hi_done:
    ; Restore whichever bank the caller had selected before the
    ; init walk clobbered PORTB / $82-$83.
    JMP _heap_restore_caller_bank  ; tail-call: RTS through restore

; _heap_init_bank — write a single whole-window free block into the bank
; currently in _heap_bank_cur. Selects the bank + window first.
_heap_init_bank:
    LDA _heap_bank_cur
    JSR _heap_select_bank
    JSR _heap_setup_window
    ; Initial block covers [window_low, window_end) — size = end - low.
    LDA _hp_win_lo_lo
    STA {{zp.hp}}
    LDA _hp_win_lo_hi
    STA {{zp.hp}}+1
    SEC
    LDA _hp_win_end_lo
    SBC _hp_win_lo_lo
    STA _heap_init_sz
    LDA _hp_win_end_hi
    SBC _hp_win_lo_hi
    ORA #$80                       ; set free flag on high byte
    STA _heap_init_sz+1
    LDY #$00
    LDA _heap_init_sz
    STA ({{zp.hp}}),Y
    INY
    LDA _heap_init_sz+1
    STA ({{zp.hp}}),Y
    RTS

_heap_init_sz:
    .byte $00, $00
_heap_hiwater:
    .byte $00

; ─────────────────────────────────────────────────────────────────────
; _heap_alloc   — allocate A bytes (A = 8-bit size).
; _heap_alloc16 — allocate A/X bytes (A=lo, X=hi; supports up to 32 KB).
; Both return A=lo / X=hi of payload pointer + Y=bank id of the bank
; that satisfied the request, or A=X=Y=0 on OOM (every bank exhausted).
; ─────────────────────────────────────────────────────────────────────
_heap_alloc:
    ; Widen the 8-bit size to 16-bit (hi=0), then fall into the 16-bit
    ; entry. Lets every call site use the same allocator regardless of
    ; whether the requested size fits in one byte. Snapshot the
    ; caller's bank first; _heap_alloc16 skips the second snapshot
    ; because we fall through into its body below the save.
    JSR _heap_save_caller_bank
    LDX #$00
    JMP _ha_body
_heap_alloc16:
    JSR _heap_save_caller_bank
_ha_body:
    ; req = size + 7 (16-bit). The seven header bytes are: 2 size bytes
    ; + 3 weak_head bytes + 2 retain-count bytes (all initialised below
    ; in _ha_ret).
    CLC
    ADC #$07
    STA _heap_req
    TXA
    ADC #$00
    STA _heap_req+1

    ; Start the bank scan at the first heap bank.
    LDA #heap_bank_first
    STA _heap_bank_cur

_ha_bank_loop:
    LDA _heap_bank_cur
    JSR _heap_select_bank
    JSR _heap_setup_window

    ; walker = window low (reset at each bank boundary)
    LDA _hp_win_lo_lo
    STA {{zp.hp}}
    LDA _hp_win_lo_hi
    STA {{zp.hp}}+1

_ha_loop:
    ; Bounds check: walker >= window end → exhausted this bank.
    LDA {{zp.hp}}+1
    CMP _hp_win_end_hi
    BCC _ha_read
    BNE _ha_next_bank
    LDA {{zp.hp}}
    CMP _hp_win_end_lo
    BCS _ha_next_bank

_ha_read:
    ; Read header; cache masked size in _heap_cur_size.
    LDY #$00
    LDA ({{zp.hp}}),Y
    STA _heap_cur_size
    INY
    LDA ({{zp.hp}}),Y
    STA _heap_cur_hdr              ; preserve raw byte (with free flag)
    AND #$7F
    STA _heap_cur_size+1

    ; Is this block free? bit 7 of raw header byte 1.
    LDA _heap_cur_hdr
    BPL _ha_advance                ; allocated → skip

    ; Compare size >= req.
    LDA _heap_cur_size
    CMP _heap_req
    LDA _heap_cur_size+1
    SBC _heap_req+1
    BCC _ha_advance                ; too small

    ; Remainder = cur_size - req.
    SEC
    LDA _heap_cur_size
    SBC _heap_req
    STA _heap_rem
    LDA _heap_cur_size+1
    SBC _heap_req+1
    STA _heap_rem+1

    ; If remainder >= 7, split; else consume whole block. The threshold is
    ; the header size: a smaller remainder could not hold a valid header, so
    ; the walker (which advances by `size`) would lose sync with the blocks.
    LDA _heap_rem+1
    BNE _ha_split
    LDA _heap_rem
    CMP #$07
    BCS _ha_split

    ; No split: clear free flag (write the masked high byte back).
    LDY #$01
    LDA _heap_cur_size+1
    STA ({{zp.hp}}),Y
    JMP _ha_ret

_ha_split:
    ; Compute new free-block address = walker + req, in {{zp.tmp}}.
    CLC
    LDA {{zp.hp}}
    ADC _heap_req
    STA {{zp.tmp}}
    LDA {{zp.hp}}+1
    ADC _heap_req+1
    STA {{zp.tmp}}+1

    ; Write new free header (size = rem, free bit set).
    LDY #$00
    LDA _heap_rem
    STA ({{zp.tmp}}),Y
    INY
    LDA _heap_rem+1
    ORA #$80
    STA ({{zp.tmp}}),Y

    ; Overwrite current header with (size = req, allocated).
    LDY #$00
    LDA _heap_req
    STA ({{zp.hp}}),Y
    INY
    LDA _heap_req+1
    STA ({{zp.hp}}),Y

_ha_ret:
    ; Initialise the weak_head chain pointer = null at bytes 2..4, then
    ; the retain count = 1 at bytes 5..6 (16-bit little-endian: lo=1,
    ; hi=0), before handing the payload pointer back to the caller.
    ;
    ; Zeroing weak_head here is load-bearing: _obj_decref tests it on
    ; EVERY dealloc, and a freed block handed straight back out would
    ; otherwise arrive holding a stale chain head and send the zeroing
    ; walk off into dead memory.
    LDY #$02
    LDA #$00
    STA ({{zp.hp}}),Y              ; weak_head lo
    INY
    STA ({{zp.hp}}),Y              ; weak_head hi
    INY
    STA ({{zp.hp}}),Y              ; weak_head bank
    INY
    LDA #$01
    STA ({{zp.hp}}),Y              ; retain lo  (byte 5)
    INY
    LDA #$00
    STA ({{zp.hp}}),Y              ; retain hi  (byte 6)

    ; Stash payload ptr (= walker + 7) so we can restore the bank
    ; window before returning. The PHA/PLA dance the previous
    ; single-bank version used can't carry Y across, so use static
    ; scratch instead.
    CLC
    LDA {{zp.hp}}
    ADC #$07
    STA _heap_ret_lo
    LDA {{zp.hp}}+1
    ADC #$00
    STA _heap_ret_hi
    ; Restore the caller's bank so the allocator is transparent to
    ; whichever bank state the caller was running under. The
    ; allocated payload's bank id is returned in Y so the caller
    ; can build a 3-byte banked pointer regardless of the live
    ; window. With 3-byte uniform pointers there is no $89 bank-hi.
    JSR _heap_restore_caller_bank
    LDA _heap_ret_lo
    LDX _heap_ret_hi
    LDY _heap_bank_cur
    RTS

_ha_advance:
    ; walker += cur_size (masked sizes already in _heap_cur_size).
    CLC
    LDA {{zp.hp}}
    ADC _heap_cur_size
    STA {{zp.hp}}
    LDA {{zp.hp}}+1
    ADC _heap_cur_size+1
    STA {{zp.hp}}+1
    JMP _ha_loop

_ha_next_bank:
    ; Try the next bank via the shared advance helper. C=1 = every
    ; owned bank exhausted (data pool then optional region-C pool).
    JSR _heap_advance_bank
    BCC _ha_bank_loop
    ; No more owned banks. On the on-demand heap, claim one more from the
    ; shared bitmap before giving up; a fixed heap is simply out of space.
    LDA #heap_bank_dynamic
    BEQ _ha_oom
    JSR _heap_grow
    BCC _ha_bank_loop
    ; fall through to OOM

_ha_oom:
    ; Every bank exhausted. Restore the caller's bank before
    ; returning A=X=Y=0.
    JSR _heap_restore_caller_bank
    LDA #$00
    TAX
    TAY
    RTS

; _heap_grow — on-demand heap only. Claim one more data bank from the
; shared bitmap and init its free-list. → C=0 with _heap_bank_cur set to
; the new bank on success; C=1 if the heap is already at the data
; window's last page or no bank is free. Leaves A/X/Y free to clobber
; (the alloc loop re-selects + re-walks afterwards).
_heap_grow:
    LDA _heap_hiwater
    CMP #heap_bank_last           ; at the last page the window can map?
    BCS _hg_full
    CLC
    ADC #$01                      ; the next CONTIGUOUS bank (hiwater+1)
    JSR _bank_claim_at            ; claim exactly that one — keeps the heap
    BCS _hg_full                  ;   contiguous; if bank() reserved it the
    STA _heap_bank_cur            ;   heap OOMs gracefully (no corruption)
    STA _heap_hiwater
    JSR _heap_init_bank
    CLC
    RTS
_hg_full:
    SEC
    RTS

; ─────────────────────────────────────────────────────────────────────
; _heap_free — free block at payload A=lo / X=hi / Y=bank. Null-safe.
; Y is the bank the pointer lives in (1-based id). On flat-heap builds
; (no _heap_select_bank emitted) this routine is still callable, but
; the JSR _heap_select_bank lines below are unreachable because flat-
; heap targets never link this template — they use the bump allocator
; instead.
; ─────────────────────────────────────────────────────────────────────
_heap_free:
    JSR _heap_save_caller_bank
    STA _heap_free_ptr
    STX _heap_free_ptr+1
    ORA _heap_free_ptr+1
    BNE _hf_not_null
    ; Null pointer: nothing to do, but restore caller bank for
    ; symmetry so the routine is bank-neutral on every path.
    JMP _heap_restore_caller_bank

_hf_not_null:
    ; Switch to the pointer's bank before touching its block header.
    STY _heap_free_bank
    TYA
    JSR _heap_select_bank
    ; Bank-cur is the bank we're freeing in; setup_window picks the
    ; right window addresses (data pool vs region C) from its bit 7.
    STY _heap_bank_cur
    JSR _heap_setup_window

    ; current = ptr - 7 (block header address), store in {{zp.tmp}}.
    SEC
    LDA _heap_free_ptr
    SBC #$07
    STA {{zp.tmp}}
    LDA _heap_free_ptr+1
    SBC #$00
    STA {{zp.tmp}}+1

    ; Mark free (set bit 7 of header byte 1).
    LDY #$01
    LDA ({{zp.tmp}}),Y
    ORA #$80
    STA ({{zp.tmp}}),Y

    ; ── Find left neighbour by walking from window low ──
    LDA _hp_win_lo_lo
    STA {{zp.hp}}
    LDA _hp_win_lo_hi
    STA {{zp.hp}}+1
    LDA #$00
    STA _heap_prev_ptr
    STA _heap_prev_ptr+1

_hf_walk:
    ; Arrived at current?
    LDA {{zp.hp}}+1
    CMP {{zp.tmp}}+1
    BNE _hf_step
    LDA {{zp.hp}}
    CMP {{zp.tmp}}
    BEQ _hf_arrived

_hf_step:
    ; Remember walker as prev before advancing.
    LDA {{zp.hp}}
    STA _heap_prev_ptr
    LDA {{zp.hp}}+1
    STA _heap_prev_ptr+1

    ; Read size (masked) at walker.
    LDY #$00
    LDA ({{zp.hp}}),Y
    STA _heap_cur_size
    INY
    LDA ({{zp.hp}}),Y
    AND #$7F
    STA _heap_cur_size+1

    ; walker += size.
    CLC
    LDA {{zp.hp}}
    ADC _heap_cur_size
    STA {{zp.hp}}
    LDA {{zp.hp}}+1
    ADC _heap_cur_size+1
    STA {{zp.hp}}+1

    ; Guard against runaway walk (shouldn't happen with well-formed chain).
    LDA {{zp.hp}}+1
    CMP _hp_win_end_hi
    BCC _hf_walk
    BNE _hf_right_merge
    LDA {{zp.hp}}
    CMP _hp_win_end_lo
    BCC _hf_walk
    JMP _hf_right_merge            ; ran off end — skip merges, just bail

_hf_arrived:
    ; Can we merge with left neighbour?
    LDA _heap_prev_ptr
    ORA _heap_prev_ptr+1
    BEQ _hf_right_merge            ; no left (we're at window low)

    ; Load prev into {{zp.hp}} to read its flag.
    LDA _heap_prev_ptr
    STA {{zp.hp}}
    LDA _heap_prev_ptr+1
    STA {{zp.hp}}+1

    LDY #$01
    LDA ({{zp.hp}}),Y
    BPL _hf_right_merge            ; prev not free

    ; prev.size += current.size. Cache current.size.
    LDY #$00
    LDA ({{zp.tmp}}),Y
    STA _heap_cur_size
    INY
    LDA ({{zp.tmp}}),Y
    AND #$7F
    STA _heap_cur_size+1

    ; Read prev header (masked), add, write back with free flag set.
    LDY #$00
    LDA ({{zp.hp}}),Y
    CLC
    ADC _heap_cur_size
    STA ({{zp.hp}}),Y
    INY
    LDA ({{zp.hp}}),Y
    AND #$7F
    ADC _heap_cur_size+1
    ORA #$80
    STA ({{zp.hp}}),Y

    ; current := prev for subsequent right-merge.
    LDA {{zp.hp}}
    STA {{zp.tmp}}
    LDA {{zp.hp}}+1
    STA {{zp.tmp}}+1

_hf_right_merge:
    ; right = current + current.size.
    LDY #$00
    LDA ({{zp.tmp}}),Y
    STA _heap_cur_size
    INY
    LDA ({{zp.tmp}}),Y
    AND #$7F
    STA _heap_cur_size+1

    CLC
    LDA {{zp.tmp}}
    ADC _heap_cur_size
    STA {{zp.hp}}
    LDA {{zp.tmp}}+1
    ADC _heap_cur_size+1
    STA {{zp.hp}}+1

    ; right >= window end → no neighbour.
    LDA {{zp.hp}}+1
    CMP _hp_win_end_hi
    BCC _hf_test_right_free
    BNE _hf_free_done
    LDA {{zp.hp}}
    CMP _hp_win_end_lo
    BCS _hf_free_done

_hf_test_right_free:
    LDY #$01
    LDA ({{zp.hp}}),Y
    BPL _hf_free_done              ; allocated, no merge

    ; current.size += right.size.
    LDY #$00
    LDA ({{zp.hp}}),Y
    STA _heap_rem
    INY
    LDA ({{zp.hp}}),Y
    AND #$7F
    STA _heap_rem+1

    LDY #$00
    LDA ({{zp.tmp}}),Y
    CLC
    ADC _heap_rem
    STA ({{zp.tmp}}),Y
    INY
    LDA ({{zp.tmp}}),Y
    AND #$7F
    ADC _heap_rem+1
    ORA #$80
    STA ({{zp.tmp}}),Y

_hf_free_done:
    ; On-demand heap give-back: if the top owned bank is now entirely one
    ; free window-sized block, return it to the shared bitmap and shrink
    ; the high-water — repeating for any newly-exposed empty top banks. A
    ; freed-empty bank below the top stays owned until it becomes the top,
    ; which keeps the owned range contiguous (the walk needs no holes).
    ; bank() (layer 3) can reclaim the returned pages.
    LDA #heap_bank_dynamic
    BEQ _hf_restore
_hf_gb_loop:
    LDA _heap_hiwater
    CMP #heap_bank_first
    BEQ _hf_restore                ; always keep at least the first bank
    STA _heap_bank_cur
    JSR _heap_select_bank
    JSR _heap_setup_window
    ; window size (end - low) → _heap_init_sz (reused as scratch)
    SEC
    LDA _hp_win_end_lo
    SBC _hp_win_lo_lo
    STA _heap_init_sz
    LDA _hp_win_end_hi
    SBC _hp_win_lo_hi
    STA _heap_init_sz+1
    ; read the first block's header at window low
    LDA _hp_win_lo_lo
    STA {{zp.hp}}
    LDA _hp_win_lo_hi
    STA {{zp.hp}}+1
    LDY #$01
    LDA ({{zp.hp}}),Y              ; header hi: free flag (bit 7) + size hi
    BPL _hf_restore                ; allocated → top bank in use → stop
    AND #$7F
    CMP _heap_init_sz+1            ; size hi == window size hi?
    BNE _hf_restore
    LDY #$00
    LDA ({{zp.hp}}),Y              ; size lo
    CMP _heap_init_sz              ; size lo == window size lo?
    BNE _hf_restore
    ; Whole bank free — give it back to the shared bitmap.
    LDA _heap_hiwater
    JSR _bank_free
    DEC _heap_hiwater
    JMP _hf_gb_loop
_hf_restore:
    ; Restore the caller's bank window before returning.
    JMP _heap_restore_caller_bank  ; tail-call: RTS through restore

; ─────────────────────────────────────────────────────────────────────
; _heap_total_free — walk the chain across every reserved bank and
; sum the sizes of all free blocks. Returns a 24-bit total free byte
; count in A=lo / X=hi / Y=b2 (a banked heap can hold > 64 KB free).
; Count includes the 7-byte header on each free block — allocating N
; bytes takes N+7 bytes from this total.
; ─────────────────────────────────────────────────────────────────────
_heap_total_free:
    JSR _heap_save_caller_bank
    LDA #$00
    STA _heap_total_lo
    STA _heap_total_hi
    STA _heap_total_b2            ; 24-bit accumulator (sum can exceed 64 KB)

    LDA #heap_bank_first
    STA _heap_bank_cur

_htf_bank_loop:
    LDA _heap_bank_cur
    JSR _heap_select_bank
    JSR _heap_setup_window

    LDA _hp_win_lo_lo
    STA {{zp.hp}}
    LDA _hp_win_lo_hi
    STA {{zp.hp}}+1

_htf_loop:
    LDA {{zp.hp}}+1
    CMP _hp_win_end_hi
    BCC _htf_read
    BNE _htf_bank_done
    LDA {{zp.hp}}
    CMP _hp_win_end_lo
    BCS _htf_bank_done

_htf_read:
    LDY #$00
    LDA ({{zp.hp}}),Y
    STA _heap_cur_size
    INY
    LDA ({{zp.hp}}),Y              ; raw high byte, free flag in bit 7
    STA _heap_cur_hdr
    AND #$7F
    STA _heap_cur_size+1

    LDA _heap_cur_hdr
    BPL _htf_advance               ; allocated → don't count

    ; Free: total += cur_size (24-bit; cur_size is 15-bit, the carry ripples
    ; into b2 so the cross-bank sum doesn't wrap at 64 KB).
    CLC
    LDA _heap_total_lo
    ADC _heap_cur_size
    STA _heap_total_lo
    LDA _heap_total_hi
    ADC _heap_cur_size+1
    STA _heap_total_hi
    LDA _heap_total_b2
    ADC #$00
    STA _heap_total_b2

_htf_advance:
    CLC
    LDA {{zp.hp}}
    ADC _heap_cur_size
    STA {{zp.hp}}
    LDA {{zp.hp}}+1
    ADC _heap_cur_size+1
    STA {{zp.hp}}+1
    JMP _htf_loop

_htf_bank_done:
    JSR _heap_advance_bank
    BCS _htf_done
    JMP _htf_bank_loop

_htf_done:
    ; On-demand heap: the banks above the high-water mark aren't claimed
    ; yet, but they're free space the heap can still grow into — count
    ; each (fully free, one window page) toward the free total so
    ; Heap.size() == Heap.totalSize() when the heap is empty.
    LDA #heap_bank_dynamic
    BEQ _htf_finish
    LDX _heap_hiwater
_htf_claim_loop:
    CPX #heap_bank_last
    BCS _htf_finish              ; X >= last allowed page → done
    INX
    CLC
    LDA _heap_total_lo
    ADC #<(heap_end - heap_low)  ; + one page (window length)
    STA _heap_total_lo
    LDA _heap_total_hi
    ADC #>(heap_end - heap_low)
    STA _heap_total_hi
    LDA _heap_total_b2
    ADC #$00
    STA _heap_total_b2
    JMP _htf_claim_loop
_htf_finish:
    JSR _heap_restore_caller_bank
    LDA _heap_total_lo            ; 24-bit free count: A=lo, X=hi, Y=b2
    LDX _heap_total_hi
    LDY _heap_total_b2
    RTS

; ─────────────────────────────────────────────────────────────────────
; _heap_largest_free — walk the chain across every reserved bank and
; track the largest single free-block size. Useful for figuring out
; whether `new T[N]` will succeed without an OOM, since the allocator
; is first-fit and can't satisfy a request that exceeds the biggest
; free extent even if the total free count is high.
; ─────────────────────────────────────────────────────────────────────
_heap_largest_free:
    JSR _heap_save_caller_bank
    LDA #$00
    STA _heap_total_lo             ; reuse as running max
    STA _heap_total_hi

    LDA #heap_bank_first
    STA _heap_bank_cur

_hlf_bank_loop:
    LDA _heap_bank_cur
    JSR _heap_select_bank
    JSR _heap_setup_window

    LDA _hp_win_lo_lo
    STA {{zp.hp}}
    LDA _hp_win_lo_hi
    STA {{zp.hp}}+1

_hlf_loop:
    LDA {{zp.hp}}+1
    CMP _hp_win_end_hi
    BCC _hlf_read
    BNE _hlf_bank_done
    LDA {{zp.hp}}
    CMP _hp_win_end_lo
    BCS _hlf_bank_done

_hlf_read:
    LDY #$00
    LDA ({{zp.hp}}),Y
    STA _heap_cur_size
    INY
    LDA ({{zp.hp}}),Y
    STA _heap_cur_hdr
    AND #$7F
    STA _heap_cur_size+1

    LDA _heap_cur_hdr
    BPL _hlf_advance

    ; Free: if cur_size > max, update max.
    LDA _heap_cur_size
    CMP _heap_total_lo
    LDA _heap_cur_size+1
    SBC _heap_total_hi
    BCC _hlf_advance               ; cur_size < max
    LDA _heap_cur_size
    STA _heap_total_lo
    LDA _heap_cur_size+1
    STA _heap_total_hi

_hlf_advance:
    CLC
    LDA {{zp.hp}}
    ADC _heap_cur_size
    STA {{zp.hp}}
    LDA {{zp.hp}}+1
    ADC _heap_cur_size+1
    STA {{zp.hp}}+1
    JMP _hlf_loop

_hlf_bank_done:
    JSR _heap_advance_bank
    BCS _hlf_done
    JMP _hlf_bank_loop

_hlf_done:
    JSR _heap_restore_caller_bank
    LDA _heap_total_lo
    LDX _heap_total_hi
    RTS

; ─────────────────────────────────────────────────────────────────────
; Static scratch (non-reentrant).
; ─────────────────────────────────────────────────────────────────────
_heap_req:
    .byte $00, $00
_heap_cur_size:
    .byte $00, $00
_heap_cur_hdr:
    .byte $00
_heap_rem:
    .byte $00, $00
_heap_prev_ptr:
    .byte $00, $00
_heap_free_ptr:
    .byte $00, $00
_heap_free_bank:
    .byte $00
; Bank-walk cursor shared by _heap_init / _heap_alloc16 /
; _heap_total_free / _heap_largest_free (only one at a time runs).
_heap_bank_cur:
    .byte $00
; Walker window cache — set by _heap_setup_window from the current
; bank's bit 7 (data pool addresses for bit clear, region-C addresses
; for bit set on the unified xt model). Walker code reads these
; instead of `#<heap_low` / `#>heap_low` / `#<heap_end` / `#>heap_end`
; immediates so it follows the right window aperture when iterating
; into a region-C bank — and so flat-heap layouts (which have non-
; page-aligned heap_low) keep working under the same walker template.
_hp_win_lo_lo:
    .byte $00
_hp_win_lo_hi:
    .byte $00
_hp_win_end_lo:
    .byte $00
_hp_win_end_hi:
    .byte $00
; Saved A/X across the bank-restore tail of _heap_alloc16 so Y can
; carry the picked bank id out to the caller without being clobbered.
_heap_ret_lo:
    .byte $00
_heap_ret_hi:
    .byte $00
; Accumulator for _heap_total_free / running max for _heap_largest_free.
; _heap_total_free uses all three bytes (24-bit: a banked heap can hold far
; more than 64 KB free, up to the 16 MB the 3-byte pointer space addresses);
; _heap_largest_free only uses lo/hi (a single block ≤ one bank window).
_heap_total_lo:
    .byte $00
_heap_total_hi:
    .byte $00
_heap_total_b2:
    .byte $00

; Scratch for the delete-array dealloc loop emitted inline at each
; `delete <class@>` site when the class defines a user dealloc()
; method. Unused by _heap_alloc / _heap_free / _heap_init.
_heap_del_saved:
    .byte $00, $00
_heap_del_hdr:
    .byte $00, $00
_heap_del_size:
    .byte $00, $00
_heap_del_end:
    .byte $00, $00
_heap_del_cur:
    .byte $00, $00
