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
// CSV.xc — comma-separated values to rows of strings and back (RFC 4180).
// ===========================================================================
//
//     Array* rows = CSV.parse(String.withCString("name,qty\r\n\"Smith, J\",3\r\n"));
//     Array* first = (Array*)rows.get(1);           // ["Smith, J", "3"]
//     String* text = CSV.stringify(rows);           // name,qty\n"Smith, J",3\n
//
// A row is an Array of String fields, and the text is an Array of rows. A
// field in double quotes may hold the separator, line breaks and "" for one
// quote; any other field is taken as it stands, spaces included. Lines end in
// \r\n, \n or \r. A final line break does not start another row, and an empty
// text has no rows. A row may have any number of fields: the parser does not
// make them equal.
//
// Writing quotes a field only when it needs it (it holds the separator, a
// quote, \r or \n), doubles its quotes, and ends every row with \n. A field
// may be any object: a String as it is, a null reference or Null as an empty
// field, anything else as its description.
//
// `records` turns rows into one Map per data row, keyed by the header row.
//
// ── Errors ──────────────────────────────────────────────────────────────────
//
// `parse` and `parseWith` throw a CSVError for a quoted field that is never
// closed, or one followed by anything but the separator or a line break.
//
// ── Availability ────────────────────────────────────────────────────────────
//
// Every heap-capable target, the 6502 included (there with u16 lengths).

#import "Foundation.xc"
#import "Error.xc"

#if ARCH_6502
#define _CSV_N u16
#else
#define _CSV_N u32
#endif

class CSVError <Error>
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

class CSV
    {
    // ── Reading ──────────────────────────────────────────────────────────

    // The rows of comma-separated `text`.
    static Array* parse(String* text) throws
        {
        return CSV.parseWith(text, (u8)',');
        }

    // The rows of `text` with another separator: (u8)'\t' for tab-separated
    // values, (u8)';' for the European spreadsheet form.
    static Array* parseWith(String* text, u8 sep) throws
        {
        Array* rows = new Array();
        if (text == 0)
            return rows;
        u8* p = text.cString();
        _CSV_N n = CSV._len(text);
        _CSV_N i = (_CSV_N)0;
        while (i < n)
            {
            Array* row = new Array();
            bool endOfRow = false;
            while (!endOfRow)
                {
                String* field = String.withCString("");
                if (i < n && p[i] == (u8)'"')
                    {
                    _CSV_N open = i;
                    i++;
                    bool closed = false;
                    while (i < n)
                        {
                        if (p[i] == (u8)'"')
                            {
                            if (i + (_CSV_N)1 < n && p[i + (_CSV_N)1] == (u8)'"')
                                {
                                CSV._add(field, (u8)'"');
                                i = i + (_CSV_N)2;
                                continue;
                                }
                            i++;
                            closed = true;
                            break;
                            }
                        CSV._add(field, p[i]);
                        i++;
                        }
                    if (!closed)
                        CSV._fail("a quoted field is never closed", open);
                    if (i < n && p[i] != sep && p[i] != (u8)'\r' && p[i] != (u8)'\n')
                        CSV._fail("text after a quoted field's closing quote", i);
                    }
                else
                    {
                    _CSV_N start = i;
                    while (i < n && p[i] != sep && p[i] != (u8)'\r' && p[i] != (u8)'\n')
                        i++;
                    if (i > start)
                        field = String.withBytes(&p[start], i - start);
                    }
                row.add(field);
                if (i < n && p[i] == sep)
                    {
                    i++;
                    continue;
                    }
                // A line break or the end ends the row; \r\n is one break.
                if (i < n && p[i] == (u8)'\r')
                    i++;
                if (i < n && p[i] == (u8)'\n')
                    i++;
                endOfRow = true;
                }
            rows.add(row);
            }
        return rows;
        }

    // One Map per row after the first, from each header field to the field
    // under it. A short row's missing fields are empty Strings; fields past
    // the header's are dropped. Header names that repeat keep the last column.
    static Array* records(Array* rows)
        {
        Array* out = new Array();
        if (rows == 0 || rows.count() == (_CSV_N)0)
            return out;
        Array* header = (Array*)rows.get((_CSV_N)0);
        _CSV_N cols = header.count();
        for (_CSV_N r = (_CSV_N)1; r < rows.count(); r++)
            {
            Array* row = (Array*)rows.get(r);
            Map* m = new Map();
            for (_CSV_N c = (_CSV_N)0; c < cols; c++)
                {
                Object* v = c < row.count() ? row.get(c) : (Object*)String.withCString("");
                m.set((String*)header.get(c), v);
                }
            out.add(m);
            }
        return out;
        }

    // ── Writing ──────────────────────────────────────────────────────────

    // `rows` as comma-separated text, every row ending in \n.
    static String* stringify(Array* rows)
        {
        return CSV.stringifyWith(rows, (u8)',');
        }

    static String* stringifyWith(Array* rows, u8 sep)
        {
        String* out = String.withCString("");
        if (rows == 0)
            return out;
        for (_CSV_N r = (_CSV_N)0; r < rows.count(); r++)
            {
            Array* row = (Array* ?)rows.get(r);
            if (row != 0)
                {
                for (_CSV_N c = (_CSV_N)0; c < row.count(); c++)
                    {
                    if (c > (_CSV_N)0)
                        CSV._add(out, sep);
                    CSV._writeField(out, row.get(c), sep);
                    }
                }
            CSV._add(out, (u8)'\n');
            }
        return out;
        }

    static void _writeField(String* out, Object* v, u8 sep)
        {
        if (v == 0 || Null.isNull(v))
            return;
        String* s = (String* ?)v;
        if (s == 0)
            s = v.description();
        u8* p = s.cString();
        _CSV_N n = CSV._len(s);
        bool quote = false;
        for (_CSV_N i = (_CSV_N)0; i < n; i++)
            {
            u8 c = p[i];
            if (c == sep || c == (u8)'"' || c == (u8)'\r' || c == (u8)'\n')
                {
                quote = true;
                break;
                }
            }
        if (!quote)
            {
            out.append(s);
            return;
            }
        CSV._add(out, (u8)'"');
        for (_CSV_N i = (_CSV_N)0; i < n; i++)
            {
            if (p[i] == (u8)'"')
                CSV._add(out, (u8)'"');
            CSV._add(out, p[i]);
            }
        CSV._add(out, (u8)'"');
        }

    // ── The two String APIs ──────────────────────────────────────────────

    static _CSV_N _len(String* s)
        {
#if ARCH_6502
        return s.length();
#else
        return s.byteLength();
#endif
        }

    static void _add(String* s, u8 c)
        {
#if ARCH_6502
        s.appendChar(c);
#else
        s.appendByte(c);
#endif
        }

    static void _fail(u8* why, _CSV_N at) throws
        {
        String* m = String.withCString("bad CSV at byte ");
#if ARCH_6502
        m.append(Number.withU16(at).description());
#else
        m.append(String.withU32(at));
#endif
        m.appendCString(": ");
        m.appendCString(why);
        throw new CSVError(m);
        }
    }
