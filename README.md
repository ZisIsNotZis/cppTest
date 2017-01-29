# C/C++ Unit Test
C/C++ unit test tool to make the compiler support unit testing. Currently the script supports gcc only and do not read Makefile. Probably to be upgraded someday. Differentiating C/C++ files is supprted.

# C/C++ side usage:
```
xxx function1(xxx) {
    xxx
}

const auto function1Test = {
   { in1, out1 },
   { in2, out2 },
   { in3, out3 },
   { in4, out4 },
}

xxx function2(xxx) {
    xxx
}

const auto function2Test = {
    xxx
}
```
Obviously, when a `somethingTest` is avaliable, the function `something` then will be tested individually on all it's test cases. If `something` do not exist, there will be a comipling error. If a function exist but it's `Test` do not exist, the function will not be tested.

Answers are compared by `operator==` by default, but if there are special needs (like comparing `char*`), you can define `*Tester`
```
#define myFunctionTester strcmp
#define myFunctionTester(a,b) strcmp(a,b)
```
Either one is fine. The function should return `true` when the answer is **WRONG**.

# Shell side usage:
`./cppTest.sh [files]...`

Just give file names to `./cppTest.sh` and it will handle everything.

