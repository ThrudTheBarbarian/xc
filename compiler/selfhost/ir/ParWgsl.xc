// ParWgsl.xc — the WGSL printer's working state (Lower.xc's wg* methods): a
// pointer value's recipe and one function being printed. As the reference's
// XTIRParWGSL.m, whose text the port prints exactly.

// Where a pointer value points: a buffer or a field variable, and the element
// index (the name of a u32 variable), if any.
class WgRecipe
    {
    String* base;      // b3, g0, f5 …
    String* index;     // or 0
    String* pointee;   // the IR type pointed at
    bool words;        // a narrow element of an array<atomic<u32>>
    }

// One function being printed.
class WgFn
    {
    String* vars;
    String* code;
    Map* varOf;        // value key -> variable name
    Map* recipeOf;     // pointer value key -> WgRecipe
    Map* used;         // value key -> 1: values some instruction reads
    String* retVar;    // or 0
    u32 temps;
    bool dry;          // the structured walk's dry run: shape only, no text

    void init(void)
        {
        vars = new String();
        code = new String();
        varOf = new Map();
        recipeOf = new Map();
        used = new Map();
        retVar = (String*)0;
        temps = (u32)0;
        dry = false;
        }
    }
