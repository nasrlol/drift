// author: dario
package game

// All axes are -1..1, zero is neutral. Input code fills it. In map mode the camera reads it,
// in drive mode ship_step will.
Controls :: struct {
	throttle: f32,
	turn:     f32,
	climb:    f32,
}
