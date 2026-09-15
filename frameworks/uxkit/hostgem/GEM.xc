// GEM.xt — host (arm64) TYPES for #import <GEM>.  Only the layouts UXKit dereferences, matching the C
// libGEM compiled for arm64 (OBJECT=32, gfx_surface=24, theme=19512; verified by a sizeof probe).
// The FUNCTIONS are hand-declared in UXGem.h.xt, so this file declares none.
struct OBJECT
    {
    i16 ob_next;
    i16 ob_head;
    i16 ob_tail; // 0,2,4
    u16 ob_type;
    u16 ob_flags;
    u16 ob_state;    // 6,8,10  (pointer forces ob_spec to 16)
    pointer ob_spec; // 16
    i16 ob_x;
    i16 ob_y;
    i16 ob_w;
    i16 ob_h; // 24,26,28,30
    // px@16 (pad after stride)
    } struct gfx_surface
    {
    i32 w;
    i32 h;
    i32 stride;
    u32 @px;
    }
    // opaque: 2439*8 = 19512 bytes, 8-aligned
    struct theme
    {
    pointer _slots[2439];
    }
