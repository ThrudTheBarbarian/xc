#include <stdint.h>

typedef struct gfx_surface
    {
    uint16_t w;
    uint16_t h;
    uint32_t stride;
    void* px;
    } gfx_surface;

int surface_area(gfx_surface* s)
    {
    return (int)(s->w * s->h);
    }

uint32_t surface_stride(gfx_surface* s)
    {
    return s->stride;
    }

/* A file-scope ANONYMOUS enum whose type is never referenced emits NO DWARF at
   all — clang constant-folds the enumerators and drops the unused type. Verified
   against -g, -g3, -fstandalone-debug and -fno-eliminate-unused-debug-types: the
   DW_TAG_enumeration_type is simply absent. So its constants CANNOT be imported;
   the information does not exist in the object file. A C library that wants its
   constants visible must give the enum a tag or a typedef (below), which is
   cheap and is what GEM/aes.h needs to do. */
enum
    {
    G_BOX = 20,
    G_TEXT = 21,
    G_USERDEF = 24
    };
enum
    {
    OF_NONE = 0x00,
    OF_SELECTABLE = 0x01,
    OF_HIDETREE = 0x80
    };
/* still no DWARF */
int surface_flags(void)
    {
    return G_USERDEF | OF_HIDETREE;
    }

/* A NAMED enum must keep working too. */
typedef enum
{
    W_NAME = 3,
    W_CLOSER = 4
} win_part;
win_part surface_part(void)
    {
    return W_NAME;
    }

/* Tagging alone is NOT enough — the enum TYPE must be USED by the library's
   interface (a parameter/return/field of that type) or clang still drops it.
   Here obj_state is a return type, so its DIE exists and its constants import. */
enum obj_state
    {
    OS_NORMAL = 0,
    OS_SELECTED = 1,
    OS_DISABLED = 8
    };
enum obj_state surface_state(void)
    {
    return OS_DISABLED;
    }
