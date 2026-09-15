// MsFn.xc — one function's entry in the checked-build parameter map.
// =================================================================
//
// Three parallel facts per parameter (frame offset, kind+width, home register)
// and the frame's callee-saved list, which is what lets the trap reporter walk
// outwards and recover the arguments of frames it did not stop in.
//
// A record rather than three loose arrays because the emission order IS the
// contract with rt-checked.c: five quads per function, three per parameter,
// a -1-terminated saved list. See private:docs/Design/memory-safety.md §4.
#import "Foundation.xc"

class MsFn
    {
    String* _name;
    Array* _params; // triples: off, kind<<8|width, reg
    Array* _saved;  // callee-saved register numbers, d-regs offset by 64
    i64 _saveBase;

    void init(void)
        {
        _params = new Array();
        _saved = new Array();
        _saveBase = (i64)0;
        }

    String* name(void)
        {
        return _name;
        }
    Array* params(void)
        {
        return _params;
        }
    Array* saved(void)
        {
        return _saved;
        }
    i64 saveBase(void)
        {
        return _saveBase;
        }

    void setName(String* n)
        {
        _name = n;
        }
    void setSaveBase(i64 b)
        {
        _saveBase = b;
        }
    void addSaved(i64 r)
        {
        _saved.add((Object*)Number.withI32((i32)r));
        }
    void addParam(i64 off, i64 kw, i64 reg)
        {
        _params.add((Object*)Number.withI32((i32)off));
        _params.add((Object*)Number.withI32((i32)kw));
        _params.add((Object*)Number.withI32((i32)reg));
        }
    }
