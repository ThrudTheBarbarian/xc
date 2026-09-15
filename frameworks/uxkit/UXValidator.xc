// UXValidator.xc — field-value validation rules (NSFormatter/validation, form-field style).
//
// A list of rules a value must pass: non-empty, matches a regex, a length range, or an integer range.
// validate() is all-pass; firstError() gives the message of the first failing rule for a field's
// error label.  Composes UXRegex.  Pure logic, testable — the check behind a text field's live
// validation and a form's Submit gate.
#import "Array.xc"
#import "UXRegex.xc"

#define UXV_REQUIRED 0
#define UXV_REGEX 1
#define UXV_MINLEN 2
#define UXV_MAXLEN 3
#define UXV_INTRANGE 4

class UXValidationRule : Object
    {
    i32 type;
    UXRegex* rx;
    i32 a;
    i32 b;
    u8* message;
    void init(void)
        {
        type = (i32)UXV_REQUIRED;
        rx = (UXRegex*)0;
        a = (i32)0;
        b = (i32)0;
        message = (u8*)"";
        }
    }

    class UXValidator
    {
    Array<UXValidationRule>* rules;
    void init(void)
        {
        rules = new Array();
        }

    static i32 slen(u8* s)
        {
        if (s == (u8*)0)
            {
            return (i32)0;
            }
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        return n;
        }
    static i32 toInt(u8* s)
        {
        i32 i = (i32)0;
        i32 sign = (i32)1;
        i32 v = (i32)0;
        if (s == (u8*)0)
            {
            return (i32)0;
            }
        if (s[i] == (u8)'-')
            {
            sign = (i32)-1;
            i = i + (i32)1;
            }
        while (s[i] >= (u8)'0' && s[i] <= (u8)'9')
            {
            v = v * (i32)10 + (i32)(s[i] - (u8)'0');
            i = i + (i32)1;
            }
        return v * sign;
        }

    void addRule(i32 type, UXRegex* rx, i32 a, i32 b, u8* msg)
        {
        UXValidationRule* r = new UXValidationRule();
        r.type = type;
        r.rx = rx;
        r.a = a;
        r.b = b;
        r.message = msg;
        rules.add(r);
        }
    void requireNonEmpty(u8* msg)
        {
        self.addRule((i32)UXV_REQUIRED, (UXRegex*)0, (i32)0, (i32)0, msg);
        }
    void requireMatch(u8* pattern, u8* msg)
        {
        self.addRule((i32)UXV_REGEX, UXRegex.compile(pattern), (i32)0, (i32)0, msg);
        }
    void requireMinLength(i32 n, u8* msg)
        {
        self.addRule((i32)UXV_MINLEN, (UXRegex*)0, n, (i32)0, msg);
        }
    void requireMaxLength(i32 n, u8* msg)
        {
        self.addRule((i32)UXV_MAXLEN, (UXRegex*)0, n, (i32)0, msg);
        }
    void requireIntRange(i32 lo, i32 hi, u8* msg)
        {
        self.addRule((i32)UXV_INTRANGE, (UXRegex*)0, lo, hi, msg);
        }

    bool passes(UXValidationRule* r, u8* value)
        {
        i32 len = UXValidator.slen(value);
        if (r.type == (i32)UXV_REQUIRED)
            {
            return len > (i32)0;
            }
        if (r.type == (i32)UXV_REGEX)
            {
            return r.rx != (UXRegex*)0 && r.rx.matches(value);
            }
        if (r.type == (i32)UXV_MINLEN)
            {
            return len >= r.a;
            }
        if (r.type == (i32)UXV_MAXLEN)
            {
            return len <= r.a;
            }
        // INTRANGE
        i32 v = UXValidator.toInt(value);
        return v >= r.a && v <= r.b;
        }

    bool validate(u8* value)
        {
        for (u16 i = (u16)0; i < rules.count(); i = i + (u16)1)
            {
            if (!self.passes((UXValidationRule* ?)rules.get(i), value))
                {
                return false;
                }
            }
        return true;
        }
    // Message of the first failing rule, or 0 if all pass.
    u8* firstError(u8* value)
        {
        for (u16 i = (u16)0; i < rules.count(); i = i + (u16)1)
            {
            UXValidationRule* r = (UXValidationRule* ?)rules.get(i);
            if (!self.passes(r, value))
                {
                return r.message;
                }
            }
        return (u8*)0;
        }
    i32 ruleCount(void)
        {
        return (i32)rules.count();
        }
    }
