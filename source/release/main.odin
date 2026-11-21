package main

import game "../game"
import "core:os"

main :: proc() {
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
