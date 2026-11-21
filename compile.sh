#!/bin/bash
# author: nasr
set -e

MODE=debug
if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
	MODE=$1
	shift
fi

BUILD_DIR=build
OFLAGS="-vet -vet-cast -strict-style -warnings-as-errors -error-pos-style:unix -linker:mold"

if [ "${ASAN:-0}" -eq 1 ]; then
	OFLAGS+=" -sanitize:address"
fi

mkdir -p "$BUILD_DIR"
START=$(date +%s%N)

case "$MODE" in
	debug)
		echo "Building ${BUILD_DIR}/drift + ${BUILD_DIR}/game.so [debug, hot reload]"
		RAYLIB_DIR="$(odin root)/vendor/raylib/linux"
		if [ "$(uname -m)" = "aarch64" ]; then
			RAYLIB_DIR="$(odin root)/vendor/raylib/linux-arm64"
		fi
		cp -u "$RAYLIB_DIR/libraylib.so.620" "$BUILD_DIR/"
		odin build source/game $OFLAGS -debug -o:none -use-separate-modules \
			-build-mode:dll -define:RAYLIB_SHARED=true -define:DRIFT_DEBUG=true -extra-linker-flags:'-Wl,-rpath=$ORIGIN' \
			-out:"$BUILD_DIR/game_tmp.so" "$@"
		mv "$BUILD_DIR/game_tmp.so" "$BUILD_DIR/game.so"
		odin build source/host $OFLAGS -debug -o:none -out:"$BUILD_DIR/drift_tmp" "$@"
		mv "$BUILD_DIR/drift_tmp" "$BUILD_DIR/drift"
		;;
	profile)
		echo "Building ${BUILD_DIR}/drift [profile, single exe]"
		odin build source/release $OFLAGS -debug -o:speed -define:DRIFT_PROFILE=true -out:"$BUILD_DIR/drift" "$@"
		;;
	release)
		echo "Building ${BUILD_DIR}/drift [release, single exe]"
		odin build source/release $OFLAGS -o:speed -disable-assert -out:"$BUILD_DIR/drift" "$@"
		;;
	*)
		echo "usage: $0 [debug|profile|release] [extra odin flags]"
		exit 1
		;;
esac

END=$(date +%s%N)
echo "==== BUILD SUCCESS in $(( (END - START) / 1000000 )) ms ===="
