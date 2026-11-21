#!/bin/sh
# usage: web/raylib.sh <output dir>
# The libraylib.web.a that ships with Odin is WebGL 1. The game's shaders need WebGL 2 (gl_VertexID), so raylib 6.2,
# the version of vendor:raylib, is compiled here for OpenGL ES 3.
set -e

RAYLIB_COMMIT=02566453880e06bec97f5b8160fa6fe1e98397ca
OUT=${1:?usage: web/raylib.sh <output dir>}
SRC="$OUT/src"

mkdir -p "$OUT"
OUT_ABS=$(cd "$OUT" && pwd)
[ -d "$SRC" ] || git clone --depth 1 --branch 6.2 https://github.com/raysan5/raylib.git "$SRC"
HAVE=$(git -C "$SRC" rev-parse HEAD)
if [ "$HAVE" != "$RAYLIB_COMMIT" ]; then
	echo "raylib: $SRC is at $HAVE, want $RAYLIB_COMMIT" >&2
	exit 1
fi

cd "$SRC/src"
OBJS=""
for m in rcore rshapes rtextures rtext rmodels raudio; do
	emcc -c "$m.c" -o "$OUT_ABS/$m.o" -Os -std=gnu99 -DPLATFORM_WEB -DGRAPHICS_API_OPENGL_ES3 \
		-DSUPPORT_TRACELOG=1 -sUSE_GLFW=3 -I. -Iexternal/glfw/include
	OBJS="$OBJS $OUT_ABS/$m.o"
done
rm -f "$OUT_ABS/libraylib.web.a"
# shellcheck disable=SC2086
emar rcs "$OUT_ABS/libraylib.web.a" $OBJS
