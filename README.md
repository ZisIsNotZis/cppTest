# cppTest

Write a test table next to a function. Run one command. Every row is called
and compared, and the answer comes out as a pass, a failure with the value
that was expected and the value that came back, or a compile error pointing
at the line you wrote.

No test framework, no build file, no registration: a `somethingTest` table is
the whole declaration.

```
./cppTest.sh exampleIncer.cpp exampleFirstCharToAer.cpp exampleFactorialer.cpp
```

That example is the point of the tool, so it contains a real bug on purpose —
`exampleFactorialer.cpp` returns 13 for 13. The run executes 19 cases. The deliberately wrong case fails and the command exits 1:

```
FAIL factorialer(13)
   expected: 6227020800
        got: 13
cppTest: 7 cases, 1 failed
cppTest: 1 of 19 test cases failed
```

## The table

```c
int incer(int n) { return n + 1; }

const int incerTest[][2] = {
  { 1, 2 },
  { 111, 112 },
  { -123, -122 },
};
```

`somethingTest` is a table of rows. For each row the function is called with
the first column, and its result is compared with the second. The element type
is the table's element type (`int` above), declared once, so a row that does
not fit it — `2.5`, or `"four"` — is a compile error at the row you wrote,
before anything runs.

The element type must be written out. `const auto somethingTest = { ... }`
cannot work: a brace table has no element type for `auto` to deduce, and no
spelling of it fixes that. cppTest says so with your line number rather than
quoting generated code:

```
cppTest: incer.cpp:4: incerTest declares its element type as auto, so nothing here can give it one
```

Two things follow from a table being data:

* **A function with no table is not tested.** No table means nothing to
  report, which is not a failure.
* **A table naming a function that does not exist is a compile error**, the
  same as any other use of a missing name.

### Comparing by something other than `==`

By default two values are compared with `==`. When that is wrong — `char *`
compares addresses, `double` needs a tolerance — define a `*Tester` for the
function. The tester receives the value produced and the value expected, and
returns **true when the answer is WRONG** (that is the old contract, kept):

```c
#define firstCharToAerTester strcmp
```

```c
#define halfTester(a, b) (fabs((a) - (b)) > 1e-9)
```

Either the bare function name or a two-argument macro works.

### Rows with only one column

`{ 777 }` calls the function and checks that it returns without crashing, and
prints a `NOTICE` saying that is all it checks. Nothing pretends a single
column was compared.

### More than two columns

Only the first two columns are compared. A `NOTICE` says the rest were
ignored, so a partial check never looks like a complete one:

```
NOTICE twiceTest: columns after the second are not compared
```

The same `NOTICE` appears with `-q`: quiet hides passes, never a failure and
never a note about what was *not* checked.

## Options and exit codes

```
./cppTest.sh [options] file.c file.cpp ...
```

| option | |
| --- | --- |
| `-q`, `--quiet` | only failures, notices and the summary |
| `-v`, `--verbose` | also print each case that passed |
| `-h`, `--help` | usage |

| exit code | meaning |
| --- | --- |
| 0 | everything that was tested passed (or there was nothing to test) |
| 1 | at least one case failed, or a test program crashed |
| 2 | a file did not compile |
| 3 | bad invocation: unknown option, missing or unreadable file, no compiler |

With several files the worst outcome wins, whatever their order.

## C and C++

The compiler follows the file name, exactly as `gcc` would: `.c` and `.h` are
compiled as C, everything else as C++. A `.c` file is really compiled as C, so
`void *` from `malloc`, `_Generic`, and C's conversion rules behave as that
file's author expects; a `.cpp` file is really C++. Nothing is guessed from
the contents, so the same file always gets the same compiler.

A file may keep its own `main`; it is renamed out of the way while the
generated tests run, and its tests still run.

`#include "something.h"` finds `something.h` next to the file, as a plain
`gcc path/to/file.c` would, because the check compiles a generated copy of
your file elsewhere. Only `"..."` gets that path; `<...>` stays system-only.

## Environment

| variable | |
| --- | --- |
| `CPPTEST_CXX` | C++ compiler (default `g++`) |
| `CPPTEST_CC` | C compiler (default `gcc`) |
| `CPPTEST_CXXFLAGS` | flags for C++ files, e.g. `-std=c++17` |
| `CPPTEST_CCFLAGS` | flags for C files (replaces the default `-std=gnu11 …`) |
| `CPPTEST_KEEP=1` | keep the generated program and binary, and print where |

Each run gets its own temporary directory, so concurrent runs of the same
files do not share a single byte.

## Checking the tool itself

```
./selfcheck.sh
```

Runs cppTest against 47 cases in a fresh temporary directory — C, C++, local
headers, `*Tester`, wrong expectations, compile errors, type mismatches,
crashes, missing files and compilers, quiet mode, and twelve simultaneous runs
of the same files — and exits 0 only if every case behaves as this README
says. It exits 1 and names the case if not, so it is usable as a check after
editing `cppTest.sh`.
