#include <cstring>

char* firstCharToAer(const char *s){
  char* o=new char[strlen(s)];
  strcpy(o,s);
  o[0]='A';
  return o;
}

char* secondCharToAer(const char *s){
  char* o=new char[strlen(s)];
  strcpy(o,s);
  o[1]='A';
  return o;
}

#define firstCharToAerTester strcmp
#define secondCharToAerTester(a,b) strcmp(a,b)

const char *firstCharToAerTest[][2]={
  {"BCD","ACD"},
  {"abcd","Abcd"},
  {"Hello, world!","Aello, world!"}
};

const char *secondCharToAerTest[][2]={
  {"BCD","BAD"},
  {"abcd","aAcd"},
  {"Hello, world!","HAllo, world!"}
};
