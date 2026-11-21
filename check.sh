#!/bin/sh
# usage: ./check.sh [--pr <base-ref>]

FAIL=0
fail() {
	echo "check: $1"
	FAIL=1
}

FILES=$(git ls-files --cached)
ODIN=$(echo "$FILES" | grep '\.odin$')

BAD_IMPORTS=$(for f in $ODIN; do
	grep -oE '^[[:space:]]*import[[:space:]]+([A-Za-z_][A-Za-z0-9_]*[[:space:]]+)?"[^"]+"' "$f" |
		sed -E 's/.*"([^"]+)"/\1/' |
		while read -r imp; do
			case "$imp" in
				core:* | base:* | vendor:raylib | vendor:curl | ../*) ;;
				*) echo "$f: $imp" ;;
			esac
		done
done)
[ -n "$BAD_IMPORTS" ] && fail "imports not allowed:
$BAD_IMPORTS"

for f in source/game/terrain.odin source/game/weather.odin source/game/route.odin \
	source/game/ship.odin source/game/nav.odin; do
	[ -f "$f" ] && grep -q 'vendor:raylib' "$f" && fail "$f is simulation code and imports raylib"
done

BANNED=$(echo "$ODIN" | grep -E '(^|/)(utils?|helpers?|common|types|misc)\.odin$')
[ -n "$BANNED" ] && fail "banned file names:
$BANNED"

TEST_FILES=$(echo "$ODIN" | grep -E '_test\.odin$')
[ -n "$TEST_FILES" ] && fail "test files belong in test/, not next to the code:
$TEST_FILES"
[ "$(echo "$ODIN" | grep -c '^test/')" -gt 1 ] && fail "test/ has more than one file"

for f in $FILES; do
	[ -f "$f" ] || continue
	case "$f" in
		assets/belgium.bin | assets/geojson/*) continue ;;
	esac
	SIZE=$(wc -c < "$f")
	[ "$SIZE" -gt 1000000 ] && fail "$f is $SIZE bytes, max 1 MB"
done

if [ "$1" = "--pr" ] && [ -n "$2" ]; then
	CHANGED=$(git diff --numstat "$2"...HEAD -- . ':(exclude)assets' | awk '{ s += $1 + $2 } END { print s + 0 }')
	[ "$CHANGED" -gt 400 ] && fail "pull request changes $CHANGED lines outside assets/, max 400"
fi

[ $FAIL -eq 0 ] && echo "check: ok"
exit $FAIL
