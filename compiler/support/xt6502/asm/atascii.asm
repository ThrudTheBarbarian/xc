; atascii.asm — ATASCII character code to glyph mapping table
; ============================================================
;
; Maps ATASCII codes 0-127 to printable glyph representations.
; Codes 128-255 are inverse video of codes 0-127.
;
; Usage: LDX #code ; LDA atascii_glyphs,X
;
; For printable characters ($20-$7C), the glyph is the character itself.
; For graphics characters ($00-$1A) and control codes, the table stores
; a substitute printable character (typically '.') since these are
; screen-mode-specific graphics glyphs that cannot be represented as
; single text bytes.
;
; Control code entries:
;   $1B = ESC         → $1B (pass through)
;   $1C = Cursor Up   → $1C
;   $1D = Cursor Down → $1D
;   $1E = Cursor Left → $1E
;   $1F = Cursor Right→ $1F
;   $7D = Clear Screen→ $7D
;   $7E = Backspace   → $7E
;   $7F = Tab         → $7F
;   $9B = EOL/Return
;   $9C = Delete Line
;   $9D = Insert Line
;   $9E = Clear Tab
;   $9F = Set Tab
;   $FD = Buzzer
;   $FE = Delete Char
;   $FF = Insert Char
;
; Glyph table for codes $00-$7F (128 bytes).
; Codes $80-$FF are inverse video: glyph = atascii_glyphs[code & $7F]

atascii_glyphs:
    ; $00-$0F: Graphics characters (hearts, box drawing, blocks, etc.)
    ; These are screen-mode glyphs; we store their ATASCII code directly
    ; so the display routine can render them in graphics mode.
    .byte $00,$01,$02,$03,$04,$05,$06,$07  ; heart, ├, block, ┘, ┤, ┐, ╱, ╲
    .byte $08,$09,$0A,$0B,$0C,$0D,$0E,$0F  ; ◢, ▗, ◣, ▝, ▘, upper-block, ▂, ▖

    ; $10-$1F: More graphics + control characters
    .byte $10,$11,$12,$13,$14,$15,$16,$17  ; clubs, ┌, ─, ┼, bullet, ▄, ▎, ┬
    .byte $18,$19,$1A,$1B,$1C,$1D,$1E,$1F  ; ┴, ▌, └, ESC, CurUp, CurDn, CurL, CurR

    ; $20-$2F: Space, punctuation, digits prefix
    .byte $20,$21,$22,$23,$24,$25,$26,$27  ; SP ! " # $ % & '
    .byte $28,$29,$2A,$2B,$2C,$2D,$2E,$2F  ; ( ) * + , - . /

    ; $30-$3F: Digits, more punctuation
    .byte $30,$31,$32,$33,$34,$35,$36,$37  ; 0 1 2 3 4 5 6 7
    .byte $38,$39,$3A,$3B,$3C,$3D,$3E,$3F  ; 8 9 : ; < = > ?

    ; $40-$4F: @ and uppercase A-O
    .byte $40,$41,$42,$43,$44,$45,$46,$47  ; @ A B C D E F G
    .byte $48,$49,$4A,$4B,$4C,$4D,$4E,$4F  ; H I J K L M N O

    ; $50-$5F: Uppercase P-Z, symbols
    .byte $50,$51,$52,$53,$54,$55,$56,$57  ; P Q R S T U V W
    .byte $58,$59,$5A,$5B,$5C,$5D,$5E,$5F  ; X Y Z [ \ ] ^ _

    ; $60-$6F: Diamond, lowercase a-o
    .byte $60,$61,$62,$63,$64,$65,$66,$67  ; ♦ a b c d e f g
    .byte $68,$69,$6A,$6B,$6C,$6D,$6E,$6F  ; h i j k l m n o

    ; $70-$7F: Lowercase p-z, card suits, control chars
    .byte $70,$71,$72,$73,$74,$75,$76,$77  ; p q r s t u v w
    .byte $78,$79,$7A,$7B,$7C,$7D,$7E,$7F  ; x y z ♠ | ClrScr BkSp Tab


; ──────────────────────────────────────────────────────────────────────
; atascii_is_printable — test if an ATASCII code is a printable glyph
; ──────────────────────────────────────────────────────────────────────
; Entry: A = ATASCII code
; Exit:  Carry set if printable, carry clear if control
;
; Printable range: $00-$1A (graphics), $20-$7C, $80-$9A, $A0-$FC
; Control codes:   $1B-$1F, $7D-$7F, $9B-$9F, $FD-$FF

atascii_is_printable:
    CMP #$20
    BCC .check_graphics   ; < $20: could be graphics ($00-$1A) or control ($1B-$1F)
    CMP #$7D
    BCC .printable        ; $20-$7C: printable
    CMP #$80
    BCC .control          ; $7D-$7F: control
    ; $80-$FF: inverse video — check lower 7 bits
    PHA
    AND #$7F
    CMP #$20
    BCC .inv_check_graphics
    CMP #$7D
    BCC .inv_printable
    ; $FD-$FF inverse: control
    PLA
    CLC
    RTS
.inv_check_graphics:
    CMP #$1B
    BCS .inv_control
.inv_printable:
    PLA
    SEC
    RTS
.inv_control:
    PLA
    CLC
    RTS
.check_graphics:
    CMP #$1B
    BCS .control          ; $1B-$1F: control
    SEC                   ; $00-$1A: printable (graphics glyph)
    RTS
.printable:
    SEC
    RTS
.control:
    CLC
    RTS


; ──────────────────────────────────────────────────────────────────────
; atascii_to_screencode — convert ATASCII code to Atari screen memory code
; ──────────────────────────────────────────────────────────────────────
; The Atari's screen memory uses a different encoding than ATASCII.
; Entry: A = ATASCII code (0-127 for normal, 128-255 for inverse)
; Exit:  A = screen code
;
; Mapping (for codes 0-127, inverse adds $80):
;   ATASCII $00-$1F → screen $40-$5F
;   ATASCII $20-$3F → screen $00-$1F
;   ATASCII $40-$5F → screen $20-$3F
;   ATASCII $60-$7F → screen $60-$7F

atascii_to_screencode:
    PHA
    AND #$80              ; save inverse bit
    STA _ata_tmp
    PLA
    AND #$7F              ; work with base code
    CMP #$20
    BCC .range_00_1f
    CMP #$40
    BCC .range_20_3f
    CMP #$60
    BCC .range_40_5f
    ; $60-$7F → $60-$7F (no change)
    JMP .apply_inverse
.range_00_1f:
    ; $00-$1F → $40-$5F
    CLC
    ADC #$40
    JMP .apply_inverse
.range_20_3f:
    ; $20-$3F → $00-$1F
    SEC
    SBC #$20
    JMP .apply_inverse
.range_40_5f:
    ; $40-$5F → $20-$3F
    SEC
    SBC #$20
.apply_inverse:
    ORA _ata_tmp          ; re-apply inverse bit
    RTS

_ata_tmp:
    .byte $00


; ──────────────────────────────────────────────────────────────────────
; atascii_print_char — write one ATASCII character to screen memory
; ──────────────────────────────────────────────────────────────────────
; Entry: A = ATASCII code
;        screen_ptr (2 bytes in ZP) = current screen memory position
; Exit:  screen_ptr advanced by 1
; Note:  The caller must set up screen_ptr to point to the desired
;        screen memory address (e.g. $7C20 for GR.0 line 0 on XL/XE).

atascii_print_char:
    JSR atascii_to_screencode
    LDY #$00
    STA (screen_ptr),Y
    ; Advance screen_ptr
    INC screen_ptr
    BNE .done
    INC screen_ptr+1
.done:
    RTS

screen_ptr:
    .byte $00,$00         ; 2-byte pointer to screen memory (set by caller)
