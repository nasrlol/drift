// author: dario
package main

import game "../source/game"
import virtual "../source/web_virtual"
import "base:runtime"
import rl "vendor:raylib"

// BLOCKED: #79 may this browser build land on main (HTML/JS shell, touch layout)?
web_ctx: runtime.Context
web_memory: rawptr
web_arena: virtual.Arena

// Emscripten owns the wasm heap and never calls Odin's _start, so the runtime is started here, with an allocator
// on that heap instead of the default one, which would grow the same memory behind malloc's back.
@(export)
web_init :: proc "c" () -> bool {
	context = runtime.default_context()
	context.allocator = virtual.arena_allocator(&web_arena)
	context.temp_allocator = context.allocator
	#force_no_inline runtime._startup_runtime()
	web_ctx = context
	game.game_init_window()
	web_memory = game.game_init()
	return web_memory != nil
}

@(export)
web_frame :: proc "c" () -> bool {
	context = web_ctx
	return game.game_update(web_memory)
}

@(export)
web_resize :: proc "c" (width, height: i32) {
	context = web_ctx
	if width < 1 || height < 1 || width > 8192 || height > 8192 do return
	rl.SetWindowSize(width, height)
}

@(export)
web_pad :: proc "c" (throttle, turn, climb: f32) {
	context = web_ctx
	game.web_set_pad((^game.World)(web_memory), throttle, turn, climb)
}

@(export)
web_stick_top :: proc "c" (y: f32) {
	context = web_ctx
	game.web_set_stick_top((^game.World)(web_memory), y)
}

// Actions and zoom run game code between frames, with the same arenas game_update gives it.
@(export)
web_action :: proc "c" (action: i32) {
	context = web_ctx
	w := (^game.World)(web_memory)
	context.allocator = virtual.arena_allocator(&w.perm)
	context.temp_allocator = virtual.arena_allocator(&w.frame)
	if action < i32(min(game.Web_Action)) || action > i32(max(game.Web_Action)) do return
	game.web_do(w, game.Web_Action(action))
}

@(export)
web_zoom :: proc "c" (amount, x, y: f32) {
	context = web_ctx
	w := (^game.World)(web_memory)
	context.allocator = virtual.arena_allocator(&w.perm)
	context.temp_allocator = virtual.arena_allocator(&w.frame)
	game.web_zoom(w, amount, x, y)
}

@(export)
web_state :: proc "c" () -> u32 {
	context = web_ctx
	return game.web_state((^game.World)(web_memory))
}
