; weak.asm — intrusive weak-reference list for -falloc=heap.
;
; Companion to retain.asm. Backs the `weak:T@` qualifier and a stored
; `^` (bound method): the slot's payload word is zeroed the moment the
; pointee's refcount reaches 0.
;
; There is NO table. The chain is threaded through the weak slots
; themselves, so:
;
;   * there is no capacity limit,
;   * a weak store is O(1) rather than a scan,
;   * and — the one that mattered most — an object with NO weak
;     references costs ONE null test at dealloc instead of a full
;     table scan. Every object in the program used to pay for a
;     feature it did not use; closing a window of ~500 objects cost
;     ~500 × N comparisons, and 499 of those had never been weakly
;     referenced by anything.
;
; Programs that never declare `weak:` still pay nothing: no
; `weakSlotsUsed` flag, this file isn't linked, and retain.asm's
; {{weak.zeroAllHook}} expands to a comment.
;
; ── Layout ───────────────────────────────────────────────────────
;
; Every pointer here is the uniform 3-byte banked pointer (lo, hi,
; bank). A "slot" address is the address of the slot's PAYLOAD word —
; the links sit in front of it:
;
;   slot-6 .. slot-4   pprev    address of the pointer that points AT
;                               this slot (&obj.weak_head, or
;                               &prev.next)
;   slot-3 .. slot-1   next     next slot in this object's chain
;   slot+0 .. slot+2   payload  the weak pointer itself; for a `^`,
;                               the receiver (the code word follows
;                               and is left alone — truthiness tests
;                               the receiver)
;
; So the node base is `slot - 6`, and (zp),Y with Y = 0..8 reaches the
; whole node from one mapping. That is why the helpers below map
; `slot - 6` rather than `slot`.
;
; The object's chain head lives in its heap block header (heap.asm):
;
;   obj-7 .. obj-6     block size
;   obj-5 .. obj-3     weak_head        ← head of the chain
;   obj-2 .. obj-1     retain count
;
; weak_head sits BEFORE the retain count so the count stays at obj-2,
; where the inline ARC hot path reads it. Not one line of ARC codegen
; changed for any of this.
;
; ── pprev, not prev ──────────────────────────────────────────────
;
; Storing the ADDRESS OF THE POINTER that points at this slot (the
; Linux hlist idiom) rather than the previous node buys two things,
; both load-bearing:
;
;   * Unlink is O(1) AND never needs the object. A version that
;     recovered the object by dereferencing the slot's payload is fine
;     for a weak pointer — but a WIDENED `^` holds a FUNCTION pointer
;     there, so it would read `.text - 5` as a block header.
;   * `pprev != 0` is an unambiguous "am I linked?" test. With a plain
;     `prev`, zero means EITHER unlinked OR head-of-chain, and
;     unregistering an unlinked slot corrupts whatever its zero
;     aliases.
;
; ── Banking ──────────────────────────────────────────────────────
;
; Slots live wherever their host does: an ivar's slot is inside a heap
; object (a heap bank), a local's is on the stack, a global's is in
; main RAM. So a chain walk can cross banks, and each node must have
; its bank mapped into the data window before it is touched.
;
; This is much cheaper than it sounds. _wk_sel compares the wanted
; bank against the LIVE bank register and writes it only when it
; differs — which, for a chain whose slots mostly live in one bank, it
; usually won't. A CMP and a branch, not a bank switch. Bank 0 means
; "not banked" (stack / main RAM / ZP: reachable whatever the window
; holds), so those cost the compare alone.
;
; Template substitutions:
;   {{zp.tmp}}   ZP pair used as the (zp),Y base for every node access.
;                Safe to clobber: retain.asm's {{weak.zeroAllHook}} sits
;                at the _od_check_zero tail, after which _obj_decref is
;                done reading zpTmp, and _obj_retain / _obj_decref
;                already clobber it themselves.

; ─────────────────────────────────────────────────────────────────
; _wk_sel — map bank A into the data window, if it isn't there already.
;
; A = bank; 0 = an unbanked address (stack / main RAM / ZP), for which
; the window is irrelevant and no switch is needed. Heap banks are
; 1-based, so 0 is never a real one.
;
; Preserves A, X and Y — the callers stage pointers in them.
; ─────────────────────────────────────────────────────────────────
_wk_sel:
    CMP #$00
    BEQ _wks_done                  ; unbanked → window irrelevant
    CMP __bank_data_reg
    BEQ _wks_done                  ; already mapped → the common case
    STA __bank_data_reg
_wks_done:
    RTS

; _wk_map — point {{zp.tmp}} at the raw address A/X and map bank Y.
_wk_map:
    STA {{zp.tmp}}
    STX {{zp.tmp}}+1
    TYA
    JMP _wk_sel

; _wk_base_map — A/X/Y is a SLOT (payload) address; point {{zp.tmp}} at
; its node base (slot - 6) and map its bank, so Y = 0..8 reaches pprev,
; next and payload.
_wk_base_map:
    STY _wk_bk
    SEC
    SBC #$06
    STA {{zp.tmp}}
    TXA
    SBC #$00
    STA {{zp.tmp}}+1
    LDA _wk_bk
    JMP _wk_sel

; ─────────────────────────────────────────────────────────────────
; _weak_unregister — unlink a slot from whatever chain holds it. O(1).
;
; Entry:  _weak_slot/+1   = slot (payload) address
;         _weak_slot_bank = the slot's bank (0 if unbanked)
; Exit:   bank-neutral. A/X/Y clobbered.
;
; Unregistering an already-unlinked slot is a no-op — it runs at
; scope exit and on re-assign, either of which may have been beaten
; to it by _weak_zero_all_for.
; ─────────────────────────────────────────────────────────────────
_weak_unregister:
    JSR _heap_save_caller_bank
    JSR _wu_core
    JMP _heap_restore_caller_bank

; The body, without the bank bracket, so _weak_register can reuse it
; inside its own bracket (heap.asm's save slot is single-depth — it
; must not be nested).
_wu_core:
    LDA _weak_slot
    LDX _weak_slot+1
    LDY _weak_slot_bank
    JSR _wk_base_map               ; {{zp.tmp}} = slot - 6

    ; pp = node.pprev
    LDY #$00
    LDA ({{zp.tmp}}),Y
    STA _wk_pp
    INY
    LDA ({{zp.tmp}}),Y
    STA _wk_pp+1
    INY
    LDA ({{zp.tmp}}),Y
    STA _wk_pp+2

    ; pprev == 0 → this slot is in no chain. Nothing to do.
    LDA _wk_pp
    ORA _wk_pp+1
    BEQ _wu_done

    ; nx = node.next
    LDY #$03
    LDA ({{zp.tmp}}),Y
    STA _wk_nx
    INY
    LDA ({{zp.tmp}}),Y
    STA _wk_nx+1
    INY
    LDA ({{zp.tmp}}),Y
    STA _wk_nx+2

    ; Clear this node's links now, while {{zp.tmp}} still points at it
    ; and its bank is still mapped. The payload is left alone: unregister
    ; is called on re-assign, and the caller is about to store the new
    ; pointee into it.
    LDA #$00
    LDY #$00
    STA ({{zp.tmp}}),Y
    INY
    STA ({{zp.tmp}}),Y
    INY
    STA ({{zp.tmp}}),Y
    INY
    STA ({{zp.tmp}}),Y
    INY
    STA ({{zp.tmp}}),Y
    INY
    STA ({{zp.tmp}}),Y

    ; *pp = nx — pp points at either obj.weak_head or prev.next, and we
    ; do not care which. That is the whole point of pprev.
    LDA _wk_pp
    LDX _wk_pp+1
    LDY _wk_pp+2
    JSR _wk_map
    LDY #$00
    LDA _wk_nx
    STA ({{zp.tmp}}),Y
    INY
    LDA _wk_nx+1
    STA ({{zp.tmp}}),Y
    INY
    LDA _wk_nx+2
    STA ({{zp.tmp}}),Y

    ; if (nx) nx.pprev = pp
    LDA _wk_nx
    ORA _wk_nx+1
    BEQ _wu_done
    LDA _wk_nx
    LDX _wk_nx+1
    LDY _wk_nx+2
    JSR _wk_base_map               ; {{zp.tmp}} = nx - 6
    LDY #$00
    LDA _wk_pp
    STA ({{zp.tmp}}),Y
    INY
    LDA _wk_pp+1
    STA ({{zp.tmp}}),Y
    INY
    LDA _wk_pp+2
    STA ({{zp.tmp}}),Y
_wu_done:
    RTS

; ─────────────────────────────────────────────────────────────────
; _weak_register — link a slot onto an object's chain. O(1).
;
; Entry:  A / X / Y       = obj ptr lo / hi / bank
;         _weak_slot/+1   = slot (payload) address
;         _weak_slot_bank = the slot's bank (0 if unbanked)
; Exit:   carry clear (kept for ABI compatibility; there is no longer
;         any failure mode to report — no table, no cap). A/X/Y
;         clobbered. Bank-neutral.
;
; A null object leaves the slot unlinked: the caller stores the null
; payload itself, and a later unregister is then a no-op.
; ─────────────────────────────────────────────────────────────────
_weak_register:
    STA _weak_obj
    STX _weak_obj+1
    STY _weak_obj_bank
    JSR _heap_save_caller_bank

    ; Drop any previous link first — a weak slot may be re-pointed at a
    ; different object, and it can only be on one chain.
    JSR _wu_core

    LDA _weak_obj
    ORA _weak_obj+1
    BEQ _wr_done                   ; null object → nothing to track

    ; pp = &obj.weak_head = obj - 5, in the object's bank.
    SEC
    LDA _weak_obj
    SBC #$05
    STA _wk_pp
    LDA _weak_obj+1
    SBC #$00
    STA _wk_pp+1
    LDA _weak_obj_bank
    STA _wk_pp+2

    ; nx = obj.weak_head; obj.weak_head = slot.
    LDA _wk_pp
    LDX _wk_pp+1
    LDY _wk_pp+2
    JSR _wk_map
    LDY #$00
    LDA ({{zp.tmp}}),Y
    STA _wk_nx
    INY
    LDA ({{zp.tmp}}),Y
    STA _wk_nx+1
    INY
    LDA ({{zp.tmp}}),Y
    STA _wk_nx+2
    LDY #$00
    LDA _weak_slot
    STA ({{zp.tmp}}),Y
    INY
    LDA _weak_slot+1
    STA ({{zp.tmp}}),Y
    INY
    LDA _weak_slot_bank
    STA ({{zp.tmp}}),Y

    ; slot.pprev = pp; slot.next = nx.
    LDA _weak_slot
    LDX _weak_slot+1
    LDY _weak_slot_bank
    JSR _wk_base_map               ; {{zp.tmp}} = slot - 6
    LDY #$00
    LDA _wk_pp
    STA ({{zp.tmp}}),Y
    INY
    LDA _wk_pp+1
    STA ({{zp.tmp}}),Y
    INY
    LDA _wk_pp+2
    STA ({{zp.tmp}}),Y
    INY                            ; Y = 3 → next
    LDA _wk_nx
    STA ({{zp.tmp}}),Y
    INY
    LDA _wk_nx+1
    STA ({{zp.tmp}}),Y
    INY
    LDA _wk_nx+2
    STA ({{zp.tmp}}),Y

    ; if (nx) nx.pprev = &slot.next  (= slot - 3, in the slot's bank).
    LDA _wk_nx
    ORA _wk_nx+1
    BEQ _wr_done
    SEC
    LDA _weak_slot
    SBC #$03
    STA _wk_pp
    LDA _weak_slot+1
    SBC #$00
    STA _wk_pp+1
    LDA _weak_slot_bank
    STA _wk_pp+2
    LDA _wk_nx
    LDX _wk_nx+1
    LDY _wk_nx+2
    JSR _wk_base_map               ; {{zp.tmp}} = nx - 6
    LDY #$00
    LDA _wk_pp
    STA ({{zp.tmp}}),Y
    INY
    LDA _wk_pp+1
    STA ({{zp.tmp}}),Y
    INY
    LDA _wk_pp+2
    STA ({{zp.tmp}}),Y
_wr_done:
    JSR _heap_restore_caller_bank
    CLC
    RTS

; ─────────────────────────────────────────────────────────────────
; _weak_zero_all_for — zero every weak slot pointing at the object
; staged in _obj_ptr / _obj_bank. Called from retain.asm's
; _od_check_zero tail the instant the refcount hits zero, just before
; dealloc()/release()/_heap_free.
;
; O(k) in the number of weak references to THIS object — and for the
; overwhelming majority of objects, k is 0 and this is a single null
; test on the header.
;
; NOT bank-bracketed, deliberately: it runs INSIDE _obj_decref's own
; save/restore bracket, and heap.asm's save slot is single-depth — a
; nested save here would overwrite the bank _obj_decref is going to
; restore. _obj_decref's tail does the restore for us, and it reloads
; _obj_ptr / _obj_bank afterwards, which this routine only reads.
;
; On entry the object's bank is already mapped (_obj_decref selected it
; to read the refcount), so reading the chain head costs no switch.
;
; Entry:  _obj_ptr/+1 = object pointer, _obj_bank = its bank
; Exit:   A/X/Y clobbered; _obj_ptr / _obj_bank preserved.
; ─────────────────────────────────────────────────────────────────
_weak_zero_all_for:
    ; pp = &obj.weak_head = obj - 5. Kept across the whole walk so the
    ; head can be cleared at the end without recomputing it.
    SEC
    LDA _obj_ptr
    SBC #$05
    STA _wk_pp
    LDA _obj_ptr+1
    SBC #$00
    STA _wk_pp+1
    LDA _obj_bank
    STA _wk_pp+2

    LDA _wk_pp
    LDX _wk_pp+1
    LDY _wk_pp+2
    JSR _wk_map
    LDY #$00
    LDA ({{zp.tmp}}),Y
    STA _wk_cur
    INY
    LDA ({{zp.tmp}}),Y
    STA _wk_cur+1
    INY
    LDA ({{zp.tmp}}),Y
    STA _wk_cur+2

    ; The common case, by a wide margin: nothing weakly references this
    ; object, and dealloc is done. This single test is the whole reason
    ; the table had to go.
    LDA _wk_cur
    ORA _wk_cur+1
    BNE _wz_loop
    RTS

_wz_loop:
    LDA _wk_cur
    LDX _wk_cur+1
    LDY _wk_cur+2
    JSR _wk_base_map               ; {{zp.tmp}} = cur - 6

    ; nx = cur.next — read it BEFORE zeroing the node.
    LDY #$03
    LDA ({{zp.tmp}}),Y
    STA _wk_nx
    INY
    LDA ({{zp.tmp}}),Y
    STA _wk_nx+1
    INY
    LDA ({{zp.tmp}}),Y
    STA _wk_nx+2

    ; Zero bytes 0..8: pprev, next, and the payload word. For a `^` that
    ; is the receiver; the code word after it is left alone, because `^`
    ; truthiness tests the receiver.
    LDA #$00
    LDY #$00
_wz_clr:
    STA ({{zp.tmp}}),Y
    INY
    CPY #$09
    BNE _wz_clr

    LDA _wk_nx
    STA _wk_cur
    LDA _wk_nx+1
    STA _wk_cur+1
    LDA _wk_nx+2
    STA _wk_cur+2
    LDA _wk_cur
    ORA _wk_cur+1
    BNE _wz_loop

    ; obj.weak_head = 0.
    LDA _wk_pp
    LDX _wk_pp+1
    LDY _wk_pp+2
    JSR _wk_map
    LDA #$00
    LDY #$00
    STA ({{zp.tmp}}),Y
    INY
    STA ({{zp.tmp}}),Y
    INY
    STA ({{zp.tmp}}),Y
    RTS

; ─── Static scratch ─────────────────────────────────────────────
; Nine bytes, total, and no tables. The old design's six parallel
; arrays cost 6 × N (384 bytes at the default N=64) and still had a cap.
_weak_obj:
    .byte $00, $00
_weak_obj_bank:
    .byte $00
_weak_slot:
    .byte $00, $00
_weak_slot_bank:
    .byte $00
_wk_pp:
    .byte $00, $00, $00
_wk_nx:
    .byte $00, $00, $00
_wk_cur:
    .byte $00, $00, $00
_wk_bk:
    .byte $00
