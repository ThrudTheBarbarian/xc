; random — 16-bit xorshift PRNG
; Output: A = random byte (low 8 bits), X = high 8 bits
;         (full 16-bit value in A/X, lo/hi)
;
; Algorithm: 16-bit xorshift (Marsaglia, shift triple 7,9,8)
;   state ^= state << 7
;   state ^= state >> 9
;   state ^= state << 8
;
; Period: 65535 (all non-zero 16-bit values)
; Speed: ~40 cycles — no loops, no tables, no multiplication, no ZP.
; State is stored inline via self-modifying code (runs from RAM).
;
; Seed: default $0001. Call randomSeed to set a custom seed.
;       On Atari, RANDOM ($D20A) is a good hardware entropy source.

random:
    ; Load state from inline storage
    LDA _rng_lo         ; 4 cycles
    LDX _rng_hi         ; 4

    ; --- state ^= state << 7 ---
    ; (state << 7) = (state << 8) >> 1
    ; (state<<8): hi=lo, lo=0  then >>1: hi=lo>>1, lo=bit0<<7
    STX _rng_tmp        ; save hi
    TAY                 ; Y = original lo
    LSR A               ; lo>>1 = hi byte of (state<<7), carry = lo bit 0
    STA _rng_tmp+1      ; scratch for shifted hi
    LDA #$00
    ROR A               ; carry into bit 7 = lo byte of (state<<7)
    ; XOR into state
    EOR _rng_lo         ; state.lo ^= (state<<7).lo
    STA _rng_lo
    LDA _rng_tmp+1
    EOR _rng_hi         ; state.hi ^= (state<<7).hi
    STA _rng_hi

    ; --- state ^= state >> 9 ---
    ; (state>>9) = {0, hi>>1}  (only affects lo byte)
    LDA _rng_hi
    LSR A               ; hi >> 1
    EOR _rng_lo
    STA _rng_lo         ; state.lo ^= (state>>9).lo

    ; --- state ^= state << 8 ---
    ; (state<<8) = {lo, 0}  (only affects hi byte)
    LDA _rng_lo
    EOR _rng_hi
    STA _rng_hi         ; state.hi ^= state.lo

    ; Return: A=lo, X=hi
    LDA _rng_lo
    LDX _rng_hi
    RTS

; Inline state — default seed $0001
_rng_lo:  .byte $01
_rng_hi:  .byte $00
_rng_tmp: .byte $00, $00

; randomSeed — seed the PRNG
; Input: A = seed lo, X = seed hi
; A zero seed is replaced by $0001.
randomSeed:
    STA _rng_lo
    STX _rng_hi
    ORA _rng_hi
    BNE .ok
    LDA #$01
    STA _rng_lo
.ok:
    RTS
