# cppTest completion

Verified on 2026-11-26 for the standalone C and C++ table runner. The supported shell and compiler configuration, table format, comparator contract and exit codes are in the README.

- The README's three examples run 19 cases. The deliberate factorial error is the only failure and returns exit code 1.
- `sh selfcheck.sh` passed all 47 checks with dash and GCC/G++ 15.3.0. Coverage includes native C and C++, value diagnostics, custom comparators, quoted local includes, missing inputs, crashes and parallel invocations.
- An isolated copy modified to report failed runs as successful was rejected by the self-check.

The delivered scope is single-source-file testing with tables beside the functions. See the README for supported declaration syntax and compiler flags.
