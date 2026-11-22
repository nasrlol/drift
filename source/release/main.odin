package main

import game "../game"
import "core:fmt"
import "core:os"
import "core:path/filepath"

// Hybrid laptops on Windows start the game on the integrated GPU unless the exe exports these (#89). The drivers
// read the symbols from the exe, so they live here and not in game.so.
when ODIN_OS == .Windows {
	@(export, link_name = "NvOptimusEnablement")
	nv_optimus_enablement: u32 = 1
	@(export, link_name = "AmdPowerXpressRequestHighPerformance")
	amd_power_xpress_request_high_performance: u32 = 1
}

main :: proc() {
	if len(os.args) > 1 && os.args[1] == "--headless" {
		os.exit(game.game_headless(os.args[1:]) ? 0 : 1)
	}
	script := len(os.args) > 1 && os.args[1] == "--script"
	// Everything the game writes lives under cache/ relative to the working directory (weather snapshot,
	// identity, messages, peers). The release exe embeds its assets, so it runs from the user's data folder
	// (~/.local/share, ~/Library/Application Support, %APPDATA%) instead of next to the exe.
	// A scripted run reads its files relative to where it was started.
	if base, err := os.user_data_dir(context.allocator); err == nil && !script {
		dir, _ := filepath.join({base, "Drift"}, context.allocator)
		if os.make_directory_all(dir) == nil || os.exists(dir) {
			if os.set_working_directory(dir) != nil do fmt.eprintln("[release] cannot use", dir, "- writing next to the exe")
		}
	}
	game.game_init_window()
	memory := game.game_init()
	if memory == nil {
		os.exit(1)
	}
	if script && (len(os.args) != 3 || !game.game_script(memory, os.args[2])) {
		fmt.eprintln("[release] usage: drift --script <file>")
		os.exit(1)
	}
	for game.game_update(memory) {
	}
	game.game_shutdown(memory)
	game.game_shutdown_window()
}
