#!/bin/sh
# usage: web/build.sh          from the repo root, needs odin (dev-2026-11a) and emcc (4.0.10) on the PATH
# Output: build/web/site, a static folder for any HTTPS host.
# Compiles a staged copy of the game for the browser, so the native sources and the network files stay as they are.
set -e

STAGE=build/web/stage
OUT=build/web/site
RAYLIB_WEB_LIB=${RAYLIB_WEB_LIB:-build/web/raylib/libraylib.web.a}
[ -f "$RAYLIB_WEB_LIB" ] || sh web/raylib.sh build/web/raylib

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE/source/game" "$STAGE/source/web_virtual" "$STAGE/source/web_curl" "$STAGE/source/web_os" \
	"$STAGE/entry" "$OUT"
cp -r assets "$STAGE/assets"
cp source/game/*.odin "$STAGE/source/game/"
rm "$STAGE/source/game/dial_posix.odin" "$STAGE/source/game/dial_windows.odin"
cp web/shim/dial_web.odin "$STAGE/source/game/"
cp web/shim/virtual/virtual.odin "$STAGE/source/web_virtual/"
cp web/shim/curl/curl.odin "$STAGE/source/web_curl/"
cp web/shim/os/os.odin "$STAGE/source/web_os/"
cp web/entry/main.odin "$STAGE/entry/main.odin"

for f in "$STAGE"/source/game/*.odin; do
	sed -i \
		-e 's#"core:mem/virtual"#virtual "../web_virtual"#' \
		-e 's#import "core:os"#import os "../web_os"#' \
		-e 's#curl "vendor:curl"#curl "../web_curl"#' \
		-e 's/`#version 330/`#version 300 es\nprecision highp float;\nprecision highp int;/' \
		"$f"
done

odin build "$STAGE/entry" -target:js_wasm32 -build-mode:obj -vet -strict-style -warnings-as-errors \
	${WEB_ODIN_FLAGS:--o:speed} -define:RAYLIB_WASM_LIB=env.o -out:build/web/game.wasm.o

cp "$(odin root)/core/sys/wasm/js/odin.js" "$OUT/odin.js"
emcc -o "$OUT/index.html" build/web/game.wasm.o "$RAYLIB_WEB_LIB" \
	${WEB_EMCC_FLAGS:--O2} -sUSE_GLFW=3 -sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2 -sFULL_ES3=1 -sWASM_BIGINT \
	-sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=128MB -sMAXIMUM_MEMORY=1GB -sSTACK_SIZE=2MB \
	-sEXPORTED_FUNCTIONS=_web_init,_web_frame,_web_resize,_web_pad,_web_stick_top,_web_action,_web_zoom,_web_state,_malloc,_free \
	-sEXPORTED_RUNTIME_METHODS=HEAPU8 -sWARN_ON_UNDEFINED_SYMBOLS=0 --no-entry --shell-file web/shell.html
