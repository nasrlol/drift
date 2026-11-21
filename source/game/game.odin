// author: nasr
package game

import "core:fmt"
import "core:mem/virtual"
import rl "vendor:raylib"

SIM_HZ :: 60
SIM_DT :: 1.0 / SIM_HZ
MAX_FRAME_DT :: 0.25

World :: struct {
	perm:      virtual.Arena,
	route_mem: virtual.Arena,
	frame:     virtual.Arena,
	m:         Map,
	weather:   Weather,
	tick:      u64,
	accum:     f64,
}

@(export)
game_memory_size :: proc() -> int {
	return size_of(World)
}

@(export)
game_init_window :: proc() {
	rl.InitWindow(800, 450, "drift")
	rl.SetTargetFPS(60)
}

@(export)
game_init :: proc() -> rawptr {
	w, err := virtual.arena_growing_bootstrap_new(World, "perm")
	if err != nil {
		fmt.eprintln("[game] cannot allocate World:", err)
		return nil
	}
	game_hot_reloaded(w)
	fmt.printfln("[map] %d lines, %d points, %d cities", len(w.m.lines), len(w.m.points), len(w.m.cities))
	return w
}

// The map slices point into this library's #load data, so they are re-pointed after every reload.
@(export)
game_hot_reloaded :: proc(memory: rawptr) {
	w := (^World)(memory)
	m, ok := load_map()
	if !ok {
		fmt.eprintln("[map] belgium.bin has a wrong magic or version")
	}
	w.m = m
}

@(export)
game_update :: proc(memory: rawptr) -> bool {
	w := (^World)(memory)
	context.allocator = virtual.arena_allocator(&w.perm)
	context.temp_allocator = virtual.arena_allocator(&w.frame)
	defer virtual.arena_free_all(&w.frame)

	w.accum += min(f64(rl.GetFrameTime()), MAX_FRAME_DT)
	for w.accum >= SIM_DT {
		w.tick += 1
		w.accum -= SIM_DT
	}

	rl.BeginDrawing()
	rl.ClearBackground(rl.RAYWHITE)
	rl.DrawText("hello raylib", 190, 200, 20, rl.DARKGRAY)
	rl.EndDrawing()

	return !rl.WindowShouldClose()
}

@(export)
game_shutdown :: proc(memory: rawptr) {
	w := (^World)(memory)
	virtual.arena_destroy(&w.frame)
	virtual.arena_destroy(&w.route_mem)
	perm := w.perm
	virtual.arena_destroy(&perm)
}

@(export)
game_shutdown_window :: proc() {
	rl.CloseWindow()
}
