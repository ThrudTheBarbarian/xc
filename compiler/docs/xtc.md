# Xtc - a modern language for a classic CPU

Xtc is a programming language for the 6502, aimed primarily at the Atari 8-bit computers. It expects paged RAM to provide expanded memory for code or data, and its optimiser targets the 6502 processor.

## Chapter 1. The pre-processor

The preprocessor has a few directives. They support the use of the xtc language without being part of it.

### Including other files into your code
`#include <file.xc>` or `#include "file.xc"`
replaces the line with the contents of the named file. The two forms select different search orders, as in C and C++:

- `"file.xc"`: search the directory of the including file first, then the system directories and any `-I` paths. Use this form for files that live alongside your source.
- `<file.xc>`: skip the including file's directory and search only the system and `-I` paths. Use this form for library headers, so that a file with the same name in your project cannot shadow the library.

Filename matching is case-sensitive, even on the case-insensitive HFS+ and APFS file systems on macOS. `#import <Sort.xc>` does not match a sibling file named `sort.xc`, so a program named after a library it imports does not collide with that library.

For example:

> ```
> #include "data.txt"
> ```


`#import <file.xc>` or `#import "file.xc"`
works like `#include` but imports the named file only once. Library code can import what it needs, and user code can import the same files, without two copies ending up in the build. The `< >` and `" "` forms search in the same order as for `#include`. For example:

> ```
> #import <Stdio.xc>
> ```

`#use <ClassName>` (or `#use ClassName`, or `#use "ClassName"`)
is shorthand for `#import "ClassName.xc"` followed by `use ClassName;` (the language-level directive, see Chapter 4). It imports the class's source once and promotes its static methods into the bare-call lookup space, so `printf("hi")` works after a single `#use Stdio` line. The class name is written bare; an optional `.xc` extension is stripped. For example:

> ```
> #use Stdio
> #use Math
> 
> void main(void) {
>     printf("answer = %u\n", 42);    // resolves to Stdio.printf
>     u8 r = rand((u8)100);            // resolves to Math.rand
> }
> ```

### Conditional compilation

`#define macro[(args)] text-string` 
defines a macro, optionally with arguments, for use later in the source. When the macro is used, the supplied comma-separated arguments replace the placeholders in the `#define` text. `#undef` removes a macro. For example:

> ```
> #define DBL(x) (double(x))
> ```

`#ifdef / #if / #ifndef / #elif / #else / #endif`
control which parts of the source are compiled or included, and which definitions apply. For example, Math.xc contains:

> ```
> #ifndef ENABLE_DOUBLE
>  #define ENABLE_DOUBLE 1
> #endif
> ```

This enables 'double' support in the maths operations by default. Specifying `-DENABLE_DOUBLE=0` on the command line turns it off. Later in the file, `ENABLE_DOUBLE` decides which code is emitted.

### Errors and warnings

`#warning text` 
inserts a warning into your code, unconditionally unless gated by `#if`. Use it as a reminder to come back and fix something, for example

> ```
> #warning need to implement doFrobble()
> ```

`#error text` 
works like `#warning` but produces an error, which stops compilation.

### Variable args

The preprocessor accepts macros of the form `#define myMacro(x, ...)`. Where the definition contains `__VA_ARGS__`, the variable part of the arguments is substituted when the macro is expanded.


## Chapter 2. The compiler front-end

The `-h` or `--help` option lists the compiler's command-line options:

> ```
> prompt% xtc -h
> Usage: xtc [options] <input.xc ...>
>
> Options:
>   -a, --assemble-only        Compile to .asm module (no runtime)
>   -D <name[=value]>          Define preprocessor symbol
>   -E, --preprocessed <path>  Write preprocessed output to file
>   -falloc=bump|heap          Heap allocator: bump (fast, no free)
>                              or heap (coalescing free-list, supports
>                              delete). Default: heap on targets with a
>                              dedicated heap region, bump elsewhere.
>   -farc[=on|off]             Automatic reference counting: controls
>                              whether `retain` and `release` statements
>                              are accepted (delete is unaffected).
>                              Accepts on|yes|1 or off|no|0. Default: on.
>   -Fli, --fn-leaf-inline <n> Max leaf-function size to inline
>                              (default: 100, requires -O2+)
>   -Flu, --fn-loop-unroll <n> Auto-unroll counted for-loops with trip
>                              count <= n (default: 5 at -O2+, 0 otherwise)
>   -H, --xtc-home <path>      Set xtc home directory
>   -h, --help                 Show this help
>   -I <path>                  Add include search path
>   -O0                        No optimisation (the default)
>   -O, -O1                    Peephole + register tracking
>   -O2                        + const prop, dead code/store elim, tail call
>                                opt, leaf inlining, loop unrolling (<=5)
>   -O3                        + branch inversion, branch threading,
>                                strength reduction, cross-function DCE,
>                                label cleanup
>   -o, --output <path>        Output file (.asm or binary)
>   -Q, --quit-style <which>   Action after main() returns: rts (default), loop
>   -q, --quiet                Suppress informational output
>   -S, --xtc-stack            Use xtc software stack globally
>   -ss, --stack-size <n>      Cap the xtc stack at <n> bytes (decimal,
>                              $hex, or 0xhex; 1..65535). Flat-heap
>                              targets (xl-shadow / xe-nobank) hand the
>                              reclaimed bytes to the heap. No effect
>                              on banked-heap or non-heap targets.
>
> Platform options:
>   --dump-layout              Print memory-map diagram and exit (use with -m)
>   --list-layouts, -ll        List available built-in layouts by platform
>   -m <layout>                Load a memory layout (.lnk file). Searches
>                              for <layout> as a file path (appends .lnk
>                              if needed), then support/layouts/<layout>.lnk
>                              Default: xl
>
> Warning options (-Wno-<category> to suppress):
>     asm-clobbers             asm{} clobbers annotation mismatch
>     class-init               bad initialiser on stack class
>     escape                   stack-addr stored in longer-lived slot
>                              (global, heap field, outer scope)
>     unknown-annotation       unrecognised function annotation
>     unknown-pragma           unrecognised # directive
>
> Function annotations (after params, comma-separated):
>   Calling convention / prologue:
>     : hwStack                Force 6502 hardware stack
>     : naked                  No prologue/epilogue (for ISRs)
>     : xtcStack               Force xtc software stack
>   Interrupt handlers (mutually exclusive with :naked):
>     : irq                    IRQ handler; OS-safe prologue, RTI epilogue
>     : vbi                    VBI handler; same shape as :irq, runs each
>                              vertical-blank (install via Vbi.install)
>   Placement (where in the memory map the function lives):
>     : banked                 Force into a bank page (banked targets only;
>                              incompatible with :irq / :vbi)
>     : main                   Force into the main (always-visible) region
>     : shadow                 Force into shadow RAM under the OS ROM
>                              (xl-shadow / xt / xe-shadow only)
>   Shadow-target helpers:
>     : needsOS                Wrap body with ROM enable/disable on shadow
>                              targets (no-op on non-shadow)
>                              (all annotations are case-insensitive)
>
> Output format (determined by -o extension or [output] in .lnk):
>     .asm                     6502 assembly source
>     .prg                     C64 PRG binary
>     .xex .exe .bin .com      Atari XEX binary
>
> Support file search order:
>     -H > $XTC_HOME > cwd > ~/xtc > /usr/local/xtc > /opt/xtc
> ```

A typical invocation of xtc looks like:

> ```
> % xtc -Q loop -O3 ahl.xc -o test.xex 
> xtc: optimised -O3 (9877 → 9698 instructions)
> xtc: compiled 'ahl.xc' -> 'test.xex' (0 warnings, 0 errors)
> xta: assembled -> 'test.xex' (19975 bytes, 1 segments)
> ```





## Chapter 3. Memory models

The compiler uses banked memory where it is available, and supports a range of memory layouts:

> ```
> % xtc -ll
> Available layouts (use with -m <platform>/<layout>):
> 
>   atari:
>     -m atari/compy320
>     -m atari/compy576
>     -m atari/rambo1088
>     -m atari/rambo192
>     -m atari/rambo256
>     -m atari/rambo320
>     -m atari/rambo576
>     -m atari/xe-shadow
>     -m atari/xe
>     -m atari/xl-shadow
>     -m atari/xl
>     -m atari/xt
>     -m atari/xt
> 
>   commodore:
>     -m commodore/c64
>```

The layouts fall into groups:

- 'atari/xl' (or 'xl') is the most basic configuration and does not shadow ROM over RAM. It represents a standard 800XL with 64KB of RAM and does not use the RAM under the OS ROM.

- 'atari/xe' (or 'xe') represents a standard 130XE with 128KB of RAM. It gives transparent access to the banked RAM: functions are stored in the banks, and any function can call any other function without handling the banking. This adds 64KB of RAM for code and data.

- The 'compyXXX' and 'ramboXXX' layouts are variants of 'xe' with more memory banks. Their linker scripts define which bits of PORTB swap pages, in the same way as the 'xe' script.

- The -shadow variants of 'xl' and 'xe' disable the ROM to use the RAM underneath. They move the character set out of the middle of the memory block, and install a VBI interrupt handler that enables the ROM whenever there is an NMI and disables it again when the NMI is over. This gives a much larger code space in always-available RAM; see the function annotation `:needsOS` below.

- 'atari/xt' (or 'xt') uses a different banking scheme from xe. Instead of PORTB driving a single 16 KB window, xt uses two independent 8 KB windows: `$82` selects the bank mapped into `$4000-$5FFF` (code half) and `$83` selects the bank mapped into `$6000-$7FFF` (data half). Code and data can live in different banks at the same time, so switching the data bank for a heap access does not swap out the caller's code page. This is why xt exists alongside xe. The `xt` layout combines shadow-ROM disable with a banked heap: shadow main (~22 KB) plus a banked free-list heap (~16 KB). The xt memory model needs external hardware.

Shadowing and banking are independent, with different trade-offs:

**Shadow RAM (~14KB at $C000-$CFFF + $D800-$FFF9)**
- Pros: directly addressable, with no window or paging, so each access has no overhead. Suits hot code, runtime routines, NMI vectors, and the unified main-code region ($A000-$CFFF, $D800-$FFF9).
- Cons: fixed size (~14KB total, split by the I/O hole). Disabling the OS ROM breaks CIO, the floating-point ROM and the default character set (which needs the charset copy and the fake-frame VBI trampoline). There is only one "bank", so content cannot be switched in and out.

**Banked RAM (16KB window at $4000-$7FFF, up to 1088KB total)**
- Pros: large capacity; rambo1088 gives 64+ pages. XTBankPageTracker packs classes and free functions across pages first-fit, so a large program scales well.
- Cons: every cross-bank call goes through the _xcall trampoline (save PORTB, switch, JSR, restore), which adds measurable per-call overhead. Only one 16KB page is visible at a time, so data and code on different pages cannot be reached without switching. The stack, heap and ZP pointers must stay in non-banked memory.

Rule of thumb: put hot or always-resident code (runtime, math, main, interrupt handlers) in shadow RAM, and move cold or bulky class methods into banked pages.

The `--dump-layout` option prints the compiler's view of any memory model. For example, the xe model with shadowing:

>```
> prompt% xtc --dump-layout -m xe-shadow
> # xe-shadow.lnk — xe-shadow
> #
> # ┌──────────────────────────────────────────────────┐
> # │ $0082-$0083  xtc ZP: SP                          │
> # ├──────────────────────────────────────────────────┤
> # │ $0084-$0085  xtc ZP: tmp                         │
> # ├──────────────────────────────────────────────────┤
> # │ $0086-$0087  xtc ZP: HP                          │
> # ├──────────────────────────────────────────────────┤
> # │ $0088-$00AF  xtc ZP: vars                        │
> # ├──────────────────────────────────────────────────┤
> # │ $00B0-$00BF  runtime params (reserved)           │
> # ├──────────────────────────────────────────────────┤
> # │ $00C0-$00FF  xtc ZP: vars                        │
> # ├──────────────────────────────────────────────────┤
> # │ $2400-$3FFF  System region                       │
> # │   Stack ↑ (after-system)                         │
> # │   $3FFF  Heap ↓ (grows down)                     │
> # ├──────────────────────────────────────────────────┤
> # │ $4000-$7FFF  Bank window (via $D301:$0C)         │
> # ├──────────────────────────────────────────────────┤
> # │ $8000-$9FFF  Screen RAM                          │
> # ├──────────────────────────────────────────────────┤
> # │ $A000-$CFFF  Main region                         │
> # ├──────────────────────────────────────────────────┤
> # │ $D800-$FFF9  Main region                         │
> # └──────────────────────────────────────────────────┘
> #
> # Banking: PORTB.
> # Shadow mode: $D301:$01.
> # Entry: $2400
>```

If no layout suits your purposes, copy one of the standard layouts and modify it.

## Chapter 4: Language specification

### Types

The language has the following types:


| Type     | Meaning                                             |
|----------|-----------------------------------------------------|
| u8, i8   | 8-bit unsigned and signed integer, respectively     |
| u16, i16 | 16-bit unsigned and signed integer, respectively    |
| u32, i32 | 32-bit unsigned and signed integer, respectively    |
| float    | 5-byte floating point number with a 24-bit mantissa |
| double   | 8-byte floating point number with a 48-bit mantissa |
| bool     | an alias for u8, can be set to 'true' or 'false'    |
| string   | an alias for pointer-to-u8, generally used for text |
| pointer  | arbitrary pointer-to-type                           |
| struct   | user-defined grouping of any of the above as a type |
| class    | a struct with state and methods to call on itself   |
| protocol | named interface: a list of method signatures that conforming classes must implement, usable as a parameter type (`Drawable@`) |

Literals:

- A sequence of characters enclosed in “” is a string literal. It is null-terminated, but the null (\0) byte does not count towards the size of the array.
- Strings accept these escape sequences:
    - \n means a newline character (carriage-return + line-feed)
    - \t means a tab character
    - \r means a carriage-return character
    - \0 means an end-of-string marker
    - \\\\\\ is a literal slash (\) character
    - \\" means a literal " character inside the quoted string
    - \\' means a single ' character inside the quoted string
- A single character within ‘’ (or two, if the first is \ ) gives the value of a single u8 byte.
- A numeric literal with the prefix ‘$’ is hexadecimal.
- A numeric literal with the prefix ‘%’ is binary.
- Underscores (_) in a numeric literal are ignored.

Assigning an integer to a narrower integer truncates it to fit. It is not sign-extended.

Assigning a float or double to an integer transfers only the integral part, truncated toward zero (`(i32)3.7` is `3`, `(i32)-3.7` is `-3`). Magnitudes that overflow the i32 range saturate to `0`; narrower integer targets (`u8`, `i8`, `u16`, `i16`) take the low bytes of the i32 result.

Casts use the C `(type)` construct. Two extensions apply to class pointers. A cast of the form `(Dog@) animal`, where `Dog` descends from the static type of `animal`, is a *runtime-checked downcast*: the compiler inserts a class-id check that traps on mismatch. Adding `?` inside the parentheses, `(Dog@ ?) animal`, gives a failable form that yields `(Dog@)0` on mismatch instead of trapping. Upcasts, same-class casts and casts of non-class pointers are unaffected. See the Inheritance section below.

The ‘auto’ keyword infers a type in place of an explicit one. It works for function returns as well as declarations.
***
### Syntax
The following syntax rules apply:

- Basic syntax is similar to the ‘C’ family of languages.
- Comments start with /* and end with */. A // comment runs to the end of the line.
- Reserved words cannot be used as variable names, class names or structure types.
- Identifiers are case-sensitive, start with a letter, and contain only letters, numbers and _
- Statements end with a semicolon ‘;’
- Blocks of code are delimited by {..}

#### <u>Variable declaration</u>

Variables can be simple instances of the types above, structs or classes (see below), arrays, or pointers.

A simple variable is declared as:
	
>```
> <type> <name> [ = <value> ];
> <type> <name1, name2> [ = <value1>, <value2>];
>```
For example: `u8 myVal,myOtherVal = 5,12;`

To initialise the bytes that make up a value, instead of giving the natural value of the type, use:

>```
> <type> <name> = {byte, byte, ...};
> ```

As with array initialisation, bytes that are not provided are set to 0, and [..] can be used instead of {..}.


To declare a structure, first define it:

> ```
> typedef struct 
>     {
>		u8 red;
>		u8 green;
>		u8 blue; 
>		} RGB; 
>```

then use it like any other variable. Initialisation takes a list in either {..} or [..], for example:

>```
> RGB white = {255, 255, 255};
> RGB black = [0,0,0];
>```

An array is declared by appending [size] to the variable’s name, for example

>```
> u8 bytes[32]; 
>```

with an optional `= [value,value,…]` or `= {value, value,…}`


Pointers work as in ‘C’ but use the @ symbol instead of *:

>```
> u8@ myPtr = &myVal;
>```
>
declares a pointer called ‘myPtr’ that holds the address of ‘myVal’ (the & operator returns an address). Pointers are covered in more detail below.

Declaring a variable volatile stops the compiler optimising away repeated stores to it. In

>```
> volatile u16@ dosvec = @10; 
> @dosvec = $1234;
> @dosvec = $4567;  
>```

both assignments happen, even at -O2 or above.

A ‘register’ variable gets priority in zero-page allocation. The compiler collects these from the whole source before general allocation begins. For example:

>```
> register u16 @myImportantPointer = $1234;
>```

A `static` variable persists after the scope it is defined in ends, and keeps its previous value when the function runs again. The scope can be the file or a function within the file. The variable is visible only within its scope.

A variable declared both `static` and `global` keeps its static behaviour and is visible in every scope.

Variable scope and storage:

| Modifier      | Storage       | Persistence | Visibility           | ZP cost      |
|---------------|---------------|-------------|----------------------|------|
| (default)     | ZP            | local scope | current block        | yes  |
| register      | ZP (priority) | local scope | current block        | yes (forced) |
| volatile      | ZP            | local scope | current block        | yes  |
| static        | data section  | permanent   | current file / block | no   |
| global static | data section  | permanent   | all files            | no   |

`typedef` defines a new name for a type, which can shorten long type definitions. The syntax is

>```
> typedef <type> alias;
>```

#### <u>Operators</u>

The operators and their precedence are close to C and C++, with the addition of <: and :>, which *rotate* left and right (as << and >> *shift* left and right). From highest to lowest precedence:

| Operators                                                                                                          | Assoc | Notes      |
|--------------------------------------------------------------------------------------------------------------------|-------|------------|
| a[i], f(…), . , -> , ++ -- (postfix)                                                             | L→R   | primary    |
| +, -, !, ~, ++, -- (prefix), @ (deref), &(addr of), (type) cast, sizeof(), <, >, >>, >>> (byte extract inline asm) | R→L   | unary      |
| *, /, %                                                                                                            | L→R   |            |
| + -                                                                                                                | L→R   |            |
| <:, :> (rotate)                                                                                                    | L→R   | rol, ror   |
| <<,  >> (shift)                                                                                                    | L→R   | asl, asr   |
| <, >, <=, =>                                                                                                       | L→R   |            |
|  ==, !=                                                                                                            | L→R   |            |
| & (bitwise and)                                                                                                    | L→R   |            |
| ^ (bitwise xor)                                                                                                    | L→R   |            |
| \| (bitwise or)                                                                                                     | L→R   |            |
| &&                                                                                                                 | L→R   |            |
| \|\|                                                                                                                 | L→R   |            |
| ? :                                                                                                                | R→L   | ternary    |
|  =, +=, -=, *=, /=, %=, &=, \|=, ^=, <<=, >>=, <:=, :>=                                                             | R→L   | assignment |


#### <u>Flow control</u>

Xtc supports the following flow control. All block delimiters can be the ‘C’ {..} or (( .. )).


- C-style if/then/else. The condition is built from the operators above, in round brackets:
`if (condition) then {block} [else {block}]`

- An extended C-style switch statement. For example:
```
switch (c)
    {
    case ..12:
        // Triggers for any value <= 12
        break;
        
    case 13..18:
        // triggers for any value 13,14,15,16,17,18
        break;
    
    case 22:
        // fall through
    case 23:
        myFunction(c);
        break;
    
    case 40..:
        // triggers for any value >= 40
        break;
        
    default:
        Stdio.printf("nope\n");
        break;
    }
```

Ranges (..x, x..y, y..) work only on u8 arguments; the other cases work on any integer. At -O2 or above, a switch statement may be compiled to a jump table.

- The ‘C’ “for” loop:
`for (setup ; loop-condition ; loop-execution) {block}`
The loop variable can be declared in the setup clause, so
	  	`for (u8 i=0; i<40; i++) {..}`     is legal.

- The array "for" loop:
`for ([type] var in array)` {block}
sets var to each value in the array in turn, for example:
`u8 chars[] = {‘h’, ‘e’, ‘l’, ‘l’, ‘o’};`
`for (u8 ch in chars) {..}`

The collection can be a fixed-size array, whose length is a compile-time constant, or a heap-allocated pointer from `new T[N]`. For a pointer, the length is read from the allocator's block header at loop entry, so recursion or reallocation inside the body does not change the iteration count.

- The range "for" loop:
`for ([type] var in start..end)` {block}                   // exclusive: end NOT visited
`for ([type] var in start...end)` {block}                  // inclusive: end IS visited
`for ([type] var in start..end step <signed-int>)` {block} // optional stride / direction

`for (u8 i in 0..10) {..}`            iterates 0, 1, …, 9 (10 iters)
`for (u8 i in 0...10) {..}`           iterates 0, 1, …, 10 (11 iters)
`for (u8 i in 0..10 step 2) {..}`     iterates 0, 2, 4, 6, 8 (5 iters)
`for (u8 i in 10..0) {..}`            iterates 10, 9, …, 1 (auto-flip, step -1)
`for (u8 i in 10..0 step -3) {..}`    iterates 10, 7, 4 (descending stride; you must keep the loop variable from underflowing)

Direction: an explicit `step <neg>` makes the loop descend. Without an explicit step, the loop descends when both bounds are integer literals and `start > end`, so `for (u8 i in 10..0)` needs no `step -1` clause. Non-literal bounds default to ascending; for a descending loop with runtime bounds, use an explicit `step -N`.

The loop variable type defaults to `u8` when both bounds (and the step magnitude) are integer literals that fit in a `u8`. Otherwise an explicit type is required, because the parser does not fold expressions: a non-literal bound or a literal above 255 needs a declared type. The range form is rewritten to an equivalent C-style for at parse time, so the usual optimisations (unrolling and others) apply.

Underflow: a descending unsigned loop whose step does not divide evenly into the start can wrap past 0 and run longer than expected. For example, `for (u8 i in 20..0 step -3)` visits 20, 17, 14, 11, 8, 5, 2; then 2 - 3 wraps to 255 and the loop continues from there. Align the bounds with the step (`21..0 step -3`) or widen the loop variable to u16/i16.

- `while (condition) {block}`
The ‘C’ while loop runs until the condition is false.

`break` exits any kind of loop, jumping to its end.

`continue` skips the rest of the current iteration of any kind of loop.

A loop variable declared in the `for(…)` statement goes out of scope when the loop ends.

A `for(…)` loop is unrolled if its trip count is within the unroll limit (at -O2 or above), or if it is annotated with :unroll, for example:

>```
> for (u8 i=0; i<40; i++) :unroll
>      {…}
>```

#### <u>Array length</u>

Fixed-size arrays and heap-allocated pointers have a `.length` pseudo-property that evaluates to a `u16` element count:

```xtc
u16 local[8];
u16 n1 = local.length;        // compile-time constant: 8

u16@ heap = new u16[64];
u16 n2 = heap.length;         // runtime: reads the heap block header, returns 64
```

`.length` on a pointer that did not come from `new T[N]` is undefined: the generated code reads whatever bytes precede the address. Bump-allocator targets (default `xl`, `xt`, `xe`) store no header before heap allocations, so `.length` is meaningful only on heap-allocator targets (`xl-shadow`, `xe-nobank`, `xt`, `xe-heap`, and the multi-bank rambo/compy family).

#### <u>`use` directive — bare-call promotion</u>

`use ClassName;` is a top-level directive that promotes a class's static methods into the bare-identifier call lookup space for the rest of the file. After `use Stdio;`, `printf("hi\n")` calls `Stdio.printf("hi\n")`. Resolution is the same as for a `Klass.method(...)` call: overload scoring, varargs, the static-init guard for the class, and the implicit self-pointer for `__sdata_<class>` all apply. The receiver comes from the `use` directive instead of the call site.

Multiple `use` directives combine: with `use Stdio;` and `use Math;`, both `printf(...)` and `rand(...)` can be called bare. If two such classes expose a static method with the same name and an overload would match the call, sema reports the call as ambiguous. Write the explicit `Klass.method(...)` form to resolve it.

`use` affects only bare identifiers. Fields, local variables, free functions and explicit `Klass.method(...)` calls keep their normal lookup. A `use` directive applies to its textual file and does not propagate across `#import`, so a class's source can `use` any class without affecting the files that import it.

The `#use Klass` preprocessor directive (see Chapter 1) combines the import and the promotion in one line:

```xtc
#use Stdio        // == #import "Stdio.xc" + use Stdio;

void main(void) {
    printf("hello\n");
    return;
}
```

#### <u>Program entry</u>
The application starts at the ‘main’ function. When main finishes, the program returns to its caller with RTS, or enters an infinite loop if the compiler was given `-Q loop`. The signature for main is either

`void main(void) {…}`				… or
`i16 main(u8 numArgs, string args[]) {…}`



#### <u>Enumerations</u>

The keyword `enum` introduces an enumeration, a named alias for a numeric value. The compiler chooses an appropriately sized type to represent it.

Enumerations start at 0 unless otherwise specified, and each element after the first is one greater than the one before.

Examples:

> ```
> enum suits = {hearts, clubs, diamonds, spades};
> enum directions = {N = 4, S, E, W};
> ```

#### <u>Arrays</u>

Arrays are created with the [..] suffix on a typed name, for example:

	u8 cakes[3];

Arrays can be initialised at declaration with `= [list]` or `= {list}`. An initialised array can leave the square brackets empty, and its size is inferred from the number of elements, so this is legal:

> ```
> u8 spaces[] = {‘ ‘, ‘\t’, ‘\n’};
> ```

#### <u>Structures</u>

Structs group related data. They are always tightly packed, because the 6502 is a byte-oriented CPU. Neither a struct nor any of its elements can be named with a reserved word.

Struct members are accessed with dot notation, and can be primitive types or other structures.

A struct definition looks like:

>```
> typedef struct 
>    {
>    u16 x;
>    u8 y;
>    } CursorPos;
>```

Structs are value types with copy semantics. They can be allocated on the stack like any other variable in any scope, or as globals. Functions can return structs by *value*, so this is legal:

>```
>	CursorPos myFunc(void) 
>    {
>    CursorPos c = {290, 40};
>    return c;
>    }
>```

A struct's address can be passed to other functions and methods, but a pointer to a struct cannot be returned outside the scope in which the struct is defined. This is *<u>not</u>* legal:

>```
> CursorPos@ myFunc(void) 
>    ((
>    CursorPos c = ((290, 40));
>    return &c;
>    ));
>```

A pointer to a structure can be passed as an argument to another function, so this *is* legal:

>```
> CursorPos myFunc(void) 
>    ((
>    CursorPos c = ((290, 40));
>    moveCursor(&c);
>    return c;
>    ));
>```

An initialiser assigns values to struct members in the order the members are declared. Members without a value are set to 0, and giving more values than the structure has members is an error. Both of these are legal:

>```
> CursorPos topRight = {319};       // sets topRight to {319, 0}
> CursorPos middle = {159, 100};    // sets middle to {159, 100}
>```

Stdio.printf() prints a structure recursively with the %@ escape sequence.


#### <u>Pointers and address calculations</u>

An ‘&’ before an identifier takes the address of that identifier. The result can be assigned to a pointer to the identifier's type.

The identifier can be a variable, a structure, a class, a function or another pointer, for example:

>```
> pointer myVec = &myISR;
> @300 = myVec;
>```

Where C and C++ use ‘*’, xtc uses ‘@’ to mean “a pointer to”:

>```
> u8 @x = $580;        // x is a pointer to an 8-bit value at $580
> u8 @y = &x;		     // y is a pointer to the 8-bit value x
>```

`->` is shorthand for member access through a pointer to a structure, because dot syntax binds tighter than @:
	
>```
> p->x === (@p).x;
>```

Unlike C, `.` also works on a pointer to a struct or class. The compiler dereferences the pointer automatically, so `p.x` and `p->x` are equivalent. `->` remains available to make the indirection explicit, which can help in raw pointer-to-struct code where the intent is less obvious. Method calls on class instances conventionally use `.`, because a class instance is almost always reached through a pointer, for example `sprite.draw()` where `sprite` is `Sprite@`.

Pointer literals also use the @ prefix:

>```
> u8 @x = @580;       // x is a pointer to a u8, and is initialised
>                     // to the value in $580,$581
>```

Pointers can be dereferenced:

>```
> u8 @x = $400;       // x is a pointer to a u8 at $400
> @x = 4;             // location $400 now contains 4
>```


The type `string` is an alias for a u8@ pointer, for example:

>```
> string tom = “great name”;
>```

Whitespace around the @ does not matter, nor does placing it next to the type or the name.


#### <u>Type inference</u>

Explicit types are preferred, but the ‘auto’ keyword infers a type where possible.

If a function has the signature “u8 fn(void)”, the following infers that retVal is a u8:

>```
> auto retVal = fn();
>```

An integer literal is inferred as the size its value needs. A positive number is inferred as unsigned and a negative number as signed, so the following are valid:

>```
> auto x = 3;         // x is a u8
> auto x = -3;        // x is an i8
> auto x = 257;		// x is a u16
> auto x = -259;		// x is an i16
> auto x = 65589;	    // x is a u32
> auto x = -555555;	// x is an i32
> auto x = 4.5;		// x is a float
> auto x = "hi";		// x is a string (u8@)
> auto x = true;		// x is a bool (same for false)
>```

A variable initialised from an expression whose type is known at compile time takes that type:

>```
> u8 x = 4;
> u8 y = 5;
> auto cc = x+y;		// cc = u8
> 
> u8 x = 4;
> u16 y = 500;
> auto cc = x+y;		// cc = u16
>```

#### <u>Functions</u>

Functions are defined as in ‘C’ with a return type. In xtc the return type can also be a tuple. For example:

>```
> (u8 x, u16 y) = myFunc();
> 
>
> u8,u16 myFunc(void)
>     { 
>     return 42, 1969;
>     }
>```

The tuple variables can be declared at the call, as above. To assign to existing variables, write:

>```
> (x, y) = myFunc();
>```

xtc supports recursive functions. Their data goes on the xtc stack, so the 6502 stack does not overflow.

`return` exits a function at any point in its body. In a function that returns a type or tuple, `return` must give a value of that type or tuple. In a void function, `return` takes no arguments.

A function can take a variable number of arguments, declared as in ‘C’:
	
>```
> void myFunc(string fmt, …) 
>     {…}
>```

Varargs follow the C model closely. See support/*machine*/Stdio.xc for an example.

Inside the body, walk the arguments with `va_start`, `va_arg(ap, type)`, and `va_end`. The cursor `ap` is a `u8` that the compiler advances as each read consumes bytes from the shared pack buffer.

>```
> u8 ap;
> va_start(ap);
> u16 n = va_arg(ap, u16);
> string s = va_arg(ap, string);
> va_end(ap);
>```
>
Supported type arguments: `u8`, `i8`, `u16`, `i16`, `u32`, `i32`, `float`, `double`, `string` (u8@), and `T@` where `T` is any pointer-to-type.

Pointer-to-struct has its own form. When `T` is a user-defined struct, `va_arg(ap, T@)` returns a typed pointer to the struct's raw bytes in the pack buffer and advances the cursor by `sizeof(T)`. Read fields through the returned pointer with `->`:

>```
> typedef struct { u8 r; u8 g; u8 b; } RGB;
>
> void logColor(string tag, ...)
> {
>     u8 ap;
>     va_start(ap);
>     RGB@ sp = va_arg(ap, RGB@);   // pointer into the pack buffer
>     u8 red = sp->r;                // field access via ->
>     u8 green = sp->g;
>     u8 blue = sp->b;
>     va_end(ap);
> }
>
> void main(void)
> {
>     RGB c = { $11, $22, $33 };
>     logColor("probe", c);          // caller packs 3 raw bytes
> }
>```
>
The returned pointer is valid only for the duration of the variadic call, because the next variadic call reuses the pack buffer. Do not store it in a global or return it.

**Shared pack buffer and reentrance.** All varargs functions share one 64-byte pack buffer, at `$0480-$04BF` on Atari. The address varies by platform; see the `[buffers] printf` entry of the active layout and the compiler-defined `XT_PRINTF_BUF` / `XT_PRINTF_DATA_BUF` macros. A variadic function `F` that has called `va_start` therefore cannot call another variadic function `G`: `G` would overwrite the buffer while `F` is reading it, and `F`'s later `va_arg` reads would return corrupted bytes. Sema reports this at compile time. Pure forwarders are exempt: variadic functions that never call `va_start` and only pass their `...` tail on to another variadic function. `Stdio.printfAt` delegates to `Stdio.printf` this way. The variadic payload per call is at most 62 bytes (64 minus the 2-byte format-pointer header); `printfAt` uses 7 header bytes, so its payload limit is 57.

A caller can inline a function by prefixing the call with the inline: directive, which removes the JSR and stack management. For example:

>```
> u8 myVal = inline:calculate(4,5);
>```

Functions can be overloaded by parameter type. Several functions can share a name and differ in the types of their arguments; the semantic analyser picks the best match for each call.

>```
> void show(u32 val)	{ Stdio.printf("u32: %d",   val); }
> void show(u8 val)	{ Stdio.printf("u8 : %d",   val); }
> void show(string s)	{ Stdio.printf("string:%s", val); }
>```

Functions can also be overloaded by return type. The semantic analyser picks the function from a set such as:

>```
> float myValue(void) {...}
> int myValue(void) {...}
> string myValue(void) {...}
> ```

according to the type of the variable that receives the result of `myValue`.

Annotations on a function force specific behaviour, for example
	
>```
> void fn(void) :naked {..}	   // No register saves, just user code
> void fn(void) :HwStack {..}    // Use the hardware stack
> void fn(void) :xtcStack {..}   // Use the software stack
> void fn(void) :needsOS {..}    // function is marked as needing OS support
> void fn(void) :irq {..}        // hardware-IRQ handler, ends with RTI
> void fn(void) :vbi {..}        // VBI handler, see Vbi.xc below
> void fn(void) :banked {..}     // place in the bank window (xt/xe)
> void fn(void) :main {..}       // place in main RAM, opt out of auto-bank
> void fn(void) :shadow {..}     // place in shadow RAM (xl/xt/xe-shadow)
>```

:needsOS marks a function that cannot be located in shadow RAM; the ROM is swapped in before it is called. Keep such functions small and self-contained. Many calls from a :needsOS function to functions stored beneath the OS make xtc swap the ROM repeatedly, which is inefficient.

:irq marks a function as a hardware-interrupt handler. It is emitted naked (no frame save or parameter convention), and its epilogue is `RTI` instead of `RTS`, so the 6502 pops the flags and return PC that the IRQ pushed. Install its address in $FFFE/$FFFF (or the platform's vector) yourself.

:vbi marks a function as a Vertical-Blank-Interrupt handler. The prologue saves A/X/Y; after the body, the epilogue restores them and `JMP`s through `XITVBV` ($E462) so the OS finishes the interrupt. Install with `Vbi.addImmediate(&fn)` or `Vbi.addDeferred(&fn)`; remove with `Vbi.removeImmediate()` / `Vbi.removeDeferred()`. Both go through `SETVBV` ($E45C), so the OS performs the SEI-safe atomic write to `VVBLKI` / `VVBLKD`.

On banked targets (xt / xe), the code generator places :irq and :vbi handlers in main RAM at a fixed address. The OS dispatcher jumps through their vector slot directly, so the bank-switch trampoline has no chance to swap the right page in.

:banked, :main and :shadow control where in the address space a function lives, and are mutually exclusive. Without them, free functions are banked automatically on xt/xe and placed in main RAM otherwise, so most programs do not need these annotations. They give explicit control over the trade-off between fast main RAM, the cheaper paged bank window, and OS-shadow RAM.

- :banked forces the function into the bank window. On a target with no banking (xl, the default Atari layout) it warns and falls back to :main.
- :main forces the function into main RAM, even on xt/xe where it would otherwise be banked. Use it for hot routines where the cross-bank trampoline cost matters, and for code called by an :irq/:vbi handler (handlers cannot use the trampoline).
- :shadow places the function under the OS ROM (the $C000-$CFFF and $D800-$FFF9 region on Atari shadow targets). On a target without shadow RAM it warns and falls back to :main. Cross-bank-style calls work in either case. :shadow code is unreachable while the ROM is on, so do not call it from inside a :needsOS function.

A function can be declared before it is defined by writing its signature followed by ; with no body, as in C. This is less necessary than in C, because xtc allows calls to functions defined later. It is useful for declaring external functions in files that do not define them.

By default, functions pass parameters on the xtc software stack and use the 6502 hardware stack for return addresses and saved registers. The `-S/--xtc-stack` command-line option sends everything through the software stack, which is larger but slightly slower.

The `:hwStack` or `:xtcStack` annotation overrides the command-line option and the default for one function: JSR/RTS and registers use the named stack. Parameters always go on the software stack.
 
#### <u>Classes</u>

Classes can define instance variables, methods and static methods. For example:

>```
> class Gfx
>     {
>     u8 red;
>     u8 green;
>     u8 blue;
> 
>     void hLine(u16 x, u8 y, u8 len)
> 	    {
> 	    ..
> 	    }
>    }
>```

Classes are often defined in their own `classname.xc` file, but need not be.

A class instance can be created in two ways, which behave differently:

- **Stack instance:** `MyClass mine;` allocates the instance in the enclosing block's local storage: ZP if the ivars fit, the data section otherwise. The slot is zero-filled on scope entry, its parameterless `init()` (if present) is called automatically, and the ZP allocator reuses the storage when the block closes. The heap is not used. A stack instance is safe to declare inside a loop, because each iteration reuses the same slot.

- **Heap instance:** `MyClass@ mine = new MyClass();` allocates on the heap and returns a pointer. The block carries a reference count that starts at 1. By default the compiler manages retains and releases (ARC), and reclaims the allocation when the last owning reference goes out of scope. See *Heap allocation and reference counting* below for the full model, including `weak:` references for breaking cycles.

For parameterised construction, add the argument list to either form:

>```
> MyClass mine(1, 2);                // stack instance, init(1,2)
> MyClass@ p = new MyClass(1, 2);    // heap instance, init(1,2)
>```

When an instance is created, the class's ‘init’ method whose parameters match the given arguments (including an init() with no parameters) is called. Because methods can differ by parameter type alone, a class can have several constructors. There is no operator overloading.

A method marked `static` can also be called without an instance. When called statically, it cannot access instance variables. A static method definition looks like:

>```
> class myClass
>     {
>     static myMethod(void)
>         {..}
>     }
> ```

#### <u>Properties</u>

Dot-syntax member access on a class instance is a property access. If the class or an ancestor defines a method whose name matches the ivar, the compiler rewrites the access as a method call; otherwise the access loads or stores the ivar directly. The rule has two halves:

- **Read** `obj.name` rewrites to `obj.name()` when a zero-arg method `name` exists on the class.
- **Write** `obj.name = value` rewrites to `obj.setName(value)` when a one-arg method `setName` exists whose parameter accepts `value`'s type (camel-casing: `foo` ↔ `setFoo`, `lineWidth` ↔ `setLineWidth`).

Each half is resolved independently. A class can provide a getter, a setter, or both; a missing accessor falls back to direct ivar access. You can add accessors one field at a time, or add a getter later without changing any call sites.

>```
> class Box
>     {
>     u8 _w;                          // backing ivar (underscored by convention)
>
>     void init(void)     { _w = 0; }
>     u8   w(void)        { return _w; }
>     void setW(u8 v)     { if (v > 100) v = 100; _w = v; }  // clamp
>     }
>
> void main(void)
>     {
>     Box@ b = new Box();
>     b.w = 150;          // calls setW(150), _w becomes 100
>     u8 v = b.w;         // calls w(), returns 100
>     }
>```

The rewrite uses the same method-call path as a direct `b.setW(150)` call, so virtual dispatch (for accessors overridden in subclasses), banked-heap bank switching, and ARC parameter retain/release all apply. A setter's parameter type can differ from the backing ivar's type: the compiler checks the right-hand side against the setter's parameter type.

Accessors are opt-in per name and per direction. One pitfall:

- **Inside the accessor body, use the ivar directly.** Writing `self.w` inside the getter `w()` recurses infinitely; read the ivar (`_w` in the example) instead. Giving the ivar a different name from the accessor, commonly with a leading underscore, avoids the problem.

Compound assignment through a setter desugars: `b.w += 1` becomes `b.w = b.w + 1`, so the read uses the getter and the write uses the setter, in that order. The base expression (`b`) is evaluated twice in the desugared form. This costs nothing for identifiers and `self`, but matters if the base has a side effect such as a function call.

#### <u>Inheritance</u>

A class can name one parent class in a `:` clause after its name. The child inherits the parent's ivars and methods, can add new ones, and can override an inherited method by redeclaring it with the same signature. A class that names no parent inherits from the universal `Object` base, so `class Foo { ... }` and `class Foo : Object { ... }` are equivalent.

>```
> class Animal
>     {
>     u8 legs;
>     void init(void)        { legs = 4; }
>     void describe(void)    { Stdio.printf("animal\n"); }
>     }
>
> class Dog : Animal
>     {
>     u8 tailWag;
>     void describe(void)    { Stdio.printf("dog\n"); }    // override
>     void wag(void)         { tailWag = tailWag + 1; }    // new
>     }
>```

A `Dog@` is accepted anywhere an `Animal@` is expected; upcasts are implicit. Unrelated class pointers do not alias: assigning a `Cat@` to an `Animal@` is allowed, but assigning a `Cat@` to a `Dog@` is a compile-time error.

<u>Construction and destruction</u>

`init` and `dealloc` chain automatically. In a subclass `init`, the compiler inserts a call to the parent's matching `init` at the top of the body; if no parent `init` matches the argument list, the class is rejected at compile time. `dealloc` chains in reverse: the subclass body runs first, then the compiler calls the parent's `dealloc` at the end. Both chains run up to `Object`. Writing `super.init(...)` or `super.dealloc()` explicitly suppresses the automatic call, so you can pass different arguments or defer cleanup.

<u>Virtual dispatch</u>

Methods that are overridden anywhere in the hierarchy are dispatched through a per-class vtable. Every class has a unique class-id byte, `new` stores it in the first byte of the allocation, and a call site reads the id and indexes the class's vtable for the method slot. Methods that are never overridden are called with a direct JSR. A `super.method()` call always goes directly to the parent's body without using the vtable, however many subclasses exist.

<u>Downcasts</u>

Assigning a derived-class pointer to an ancestor-class pointer (upcast) is always accepted. The reverse, retrieving a `Dog@` stored in an `Animal@` slot, needs a runtime check, because the actual type is not known statically. xtc uses the cast syntax for this: when the source and target are related classes and the cast goes down the hierarchy, the compiler inserts a runtime class-id check.

- `(Dog@) animal`: runtime-checked downcast. If the instance is not a `Dog` or a `Dog` subclass, the program traps (a `BRK` instruction stops execution).
- `(Dog@ ?) animal`: **failable** downcast. The `?` inside the cast parentheses selects null on mismatch: the result is the retyped pointer on success or `(Dog@)0` on failure. It is commonly followed by an `if (d != 0)` check.

>```
> Animal@ a = new Dog();
> Dog@ d = (Dog@ ?)a;        // d != 0: dispatch through Dog's vtable
> Cat@ c = (Cat@ ?)a;        // c == 0: a isn't a Cat
> Dog@ d2 = (Dog@)a;         // succeeds; no check fires on match
>```

The check reads the class-id byte that `new` stored at payload offset 0 and walks up the `__class_parent` table until it finds the target's id or reaches the universal `Object` root. A null operand passes through unchanged in both forms. Upcasts and same-class casts emit no check. A cast between unrelated class trees (neither is an ancestor of the other) is rejected at compile time, because the runtime check could never succeed. The `?` marker is valid only on class-pointer casts; `(u16 ?)x` or any other scalar cast with `?` is a compile-time error.

<u>Interaction with protocols</u>

A class's conformance clause (`<P1, P2>`) sits next to the parent clause. Either, both or neither may appear. Subclasses inherit their parent's conformances; see the Protocols section below.

#### <u>Protocols</u>

A protocol is a named interface: a list of method signatures with no bodies, no ivars and no implementation. A class declares that it *conforms to* one or more protocols. The compiler checks that the class implements every method each protocol names, and accepts instances of the class wherever the protocol type is expected.

Inheritance shares implementation down a single line of descent. Protocols share a *calling convention* across unrelated class trees. A `Sprite` and a `Terrain` may have no structure in common, but both can conform to `Drawable`, and a single `render()` routine can then handle either.

<u>Declaring a protocol</u>

>```
> protocol Drawable
>     {
>     void draw(void);
>     u8   width(void);
>     }
>```

A protocol body accepts only method signatures. Method bodies, instance variables, static methods and nested declarations are rejected at parse time.

<u>Conforming to a protocol</u>

A class lists the protocols it adopts in a `<...>` clause after the class name, and after the `: Parent` clause if there is one:

>```
> class Sprite <Drawable>
>     {
>     u8 w;
>     void init(void)   { w = 16; }
>     void draw(void)   { Stdio.printf("sprite\n"); }
>     u8   width(void)  { return w; }
>     }
>
> class Terrain <Drawable>
>     {
>     u8 h;
>     void draw(void)   { Stdio.printf("terrain\n"); }
>     u8   width(void)  { return h; }
>     }
>
> class Badge : Sprite <Labelled>     // parent class + protocol list
>     {
>     void label(void)  { Stdio.printf("badge\n"); }
>     }
>```

The `: Parent` clause names a single parent class; the `<P1, P2, ...>` clause is a comma-separated list of the protocols the class adopts. Either clause may be omitted. A class with neither inherits from the universal `Object` base and adopts no protocols.

A class that claims conformance but lacks a declared method is rejected at compile time:

>```
> class Broken <Drawable>
>     {
>     u8 w;
>     // missing draw and width
>     }
> // error: Class 'Broken' claims conformance to protocol
> //        'Drawable' but doesn't implement 'draw'
>```

Subclasses inherit their parent's conformances. If `Sprite` adopts `Drawable`, any subclass of `Sprite` is accepted where a `Drawable` is expected, without re-listing `Drawable` in its own conformance clause.

<u>Using a protocol as a type</u>

A protocol name used as a type denotes a value that conforms to the protocol. The pointer form (`Drawable@`) is the usual one; it holds a pointer to any conforming instance, whatever its concrete class:

>```
> void render(Drawable@ d)
>     {
>     d.draw();
>     }
>
> void main(void)
>     {
>     Sprite@  s = new Sprite();
>     Terrain@ t = new Terrain();
>     render(s);      // calls Sprite.draw
>     render(t);      // calls Terrain.draw
>     }
>```

Passing a non-conforming instance is a compile-time error:

>```
> class Vehicle { u8 wheels; }
>
> void main(void)
>     {
>     Vehicle@ v = new Vehicle();
>     render(v);      // error: 'Vehicle' does not conform to
>                     //        protocol 'Drawable'
>     }
>```

<u>Dispatch</u>

Calls through a protocol-typed pointer use the same per-class vtables as class inheritance. Each protocol method is assigned its own global slot, and each conforming class's implementation goes in that slot of the class's vtable. At the call site the compiler reads the instance's class-id byte (stored by `new` at payload offset 0) and uses it to index the class's vtable for the slot. Each call is one indirect JMP, with no runtime string lookup.

A class can adopt any number of protocols, listed in any order. When two protocols declare a method with the same name and signature, they share one vtable slot, and a class that conforms to both supplies one implementation for both.

#### <u>Heap allocation and reference counting</u>

Xtc has a coalescing free-list heap with reference-counted ownership. It is available on memory layouts that declare a `[heap]` region: `xl-shadow`, `xe-nobank`, `xt`, `xe-heap`, and the `rambo*` / `compy*` extended-memory variants. On those targets `-falloc=heap` is the default. Layouts without a `[heap]` region use a bump allocator, and sema rejects heap-only statements. Banked-heap targets reserve one or more 16 KB bank pages for the heap, and the runtime selects the right bank on each allocator call.

<u>Allocation</u>

Three `new` forms allocate primitives, structs and classes, singly or as arrays. Every successful `new` zero-fills the payload and sets its reference count to 1:

>```
> MyClass@ p  = new MyClass();       // class instance (init() runs)
> MyClass@ q  = new MyClass(4, 2);   // parameterised init
> RGB@ pixel  = new RGB;             // struct scalar
> u8@ buf     = new u8[128];         // array of primitives
> MyClass@ mob = new MyClass[8];     // array of class instances
>```

`new T[N]` is the only way to allocate an array on the heap. For arrays of class instances, every element is zero-filled and its `init()` runs. When memory runs out, `new` returns a null pointer; check for it where it matters.

<u>Automatic reference counting (ARC)</u>

By default (`-farc` on) the compiler manages reference counts. Every heap block has a 4-byte header immediately before the payload: a 15-bit size, a free-flag bit and a 16-bit retain count. The compiler emits retains and releases at these points:

- **On `new`:** the allocator returns with refcount = 1, and the declared slot takes ownership without a retain.
- **On decl-init from another identifier** (`Foo@ b = a;`): the slot takes a second owning reference, so the compiler retains the pointee.
- **On assignment** (`slot = expr;`): the old pointee is released. The new pointee is retained if the right-hand side was a borrowed read; if the right-hand side produced a value, such as `new T()` or a function call, its `+1` is absorbed.
- **On scope exit:** every tracked strong class-pointer local is released, in LIFO order. Fall-through return, early `return` and `break` out of a block all take the same path.
- **On class dealloc:** when a block's refcount reaches zero, the aggregate walker recursively releases every strong class-pointer ivar before returning the bytes to the free list.

These rules give the calling conventions:

- **Always-`+1` returns:** a function that returns a class pointer gives the caller an owning reference. The callee has retained it, so the caller does not.
- **Callee-retains-params:** a class-pointer parameter is retained on function entry and released on exit. If the body uses the pointer only transiently, the net effect is zero; a store that outlives the call (into a global or another heap object's field) keeps the +1 from the retain.

Sema rejects the manual `retain`, `release` and `delete` statements on a class instance, because the compiler owns those lifetimes. `delete` still frees a struct or primitive array, which ARC does not manage (see *Freeing what ARC does not own* below).

An example:

>```
> void work(void)
>     {
>     Foo@ a = new Foo();   // take allocator's +1.
>     Foo@ b = a;           // a borrowed read → retain; refcount = 2.
>     a = new Foo();        // release old-a, absorb new +1.
>                           //   old-a refcount → 1 (b still holds it).
>                           //   new-a refcount = 1.
>     // scope exit: release b (old-a's refcount → 0 → dealloc);
>     //             release a (new-a's refcount → 0 → dealloc).
>     }
>```

<u>The dealloc callback</u>

When a class pointer's refcount reaches zero, the class's `dealloc(void)` method runs before the bytes return to the free list. Every class gets a generated empty `dealloc()` stub. Classes that own external state (open files, mapped I/O, caches the ARC walker cannot see) override it with their own cleanup:

>```
> class Buffer
>     {
>     u8@ bytes;
>     u16 len;
>
>     void init(u16 n)
>         {
>         bytes = new u8[n];
>         len   = n;
>         }
>
>     void dealloc(void)
>         {
>         // bytes is a strong class-pointer ivar — the aggregate
>         // walker releases it automatically. Override dealloc
>         // only for things the compiler can't see (hardware,
>         // logging, cache invalidation, …).
>         }
>     }
>```

Releasing an array of class instances (allocated with `new T[N]`) calls `dealloc()` once per element before freeing the block. `dealloc` runs when the last owning reference is dropped, and only once.

<u>Weak references</u>

Plain reference counting leaks cycles. If `Parent` owns `Child` strongly and `Child` has a back-pointer to `Parent`, each refcount stays at 1 after every external reference is dropped, and the two instances keep each other alive. The `weak:` qualifier breaks the cycle:

>```
> class Child
>     {
>     weak:Parent@ dad;     // non-owning back-pointer
>     u8 tag;
>     }
>
> class Parent
>     {
>     Child@ kid;           // strong, owning
>     u8 tag;
>     }
>```

A `weak:T@` slot holds a raw pointer that reference counting ignores: assigning to it does not retain, and releasing the pointee does not consult it. The runtime records every live weak slot in a bounded side table. When a refcount reaches zero, the dealloc path walks the table and writes `$00` through every slot that points at the dying block, so later reads of the slot return null. For example:

>```
> Parent@ p = new Parent();
> p.kid = new Child();
> p.kid.dad = p;                   // weak: no retain on p.
> // Parent refcount = 1 (held by p).
> // Child refcount  = 1 (held by p.kid).
> p = (Parent@)0;                  // p's release cascades:
> //   Parent refcount → 0; dealloc fires.
> //     Aggregate walker releases Parent.kid.
> //       Child refcount → 0; dealloc fires.
> //         Aggregate walker processes Child.dad — it's weak, so
> //         the walker just unregisters the slot from the side
> //         table. No decref.
> //     Child freed.
> //   Weak walker zeroes any external weak refs to Parent.
> //   Parent freed.
> // No leak, no dangling pointer — dad would have read as null
> // even if we'd stashed it somewhere before p's release.
>```

Weak slots can take every form a strong pointer can:

>```
> weak:Foo@ g;                     // module-scope global
> weak:Foo@ local;                 // stack-resident local
> weak:Foo@ arr[8];                // stack array of weak slots
> class Observer
>     {
>     weak:Subject@ target;        // ivar
>     }
>```

Rules and limits:

- **Class pointers only.** `weak:u8@`, `weak:<fn_ptr>@` and other non-class pointees are rejected at compile time. The side table is keyed on heap-block addresses, and non-class pointers do not own heap blocks with refcount headers.
- **Use `weak:banked:T@` when the pointee is itself banked.** A bare `weak:T@` class ivar uses whatever placement the target gives a bare T@. On banked-heap layouts that is a 2-byte implicit-bank pointer, which suits ivars that hold Heap-placement pointees. If the weak slot needs a per-instance bank byte (because the pointee is `banked:T@`), declare it explicitly.
- **Cycle-detection is your responsibility.** There is no automatic cycle collector. The `weak:` annotation tells the compiler which edge in a cycle is the non-owning one.
- **Reading is a plain pointer read.** A non-null weak slot always points at a live block, because the side table is updated before the block's dealloc runs. `if (w != 0) …` is sufficient; there is no special `weak_load` primitive.

The side table is bounded. It holds 64 entries by default; each declared weak slot uses one entry, and an array uses one per element. If the static count of weak declarations in your program exceeds the capacity, sema warns at compile time and points to the layout override. To raise the limit, add a `[weak]` section to your `.lnk`:

>```
> [weak]
> entries = 128                    # default 64; max 255
>```

The maximum is 255. The runtime stores entries in six parallel byte-wide tables (obj lo / hi / bank, slot lo / hi / bank) indexed by entry number, and the scan loops end on `CPX #WEAK_TABLE_ENTRIES / BEQ done`. That is an 8-bit immediate compare, so 256 does not fit. The tables take `6 × N` bytes of main RAM: 384 bytes for the default 64 and 1530 bytes for 255. A lower value reclaims space when you know how many weak slots your program needs.

<u>Freeing what ARC does not own</u>

ARC owns class instances, both single objects and arrays of them, and sema rejects `retain`, `release` and `delete` on them. A manual decrement on top of a compiler-inserted one would free an object that is still aliased: a use-after-free that shows up far from its cause.

`delete` frees everything ARC does not manage, and is the *only* way to free it:

>```
> u8@ buf   = new u8[20];      delete buf;     // primitive array
> Point@ ps = new Point[4];    delete ps;      // array of structs
>```

There is no manual-lifecycle mode. `-farc=off` is accepted so that existing command lines keep working, but it only produces a warning: the build emits the same retains and releases as without it.

<u>Introspection</u>

The `Heap` library class (`#import <Heap.xc>`) has static methods for inspecting the allocator at runtime:

- `Heap.size()` returns `u32`: the total free bytes across every reserved bank, including the 4-byte per-block header overhead.
- `Heap.largest()` returns `u16`: the size of the largest single free extent. First-fit allocation cannot satisfy a larger request, even if `size()` is bigger; compare it with an intended allocation to see whether that allocation will succeed.
- `Heap.totalSize()` returns `u32`: the heap capacity fixed at compile time, summed across all reserved banks.

<u>Limits</u>

- A single block cannot exceed 16 KB, the size of the bank page that holds the heap. Multi-bank layouts (rambo*, compy*) hold more in total, but no allocation can span a bank boundary.
- Retain counts saturate at `$FFFF` (65535). This is effectively unlimited for normal ownership patterns; do not work around it with extra retains.
- The weak-reference side table has 64 entries per program by default. Raise it with `[weak] entries = N` in the layout (max 255); sema warns at compile time when static declarations exceed the limit.
- On `xt` and `xe-heap`, a function or method that touches a heap pointer (a direct dereference, a method call on a heap-allocated class, a custom `dealloc`) must be annotated `:main`. A `:banked` function runs with its own bank selected, so the heap bank is not visible during the call.

#### <u>Assembly Language integration</u>

An 'asm' block can be placed anywhere in the source code. The syntax is:

>```
> asm 
>    {
>    assembly-language instructions
>    }
>```

or:

>```
> asm
>    ((
>    assembly-language instructions
>    ))
>```

For these blocks, the compiler works out which registers are written and saves and restores them around the block. To override this, for example to keep a side effect, list the registers to save by telling the compiler which ones the block "clobbers". A block that clobbers all registers is written:

>```
> asm 
>    {
>    assembly-language instructions
>    } : clobbers A,X,Y
>```


<u>Operators:</u>

- The '<' prefix on a 16-bit or 32-bit constant or symbol evaluates to the low byte (bits 0..7) of that constant/symbol.

- The '>' prefix on a 16-bit or 32-bit constant or symbol evaluates to bits 8..15 of that constant/symbol.

- The '>>' prefix on a 32-bit constant or symbol evaluates to bits 16..23 of that constant/symbol.

- The '>>>' prefix on a 32-bit constant or symbol evaluates to bits 24..31 of that constant/symbol.

<u>Xtc variables</u>

The assembler recognises xtc variables by the same names as the language does, and the operators above apply to them. For example:
	  	
>```
> u16 val= $1234;
> asm
>    {
>    lda #<val;		// evaluates to LDA #$34
>    ldx #>val;		// evaluates to LDX #$12
>    }
>```


## Chapter 5. Support files

The support files are in xtc's "home" directory, which can be set in several ways (see `xtc -h`). Its structure is:

>```
>
>  support/
>    generic/
>      asm/           ← 6502 assembler routines (banked, heap, i8…, float, double)
>      lib/           ← platform-agnostic xtc classes (eg: Assert.xc)
>    atari/
>      asm/           ← atari-specific asm (atascii.asm, random.asm)
>      layouts/       ← *.lnk layout files for atari
>      lib/           ← atari xtc classes (Stdio, Math, Time, Heap, …)
>      rom/           ← OS ROM image for simulator 
>      startup/       ← startup asm templates for different memory models
>      symbols/       ← hardware symbol tables
>    commodore/       ← mirror of the above for c64, ... 
>```



