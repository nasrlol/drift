package game

// x, y in km (map space, y down). Returns ground height above sea level in m: bilinear between the 250 m cell
// centres of w.m.heights (Copernicus surface model, so forests and big buildings are in it, sea is 0).
// Outside the map the edge value holds, like wind_at. NaN in x or y gives 0, and so does a map that failed to
// load (no heights).
height_at :: proc(w: ^World, x, y: f32) -> f32 {
	hs := w.m.heights
	if len(hs) != HEIGHT_W * HEIGHT_H do return 0
	fx := x / HEIGHT_CELL_KM - 0.5
	fy := y / HEIGHT_CELL_KM - 0.5
	// Written so NaN fails the test: a NaN index would be undefined behaviour after the int conversion.
	if !(fx == fx && fy == fy) do return 0
	fx = clamp(fx, 0, HEIGHT_W - 1)
	fy = clamp(fy, 0, HEIGHT_H - 1)
	ix := min(int(fx), HEIGHT_W - 2)
	iy := min(int(fy), HEIGHT_H - 2)
	tx, ty := fx - f32(ix), fy - f32(iy)
	i := iy * HEIGHT_W + ix
	top := f32(hs[i]) + (f32(hs[i + 1]) - f32(hs[i])) * tx
	bottom := f32(hs[i + HEIGHT_W]) + (f32(hs[i + HEIGHT_W + 1]) - f32(hs[i + HEIGHT_W])) * tx
	return top + (bottom - top) * ty
}
