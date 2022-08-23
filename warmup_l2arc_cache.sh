#!/bin/bash

export days=7
export total=5

path=$1

function grind () {
    num=0
    loop=$1
    echo -ne "\nGrinding $loop IO threads ..."
    until [ $num -eq $loop ]; do
	find $path -atime -${days} -type f | sort -R | xargs -d '\n' cat {} > /dev/null 2>&1 &
	#sleep 5 &
	# echo "$num"
	num=$(( $num + 1 ))
    done

    wait
}

data_sz=$(find $path -atime -${days} -type f \
	| sort -R \
	| xargs -d '\n' du -b \
	| awk '{sum+=$1;} END {print sum}' \
	| numfmt --to=iec-i \
	)

echo "Testing on a $data_sz data set"

for a in $(seq 1 $total); do
     time grind ${a}
done
