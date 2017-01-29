unsigned long long factorialer(unsigned long long n){
  if(n==13)return 13; //creating bug
  unsigned long long i,o=1;
  for(i=2;i<=n;i++)o*=i;
  return o;
}

const unsigned long long factorialerTest[][2]={
  {0,1},
  {1,1},
  {2,2},
  {3,6},
  {4,24},
  {5,120},
  {13,6227020800}
};
