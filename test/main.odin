// End to end tests: fixed snapshot + fixed inputs through headless_run, compared to stored results.
// On a mismatch the actual output is written to build/test_<name>.txt so it can be diffed.
// Never update an expected file to make a test pass, see AGENTS.md.
package test

import game "../source/game"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"

Case :: struct {
	name:     string,
	snapshot: string,
	inputs:   string,
	expected: string, // "" when the run must fail
}

CASES :: [?]Case {
	// All modes, first and last hour, a route to the same hub.
	{"calm_routes", "test/data/calm.snap", "test/data/routes.txt", "test/data/calm_routes.expected"},
	// Wind and gusts differ per layer, so the three modes must fly different layers.
	{
		"windy_routes",
		"test/data/windy.snap",
		"test/data/windy_routes.txt",
		"test/data/windy_routes.expected",
	},
	// A NaN in the wind field must reject the snapshot, not reach the router.
	{"nan_wind", "test/data/nan_wind.snap", "test/data/routes.txt", ""},
}

main :: proc() {
	failed := 0
	for c in CASES {
		if !run_case(c) do failed += 1
	}
	fmt.printfln("test: %d passed, %d failed", len(CASES) - failed, failed)
	os.exit(failed == 0 ? 0 : 1)
}

run_case :: proc(c: Case) -> bool {
	w := (^game.World)(game.game_init())
	if w == nil {
		fmt.printfln("test %s: cannot create the World", c.name)
		return false
	}
	defer game.game_shutdown(w)
	context.allocator = virtual.arena_allocator(&w.perm)
	context.temp_allocator = virtual.arena_allocator(&w.frame)

	inputs, inputs_err := os.read_entire_file(c.inputs, context.allocator)
	if inputs_err != nil {
		fmt.printfln("test %s: cannot read %s: %v", c.name, c.inputs, inputs_err)
		return false
	}

	out := strings.builder_make()
	ok := game.headless_run(w, c.snapshot, inputs, &out)
	if c.expected == "" {
		if ok do fmt.printfln("test %s: run succeeded, it must fail", c.name)
		return !ok
	}
	if !ok {
		fmt.printfln("test %s: run failed, see the log above", c.name)
		return false
	}

	expected, expected_err := os.read_entire_file(c.expected, context.allocator)
	if expected_err != nil {
		fmt.printfln("test %s: cannot read %s: %v", c.name, c.expected, expected_err)
		return false
	}
	got, want := strings.to_string(out), string(expected)
	if got == want do return true

	line := 1
	for {
		g, g_ok := strings.split_lines_iterator(&got)
		e, e_ok := strings.split_lines_iterator(&want)
		if !g_ok && !e_ok do break
		if g != e || g_ok != e_ok {
			fmt.printfln("test %s: line %d differs\n  got:  %q\n  want: %q", c.name, line, g, e)
			break
		}
		line += 1
	}
	actual := fmt.tprintf("build/test_%s.txt", c.name)
	if err := os.write_entire_file(actual, strings.to_string(out)); err != nil {
		fmt.printfln("test %s: cannot write %s: %v", c.name, actual, err)
	} else {
		fmt.printfln("test %s: full output in %s, expected in %s", c.name, actual, c.expected)
	}
	return false
}
