package main

import game "../game"
import "core:os"

main :: proc() {
	if len(os.args) > 1 && os.args[1] == "--headless" {
		os.exit(game.game_headless(os.args[1:]) ? 0 : 1)
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
