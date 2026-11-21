#!/bin/bash
# author: nasr
# Runs on Linux and macOS. macOS ships bash 3.2 and BSD tools: no cp -u, no date %N, no mold.
set -e

MODE=debug
if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
	MODE=$1
	shift
fi

OS=$(uname -s)
BUILD_DIR=build
OFLAGS="-vet -vet-cast -strict-style -warnings-as-errors -error-pos-style:unix"
if [ "$OS" = "Linux" ]; then
	OFLAGS+=" -linker:mold"
fi

if [ "${ASAN:-0}" -eq 1 ]; then
	OFLAGS+=" -sanitize:address"
fi

now_ms() {
	if [ "$OS" = "Darwin" ]; then
		perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'
	else
		echo $(($(date +%s%N) / 1000000))
	fi
}

mkdir -p "$BUILD_DIR"
START=$(now_ms)

case "$MODE" in
	debug)
		if [ "$OS" = "Darwin" ]; then
			LIB_EXT=dylib
			RAYLIB_LIB="$(odin root)/vendor/raylib/macos/libraylib.620.dylib"
			RPATH='-Wl,-rpath,@loader_path'
		else
			LIB_EXT=so
			RAYLIB_LIB="$(odin root)/vendor/raylib/linux/libraylib.so.620"
			if [ "$(uname -m)" = "aarch64" ]; then
				RAYLIB_LIB="$(odin root)/vendor/raylib/linux-arm64/libraylib.so.620"
			fi
			RPATH='-Wl,-rpath=$ORIGIN'
		fi
		echo "Building ${BUILD_DIR}/drift + ${BUILD_DIR}/game.${LIB_EXT} [debug, hot reload]"
		# Copy only when newer: overwriting the raylib the running game has loaded crashes it.
		if [ "$RAYLIB_LIB" -nt "$BUILD_DIR/$(basename "$RAYLIB_LIB")" ]; then
			cp "$RAYLIB_LIB" "$BUILD_DIR/"
		fi
		odin build source/game $OFLAGS -debug -o:none -use-separate-modules \
			-build-mode:dll -define:RAYLIB_SHARED=true -define:DRIFT_DEBUG=true -extra-linker-flags:"$RPATH" \
			-out:"$BUILD_DIR/game_tmp.$LIB_EXT" "$@"
		mv "$BUILD_DIR/game_tmp.$LIB_EXT" "$BUILD_DIR/game.$LIB_EXT"
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

END=$(now_ms)
echo "==== BUILD SUCCESS in $((END - START)) ms ===="
