---
title: Grammar
description: The full BNF grammar for the xc language, covering declarations, types, statements and expressions.
---

This is the grammar the compiler accepts. It was written from the parser, so
where prose elsewhere on this site is ambiguous, this page says what the parser
does. Semantic rules that a grammar cannot express, such as type checking,
overload resolution and reference counting, are covered by the other pages in
this section.

## Notation

| Form | Meaning |
|---|---|
| `UPPERCASE` | a terminal produced by the lexer |
| `'text'` | a literal keyword or punctuation token |
| `x?` | optional |
| `x*` | zero or more |
| `x+` | one or more |
| `(a \| b)` | alternation |

Whitespace and comments separate tokens and are otherwise discarded. The
preprocessor runs to completion before the parser starts, so the parser never
sees a `#` directive.

## Reserved words

These 54 words are recognised by the lexer and cannot be used as identifiers:

```
asm      auto     bool     break    case     catch    class    continue
default  defer    delete   double   else     enum     extern   false
final    float    for      global   goto     i8       i16      i32
i64      if       in       inline   new      optional pointer  protocol
register release  retain   return   sizeof   static   string   struct
switch   throw    throws   true     try      typedef  u8       u16
u32      u64      use      void     volatile while
```

Several words that behave like keywords are **contextual** and stay usable as
ordinary identifiers: `block`, `callback`, `weak`, `main`, `shadow`, `banked`,
`cloaked`, `packed`, `since`, `step`, `clobbers`, `unroll`, and the annotation
names below. `i32 callback = 7;` compiles.

## Lexical structure

```bnf
comment         ::= '//' <to end of line>
                  | '/*' <any text, no nesting> '*/'

IDENT           ::= [A-Za-z_] [A-Za-z0-9_]*

INT_LIT         ::= [0-9] [0-9_]*                  // decimal
                  | '$' [0-9A-Fa-f] [0-9A-Fa-f_]*  // hex
                  | '0x' [0-9A-Fa-f] [0-9A-Fa-f_]* // hex
                  | '%' [01] [01_]*                // binary

FLOAT_LIT       ::= [0-9] [0-9_]* '.' [0-9] [0-9_]* ( [eE] [-+]? [0-9]+ )?

CHAR_LIT        ::= "'" ( char | escape ) "'"

STRING_LIT      ::= '"' ( char | escape )* '"'

escape          ::= '\\' ( 'n' | 'r' | 't' | '0' | '\\' | '"' | "'" )
                  | '\\x' hex hex                  // 00 to 7F only
                  | '\\u' hex hex hex hex          // code point, encoded UTF-8
                  | '\\U' hex hex hex hex hex hex hex hex
```

Underscores in numeric literals are digit separators and are ignored. Floating
literals are encoded at lex time, binary32 for `float` and binary64 for
`double`.

Adjacent string literals are joined, so `"ab" "cd"` is `"abcd"`. A newline
between the pieces makes no difference. The join happens in the parser, so the
token stream still holds both literals.

## Compilation unit

```bnf
program         ::= top-decl* EOF

top-decl        ::= func-decl
                  | class-decl
                  | protocol-decl
                  | use-decl
                  | struct-decl ';'
                  | enum-decl ';'
                  | typedef-decl ';'
                  | var-decl ';'

use-decl        ::= 'use' IDENT ';'
```

## Types

```bnf
type            ::= type-qualifier* base-type ptr-sigil* array-suffix?
                  | callback-type
                  | block-type

type-qualifier  ::= ( 'main' | 'shadow' | 'banked' | 'weak' ) ':'

base-type       ::= 'i8'  | 'u8'  | 'i16' | 'u16' | 'i32' | 'u32'
                  | 'i64' | 'u64' | 'float' | 'double'
                  | 'bool' | 'void' | 'string' | 'pointer'
                  | 'auto'
                  | IDENT                  // class, struct, enum, protocol, typedef

ptr-sigil       ::= '*' | '@'

array-suffix    ::= '[' expr? ']'

type-list       ::= type (',' type)*
```

`*` is the current pointer sigil and `@` is accepted for source written before
it changed. The sigil binds to the type, so `u8* a, b;` declares two pointers.

Qualifiers may be stacked, as in `weak:banked:T*`. `weak:` cannot be written on
a `callback` or `block`, where it is already implied.

A protocol name in a type position accepts any conforming instance.

### Callback and block types

```bnf
callback-type   ::= 'callback' IDENT? array-suffix? type '(' param-list ')'
block-type      ::= 'block'    IDENT? array-suffix? type '(' param-list ')'
```

The declared name comes before the signature, and an array suffix binds to that
name: `callback tbl[2] i32(i32 n)`. A callback type also has the older spelling
`T^`, where `T` is a function typedef. The two spellings are one type and mix
freely.

## Declarations

```bnf
var-decl        ::= var-qualifier* type declarator (',' declarator)*

var-qualifier   ::= 'static' | 'global' | 'volatile' | 'register' | 'extern'

declarator      ::= IDENT array-suffix? ('=' initialiser)?

initialiser     ::= expr
                  | '{' expr-list? '}'
                  | expr ('..' | '...') expr        // range fill, integer arrays

func-decl       ::= type-list IDENT '(' param-list ')' annotations? 'throws'?
                    ( block | ';' )

param-list      ::= 'void'
                  | '...'
                  | param (',' param)* (',' '...')?

param           ::= type IDENT?

annotations     ::= ':' annotation (',' annotation)*

annotation      ::= 'banked' | 'main' | 'shadow'
                  | 'cloaked' ('(' IDENT ')')?
                  | 'naked' | 'irq' | 'vbi' | 'action'
                  | 'hwstack' | 'xtcstack' | 'needsos'
```

`{ }` is the only bracket for a body, an initialiser, an `enum` body and a
`struct` body. `[ ]` means subscripting and array declaration.

A function may return several values. The return type is a type list and
`return` carries a matching value list.

### Structs, enums, type aliases

```bnf
struct-decl     ::= 'struct' IDENT? (':' 'packed')? '{' struct-field* '}'
                  | 'struct' IDENT                  // forward declaration

struct-field    ::= type IDENT (',' IDENT)* ';'

enum-decl       ::= 'enum' IDENT '=' '{' enum-member (',' enum-member)* ','? '}'

enum-member     ::= IDENT ('=' expr)?

typedef-decl    ::= 'typedef' type IDENT
                  | 'typedef' struct-decl IDENT
```

Enum values start at 0 and increment by 1 unless given. Members are in scope
as bare identifiers, so a member is written `blue`, not `colours.blue`.

`:packed` drops the tail rounding, so the size is the sum of the field widths.

### Classes and protocols

```bnf
class-decl      ::= 'class' IDENT class-category? class-parent? class-protocols?
                    '{' class-member* '}'

class-category  ::= '(' IDENT? ')'                  // '()' is an extension
class-parent    ::= ':' IDENT
class-protocols ::= '<' IDENT (',' IDENT)* '>'

class-member    ::= member-modifier* ( field-decl ';' | method-decl )

member-modifier ::= 'static' | 'final' | 'since' '(' STRING_LIT ')'

field-decl      ::= type IDENT (',' IDENT)*

method-decl     ::= type-list IDENT '(' param-list ')' annotations? 'throws'?
                    ( block | ';' )

protocol-decl   ::= 'protocol' IDENT '{' protocol-member* '}'

protocol-member ::= 'optional'? method-decl        // signature only, no body
```

## Statements

```bnf
block           ::= '{' statement* '}'

statement       ::= if-stmt
                  | while-stmt
                  | for-stmt
                  | switch-stmt
                  | return-stmt ';'
                  | 'break' ';'
                  | 'continue' ';'
                  | 'goto' IDENT ';'
                  | defer-stmt
                  | throw-stmt
                  | try-stmt
                  | ref-op-stmt
                  | asm-block
                  | typedef-decl ';'
                  | struct-decl ';'
                  | enum-decl ';'
                  | var-decl ';'
                  | tuple-assign ';'
                  | expr ';'
                  | block

if-stmt         ::= 'if' '(' expr ')' block ('else' (if-stmt | block))?

while-stmt      ::= 'while' '(' expr ')' block

return-stmt     ::= 'return' expr-list?

defer-stmt      ::= 'defer' block

throw-stmt      ::= 'throw' expr ';'

try-stmt        ::= 'try' block catch-clause+

catch-clause    ::= 'catch' '(' IDENT? IDENT ')' block

ref-op-stmt     ::= ('delete' | 'retain' | 'release') expr ';'

tuple-assign    ::= '(' tuple-target (',' tuple-target)+ ')' '=' expr

tuple-target    ::= type? IDENT
```

A `defer` body runs when the enclosing scope exits by any path, most recently
registered first. `catch` arms are tested in source order; a typed arm runs only
when the error is an instance of that class.

### Switch

```bnf
switch-stmt     ::= 'switch' '(' expr ')' '{' switch-arm* '}'

switch-arm      ::= ('case' case-label ':' | 'default' ':')+ statement*

case-label      ::= const-expr
                  | const-expr '..' const-expr
                  | '..' const-expr
                  | const-expr '..'
```

Labels with no statements between them share a body. Control falls through into
the next arm unless the body ends with `break`. Range labels require a one-byte
subject.

### For

```bnf
for-stmt        ::= for-c-style | for-in

for-c-style     ::= 'for' '(' for-init? ';' expr? ';' expr? ')'
                    loop-annotation? block

for-init        ::= var-decl | expr

for-in          ::= 'for' '(' type? IDENT 'in' iterable ')'
                    loop-annotation? block

iterable        ::= expr
                  | range
                  | slice

range           ::= expr ('..' | '...') expr ('step' signed-int-lit)?

slice           ::= postfix '[' range-bounds ']'

range-bounds    ::= expr ('..' | '...') expr
                  | '..' expr
                  | expr '..'

loop-annotation ::= ':' 'unroll'
```

`..` is exclusive and `...` is inclusive. A `step` must be an integer literal or
its negation, not an expression. Slices are valid only as the iterable of a
for-in loop; there are no first-class slice values.

## Expressions

Listed highest precedence first. All levels are left-associative except
assignment and the conditional, which are right-associative.

```bnf
expr            ::= assignment

assignment      ::= conditional
                  | unary assign-op assignment

assign-op       ::= '=' | '+=' | '-=' | '*=' | '/=' | '%='
                  | '&=' | '|=' | '^=' | '<<=' | '>>='
                  | '<:=' | ':>='

conditional     ::= logical-or ('?' expr ':' conditional)?

logical-or      ::= logical-and ('||' logical-and)*
logical-and     ::= bitwise-or  ('&&' bitwise-or)*
bitwise-or      ::= bitwise-xor ('|' bitwise-xor)*
bitwise-xor     ::= bitwise-and ('^' bitwise-and)*
bitwise-and     ::= equality    ('&' equality)*
equality        ::= relational  (('==' | '!=') relational)*
relational      ::= shift       (('<' | '>' | '<=' | '>=') shift)*
shift           ::= rotate      (('<<' | '>>') rotate)*
rotate          ::= additive    (('<:' | ':>') additive)*
additive        ::= multiplicative (('+' | '-') multiplicative)*
multiplicative  ::= unary (('*' | '/' | '%') unary)*

unary           ::= ('~' | '!' | '-' | '*' | '@' | '&' | '++' | '--') unary
                  | postfix

postfix         ::= primary postfix-op*

postfix-op      ::= '++' | '--'
                  | '[' expr ']'
                  | '.' IDENT
                  | '->' IDENT
                  | '(' arg-list ')'

primary         ::= INT_LIT | FLOAT_LIT | CHAR_LIT | STRING_LIT+
                  | 'true' | 'false'
                  | IDENT
                  | 'new' type-name array-suffix? ('(' arg-list ')')?
                  | 'sizeof' '(' (type | expr) ')'
                  | '(' type ')' unary
                  | '(' type '?' ')' unary
                  | '(' expr ')'
                  | 'inline' ':' postfix

arg-list        ::= (expr (',' expr)*)?
expr-list       ::= expr (',' expr)*
```

`&` takes an address, and `&obj.method` also binds a method to its receiver to
fill a `callback`. `->` is shorthand for `(*p).field`.

`(T)x` is a cast. `(T*?)x` is a checked downcast that yields null when `x` is
not an instance of `T`.

`new T` allocates, `new T[n]` allocates an array, and `new T(args)` calls an
initialiser. `delete` frees.

## Inline assembly

```bnf
asm-block       ::= 'asm' '{' asm-line* '}' asm-clobbers?

asm-clobbers    ::= ':' 'clobbers' '(' reg-list ')'

reg-list        ::= IDENT (',' IDENT)*

asm-line        ::= <tokens to the end of the physical line>
```

Identifiers inside the block resolve against the program's symbols. On 6502
targets the prefixes `<`, `>`, `>>` and `>>>` select byte 0 to byte 3 of the
resolved value. On other targets the body is passed through unchanged.

## What the grammar does not say

The parser accepts more than the language allows. These rules are applied after
parsing:

- Type checking, integer widening and overload resolution.
- `auto` requires an initialiser.
- A protocol body holds signatures only.
- `throws` on a callee requires the caller to handle the error or be `throws`
  itself.
- Whether a conversion, a cast or a dereference is legal.
- Reference counting, and which targets support a given feature.
