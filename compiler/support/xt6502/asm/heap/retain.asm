; retain.asm — reference-count helpers for -falloc=heap targets.
;
; Block header layout is documented in heap.asm. Bytes 2 and 3 of the
; header hold a 16-bit little-endian retain count (byte 2 = lo, byte 3
; = hi) which the allocator initialises to 1. The two helpers here are
; the primitives behind the `retain ptr;` and `release ptr;` statements
; (and the decrement tail of `delete`).
;
; Calling convention mirrors _heap_free: entry A=lo / X=hi / Y=bank.
; Y carries the 1-based bank id of the heap bank the pointer lives
; in (banked-heap targets); flat-heap targets pass Y=heap_bank_first
; (== 0) and the _heap_select_bank stub is a plain RTS, so the two
; bank-switch JSRs around the refcount work execute as zero-cost
; no-ops. All helpers are null-safe and non-reentrant; static scratch
; is shared across calls. Exit bank is always heap_bank_first so main
; code sees the invariant window between calls.
;
; Template substitutions:
;   {{zp.tmp}}             ZP pair staged as the refcount-lo pointer
;                          (Y=0 reads lo, Y=1 reads hi)
;   {{weak.zeroAllHook}}   Single-instruction hook at the refcount-
;                          reached-zero tail. Expands to
;                          `JSR _weak_zero_all_for` when the program
;                          declares weak slots; expands to a comment
;                          otherwise so no-weak programs don't pull
;                          in weak.asm or its side tables.
;   {{heap.objBankStash}}  Bank-byte stash at _obj_decref entry. On
;                          banked-heap: `STY _obj_bank` (captures
;                          caller-passed bank). On flat: `LDA #$00`
;                          + `STA _obj_bank` — Y is undefined on
;                          entry from flat call sites, and weak.asm's
;                          _weak_zero_all_for compares _obj_bank
;                          against a zero-initialised bank table so
;                          both sides must agree at 0.
;
; ─────────────────────────────────────────────────────────────────────
; _obj_retain — increment 16-bit refcount for block at A=lo / X=hi / Y=bank.
;
; Saturates at $FFFF so pathological retain loops don't wrap the count
; back through 0 and trigger a spurious free. Preserves nothing.
; ─────────────────────────────────────────────────────────────────────
_obj_retain:
    JSR _heap_save_caller_bank
    STA _obj_ptr
    STX _obj_ptr+1
    ORA _obj_ptr+1
    BEQ _or_done                   ; null → no bank change needed
    STY _obj_bank

    TYA
    JSR _heap_select_bank          ; switch to object's bank

    ; tmp = ptr - 2 (refcount-lo byte lives two bytes behind the
    ; payload; refcount-hi at ptr-1 = tmp+1, reached via Y=1).
    SEC
    LDA _obj_ptr
    SBC #$02
    STA {{zp.tmp}}
    LDA _obj_ptr+1
    SBC #$00
    STA {{zp.tmp}}+1

    ; Refcount ZERO means the object is being DESTROYED: _obj_decref has
    ; already taken it to 0 and the caller is running dealloc. Retaining it
    ; here would let the matching release take it back to 0 and dispatch
    ; dealloc AGAIN — an unbounded loop, which is what any strong local
    ; (`Object* o = self;`, or the `%@` argument printf binds) inside a
    ; dealloc used to cause (bug 038). A live object always holds at least
    ; one reference, so 0 can only mean "already dying", and retain/release
    ; are both no-ops on it. _obj_decref has had the mirror-image guard all
    ; along; this makes the pair symmetric.
    ;
    ; It must come BEFORE the saturation test below, which branches straight
    ; to _or_inc and would jump over it.
    LDY #$00
    LDA ({{zp.tmp}}),Y             ; lo
    INY
    ORA ({{zp.tmp}}),Y             ; | hi
    BEQ _or_done                   ; count == 0 → dying, leave it alone

    ; Saturation check. If hi != $FF the count can never wrap; skip
    ; straight to the increment. Otherwise read lo too — both bytes
    ; $FF means the counter is already saturated and we leave it alone.
    LDY #$01
    LDA ({{zp.tmp}}),Y
    CMP #$FF
    BNE _or_inc
    LDY #$00
    LDA ({{zp.tmp}}),Y
    CMP #$FF
    BEQ _or_done                   ; saturated at $FFFF

_or_inc:
    ; 16-bit increment through (tmp),Y.
    LDY #$00
    LDA ({{zp.tmp}}),Y
    CLC
    ADC #$01
    STA ({{zp.tmp}}),Y
    BCC _or_done                   ; no carry into hi byte
    INY
    LDA ({{zp.tmp}}),Y
    ADC #$00                       ; carry is set here
    STA ({{zp.tmp}}),Y

_or_done:
    JMP _heap_restore_caller_bank  ; tail-call: RTS through restore

; ─────────────────────────────────────────────────────────────────────
; _obj_decref — decrement 16-bit refcount for block at A=lo / X=hi / Y=bank.
;
; On exit:
;   Carry set   → refcount reached 0; caller should run the dealloc
;                 path and JSR _heap_free.
;   Carry clear → block still has live references, or the input was
;                 null, or the stored count was already 0 (guard
;                 against double-release), or it was saturated at
;                 $FFFF: caller takes no action.
;
; The payload pointer + bank are preserved in A/X/Y across the call
; so the caller can feed them straight into the dealloc/_heap_free
; sequence. Exit bank is always heap_bank_first.
; Clobbers _obj_ptr / _obj_bank.
; ─────────────────────────────────────────────────────────────────────
_obj_decref:
    JSR _heap_save_caller_bank
    STA _obj_ptr
    STX _obj_ptr+1
    {{heap.objBankStash}}          ; save bank (banked) or zero it (flat)
    ORA _obj_ptr+1
    BEQ _od_restore_cc             ; null → carry clear, no action

    TYA
    JSR _heap_select_bank          ; switch to object's bank

    ; tmp = ptr - 2 (refcount-lo address).
    SEC
    LDA _obj_ptr
    SBC #$02
    STA {{zp.tmp}}
    LDA _obj_ptr+1
    SBC #$00
    STA {{zp.tmp}}+1

    ; Guard against double-release: if both refcount bytes are zero
    ; leave them alone (don't wrap to $FFFF and leak the block).
    LDY #$00
    LDA ({{zp.tmp}}),Y             ; lo
    INY
    ORA ({{zp.tmp}}),Y             ; | hi
    BEQ _od_restore_cc

    ; A saturated count stays saturated. _obj_retain stops at $FFFF, so
    ; once it is there the true number of references is unknown, and
    ; counting down from it would free the block while references are
    ; still live (bug 261). The block is leaked instead.
    DEY
    LDA ({{zp.tmp}}),Y             ; lo
    INY
    AND ({{zp.tmp}}),Y             ; & hi
    CMP #$FF
    BEQ _od_restore_cc             ; $FFFF → leave it, carry clear

    ; 16-bit decrement through (tmp),Y.
    LDY #$00
    LDA ({{zp.tmp}}),Y
    SEC
    SBC #$01
    STA ({{zp.tmp}}),Y
    BCS _od_check_zero             ; no borrow into hi byte
    INY
    LDA ({{zp.tmp}}),Y
    SBC #$00                       ; carry clear here → subtracts 1
    STA ({{zp.tmp}}),Y

_od_check_zero:
    ; Both bytes zero now → caller should dealloc+free.
    LDY #$00
    LDA ({{zp.tmp}}),Y
    INY
    ORA ({{zp.tmp}}),Y
    BNE _od_restore_cc             ; still referenced

    ; Refcount reached 0 — zero every registered weak slot that
    ; points at this object BEFORE the caller runs dealloc() /
    ; release() / _heap_free, so user-dealloc code that looks at
    ; weak back-pointers sees them as nil rather than as dangling
    ; references to memory about to be returned to the free list.
    ; No-weak programs substitute a comment and the runtime pays
    ; nothing. The helper loads _obj_ptr/+1 itself — still valid
    ; here since the entry code stashed it into the static slot,
    ; and the tail below reloads it anyway for the return value.
    ; Y/A clobbered by the helper; the tail restores them.
    {{weak.zeroAllHook}}

    ; Refcount reached 0 — restore caller bank, signal caller.
    JSR _heap_restore_caller_bank
    LDA _obj_ptr
    LDX _obj_ptr+1
    LDY _obj_bank
    SEC
    RTS

_od_restore_cc:
    JSR _heap_restore_caller_bank
    LDA _obj_ptr
    LDX _obj_ptr+1
    LDY _obj_bank
    CLC
    RTS

_obj_ptr:
    .byte $00, $00
_obj_bank:
    .byte $00

; Return-value preservation across ARC scope-exit cleanup. emitReturn
; stashes A/X (+Y for banked) here before running inline cleanup, then
; restores A/X/Y before JMPing to the function's end label. Reusing
; the heap-delete scratch isn't safe because the cleanup's dealloc
; loop itself clobbers _heap_del_saved. These slots are dedicated to
; the ARC return path so reentrancy through cleanup is impossible.
_arc_retval_lo:
    .byte $00
_arc_retval_hi:
    .byte $00
_arc_retval_bank:
    .byte $00

; Old-value scratch for ARC member stores. emitArcMemberStore reads
; the OLD field value into these slots before running the release
; sequence, so the cleanup's indirect-addressed reads through zpTmp
; don't compete with the RHS that lives in _arc_retval_*.
_arc_assign_old_lo:
    .byte $00
_arc_assign_old_hi:
    .byte $00
_arc_assign_old_bank:
    .byte $00

; Transitive aggregate-walker scratch (ARC 2f). When a strong ivar's
; refcount hits 0 the walker has to (a) JSR the inner class's user
; dealloc, (b) recursively release the inner's own strong ivars, and
; (c) _heap_free the inner block. zpTmp can't carry the inner pointer
; across the user-dealloc JSR (the method body clobbers it), so the
; pointer lives here instead. Deeper nesting saves the prior value on
; the hw stack around each recursion level, so one pair suffices
; regardless of class-tree depth.
_arc_tx_ptr_lo:
    .byte $00
_arc_tx_ptr_hi:
    .byte $00
