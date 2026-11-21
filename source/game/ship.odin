// author: dario
package game

// All axes are -1..1, zero is neutral. Input code fills it, ship_step reads it.
Controls :: struct {
	throttle: f32,
	turn:     f32,
	climb:    f32,
}
