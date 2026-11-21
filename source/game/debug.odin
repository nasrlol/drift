package game

import "core:time"

// Timing is compiled in for debug and profile builds only. Wall-clock time is fine here,
// it is only displayed and never fed back into the simulation.
PROFILING :: DRIFT_DEBUG || DRIFT_PROFILE
PROF_FRAMES :: 120
FRAME_BUDGET_MS :: 4

Prof_Block :: enum u8 {
	Update,
	Draw,
	Route,
	Weather_Load,
}

// Zero is valid: nothing measured yet, overlay shown.
Profiler :: struct {
	ms:         [Prof_Block]f32, // last measurement of each block
	frame_ms:   [PROF_FRAMES]f32, // update + draw, ring buffer, head is the oldest
	head:       int,
	frame_used: uint, // frame arena bytes used by the previous frame
	hidden:     bool,
}

prof_begin :: proc() -> time.Tick {
	when PROFILING {
		return time.tick_now()
	} else {
		return {}
	}
}

prof_end :: proc(w: ^World, block: Prof_Block, start: time.Tick) {
	when PROFILING {
		w.prof.ms[block] = f32(time.duration_milliseconds(time.tick_since(start)))
	}
}
