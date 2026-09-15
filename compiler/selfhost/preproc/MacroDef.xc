// MacroDef.xc — one #define.
// =================================================================
//
// self-hosting M5. The xtc counterpart of src/xtc/preprocessor/
// XTMacroDefinition.m, and the same three fields: the name, the parameter list
// (absent for an object-like macro), and the body as raw text.
//
// `isFunctionLike` is "has a parameter list", NOT "has a non-empty parameter
// list": `#define F() x` is function-like with zero parameters, and expanding it
// requires a `()` at the call site. The distinction is carried by a separate
// flag rather than by `params == 0`, because an empty Array@ and a null one are
// easy to confuse and the difference changes what the expander does.

#import "Foundation.xc"

class MacroDef
    {
    String* _name;
    Array* _params; // of String@; null for an object-like macro
    String* _body;
    bool _functionLike;
    bool _varArgs; // last parameter is "..."

    void init(void)
        {
        _name = (String*)0;
        _params = (Array*)0;
        _body = (String*)0;
        _functionLike = false;
        _varArgs = false;
        }

    static MacroDef* with(String* name, Array* params, String* body)
        {
        MacroDef* m = new MacroDef();
        m._name = name;
        m._params = params;
        m._body = (body == 0) ? String.withCString("") : body;
        m._functionLike = (params != 0);
        m._varArgs = false;
        if (params != 0 && params.count() > (u32)0)
            {
            String* last = (String*)params.get(params.count() - (u32)1);
            m._varArgs = last.equals(String.withCString("..."));
            }
        return m;
        }

    String* name(void)
        {
        return _name;
        }
    Array* params(void)
        {
        return _params;
        }
    String* body(void)
        {
        return _body;
        }
    bool functionLike(void)
        {
        return _functionLike;
        }
    bool varArgs(void)
        {
        return _varArgs;
        }
    }
