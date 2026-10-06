// xcc runtime library.
//
// Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
//
// This file is part of the xcc runtime library: the code that is combined
// with a program when xcc compiles it. It is free software; you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// Under Section 7 of GPL version 3, you are granted additional permissions
// described in the GCC Runtime Library Exception, version 3.1, as published
// by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
// parent.
//
// The effect of that exception is the point: a program compiled by xcc
// contains parts of this file, and the exception is what leaves that program
// under whatever licence its author chooses, including a proprietary one.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.
// Expression.xc — parse an arithmetic expression once, evaluate it many times
// (NSExpression in shape).
// ===========================================================================
//
//     Expression* e = Expression.parse(String.withCString("qty * price + tax"));
//     Map* vars = new Map();
//     vars.set(String.withCString("qty"), Number.withI64((i64)3));
//     vars.set(String.withCString("price"), Number.withI64((i64)200));
//     vars.set(String.withCString("tax"), Number.withDouble(12.5d));
//     Number* total = e.evaluate(vars);          // 612.5
//
// ── The language ────────────────────────────────────────────────────────────
//
// From the loosest binding to the tightest:
//
//     a || b          either is non-zero                  (a bool)
//     a && b          both are non-zero                   (a bool)
//     == != < > <= >= compare                             (a bool)
//     + -             add, subtract
//     * / %           multiply, divide, remainder
//     - ! +           negate, not, plus                   (prefix)
//     42  0x2A  2.5  1e3  true  false  name  f(a, b)  ( … )
//
// Names are letters, digits and '_' after a letter or '_'. The functions are
// min and max (one or more arguments) and abs (one). && and || evaluate their
// right side only when they need it.
//
// ── Numbers ─────────────────────────────────────────────────────────────────
//
// Values are Numbers. An operation on two integers stays an exact 64-bit
// integer (wrapping on overflow, as the language's i64 does): / truncates
// toward zero and % takes the sign of the left side. If either side is a
// double the operation is done in double. Literals are read exactly (the
// nearest double, as JSON reads them). A comparison or a logical operator
// gives Number.withBool. A literal with a '.' or an exponent is a double.
//
// ── Errors ──────────────────────────────────────────────────────────────────
//
// `parse` throws an ExpressionError for text that is not one expression, with
// the byte offset. `evaluate` throws one for a variable with no value (or a
// value that is not a Number), and for an integer / or % by zero.
//
// ── Availability ────────────────────────────────────────────────────────────
//
// Every target except xt6502.

#if ARCH_6502
#error "Expression: not available on xt6502"
#endif

#import "Foundation.xc"
#import "Error.xc"
#import "JSON.xc"

class ExpressionError <Error>
    {
    String* _message;

    void init(String* message)
        {
        _message = message;
        }

    String* message(void)
        {
        return _message;
        }
    }

enum _ExprOp = {XO_NUM, XO_VAR, XO_CALL, XO_NEG, XO_NOT, XO_ADD, XO_SUB, XO_MUL, XO_DIV, XO_MOD,
                XO_EQ, XO_NE, XO_LT, XO_GT, XO_LE, XO_GE, XO_AND, XO_OR};

class _ExprNode
    {
    u8 op;
    Number* value;  // XO_NUM
    String* name;   // XO_VAR, XO_CALL
    _ExprNode* a;
    _ExprNode* b;
    Array* args;    // XO_CALL: _ExprNode arguments
    }

class Expression
    {
    _ExprNode* _root;
    Array* _names;  // the variables, first use first
    String* _text;  // the source while parsing
    u8* _p;
    u32 _n;
    u32 _i;

    // ── Parsing ──────────────────────────────────────────────────────────

    // The expression `text` holds, ready to evaluate.
    static Expression* parse(String* text) throws
        {
        Expression* e = new Expression();
        e._names = new Array();
        if (text == 0)
            Expression._fail("no text", (u32)0);
        e._text = text;
        e._p = text.cString();
        e._n = text.byteLength();
        e._i = (u32)0;
        e._root = e._or();
        e._ws();
        if (e._i < e._n)
            Expression._fail("unexpected text after the expression", e._i);
        e._text = (String*)0;
        e._p = (u8*)0;
        return e;
        }

    // The names of the variables it uses, each once, in the order they
    // first appear.
    Array* variables(void)
        {
        Array* out = new Array();
        for (u32 i = (u32)0; i < _names.count(); i++)
            out.add(_names.get(i));
        return out;
        }

    static void _fail(u8* why, u32 at) throws
        {
        String* m = String.withCString("bad expression at byte ");
        m.append(String.withU32(at));
        m.appendCString(": ");
        m.appendCString(why);
        throw new ExpressionError(m);
        }

    void _ws(void)
        {
        u8* p = _p;
        while (_i < _n && (p[_i] == (u8)' ' || p[_i] == (u8)'\t' || p[_i] == (u8)'\n' || p[_i] == (u8)'\r'))
            _i++;
        }

    // Consumes `s` (after spaces) when it is next.
    bool _take(u8* s)
        {
        _ws();
        u8* p = _p;
        u32 k = (u32)0;
        while (s[k] != (u8)0)
            {
            if (_i + k >= _n || p[_i + k] != s[k])
                return false;
            k++;
            }
        _i = _i + k;
        return true;
        }

    static _ExprNode* _node(u8 op, _ExprNode* a, _ExprNode* b)
        {
        _ExprNode* n = new _ExprNode();
        n.op = op;
        n.a = a;
        n.b = b;
        return n;
        }

    _ExprNode* _or(void) throws
        {
        _ExprNode* l = _and();
        while (_take("||"))
            l = Expression._node((u8)XO_OR, l, _and());
        return l;
        }

    _ExprNode* _and(void) throws
        {
        _ExprNode* l = _compare();
        while (_take("&&"))
            l = Expression._node((u8)XO_AND, l, _compare());
        return l;
        }

    _ExprNode* _compare(void) throws
        {
        _ExprNode* l = _add();
        while (true)
            {
            u8 op;
            if (_take("=="))
                op = (u8)XO_EQ;
            else if (_take("!="))
                op = (u8)XO_NE;
            else if (_take("<="))
                op = (u8)XO_LE;
            else if (_take(">="))
                op = (u8)XO_GE;
            else if (_take("<"))
                op = (u8)XO_LT;
            else if (_take(">"))
                op = (u8)XO_GT;
            else
                return l;
            l = Expression._node(op, l, _add());
            }
        return l;
        }

    _ExprNode* _add(void) throws
        {
        _ExprNode* l = _mul();
        while (true)
            {
            if (_take("+"))
                l = Expression._node((u8)XO_ADD, l, _mul());
            else if (_take("-"))
                l = Expression._node((u8)XO_SUB, l, _mul());
            else
                return l;
            }
        return l;
        }

    _ExprNode* _mul(void) throws
        {
        _ExprNode* l = _unary();
        while (true)
            {
            if (_take("*"))
                l = Expression._node((u8)XO_MUL, l, _unary());
            else if (_take("/"))
                l = Expression._node((u8)XO_DIV, l, _unary());
            else if (_take("%"))
                l = Expression._node((u8)XO_MOD, l, _unary());
            else
                return l;
            }
        return l;
        }

    _ExprNode* _unary(void) throws
        {
        if (_take("-"))
            return Expression._node((u8)XO_NEG, _unary(), (_ExprNode*)0);
        if (_take("!"))
            return Expression._node((u8)XO_NOT, _unary(), (_ExprNode*)0);
        if (_take("+"))
            return _unary();
        return _primary();
        }

    static bool _isDigit(u8 c)
        {
        return c >= (u8)'0' && c <= (u8)'9';
        }

    static bool _isNameStart(u8 c)
        {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z') || c == (u8)'_';
        }

    _ExprNode* _primary(void) throws
        {
        _ws();
        if (_i >= _n)
            Expression._fail("expected a value", _i);
        u8* p = _p;
        u8 c = p[_i];
        if (c == (u8)'(')
            {
            _i++;
            _ExprNode* inner = _or();
            if (!_take(")"))
                Expression._fail("expected ')'", _i);
            return inner;
            }
        if (Expression._isDigit(c) || (c == (u8)'.' && _i + (u32)1 < _n && Expression._isDigit(p[_i + (u32)1])))
            return _number();
        if (Expression._isNameStart(c))
            {
            u32 start = _i;
            while (_i < _n && (Expression._isNameStart(p[_i]) || Expression._isDigit(p[_i])))
                _i++;
            String* name = String.withBytes(&p[start], _i - start);
            if (name.equals(String.withCString("true")) || name.equals(String.withCString("false")))
                {
                _ExprNode* b = Expression._node((u8)XO_NUM, (_ExprNode*)0, (_ExprNode*)0);
                b.value = Number.withBool(name.equals(String.withCString("true")));
                return b;
                }
            if (_take("("))
                return _call(name, start);
            _ExprNode* v = Expression._node((u8)XO_VAR, (_ExprNode*)0, (_ExprNode*)0);
            v.name = name;
            if (!_names.containsEqual(name))
                _names.add(name);
            return v;
            }
        Expression._fail("expected a value", _i);
        return (_ExprNode*)0;
        }

    _ExprNode* _call(String* name, u32 at) throws
        {
        bool one = name.equals(String.withCString("abs"));
        if (!one && !name.equals(String.withCString("min")) && !name.equals(String.withCString("max")))
            Expression._fail("unknown function", at);
        _ExprNode* f = Expression._node((u8)XO_CALL, (_ExprNode*)0, (_ExprNode*)0);
        f.name = name;
        f.args = new Array();
        if (!_take(")"))
            {
            f.args.add(_or());
            while (_take(","))
                f.args.add(_or());
            if (!_take(")"))
                Expression._fail("expected ')' or ','", _i);
            }
        if (f.args.count() == (u32)0 || (one && f.args.count() != (u32)1))
            Expression._fail(one ? "abs takes one argument" : "min and max take at least one argument", at);
        return f;
        }

    _ExprNode* _number(void) throws
        {
        u8* p = _p;
        u32 start = _i;
        _ExprNode* n = Expression._node((u8)XO_NUM, (_ExprNode*)0, (_ExprNode*)0);
        if (p[_i] == (u8)'0' && _i + (u32)1 < _n && (p[_i + (u32)1] == (u8)'x' || p[_i + (u32)1] == (u8)'X'))
            {
            _i = _i + (u32)2;
            u64 v = (u64)0;
            u32 digits = (u32)0;
            while (_i < _n)
                {
                u8 c = p[_i];
                u64 d;
                if (Expression._isDigit(c))
                    d = (u64)(c - (u8)'0');
                else if (c >= (u8)'a' && c <= (u8)'f')
                    d = (u64)(c - (u8)'a') + (u64)10;
                else if (c >= (u8)'A' && c <= (u8)'F')
                    d = (u64)(c - (u8)'A') + (u64)10;
                else
                    break;
                if (digits == (u32)16)
                    Expression._fail("hex number too large", start);
                v = v * (u64)16 + d;
                digits++;
                _i++;
                }
            if (digits == (u32)0)
                Expression._fail("bad number", start);
            n.value = Number.withI64((i64)v);
            return n;
            }
        bool isFloat = false;
        while (_i < _n && Expression._isDigit(p[_i]))
            _i++;
        if (_i < _n && p[_i] == (u8)'.')
            {
            isFloat = true;
            _i++;
            while (_i < _n && Expression._isDigit(p[_i]))
                _i++;
            }
        if (_i < _n && (p[_i] == (u8)'e' || p[_i] == (u8)'E'))
            {
            u32 save = _i;
            _i++;
            if (_i < _n && (p[_i] == (u8)'+' || p[_i] == (u8)'-'))
                _i++;
            if (_i < _n && Expression._isDigit(p[_i]))
                {
                isFloat = true;
                while (_i < _n && Expression._isDigit(p[_i]))
                    _i++;
                }
            else
                _i = save;
            }
        if (_i < _n && Expression._isNameStart(p[_i]))
            Expression._fail("bad number", start);
        if (isFloat)
            {
            n.value = Number.withDouble(_json_parseDouble(&p[start], _i - start));
            return n;
            }
        u64 v = (u64)0;
        for (u32 k = start; k < _i; k++)
            {
            u64 d = (u64)(p[k] - (u8)'0');
            if (v > ((u64)0x7FFFFFFFFFFFFFFF - d) / (u64)10)
                Expression._fail("integer too large; write it with a '.' for a double", start);
            v = v * (u64)10 + d;
            }
        n.value = Number.withI64((i64)v);
        return n;
        }

    // ── Evaluating ───────────────────────────────────────────────────────

    // The value with no variables.
    Number* evaluate(void) throws
        {
        return _eval(_root, (Map*)0);
        }

    // The value with each variable taken from `vars`, a Map from its name (a
    // String) to a Number.
    Number* evaluate(Map* vars) throws
        {
        return _eval(_root, vars);
        }

    static bool _truth(Number* v)
        {
        return v.asBool();
        }

    Number* _eval(_ExprNode* n, Map* vars) throws
        {
        u8 op = n.op;
        if (op == (u8)XO_NUM)
            return n.value;
        if (op == (u8)XO_VAR)
            {
            Number* v = (Number*)0;
            if (vars != 0)
                v = (Number* ?)vars.get(n.name);
            if (v == 0)
                {
                String* m = String.withCString("no Number for the variable '");
                m.append(n.name);
                m.appendCString("'");
                throw new ExpressionError(m);
                }
            return v;
            }
        if (op == (u8)XO_CALL)
            {
            Number* best = _eval((_ExprNode*)n.args.get((u32)0), vars);
            if (n.name.equals(String.withCString("abs")))
                {
                if (best.isFloat())
                    return Number.withDouble(best.asDouble() < 0.0d ? -best.asDouble() : best.asDouble());
                return Number.withI64(best.asI64() < (i64)0 ? (i64)0 - best.asI64() : best.asI64());
                }
            bool wantMax = n.name.equals(String.withCString("max"));
            for (u32 k = (u32)1; k < n.args.count(); k++)
                {
                Number* x = _eval((_ExprNode*)n.args.get(k), vars);
                i8 c = Expression._cmp(x, best);
                if ((wantMax && c > (i8)0) || (!wantMax && c < (i8)0))
                    best = x;
                }
            return best;
            }
        if (op == (u8)XO_NEG)
            {
            Number* v = _eval(n.a, vars);
            if (v.isFloat())
                return Number.withDouble(-v.asDouble());
            return Number.withI64((i64)0 - v.asI64());
            }
        if (op == (u8)XO_NOT)
            return Number.withBool(!Expression._truth(_eval(n.a, vars)));
        if (op == (u8)XO_AND)
            {
            if (!Expression._truth(_eval(n.a, vars)))
                return Number.withBool(false);
            return Number.withBool(Expression._truth(_eval(n.b, vars)));
            }
        if (op == (u8)XO_OR)
            {
            if (Expression._truth(_eval(n.a, vars)))
                return Number.withBool(true);
            return Number.withBool(Expression._truth(_eval(n.b, vars)));
            }
        Number* l = _eval(n.a, vars);
        Number* r = _eval(n.b, vars);
        if (op >= (u8)XO_EQ)
            {
            i8 c = Expression._cmp(l, r);
            if (op == (u8)XO_EQ)
                return Number.withBool(c == (i8)0);
            if (op == (u8)XO_NE)
                return Number.withBool(c != (i8)0);
            if (op == (u8)XO_LT)
                return Number.withBool(c < (i8)0);
            if (op == (u8)XO_GT)
                return Number.withBool(c > (i8)0);
            if (op == (u8)XO_LE)
                return Number.withBool(c <= (i8)0);
            return Number.withBool(c >= (i8)0);
            }
        if (l.isFloat() || r.isFloat())
            {
            double x = l.asDouble();
            double y = r.asDouble();
            if (op == (u8)XO_ADD)
                return Number.withDouble(x + y);
            if (op == (u8)XO_SUB)
                return Number.withDouble(x - y);
            if (op == (u8)XO_MUL)
                return Number.withDouble(x * y);
            if (op == (u8)XO_DIV)
                return Number.withDouble(x / y);
            // The remainder of a truncated quotient, sign of x.
            double q = x / y;
            double t = (q < 0.0d) ? -(double)(i64)(-q) : (double)(i64)q;
            return Number.withDouble(x - t * y);
            }
        i64 a = l.asI64();
        i64 b = r.asI64();
        if (op == (u8)XO_ADD)
            return Number.withI64((i64)((u64)a + (u64)b));
        if (op == (u8)XO_SUB)
            return Number.withI64((i64)((u64)a - (u64)b));
        if (op == (u8)XO_MUL)
            return Number.withI64((i64)((u64)a * (u64)b));
        if (b == (i64)0)
            throw new ExpressionError(String.withCString(op == (u8)XO_DIV ? "integer division by zero" : "integer remainder by zero"));
        // The one quotient that overflows: the most negative i64 over -1.
        if (b == (i64)-1)
            return Number.withI64(op == (u8)XO_DIV ? (i64)((u64)0 - (u64)a) : (i64)0);
        if (op == (u8)XO_DIV)
            return Number.withI64(a / b);
        return Number.withI64(a % b);
        }

    // Order of two Numbers: exact for two integers, in double otherwise.
    static i8 _cmp(Number* x, Number* y)
        {
        if (x.isFloat() || y.isFloat())
            {
            double a = x.asDouble();
            double b = y.asDouble();
            return a < b ? (i8)-1 : (a > b ? (i8)1 : (i8)0);
            }
        i64 a = x.asI64();
        i64 b = y.asI64();
        return a < b ? (i8)-1 : (a > b ? (i8)1 : (i8)0);
        }
    }
