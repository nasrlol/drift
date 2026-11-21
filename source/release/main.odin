package main

import game "../game"
import "core:fmt"
import "core:os"
import "core:path/filepath"

main :: proc() {
	if len(os.args) > 1 && os.args[1] == "--headless" {
		os.exit(game.game_headless(os.args[1:]) ? 0 : 1)
	}
	// Everything the game writes lives under cache/ relative to the working directory (weather snapshot,
	// identity, messages, peers). The release exe embeds its assets, so it runs from the user's data folder
	// (~/.local/share, ~/Library/Application Support, %APPDATA%) instead of next to the exe.
	if base, err := os.user_data_dir(context.allocator); err == nil {
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
	for game.game_update(memory) {
	}
	game.game_shutdown(memory)
	game.game_shutdown_window()
}
