package main

import "core:os"
import game "../game"

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
