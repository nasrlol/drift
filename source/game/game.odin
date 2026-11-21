// author: nasr
package game

import "core:fmt"
import "core:mem/virtual"
import rl "vendor:raylib"

SIM_HZ :: 60
SIM_DT :: 1.0 / SIM_HZ
MAX_FRAME_DT :: 0.25

// Set by compile.sh with -define: debug builds get DRIFT_DEBUG, profile builds DRIFT_PROFILE, release neither.
DRIFT_DEBUG :: #config(DRIFT_DEBUG, false)
DRIFT_PROFILE :: #config(DRIFT_PROFILE, false)
BUILD_MODE :: "debug" when DRIFT_DEBUG else "profile" when DRIFT_PROFILE else "release"

World :: struct {
	perm:      virtual.Arena,
	route_mem: virtual.Arena,
	frame:     virtual.Arena,
	m:         Map,
	weather:   Weather,
	tick:      u64,
	accum:     f64,
	prof:      Profiler,
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
	fmt.eprintln("[game] build:", BUILD_MODE)
	fmt.eprintfln(
		"[map] %d lines, %d points, %d cities, %d hubs",
		len(w.m.lines),
		len(w.m.points),
		len(w.m.cities),
		w.m.hub_count,
	)
	return w
}

// The map slices point into this library's #load data, so they are re-pointed after every reload.
@(export)
game_hot_reloaded :: proc(memory: rawptr) {
	w := (^World)(memory)
	m, ok := load_map()
	if !ok {
		fmt.eprintfln(
			"[map] belgium.bin: wrong magic or version (want %d) or more than %d hubs",
			MAP_VERSION,
			MAX_HUBS,
		)
	}
	w.m = m
}

@(export)
game_update :: proc(memory: rawptr) -> bool {
	w := (^World)(memory)
	context.allocator = virtual.arena_allocator(&w.perm)
	context.temp_allocator = virtual.arena_allocator(&w.frame)
	defer virtual.arena_free_all(&w.frame)

	t := prof_begin()
	w.accum += min(f64(rl.GetFrameTime()), MAX_FRAME_DT)
	for w.accum >= SIM_DT {
		w.tick += 1
		w.accum -= SIM_DT
	}
	prof_end(w, .Update, t)

	rl.BeginDrawing()
	t = prof_begin()
	rl.ClearBackground(rl.RAYWHITE)
	rl.DrawText("hello raylib", 190, 200, 20, rl.DARKGRAY)
	prof_end(w, .Draw, t)

	// Profiler overlay, F3 toggles it. It shows the previous frame and is not counted in draw ms.
	when PROFILING {
		p := &w.prof
		if rl.IsKeyPressed(.F3) do p.hidden = !p.hidden
		if !p.hidden {
			worst: f32
			for ms in p.frame_ms do worst = max(worst, ms)
			MB :: f32(1 << 20)
			rl.DrawRectangle(8, 8, 300, 132, {0, 0, 0, 170})
			lines := [?]cstring {
				fmt.ctprintf(
					"frame %.2f ms (update %.2f, draw %.2f)",
					p.ms[.Update] + p.ms[.Draw],
					p.ms[.Update],
					p.ms[.Draw],
				),
				fmt.ctprintf("worst of %d frames %.2f ms, budget %d", PROF_FRAMES, worst, FRAME_BUDGET_MS),
				fmt.ctprintf("route %.2f ms, weather load %.2f ms", p.ms[.Route], p.ms[.Weather_Load]),
				fmt.ctprintf(
					"perm %.2f / %.2f MB, route %.2f / %.2f MB",
					f32(w.perm.total_used) / MB,
					f32(w.perm.total_reserved) / MB,
					f32(w.route_mem.total_used) / MB,
					f32(w.route_mem.total_reserved) / MB,
				),
				fmt.ctprintf("frame arena %.1f KB", f32(p.frame_used) / 1024),
			}
			for line, i in lines do rl.DrawText(line, 14, 14 + i32(i) * 12, 10, rl.RAYWHITE)

			// 2 px per frame, oldest on the left, 10 px per ms, the yellow line is the budget.
			base :: 134
			rl.DrawLine(
				14,
				base - FRAME_BUDGET_MS * 10,
				14 + PROF_FRAMES * 2,
				base - FRAME_BUDGET_MS * 10,
				rl.YELLOW,
			)
			for i in 0 ..< PROF_FRAMES {
				ms := p.frame_ms[(p.head + i) % PROF_FRAMES]
				h := clamp(i32(ms * 10), 1, 60)
				rl.DrawRectangle(14 + i32(i) * 2, base - h, 2, h, ms > FRAME_BUDGET_MS ? rl.RED : rl.GREEN)
			}
		}
	}
	rl.EndDrawing()

	when PROFILING {
		w.prof.frame_ms[w.prof.head] = w.prof.ms[.Update] + w.prof.ms[.Draw]
		w.prof.head = (w.prof.head + 1) % PROF_FRAMES
		w.prof.frame_used = w.frame.total_used
	}

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
