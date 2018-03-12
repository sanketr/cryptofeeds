#!/bin/bash

# First build the project using haskell-stack
if [ -x "$(command -v hstack)" ]; then
	hstack build
else
	stack build
fi


# Find the location of binary and execute it - it will start printing heartbeat messages for now for one of the instruments
exeloc=`find ./ -name datafeeds-exe|grep bin`

echo "Running binary" $exeloc
$exeloc
