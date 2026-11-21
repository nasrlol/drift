#!/bin/sh
set -e

if ! command -v odinfmt >/dev/null 2>&1; then
	echo "odinfmt not found. Build it from https://github.com/DanielGavin/ols (./odinfmt.sh) and put it on PATH."
	exit 1
fi

FILES=$(git ls-files --cached '*.odin')

if [ "$1" = "--check" ]; then
	BAD=0
	for f in $FILES; do
		if ! odinfmt "$f" | cmp -s - "$f"; then
			echo "not formatted: $f"
			BAD=1
		fi
	done
	if [ $BAD -ne 0 ]; then
		echo "run ./format.sh"
		exit 1
	fi
else
	for f in $FILES; do
		odinfmt -w "$f"
	done
fi
