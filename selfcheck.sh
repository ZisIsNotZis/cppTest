#!/bin/sh
# selfcheck.sh - prove that cppTest.sh does what README.md says.
#
# Every case runs in a private temporary directory that holds only a copy of
# the tool and the files under test, so a pass here cannot depend on leftovers
# from an earlier run. The check also proves that the tool does not trust its
# own receipt: a wrong expectation, a compile error, and a program that dies
# halfway all have to come out as failures, and a crash must never look like
# a pass.
#
# Usage: ./selfcheck.sh [tool]
#   tool            path to cppTest.sh (default: ./cppTest.sh, next to this file)
#
# Compilers come from CPPTEST_CXX / CPPTEST_CC, then g++ / gcc from PATH.
# Exit codes: 0 every case behaved as documented, 1 some case did not.

set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
tool=${1:-$here/cppTest.sh}
if [ ! -f "$tool" ]; then
	echo "selfcheck: no such file: $tool" >&2
	exit 1
fi

: "${CPPTEST_CXX:=g++}"
: "${CPPTEST_CC:=gcc}"
export CPPTEST_CXX CPPTEST_CC

work=${TMPDIR:-/tmp}/cppTest-selfcheck.$$
rm -rf "$work"
mkdir -p "$work" || exit 1
cp "$tool" "$work/cppTest.sh" || exit 1
chmod +x "$work/cppTest.sh"
cd "$work" || exit 1

pass=0
fail=0
failed_names=""

# check <name> <want rc> <stdout/stderr regex> <command...>
# The regex is anchored at the start of a line unless it starts with '~' or
# '.', so a case can insist on the shape of the output, not merely on some
# text appearing somewhere in it.
check() {
	name=$1 want=$2 re=$3
	shift 3
	out=$("$@" 2>&1)
	rc=$?
	ok=1
	[ "$rc" -eq "$want" ] || ok=0
	case $re in
	~*) printf '%s\n' "$out" | grep -Eq -- "${re#\~}" || ok=0 ;;
	esac
	if [ "$ok" = 1 ]; then
		pass=$((pass + 1))
		printf 'ok   %-28s rc=%s\n' "$name" "$rc"
	else
		fail=$((fail + 1))
		failed_names="$failed_names $name"
		printf 'FAIL %-28s rc=%s (wanted %s, /%s/)\n' "$name" "$rc" "$want" "$re"
		printf '%s\n' "$out" | sed 's/^/     | /'
	fi
}

skip() {
	name=$1 why=$2
	echo "skip $name: $why"
}

# --- fixtures -------------------------------------------------------------
# C and C++ files, including the cases that must fail.
cat > c-example.c <<'EOF'
int double_it(int n) { return n * 2; }
const int double_itTest[][2] = {{1, 2}, {-3, -6}};
EOF
cat > c11-example.c <<'EOF'
int category(int n) { return _Generic(n, int: 7, default: -1); }
const int categoryTest[][2] = {{0, 7}};
EOF
cat > malloc.c <<'EOF'
#include <stdlib.h>

int first_and_len(int n) { int *p = malloc(2 * sizeof *p); p[0] = n; return p[0]; }

const int first_and_lenTest[][2] = {{3, 3}, {7, 7}};
EOF
cat > strdup.c <<'EOF'
#include <string.h>

const char *shout(const char *s) { char *o = strdup(s); o[0] = 'A'; return o; }

#define shoutTester(a, b) strcmp(a, b)

const char *shoutTest[][2] = {{"abc", "Abc"}, {"x", "A"}};
EOF
cat > three.c <<'EOF'
int twice(int n) { return n * 2; }

/* A C table holds one element type, so extra columns are the only way to
   record more than a call and its answer. Only the first two are compared. */
const int twiceTest[][3] = {{1, 2, 0}, {5, 10, 0}};
EOF
cat > tester.c <<'EOF'
#include <math.h>

double half(double x) { return x / 2; }

/* A tester says WRONG when it returns true, so this one asks for closeness. */
#define halfTester(a, b) (fabs((a) - (b)) > 1e-9)

const double halfTest[][2] = {{1, 0.5}, {3, 1.5}, {-8, -4}};
EOF
cat > tester2.c <<'EOF'
int incer(int n) { return n + 1; }

#define incerTester(a, b) ((a) != (b))

const int incerTest[][2] = {{1, 2}, {9, 10}};
EOF
cat > factorialer.cpp <<'EOF'
unsigned long long factorialer(unsigned long long n) {
  unsigned long long i, o = 1;
  for (i = 2; i <= n; i++) o *= i;
  return o;
}

const unsigned long long factorialerTest[][2] = {
  {0, 1}, {1, 1}, {2, 2}, {3, 6}, {4, 24}, {5, 120}, {13, 6227020800}
};
EOF
cat > incer.cpp <<'EOF'
int incer(int n) { return n + 1; }

const int incerTest[][2] = {
  {1, 2}, {111, 112}, {-123, -122}, {758, 759}, {0, 1}, {9999999, 10000000}
};
EOF
cat > chars.cpp <<'EOF'
#include <cstring>

char *firstCharToAer(const char *s) {
  char *o = new char[strlen(s) + 1];
  strcpy(o, s);
  o[0] = 'A';
  return o;
}

#define firstCharToAerTester strcmp

const char *firstCharToAerTest[][2] = {
  {"BCD", "ACD"}, {"abcd", "Abcd"}, {"Hello, world!", "Aello, world!"}
};
EOF
cat > wrong.c <<'EOF'
int double_it(int n) { return n * 2; }
const int double_itTest[][2] = {{1, 2}, {-3, 6}};
EOF
cat > wrong.cpp <<'EOF'
int incer(int n) { return n + 1; }
const int incerTest[][2] = {{1, 2}, {2, 99}, {3, 4}};
EOF
cat > broken.c <<'EOF'
int broken(int n) { return n + ; }
const int brokenTest[][2] = {{1, 2}};
EOF
cat > notable.cpp <<'EOF'
int nothing(int n) { return n; }
EOF
cat > wide.cpp <<'EOF'
int double_it(int n) { return n * 2; }
const int double_itTest[][3] = {{1, 2}, {-3, -6}};
EOF
cat > ownmain.cpp <<'EOF'
#include <cstdio>
int incer(int n) { return n + 1; }
const int incerTest[][2] = {{1, 2}, {2, 3}};
int main(int argc, char **argv) {
  printf("the file's own main saw %d argument(s)\n", argc - 1);
  return 0;
}
EOF
cat > onerow.c <<'EOF'
int incer(int n) { return n + 1; }
const int incerTest[][2] = {{1, 2}};
EOF
cat > autotable.cpp <<'EOF'
int incer(int n) { return n + 1; }

/* The syntax the old README used. C++ cannot deduce an element type from a
   brace table, so this is reported as the user's mistake, not as a failure
   inside generated code. */
const auto incerTest = {
  { 1, 2 },
  { 2, 3 },
};
EOF
cat > autowidth.cpp <<'EOF'
int incer(int n) { return n + 1; }
const auto incerTest[][2] = {{1, 2}, {2, 3}};
EOF
cat > header.h <<'EOF'
static int twice(int n) { return 2 * n; }
const int twiceTest[][2] = {{1, 2}, {4, 8}};
EOF
cat > crasher.cpp <<'EOF'
int boom(int n) { return n / (n - n); }
const int boomTest[][2] = {{0, 1}};
EOF
cat > mismatch.cpp <<'EOF'
int doubler(int n) { return 2 * n; }
const int doublerTest[][2] = {{1, 2}, {2, "four"}};
EOF
cat > quietnotice.c <<'EOF'
int twice(int n) { return n * 2; }
const int twiceTest[][3] = {{1, 2, 0}};
EOF
# A file that exists and cannot be read. Its *contents* are never the point:
# the tool has to say so before it tries to parse anything.
cat > locked.c <<'EOF'
int incer(int n) { return n + 1; }
const int incerTest[][2] = {{1, 2}};
EOF
chmod 000 locked.c

# A file that includes a header sitting next to it. The program text is built
# in a temporary directory, so this only works if the tool adds the source's
# own directory to the quote-include path -- exactly what a plain
# `gcc lib/scale.c` would do.
mkdir -p lib
cat > lib/scale.h <<'EOF'
#ifndef SCALE_H
#define SCALE_H
double scale(double x);
#endif
EOF
cat > lib/scale.c <<'EOF'
#include "scale.h"

double scale(double x) { return 2 * x; }
const double scaleTest[][2] = {{1, 2}, {-3, -6}};
EOF
cat > lib/scale.cpp <<'EOF'
#include "scale.h"

double scale(double x) { return 3 * x; }
const double scaleTest[][2] = {{1, 3}, {-3, -9}};
EOF
# The same header reached the other way must NOT be found: only "..."
# lookups get the source directory, never <...>.
cat > lib/scale-angle.c <<'EOF'
#include <scale.h>
double scale(double x) { return x; }
const double scaleTest[][2] = {{1, 1}};
EOF

# --- cases: the documented behaviour ---------------------------------------
check 'C file'                0 '^cppTest: passed, 2 test cases in 1 file'  ./cppTest.sh c-example.c
check 'C11 _Generic'          0 '^cppTest: passed, 1 test cases in 1 file'  ./cppTest.sh c11-example.c
check 'C void* from malloc'   0 '^cppTest: passed, 2 test cases in 1 file'  ./cppTest.sh malloc.c
check 'C strdup (gnu11)'      0 '^cppTest: passed, 2 test cases in 1 file'  ./cppTest.sh strdup.c
check 'C three columns'       0 '^NOTICE twiceTest'                        ./cppTest.sh three.c
check 'C tester macro'        0 '^cppTest: passed, 3 test cases in 1 file'  ./cppTest.sh tester.c
check 'C integer tester'      0 '^cppTest: passed, 2 test cases in 1 file'  ./cppTest.sh tester2.c
check 'C++ factorialer'       0 '^cppTest: passed, 7 test cases in 1 file'  ./cppTest.sh factorialer.cpp
check 'C++ incer'             0 '^cppTest: passed, 6 test cases in 1 file'  ./cppTest.sh incer.cpp
check 'C++ tester macro'      0 '^cppTest: passed, 3 test cases in 1 file'  ./cppTest.sh chars.cpp
check 'mixed C and C++'       0 '^cppTest: passed, 19 test cases in 5 files' \
	./cppTest.sh c-example.c c11-example.c factorialer.cpp chars.cpp incer.cpp
check 'one-row C table'       0 '^cppTest: passed, 1 test cases in 1 file'  ./cppTest.sh onerow.c
check 'file with own main'    0 '^cppTest: passed, 2 test cases in 1 file'  ./cppTest.sh ownmain.cpp
check 'no tables'             0 '^cppTest: no test tables found'            ./cppTest.sh notable.cpp
check '.h file is C'          0 '^cppTest: passed, 2 test cases in 1 file'  ./cppTest.sh header.h
check 'extra column C++'      0 '^NOTICE double_itTest'                     ./cppTest.sh wide.cpp
check 'help'                  0 '^Usage: ./cppTest.sh'                      ./cppTest.sh -h
check 'long option --verbose' 0 '^PASS incer(1)'                            ./cppTest.sh --verbose incer.cpp
check 'long option --quiet'   0 '^cppTest: passed, 1 test cases'            ./cppTest.sh --quiet incer.cpp

# -v has to show the passing cases, one line each, and still the summary.
check 'verbose lists passes'  0 '^PASS incer(9999999)'                      ./cppTest.sh -v incer.cpp

# --- cases: real problems must be reported as problems ---------------------
check 'wrong expectation C'   1 '^FAIL double_it\(-3\)'                     ./cppTest.sh wrong.c
check 'wrong expectation C++' 1 '^FAIL incer\(2\)'                          ./cppTest.sh wrong.cpp
check 'compile error'         2 '^cppTest: broken.c does not compile'       ./cppTest.sh broken.c
check 'type mismatch'         2 '^  mismatch.cpp:5:7: error:'                ./cppTest.sh mismatch.cpp
# An untypeable table is the user's syntax to fix, so the message quotes
# their line and the table name and suggests the typed spelling. Neither the
# braces-only nor the sized spelling can deduce `auto`; both say so.
check 'auto table, no width'  2 '^cppTest: autotable.cpp:4: incerTest declares its element type as auto' \
	./cppTest.sh autotable.cpp
check 'auto table, width'     2 '^cppTest: autowidth.cpp:2: incerTest declares its element type as auto' \
	./cppTest.sh autowidth.cpp
check 'auto table, fix hint'  2 '~^         const int incerTest\[\]\[2\] = {' \
	./cppTest.sh autotable.cpp
check 'crash is not a pass'   1 '^cppTest: crasher.cpp: the test program ended with status' \
	./cppTest.sh crasher.cpp
check 'missing file'          3 '^cppTest: no such file: nosuch.c'          ./cppTest.sh nosuch.c
check 'unreadable file'       3 '^cppTest: cannot read file: locked.c'      ./cppTest.sh locked.c
check 'unknown option'        3 '^cppTest: unknown option -Z'               ./cppTest.sh -Z c-example.c
check 'unknown long option'   3 '^cppTest: unknown option --nope'           ./cppTest.sh --nope incer.cpp
check 'no arguments'          3 '^cppTest: no files given'                  ./cppTest.sh

# --- cases: quiet mode keeps what matters ----------------------------------
# A quiet run may hide passes, but it must not hide a FAIL, the two lines
# that explain it, or a NOTICE about a column that was not compared.
check 'quiet keeps FAIL'      1 '^FAIL double_it\(-3\)'                     ./cppTest.sh -q wrong.c
check 'quiet keeps expected'  1 '^   expected: 6$'                          ./cppTest.sh -q wrong.c
check 'quiet keeps got'       1 '^        got: -6$'                         ./cppTest.sh -q wrong.c
check 'quiet keeps NOTICE'    0 '^NOTICE twiceTest'                         ./cppTest.sh -q quietnotice.c

# --- the examples shipped next to the tool -----------------------------------
# README's first command. This runs the examples in the repository, not a
# copy, so a broken example is caught here.
check 'shipped exampleIncer'  0 '^cppTest: passed, 6 test cases in 1 file' \
	./cppTest.sh "$here/exampleIncer.cpp"
check 'shipped exampleFirstCharToAer' 0 '^cppTest: passed, 6 test cases in 1 file' \
	./cppTest.sh "$here/exampleFirstCharToAer.cpp"

# exampleFactorialer.cpp carries the bug its author left in it on purpose:
# a real failure, reported as one. README relies on this, so it is pinned.
check 'shipped example fails honestly' 1 '^FAIL factorialer\(13\)' \
	./cppTest.sh "$here/exampleFactorialer.cpp"

# --- a header next to the source --------------------------------------------
# Both languages, and both pointed at through "...". The tool compiles a
# generated copy of the file, so it has to tell the compiler where the
# original file lives.
check 'local header, C'       0 '^cppTest: passed, 2 test cases in 1 file'  ./cppTest.sh lib/scale.c
check 'local header, C++'     0 '^cppTest: passed, 2 test cases in 1 file'  ./cppTest.sh lib/scale.cpp
check 'local header, both'    0 '^cppTest: passed, 4 test cases in 2 files' \
	./cppTest.sh lib/scale.c lib/scale.cpp
# <...> must stay a system-only lookup: this file has no business compiling.
check 'angle header not added' 2 '^cppTest: lib/scale-angle.c does not compile' \
	./cppTest.sh lib/scale-angle.c

# --- a compiler that is not there ------------------------------------------
check 'missing C++ compiler' 3 '^cppTest: no C++ compiler found' \
	env CPPTEST_CXX=/nonexistent/compiler ./cppTest.sh incer.cpp
check 'missing C compiler'   3 '^cppTest: no C compiler found' \
	env CPPTEST_CC=/nonexistent/compiler ./cppTest.sh c-example.c

# --- parallel runs must not step on each other ------------------------------
# Twelve runs of the same two files at once: every run has to reach the same
# verdict and print the same bytes, or a pass could depend on another run.
printf '%s\n' 'int incer(int n) { return n + 1; }' \
	'const int incerTest[][2] = {{1, 2}, {2, 3}, {3, 4}};' > par.cpp
i=0
while [ "$i" -lt 12 ]; do
	( ./cppTest.sh par.cpp >"par.$i.out" 2>&1; echo $? >"par.$i.rc" ) &
	i=$((i + 1))
done
wait
uniq_rc=$(sort -u par.*.rc | tr -d '\n')
uniq_out=$(md5sum par.*.out | awk '{ print $1 }' | sort -u | wc -l | tr -d ' ')
if [ "$uniq_rc" = 0 ] && [ "$uniq_out" = 1 ]; then
	pass=$((pass + 1))
	echo "ok   12 parallel runs             rc=0, identical output"
else
	fail=$((fail + 1))
	failed_names="$failed_names parallel"
	echo "FAIL 12 parallel runs             rc=$uniq_rc, $uniq_out distinct outputs"
fi

# --- verdict ---------------------------------------------------------------
printf '\n%s passed, %s failed of %s cases\n' "$pass" "$fail" "$((pass + fail))"
if [ "$fail" -ne 0 ]; then
	echo "failed:$failed_names" >&2
	echo "generated files kept in $work" >&2
	exit 1
fi
echo "compilers: C++ $CPPTEST_CXX, C $CPPTEST_CC"
rm -rf "$work"
