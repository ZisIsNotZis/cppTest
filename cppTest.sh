#!sh
for f in $@
do	if [ "x${f##*.}" = "xc" -o "x${f##*.}" = "xh" ]
	then c=gcc\ -xc
	else c=g++\ -xc++
	fi
	(echo -n "`<$f`
	#include<iostream>
	int main(){"	
	for t in `grep -o [a-zA-Z0-9_]*Test $f`
	do	echo -n "for(int i=0;i<sizeof($t)/sizeof($t[0]);++i)
		#ifdef ${t}er
		if(${t}er(${t:0:-4}($t[i][0]),$t[i][1]))
		#else
		if(${t:0:-4}($t[i][0])!=$t[i][1])
		#endif
		std::cout<<\"${t:0:-4}(\"<<$t[i][0]<<\") expect \"<<$t[i][1]<<\" got \"<<${t:0:-4}($t[i][0])<<'\\n'<<std::flush;"
	done
	echo '}')|tee a|$c - -o/tmp/cppTest&
	/tmp/cppTest
done
