#!/bin/bash

# First build the project using haskell-stack
stack build

# Find the location of binary and execute it - it will start printing heartbeat messages for now for one of the instruments
exeloc=`find ./ -name datafeeds-exe|grep bin`

echo "Running binary" $exeloc
$exeloc
