#!/bin/sh
# cppTest - turn plain C/C++ files into tiny unit tests.
#
# Usage: ./cppTest.sh [options] file.c file.cpp ...
#
# For every `somethingTest` table in a file, the function `something` is
# called with each first column and its result compared to the second column.
# See README.md for the table format, custom `*Tester` comparators and the
# exit codes.
#
# Environment:
#   CPPTEST_CXX       C++ compiler command (default: g++)
#   CPPTEST_CC        C compiler command   (default: gcc, for .c and .h)
#   CPPTEST_CXXFLAGS  extra flags for C++ files, e.g. -std=c++17
#   CPPTEST_CCFLAGS   extra flags for C files (they replace the default
#                     `-std=gnu11 -fgnu89-inline ...`)
#   CPPTEST_KEEP=1    keep the generated main and binaries for debugging

set -eu

usage() {
	cat <<'EOF'
Usage: ./cppTest.sh [options] file.c file.cpp ...

  -q, --quiet    only print failures and the summary
  -v, --verbose  also print every case that passed
  -h, --help     show this help

Exit codes: 0 all tested functions passed (or there was nothing to test)
            1 at least one case failed
            2 a file could not be compiled
            3 bad invocation (unknown option, missing file or no compiler)
EOF
}

case ${0##*/} in
cppTest.sh | sh | bash | dash | ksh | zsh | ash | -sh | -bash | -dash) ;;
*) usage >&2; echo "cppTest: run me as ./cppTest.sh" >&2; exit 3 ;;
esac

CC=${CPPTEST_CC:-gcc}
CXX=${CPPTEST_CXX:-g++}
CFLAGS=${CPPTEST_CCFLAGS:-}
XFLAGS=${CPPTEST_CXXFLAGS:-}
quiet=0
verbose=0

while getopts ":qvh-:" opt; do
	case $opt in
	q) quiet=1 ;;
	v) verbose=1 ;;
	h) usage; exit 0 ;;
	-)
		case $OPTARG in
		quiet | quiet=*) quiet=1 ;;
		verbose | verbose=*) verbose=1 ;;
		help) usage; exit 0 ;;
		*) usage >&2; echo "cppTest: unknown option --$OPTARG" >&2; exit 3 ;;
		esac
		;;
	*) usage >&2; echo "cppTest: unknown option -$OPTARG" >&2; exit 3 ;;
	esac
done
shift $((OPTIND - 1))

if [ $# -eq 0 ]; then
	usage >&2
	echo "cppTest: no files given" >&2
	exit 3
fi

files=0
cases=0
failed=0
exitcode=0
brokenfiles=""

# One directory per run, so parallel runs never share generated files.
work=$(mktemp -d "${TMPDIR:-/tmp}/cppTest.XXXXXX") || {
	echo "cppTest: cannot create a temporary directory" >&2
	exit 3
}

# The summary is printed once, from the EXIT trap, so every way out of the
# script (a failure, a usage error, an unexpected stop) ends with one line
# that says what happened and one exit status that matches it.
finish() {
	status=$?
	# A nonzero status is this script's own `exit 1/2/3` (a bad invocation, an
	# unreadable file) or an unexpected stop. Either way it wins over the
	# per-file exitcode, which is still 0 when the script exited early.
	if [ "$status" -ne 0 ]; then
		case $status in
		1 | 2 | 3) exitcode=$status ;;
		*)
			echo "cppTest: stopped with status $status (this is a bug in cppTest.sh)" >&2
			exitcode=$status
			;;
		esac
	fi
	if [ "${CPPTEST_KEEP:-0}" = 1 ]; then
		echo "cppTest: kept generated files in $work"
	else
		rm -rf "$work"
	fi
	case $exitcode in
	0)
		if [ "$files" -eq 1 ]; then
			echo "cppTest: passed, $cases test cases in 1 file"
		else
			echo "cppTest: passed, $cases test cases in $files files"
		fi
		[ "$cases" -eq 0 ] && echo "cppTest: no test tables found, nothing was tested"
		;;
	1)
		if [ "$cases" -eq 0 ]; then
			echo "cppTest: stopped before running a case (this is a bug in cppTest.sh)" >&2
		else
			echo "cppTest: $failed of $cases test cases failed" >&2
		fi
		;;
	2)
		echo "cppTest: could not compile:" >&2
		printf '%s\n' "$brokenfiles" | sed '/^$/d; s/^/  /' >&2
		;;
	3) ;; # the specific message was already printed where the error was found
	esac
	exit "$exitcode"
}
trap finish EXIT
# ---- reading the source ---------------------------------------------------
#
# Comments are dropped before anything is parsed, so `// fooTest` in a remark
# never looks like a test. String and character literals as the user wrote them.
clean_source() { # <file> <out>
	awk '
	{
		line = $0; out = ""; i = 1; n = length(line)
		while (i <= n) {
			c = substr(line, i, 1); d = substr(line, i, 2)
			if (inblock) {
				if (d == "*/") { inblock = 0; i += 2 } else i += 1
				continue
			}
			if (c == "\"" || c == "\047") {
				q = c; out = out c; i += 1
				while (i <= n) {
					c = substr(line, i, 1); out = out c
					if (c == "\\") { i += 1; out = out substr(line, i, 1) }
					else if (c == q) break
					i += 1
				}
				i += 1; continue
			}
			if (d == "//") break
			if (d == "/*") { inblock = 1; i += 2; continue }
			out = out c; i += 1
		}
		print out
	}' "$1" >"$2"
}

# Tables in the cleaned source, one line each:
#   <table> TAB <function> TAB <declared type without outer size> TAB <offset of first row>
# A table is `nameTest` followed by `=` and `{` outside any braces, so a
# local variable inside a function body is never mistaken for one.
find_tables() { # <cleaned source> <out>
	LC_ALL=C awk '
	function skipquote(s, i, q, L) {
		for (i++; i <= L; i++) {
			if (substr(s, i, 1) == "\\") i++
			else if (substr(s, i, 1) == q) return i + 1
		}
		return L + 1
	}
	function finish(   t) {
		t = decl; decl = ""
		gsub(/[\r\n]+/, " ", t)
		gsub(/[ \t]+/, " ", t)
		sub(/^ /, "", t); sub(/ $/, "", t)
		if (cand != "" && eq) {
			cols = 0
			if (match(t, /\[[ ]*[0-9]+[ ]*\][ ]*$/)) {
				inner = substr(t, RSTART, RLENGTH)
				gsub(/[^0-9]/, "", inner)
				cols = inner + 0
			}
			while (t ~ /\[[^]]*\][ ]*$/) sub(/\[[^]]*\][ ]*$/, "", t)
			sub(/[ ]*$/, "", t)
			sub(/[A-Za-z_][A-Za-z0-9_]*$/, "", t)
			sub(/[ ]*$/, "", t)
			sub(/[ ]*$/, "", t)
			while (t ~ /^(static|extern|inline|constexpr)[ ]/) sub(/^(static|extern|inline|constexpr)[ ]/, "", t)
			line = 1
			if (k > 1) {
				s = substr(buf, 1, k - 1)
				line = gsub(/\n/, "", s) + 1
			}
			print cand "\t" substr(cand, 1, length(cand) - 4) "\t" cols "\t" t "\t" bracepos "\t" line
		}
		cand = ""; eq = 0; bracepos = 0; cols = 0
	}
	{ buf = buf $0 "\n" }
	END {
		L = length(buf); depth = 0
		for (i = 1; i <= L; i++) {
			c = substr(buf, i, 1)
			if (c == "\"" || c == "\047") { i = skipquote(buf, i, c, L) - 1; continue }
			if (c == "{") {
				if (depth == 0) {
					k = i + 1
					while (k <= L) {
						ch = substr(buf, k, 1)
						if (ch != " " && ch != "\t" && ch != "\r" && ch != "\n") break
						k++
					}
					bracepos = k
					finish()
				}
				depth++
				continue
			}
			if (c == "}") { if (depth > 0) depth--; continue }
			if (depth > 0) continue
			if (c == "#") {
				while (i <= L && substr(buf, i, 1) != "\n") i++
				continue
			}
			if (c == ";") { finish(); continue }
			if (c == "=") { eq = 1; continue }
			if (c ~ /[A-Za-z0-9_]/) {
				j = i; w = ""
				while (j <= L && substr(buf, j, 1) ~ /[A-Za-z0-9_]/) { w = w substr(buf, j, 1); j++ }
				if (w ~ /^[A-Za-z_][A-Za-z0-9_]*Test$/) cand = w
				decl = decl " " w
				i = j - 1; continue
			}
			if (c == " " || c == "\t" || c == "\n") { decl = decl c; continue }
			decl = decl c
		}
	}' "$1" >"$2"
}


# The text from a 1-based byte offset to the end of the file.
slice_from() { # <file> <offset>
	LC_ALL=C awk -v off="$2" '
	BEGIN { pos = 0; started = 0 }
	{
		len = length($0) + 1
		if (!started) {
			if (pos + len < off) { pos += len; next }
			started = 1
			print substr($0, off - pos)
		} else print $0
	}' "$1"
}
# ---- tables the compiler cannot type --------------------------------------
#
# C++ cannot deduce `auto` from a brace-enclosed table: the initializer is a
# `initializer_list<auto>`, which has no element type to deduce from. That is
# a property of the language, not of this tool, and no amount of help here can
# make `const auto fooTest = {{1, 2}, {2, 3}}` compile. It is worth saying so
# once, in the user's own terms, because the failure that comes out of the
# compiler otherwise names generated code and hides the real cause.
#
# `const auto x[][2] = ...` does compile (the width gives the element type),
# so only a declared type that is exactly `auto` is reported.
auto_tables() { # <tables file> -> "<table> TAB <function> TAB <line>" for each
	LC_ALL=C awk -F'\t' '
	$1 == "" { next }
	{
		ty = $4
		gsub(/^(static|extern|inline|constexpr|const volatile|const|volatile)[ \t]+/, "", ty)
		if (ty == "auto" || ty == "decltype(auto)") print $1 "\t" $2 "\t" $6
	}' "$1"
}
# One line per row of a test table: <first column> TAB <second column>
# TAB <extra columns, if any> TAB <line in the slice where that row begins>.
# The slice starts right after the table's opening brace, so the first
# unbalanced closing brace ends the table. A row is one `{...}` group, or
# a run of <columns> top-level values. Quotes, parentheses and nested braces
# are part of the value: `{f(a,b), "x,y"}` stays one row.
table_rows() { # <initialiser text> <columns>
	LC_ALL=C awk -v cols="$2" '
	function add(  ) { if (lit != "") { nv++; v[nv] = lit; lit = "" } }
	function row(  k, second, extra) {
		add()
		if (nv == 0) return
		second = (nv >= 2) ? v[2] : ""
		extra = ""
		for (k = 3; k <= nv; k++) extra = extra (k > 3 ? ", " : "") v[k]
		print v[1] "\t" second "\t" extra "\t" begin
		for (k = 1; k <= nv; k++) v[k] = ""
		begin = 0; nv = 0; inrow = 0
	}
	BEGIN { lit = ""; nv = 0; inrow = 0; begin = 0; line = 1; q = 0; bd = 0; pd = 0 }
	{ buf = buf $0 "\n" }
	END {
		n = length(buf)
		for (i = 1; i <= n; i++) {
			c = substr(buf, i, 1)
			if (c == "\n") { line++; if (!q) { if (lit != "") lit = lit " " } continue }
			if (q) {
				lit = lit c
				if (c == "\\" && i < n) { i++; lit = lit substr(buf, i, 1) }
				else if (c == q) q = 0
				continue
			}
			if (c == "\"" || c == "\047") {
				if (!inrow) { inrow = 1; begin = line }
				q = c; lit = lit c; continue
			}
			if (c == "(") { pd++; lit = lit c; continue }
			if (c == ")") { if (pd > 0) pd--; lit = lit c; continue }
			if (c == "{") {
				if (bd == 0) { inrow = 1; begin = line; nv = 0; lit = "" }
				else lit = lit c
				bd++; continue
			}
			if (c == "}") {
				if (bd == 0) break
				bd--
				if (bd == 0) { row(); continue }
				lit = lit c; continue
			}
			if (c == "," && pd == 0 && bd <= 1) {
				if (!inrow || lit == "") continue
				add()
				if (bd == 0 && cols > 0 && nv >= cols) row()
				else if (bd == 0 && cols == 0) row()
				continue
			}
			if (c == " " && lit == "") continue
			if (!inrow) { inrow = 1; begin = line }
			if (c == " ") { if (lit != "") lit = lit c; continue }
			lit = lit c
		}
		if (inrow) row()
	}' "$1"
}
# ---- the generated program -------------------------------------------------
#
# The user's file is compiled unchanged: its text is copied after this
# prologue with `#line` so compiler messages point at the real file. The
# test code follows the file, one block per table, and the runner last.

PROLOGUE='// Generated by cppTest.sh around your file.
#include <cstdio>
#include <cstring>
#include <string>

namespace cppTest {
inline int &verbose() { static int v = 0; return v; }
inline long &cases() { static long n = 0; return n; }
inline long &fails() { static long n = 0; return n; }

inline std::string show(long double v) { char b[80]; snprintf(b, sizeof b, "%.21Lg", v); return b; }
inline std::string show(double v) { char b[80]; snprintf(b, sizeof b, "%.17g", v); return b; }
inline std::string show(float v) { char b[80]; snprintf(b, sizeof b, "%.9g", (double)v); return b; }
inline std::string show(bool v) { return v ? "true" : "false"; }
inline std::string show(const std::string &s) { return s; }
inline std::string show(const char *s) { return s ? std::string(s) : std::string("(null)"); }
inline std::string show(char *s) { return show((const char *)s); }
inline std::string show(char v) { return std::to_string((long long)v); }
inline std::string show(signed char v) { return std::to_string((long long)v); }
inline std::string show(unsigned char v) { return std::to_string((unsigned long long)v); }
inline std::string show(short v) { return std::to_string((long long)v); }
inline std::string show(unsigned short v) { return std::to_string((unsigned long long)v); }
inline std::string show(int v) { return std::to_string((long long)v); }
inline std::string show(unsigned v) { return std::to_string((unsigned long long)v); }
inline std::string show(long v) { return std::to_string((long long)v); }
inline std::string show(unsigned long v) { return std::to_string((unsigned long long)v); }
inline std::string show(long long v) { return std::to_string(v); }
inline std::string show(unsigned long long v) { return std::to_string(v); }
template <class T> std::string show(const T &) { return "(value)"; }

inline void pass(const std::string &what) {
	cases()++;
	if (verbose() > 0) { printf("PASS %s\n", what.c_str()); fflush(stdout); }
}
inline void fail(const std::string &what, const std::string &want, const std::string &got) {
	cases()++; fails()++;
	printf("FAIL %s\n   expected: %s\n        got: %s\n", what.c_str(), want.c_str(), got.c_str());
	fflush(stdout);
}
inline void ran(const std::string &what) {
	cases()++;
	if (verbose() > 0) { printf("PASS %s (only checked that it runs)\n", what.c_str()); fflush(stdout); }
}
inline void notice(const std::string &what) { printf("NOTICE %s\n", what.c_str()); fflush(stdout); }
inline int finish() {
	printf("cppTest: %ld cases, %ld failed\n", cases(), fails());
	fflush(stdout);
	return fails() > 0 ? 1 : 0;
}
}

// The file under test can keep its own main; it just gets another name.
#define main cppTest_user_main
'

# The same helpers for C. C has no overloading, so one printer takes a long
# double / long long / unsigned long long / string and `cppTest_show(x)`
# picks the right one with _Generic (C11). A caught value is shown with
# `(void)&cppTest_show_it(cppTest_show(v))(v)`. The names used by the test
# code are here too and return long, so one case generator serves C and C++.
CPROLOGUE='/* Generated by cppTest.sh around your C file. */
#include <stdio.h>
#include <string.h>
#include <stdbool.h>

static long cppTest_cases, cppTest_fails;
static int cppTest_verbose;
static long cppTest_cd(long double v) { printf("%.21Lg", v); return 0; }
static long cppTest_i(long long v) { printf("%lld", v); return 0; }
static long cppTest_u(unsigned long long v) { printf("%llu", v); return 0; }
static long cppTest_s(const char *v) { printf("%s", v ? v : "(null)"); return 0; }
#define cppTest_show(x) \
	_Generic((x), \
		char: cppTest_i, signed char: cppTest_i, unsigned char: cppTest_u, \
		short: cppTest_i, unsigned short: cppTest_u, \
		const short: cppTest_i, const unsigned short: cppTest_u, \
		int: cppTest_i, unsigned: cppTest_u, \
		const int: cppTest_i, const unsigned: cppTest_u, \
		long: cppTest_i, unsigned long: cppTest_u, \
		const long: cppTest_i, const unsigned long: cppTest_u, \
		long long: cppTest_i, unsigned long long: cppTest_u, \
		const long long: cppTest_i, const unsigned long long: cppTest_u, \
		float: cppTest_cd, double: cppTest_cd, long double: cppTest_cd, \
		const float: cppTest_cd, const double: cppTest_cd, const long double: cppTest_cd, \
		bool: cppTest_i, \
		char *: cppTest_s, const char *: cppTest_s, \
		default: cppTest_i)

/* Print a caught value: `cppTest_show_it(v)`, or wrap it in (void)&. */
#define cppTest_show_it(expr) ((void)(cppTest_show(expr)(expr)))

static long cppTest_pass(const char *what) {
	cppTest_cases++;
	if (cppTest_verbose > 0) { printf("PASS %s\n", what); fflush(stdout); }
	return 0;
}
/* A failure prints `FAIL f(arg)`, the expected text, then the actual value
   written through the right printer, all on the usual three lines. C has no
   overloading, so the value has to be printed by the caller in between. */
static long cppTest_fail_head(const char *what, const char *want) {
	cppTest_cases++; cppTest_fails++;
	printf("FAIL %s\n   expected: %s\n        got: ", what, want);
	fflush(stdout);
	return 0;
}
static long cppTest_fail_tail(void) {
	printf("\n");
	fflush(stdout);
	return 0;
}
static long cppTest_ran(const char *what) {
	cppTest_cases++;
	if (cppTest_verbose > 0) { printf("PASS %s (only checked that it runs)\n", what); fflush(stdout); }
	return 0;
}
static long cppTest_notice(const char *what) { printf("NOTICE %s\n", what); fflush(stdout); return 0; }
static int cppTest_finish(void) {
	printf("cppTest: %ld cases, %ld failed\n", cppTest_cases, cppTest_fails);
	fflush(stdout);
	return cppTest_fails > 0 ? 1 : 0;
}

/* The file under test can keep its own main; it just gets another name. */
#define main cppTest_user_main
'

# One row of the table becomes one case. The expected value is compared with
# `==` unless the file defines `<fn>Tester` (a true result means WRONG).
# Values are shown through the file's own type, so an expected literal that
# does not fit the column type still compiles here and fails at run time
# with a readable message.
case_lines() { # <function> <tester 0|1> <rows file>
	LC_ALL=C awk -v fn="$1" -v tester="$2" -F'\t' '
	# The label is the table text as written, escaped so quotes and commas
	# in it cannot break the generated string literal.
	function esc(s,   i, c, out) {
		out = ""
		for (i = 1; i <= length(s); i++) {
			c = substr(s, i, 1)
			if (c == "\\" || c == "\"") out = out "\\"
			out = out c
		}
		return out
	}
	$1 == "" { next }
	{
		what = esc(fn "(" $1 ")")
		printf "\t\t{ auto cppTest_got = %s(%s);\n", fn, $1
		if ($2 == "") {
			printf "\t\t  (void)cppTest_got; cppTest::ran(\"%s\"); }\n", what
		} else if (tester) {
			printf "\t\t  if (!cppTestT%s(cppTest_got, (%s))) cppTest::pass(\"%s\");\n", fn, $2, what
			printf "\t\t  else cppTest::fail(\"%s\", cppTest::show(%s), cppTest::show(cppTest_got)); }\n", what, $2
		} else {
			printf "\t\t  if (cppTest_got == (%s)) cppTest::pass(\"%s\");\n", $2, what
			printf "\t\t  else cppTest::fail(\"%s\", cppTest::show(%s), cppTest::show(cppTest_got)); }\n", what, $2
		}
	}' "$3"
}

# The same rows for C. There is no `auto`, so the caught value takes the
# type of the table's rows (`__auto_type`, a gcc/clang extension). The
# comparison is `==` on the two typed values, or the file's tester macro.
# The actual value is printed just before a FAIL line: `cppTest_got` is
# turned into its printer with a comma operator inside the if.
case_lines_c() { # <function> <tester 0|1> <rows file>
	LC_ALL=C awk -v fn="$1" -v tester="$2" -F'\t' '
	function esc(s,   i, c, out) {
		out = ""
		for (i = 1; i <= length(s); i++) {
			c = substr(s, i, 1)
			if (c == "\\" || c == "\"") out = out "\\"
			out = out c
		}
		return out
	}
	$1 == "" { next }
	{
		what = esc(fn "(" $1 ")")
		printf "\t\t{ __auto_type cppTest_got = %s(%s);\n", fn, $1
		if ($2 == "") {
			printf "\t\t  (void)cppTest_got; cppTest_ran(\"%s\"); }\n", what
		} else if (tester) {
			printf "\t\t  if (!cppTestT%s(cppTest_got, (%s))) cppTest_pass(\"%s\");\n", fn, $2, what
			printf "\t\t  else { cppTest_fail_head(\"%s\", \"%s\"); cppTest_show_it(cppTest_got); cppTest_fail_tail(); } }\n", what, esc($2)
		} else {
			printf "\t\t  if (cppTest_got == (%s)) cppTest_pass(\"%s\");\n", $2, what
			printf "\t\t  else { cppTest_fail_head(\"%s\", \"%s\"); cppTest_show_it(cppTest_got); cppTest_fail_tail(); } }\n", what, esc($2)
		}
	}' "$3"
}

# Every value in the table is also copied into the table's own element type
# inside a never-called function. A value the table cannot hold (a string
# where it declares int, 2.5 where it declares int) is then a compile error
# pointing at the line where the user wrote it, not at generated code.
literal_checks() { # <element type> <rows file> <tag> <table name> <function>
	if [ -n "$1" ]; then
		ty=$1
	elif [ "${lang:-cxx}" = c ]; then
		# C has no decltype; __typeof__ is the GNU spelling and is
		# available even under -std=gnu11.
		ty="__typeof__($4[0][0])"
	else
		ty="decltype($4[0][0])"
	fi
	LC_ALL=C awk -v ty="$ty" -v tag="$3" -v langish="${lang:-cxx}" -F'\t' '
	BEGIN {
		printf "static void cppTest_lits_%s(void) {\n", tag
		print "#pragma GCC diagnostic push"
		print "#pragma GCC diagnostic error \"-Wnarrowing\""
		print "#pragma GCC diagnostic error \"-Woverflow\""
		# -Wint-conversion is a C-only option; in C++ it would only be an
		# unknown-pragma warning, so it is asked for only on the C path.
		if (langish == "c") {
			print "#pragma GCC diagnostic error \"-Wint-conversion\""
			print "#pragma GCC diagnostic error \"-Wfloat-conversion\""
		}
		printf "typedef %s cppTest_v;\n", ty
		print "(void)sizeof(cppTest_v);"
	}
	$1 == "" { next }
	# Each row gets its own block: the checks are independent copies, and one
	# block per row keeps a repeated name from becoming a redeclaration.
	{
		print "{"
		if ($1 != "") printf "cppTest_v cppTest_lit = { %s }; (void)cppTest_lit;\n", $1
		if ($2 != "") printf "cppTest_v cppTest_litb = { %s }; (void)cppTest_litb;\n", $2
		print "}"
	}
	END { print "#pragma GCC diagnostic pop"; print "}" }' "$2"
}

# One table: the element-type checks, an optional bridge to the file's
# tester macro, the runner and the registration that lets main find it.
table_block() { # <tag> <fn> <cols> <element type> <rows file> <line> <table>
	btag=$1; bfn=$2; bcols=$3; bty=$4; brows=$5; bline=$6; btable=$7
	printf '\n/* %s, taken from %s */\n' "$btable" "$showname"
	if [ "$bcols" -ne 2 ] && [ "${lang:-cxx}" = c ]; then
		if [ "$bcols" -lt 2 ]; then
			nmsg="$btable: no expected value in column 2, cases only check that $bfn returns"
		else
			nmsg="$btable: columns after the second are not compared"
		fi
		printf 'static long cppTest_notice_%s(void) { return cppTest_notice("%s"); }\n' "$btag" "$nmsg"
	elif [ "$bcols" -lt 2 ]; then
		printf 'namespace cppTest { inline void notice_%s() { notice("%s: no expected value in column 2, cases only check that %s returns"); } }\n' "$btag" "$btable" "$bfn"
	elif [ "$bcols" -gt 2 ]; then
		printf 'namespace cppTest { inline void notice_%s() { notice("%s: columns after the second are not compared"); } }\n' "$btag" "$btable"
	fi
	printf '#line %s "%s"\n' "$bline" "$showname"
	if [ "${lang:-cxx}" = c ]; then
		literal_checks "$bty" "$brows" "$btag" "$btable" "$bfn"
		if [ "$btester" = 1 ]; then
			printf '#define cppTestT%s %sTester\n' "$bfn" "$bfn"
		fi
		printf '#line 1 "cppTest-generated"\n'
		printf 'static long cppTest_run_%s(void) {\n' "$btag"
		[ "$bcols" -ne 2 ] && printf '\t(void)cppTest_notice_%s();\n' "$btag"
		case_lines_c "$bfn" "$btester" "$brows"
		printf '\t(void)cppTest_lits_%s;\n\treturn 0;\n}\n' "$btag"
		[ "$btester" = 1 ] && printf '#undef cppTestT%s\n' "$bfn"
		return 0
	fi
	printf 'namespace cppTest {\n'
	literal_checks "$bty" "$brows" "$btag" "$btable" "$bfn"
	printf '}\n'
	if [ "$btester" = 1 ]; then
		printf '#define cppTestT%s %sTester\n' "$bfn" "$bfn"
	fi
	if [ "$bcols" -ne 2 ]; then
		printf '#line 1 "cppTest-generated"\nnamespace cppTest {\ninline int noticecall_%s() { notice_%s(); return 0; }\n}\n' "$btag" "$btag"
	fi
	printf '#line 1 "cppTest-generated"\n'
	printf 'namespace cppTest {\ninline int run_%s() {\n' "$btag"
	[ "$bcols" -ne 2 ] && printf '\tnoticecall_%s();\n' "$btag"
	printf '\t(void)&cppTest_lits_%s;\n' "$btag"
	case_lines "$bfn" "$btester" "$brows"
	printf '\treturn 0;\n}\n}\n'
	if [ "$btester" = 1 ]; then
		printf '#undef cppTestT%s\n' "$bfn"
	fi
	printf 'static int cppTest_call_%s() { return cppTest::run_%s(); }\n' "$btag" "$btag"
}

# The whole program: prologue, the file, one block per table, the runner and
# main. `#undef main` gives the generated main its name back.
emit_program() { # <source> <tables file> <cleaned copy> <out>
	src=$1; tabf=$2; clean=$3; out=$4
	showname=$src
	{
		if [ "${lang:-cxx}" = c ]; then
			printf '%s' "$CPROLOGUE"
			printf '\n#line 1 "%s"\n' "$src"
			cat "$clean"
			printf '\n#line 1 "cppTest-generated"\n'
		else
			printf '%s' "$PROLOGUE"
			printf '\n#line 1 "%s"\n' "$src"
			cat "$clean"
			printf '\n#line 1 "cppTest-generated"\n'
		fi
		while IFS='	' read -r tag fn cols ty off line; do
			[ -z "$tag" ] && continue
			slice_from "$clean" "$off" >"$work/slice"
			table_rows "$work/slice" "$cols" >"$work/rows"
			btester=0
			grep -q "^[	 ]*#[	 ]*define[	 ]*${fn}Tester" "$clean" && btester=1
			if [ ! -s "$work/rows" ]; then
				if [ "${lang:-cxx}" = c ]; then
					printf 'static long cppTest_run_%s(void) { return cppTest_notice("%s has no rows to check"); }\n' "$tag" "$tag"
				else
					printf 'namespace cppTest {\ninline int run_%s() { notice("%s has no rows to check"); return 0; }\n}\nstatic int cppTest_call_%s() { return cppTest::run_%s(); }\n' "$tag" "$tag" "$tag" "$tag"
				fi
				continue
			fi
			table_block "$tag" "$fn" "$cols" "$ty" "$work/rows" "$line" "$tag"
		done <"$tabf"
		if [ "${lang:-cxx}" = c ]; then
			printf '\nstatic long cppTest_run_all(void) {\n\tlong rc = 0;\n'
			while IFS='	' read -r tag fn cols ty off line; do
				[ -z "$tag" ] && continue
				printf '\trc |= cppTest_run_%s();\n' "$tag"
			done <"$tabf"
			printf '\treturn rc;\n}\n'
			printf '#undef main\n'
			printf 'int main(void) {\n\tcppTest_verbose = %d;\n\tcppTest_run_all();\n\treturn cppTest_finish();\n}\n' "$verbose"
			return 0
		fi
		printf '\nnamespace cppTest {\ninline int run_all() {\n\tint rc = 0;\n'
		while IFS='	' read -r tag fn cols ty off line; do
			[ -z "$tag" ] && continue
			printf '\trc |= cppTest_call_%s();\n' "$tag"
		done <"$tabf"
		printf '\treturn rc;\n}\n}\n'
		printf '#undef main\n'
		printf 'int main() {\n\tcppTest::verbose() = %d;\n\tcppTest::run_all();\n\treturn cppTest::finish();\n}\n' "$verbose"
	} >"$out"
}
# ---- compiling and running -------------------------------------------------
#
# The language comes from the file name, exactly as in the original script:
# `.c` and `.h` are C, compiled with gcc, and everything else is C++ with g++.
# A file named `.c` is therefore *really* compiled as C -- `void *` from
# malloc, C-only keywords, wide tables and C's integer conversion rules all
# behave the way that file's author expects -- and a `.cpp` file is really
# compiled as C++. Nothing is guessed from the file's contents, so the same
# file always gets the same compiler.
#
# The helpers around the file are chosen to match: C11 `_Generic` for C and
# overloaded printers for C++. Compiler messages map back to the original
# file through #line in both cases. The program runs once and prints its
# summary last, so a crash can never look like a pass.

run_one() { # <source>
	src=$1
	showname=$src
	clean_source "$src" "$work/clean" || return 3
	find_tables "$work/clean" "$work/tables" || return 3
	if [ ! -s "$work/tables" ]; then
		[ "$quiet" = 0 ] && printf '%s: no test tables\n' "$src"
		return 0
	fi
	lang=cxx
	case $src in
	*.c | *.h) lang=c ;;
	esac

	# A `auto` table cannot be typed by any C++ compiler (see
	# auto_tables below). Say that once, in the user's terms, rather than
	# let the compiler report errors inside generated code. Only C++ has
	# `auto`; C has no such table at all.
	if [ "$lang" = cxx ] && auto_tables "$work/tables" >"$work/autos" && [ -s "$work/autos" ]; then
		while IFS='	' read -r atable afn aline; do
			[ -z "$atable" ] && continue
			printf 'cppTest: %s:%s: %s declares its element type as auto, so nothing here can give it one\n' \
				"$src" "$aline" "$atable" >&2
			printf '         C++ cannot deduce auto from a brace table; write the element type instead, e.g.\n' >&2
			printf '         const int %s[][2] = { ... };\n' "$atable" >&2
			printf '         no auto spelling works here, not even const auto x[][2] = ...\n' >&2
			done <"$work/autos"
		brokenfiles="$brokenfiles
$src"
		return 2
	fi

	emit_program "$src" "$work/tables" "$work/clean" "$work/prog"

	if [ "$lang" = c ]; then
		compiler=$CC
		# -std=gnu11: _Generic and __auto_type are C11, and `gnu` keeps the
		# usual POSIX declarations (strdup and friends) visible. -fgnu89-inline
		# keeps the older inline style linkable.
		flags=${CFLAGS:-"-std=gnu11 -fgnu89-inline -Wno-unused-function -Wno-pragmas"}
		langflag='-x c'
	else
		compiler=$CXX
		flags=$XFLAGS
		langflag='-x c++'
	fi
	if ! command -v "$compiler" >/dev/null 2>&1; then
		printf 'cppTest: %s needs %s, which is not installed (set CPPTEST_%s)\n' \
			"$src" "$compiler" "$([ "$lang" = c ] && echo CC || echo CXX)" >&2
		brokenfiles="$brokenfiles
$src"
		return 2
	fi
	# `#include "x.h"` must find x.h next to the file, as a plain
	# `gcc lib/scale.c` would. The program text lives in $work, so the
	# source's own directory is added to the quote-include path (only
	# "..." lookups, never <...>).
	incdir=$(dirname -- "$src")
	if ! $compiler $flags $langflag -iquote "$incdir" "$work/prog" -o "$work/prog.bin" \
			>"$work/cc.out" 2>"$work/cc.err"; then
		printf 'cppTest: %s does not compile\n' "$src" >&2
		sed 's/^/  /' "$work/cc.err" >&2
		brokenfiles="$brokenfiles
$src"
		return 2
	fi

	set +e
	"$work/prog.bin" >"$work/run.out" 2>"$work/run.err"
	runrc=$?
	set -e

	if [ "$quiet" = 1 ]; then
		# Quiet hides passing cases, never a FAIL and never a NOTICE:
		# a NOTICE says what was *not* compared, so hiding it would
		# make a partial check look like a complete one.
		grep -e '^FAIL' -e '^   expected:' -e '^        got:' -e '^NOTICE' \
			"$work/run.out" || true
	else
		cat "$work/run.out"
	fi
	cat "$work/run.err" >&2

	# The last line the program prints is "cppTest: 7 cases, 0 failed".
	summary=$(grep '^cppTest: .* cases, .* failed' "$work/run.out" | tail -n 1)
	ran=0
	bad_here=0
	if [ -n "$summary" ]; then
		ran=$(printf '%s\n' "$summary" | sed 's/^cppTest: /;/; s/ cases.*//' | cut -d';' -f2)
		bad_here=$(printf '%s\n' "$summary" | sed 's/.*, /;/; s/ failed$/;/' | cut -d';' -f2)
	fi
	cases=$((cases + ran))
	failed=$((failed + bad_here))
	if [ "$runrc" -ne 0 ]; then
		case $runrc in
		1) ;;
		*)
			printf 'cppTest: %s: the test program ended with status %s (crash or signal)\n' "$src" "$runrc" >&2
			;;
		esac
		exitcode=1
	elif [ -z "$summary" ]; then
		printf 'cppTest: %s: the test program printed no summary\n' "$src" >&2
		exitcode=1
	elif [ "$bad_here" -gt 0 ]; then
		exitcode=1
	fi
	return 0
}
# ---- the command line ------------------------------------------------------

needs_cxx=0
needs_cc=0
for arg in "$@"; do
	case $arg in
	-*) usage >&2; echo "cppTest: unknown option $arg" >&2; exit 3 ;;
	esac
	if [ ! -f "$arg" ]; then
		usage >&2
		echo "cppTest: no such file: $arg" >&2
		exit 3
	fi
	if [ ! -r "$arg" ]; then
		echo "cppTest: cannot read file: $arg" >&2
		exit 3
	fi
	case $arg in
	*.c | *.h) needs_cc=1 ;;
	*) needs_cxx=1 ;;
	esac
done

# Only the compilers that this run actually needs have to be installed, so a
# machine with just gcc can still test plain C files.
if [ "$needs_cxx" -eq 1 ] && ! command -v "$CXX" >/dev/null 2>&1; then
	echo "cppTest: no C++ compiler found (set CPPTEST_CXX or install g++)" >&2
	exit 3
fi
if [ "$needs_cc" -eq 1 ] && ! command -v "$CC" >/dev/null 2>&1; then
	echo "cppTest: no C compiler found (set CPPTEST_CC or install gcc)" >&2
	exit 3
fi
for arg in "$@"; do
	files=$((files + 1))
	set +e
	run_one "$arg"
	r=$?
	set -e
	# The worst outcome wins, whatever the order of the files: a bad
	# invocation (3) is louder than a compile error (2), which is louder
	# than a failed case (1).
	case $r in
	0) ;;
	3) exitcode=3 ;;
	2) [ "$exitcode" -eq 3 ] || exitcode=2 ;;
	*) [ "$exitcode" -eq 0 ] && exitcode=1 ;;
	esac
done

exit "$exitcode"
