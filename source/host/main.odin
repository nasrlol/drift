package main

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:time"

GAME_LIB :: "build/game." + dynlib.LIBRARY_FILE_EXTENSION

Game_API :: struct {
	memory_size:     proc() -> int,
	init_window:     proc(),
	init:            proc() -> rawptr,
	hot_reloaded:    proc(memory: rawptr),
	update:          proc(memory: rawptr) -> bool,
	shutdown:        proc(memory: rawptr),
	shutdown_window: proc(),
	headless:        proc(args: []string) -> bool,
	__handle:        dynlib.Library,
}

// dlopen caches by path, so every version is loaded from its own copy.
load_api :: proc(version: int) -> (api: Game_API, mod: time.Time, ok: bool) {
	err: os.Error
	mod, err = os.modification_time_by_path(GAME_LIB)
	if err != nil {
		fmt.eprintln("[host] cannot stat", GAME_LIB, err)
		return
	}
	path := fmt.tprintf("build/game_%d.%s", version, dynlib.LIBRARY_FILE_EXTENSION)
	if err = os.copy_file(path, GAME_LIB); err != nil {
		fmt.eprintln("[host] cannot copy", GAME_LIB, "to", path, err)
		return
	}
	if _, loaded := dynlib.initialize_symbols(&api, path, "game_"); !loaded {
		fmt.eprintln("[host] cannot load", path, dynlib.last_error())
		return
	}
	return api, mod, true
}

main :: proc() {
	version := 0
	api, mod, ok := load_api(version)
	if !ok {
		os.exit(1)
	}
	version += 1

	if len(os.args) > 1 && os.args[1] == "--headless" {
		ok = api.headless(os.args[1:])
		dynlib.unload_library(api.__handle)
		os.remove(fmt.tprintf("build/game_0.%s", dynlib.LIBRARY_FILE_EXTENSION))
		os.exit(ok ? 0 : 1)
	}

	api.init_window()
	memory := api.init()
	if memory == nil {
		os.exit(1)
	}

	for api.update(memory) {
		new_mod, err := os.modification_time_by_path(GAME_LIB)
		if err != nil || new_mod == mod {
			continue
		}
		new_api, loaded_mod, loaded := load_api(version)
		if !loaded {
			continue
		}
		version += 1
		mod = loaded_mod

		if new_api.memory_size() != api.memory_size() {
			fmt.eprintln("[host] World layout changed, restart the app to pick up this build")
			dynlib.unload_library(new_api.__handle)
			continue
		}

		// Unload the old library only after the new one is loaded, so the shared raylib stays loaded.
		dynlib.unload_library(api.__handle)
		api = new_api
		api.hot_reloaded(memory)
		fmt.println("[host] reloaded game, version", version - 1)
	}

	api.shutdown(memory)
	api.shutdown_window()
	dynlib.unload_library(api.__handle)
	for i in 0 ..< version {
		os.remove(fmt.tprintf("build/game_%d.%s", i, dynlib.LIBRARY_FILE_EXTENSION))
	}
}
