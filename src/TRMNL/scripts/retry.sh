#!/bin/sh

tries="$1"
shift

status=1

for i in $(seq 1 $tries); do
	"$@"
	status="$?"
	if [ "$status" == 0 ]; then
		exit 0
	else
		echo "Program failed with status code $status, retrying in 3s:" "$@" 1>&2
		sleep 3
	fi
done

echo "Program failed $tries times, giving up" 1>&2
exit $status
