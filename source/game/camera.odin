// author: dario
package game

import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

// Camera: zoom is log2 relative to the fitted Belgium view, so zero is all of Belgium and negative zooms
// pull back to the 3D Earth globe (ZOOM_MIN fits the whole globe).
ZOOM_MIN :: -6.2
ZOOM_MAX :: 7
WHEEL_ZOOM_STEP :: 0.25
ZOOM_PER_S :: 2
PAN_PX_PER_S :: 600
CAM_FOV_DEG :: 45
// Motion (design "Beweging en animatie"), all ease-out.
CAM_ZOOM_GLIDE_S :: 0.6
CAM_FIT_S :: 0.8
CAM_CHASE_S :: 1.2
CAM_PREVIEW_S :: 9.0
CAM_CHASE_TILT :: 53 * math.RAD_PER_DEG
CAM_CHASE_ZOOM :: 5.5
// The ship sits just below the middle of the screen in navigation: the camera looks this share of the visible
// height ahead of it.
CAM_CHASE_AHEAD :: 0.18
// Following the ship: the camera closes this share of the gap per second (a small lag, turns with the ship).
CAM_FOLLOW_RATE :: 4.0
// Orbiting the chase camera with the right mouse button (nasr, 2026-11-22: "can we move it?"): radians per
// pixel dragged, and the default steepest tilt (0 = straight down, w.view_edit changes it).
CAM_ORBIT_RAD_PER_PX :: 0.005
CAM_ORBIT_MAX_TILT :: 80 * math.RAD_PER_DEG

// Where the camera looks: pan = km from the map centre to the point under the screen centre (in Belgium),
// globe_rot = (lon, lat) radians away from Belgium when orbiting the globe, zoom, yaw (radians clockwise)
// and tilt (0 = straight down). Zero is the whole Belgium map, north up, from above.
Cam_Pose :: struct {
	pan:       [2]f32,
	globe_rot: [2]f32,
	zoom:      f32,
	yaw:       f32,
	tilt:      f32,
}

Cam_Mode :: enum u8 {
	Free, // the user moves it (plan screen, after a drag in navigation)
	Chase, // behind the ship, turns with its heading
	Preview, // flies the chosen route in CAM_PREVIEW_S
}

// Zero = the whole map from above, nothing moving.
Cam :: struct {
	pose:         Cam_Pose,
	mode:         Cam_Mode,
	// A glide from one pose to another (fit, chase dive, compass), ease-out over dur seconds. dur 0 = none.
	glide_from:   Cam_Pose,
	glide_to:     Cam_Pose,
	glide_t:      f32,
	glide_dur:    f32,
	// Wheel and zoom buttons glide too: zoom moves to zoom_goal keeping the ground under zoom_anchor (px).
	zoom_goal:    f32,
	zoom_anchor:  [2]f32,
	zooming:      bool,
	preview_t:    f32, // seconds into the preview
	preview_mode: Route_Mode,
	dragged:      bool, // the user moved the map in navigation: Re-centre shows
	// The chase camera turned around the ship (right drag): yaw added to the heading, tilt added to
	// CAM_CHASE_TILT. Zero = straight behind; it keeps following while turned.
	orbit_yaw:    f32,
	orbit_tilt:   f32,
	// A zoom in asked for more than ZOOM_MAX while the camera is already there: the street view takes over
	// (street_switch, street.odin). Cleared every frame by game_update.
	zoom_past:    bool,
	// This frame, built by cam_update: the raylib camera, the screen size and the scale at the screen centre.
	view:         rl.Camera3D,
	screen:       [2]f32,
	px_per_km:    f32,
}

ease_out :: proc(t: f32) -> f32 {
	u := 1 - clamp(t, 0, 1)
	return 1 - u * u * u
}

ease_in_out :: proc(x: f32) -> f32 {
	t := clamp(x, 0, 1)
	return t * t * (3 - 2 * t)
}

// Shortest way from angle a to angle b, so a glide never spins the long way round.
angle_lerp :: proc(a, b, t: f32) -> f32 {
	d := math.mod(b - a + 3 * math.PI, math.TAU) - math.PI
	return a + d * t
}

cam_fit_scale :: proc(screen: [2]f32) -> f32 {
	return 0.95 * min(screen.x / MAP_W_KM, screen.y / MAP_H_KM)
}

// The raylib camera for a pose. World space is (x km, y km, -altitude km): x east, y south, z down, so the
// raylib right-handed look-at keeps east on the right. At globe_rot = 0 and zoom >= 0 it sits over Belgium's
// flat z = 0 plane; negative zooms or non-zero globe_rot orbit the Earth sphere tangent to Belgium's centre.
cam_build :: proc(p: Cam_Pose, screen: [2]f32) -> (view: rl.Camera3D, px_per_km: f32) {
	px_per_km = cam_fit_scale(screen) * math.pow(f32(2), p.zoom)
	dist := screen.y / (2 * math.tan(f32(CAM_FOV_DEG) * math.RAD_PER_DEG / 2) * px_per_km)
	st, ct := math.sin(p.tilt), math.cos(p.tilt)
	if p.globe_rot == {} && p.zoom >= 0 {
		target := [2]f32{MAP_W_KM, MAP_H_KM} / 2 + p.pan
		fwd := [2]f32{math.sin(p.yaw), -math.cos(p.yaw)}
		view = {
			position   = {target.x - fwd.x * dist * st, target.y - fwd.y * dist * st, -dist * ct},
			target     = {target.x, target.y, 0},
			up         = {fwd.x * ct, fwd.y * ct, -st},
			fovy       = CAM_FOV_DEG,
			projection = .PERSPECTIVE,
		}
		return
	}

	lon := BELGIUM_LON0 + p.globe_rot.x * math.DEG_PER_RAD
	lat := clamp(BELGIUM_LAT0 + p.globe_rot.y * math.DEG_PER_RAD, -85, 85)
	n := globe_normal(lon, lat)
	phi0 := f32(BELGIUM_LAT0 * math.RAD_PER_DEG)
	north_axis := [3]f32{0, -math.cos(phi0), -math.sin(phi0)}
	east := linalg.normalize(linalg.cross(north_axis, n))
	south := linalg.normalize(linalg.cross(east, n))

	// Blend Belgium's flat pan out as zoom drops below 0 so zooming out to space stays smooth.
	pan_w := clamp(p.zoom + 1, 0, 1)
	ec := earth_centre()
	target := ec + n * EARTH_RADIUS_KM + (east * p.pan.x + south * p.pan.y) * pan_w
	fwd := east * math.sin(p.yaw) - south * math.cos(p.yaw)
	view = {
		position   = target + n * (dist * ct) - fwd * (dist * st),
		target     = target,
		up         = fwd * ct + n * st,
		fovy       = CAM_FOV_DEG,
		projection = .PERSPECTIVE,
	}
	return
}

// Screen position of pos (x km, y km, altitude m). visible = in front of the camera and on the screen.
cam_to_screen :: proc(w: ^World, pos: [3]f32) -> (px: [2]f32, visible: bool) {
	c := &w.cam
	p := [3]f32{pos.x, pos.y, -pos.z / 1000}
	fwd := linalg.normalize(c.view.target - c.view.position)
	if linalg.dot(p - c.view.position, fwd) <= 0.01 do return {-1e6, -1e6}, false
	px = rl.GetWorldToScreenEx(p, c.view, i32(c.screen.x), i32(c.screen.y))
	visible = px.x >= 0 && px.y >= 0 && px.x < c.screen.x && px.y < c.screen.y
	return
}

// The point on the ground (km) under a screen position. ok = false above the horizon.
cam_ground_at :: proc(w: ^World, px: [2]f32) -> (pos: [2]f32, ok: bool) {
	c := &w.cam
	ray := rl.GetScreenToWorldRayEx(px, c.view, i32(c.screen.x), i32(c.screen.y))
	if ray.direction.z <= 1e-4 do return {}, false
	t := -ray.position.z / ray.direction.z
	return ray.position.xy + ray.direction.xy * t, true
}

cam_glide :: proc(w: ^World, to: Cam_Pose, dur: f32) {
	c := &w.cam
	c.glide_from = c.pose
	c.glide_to = to
	c.glide_to.zoom = clamp(to.zoom, ZOOM_MIN, ZOOM_MAX)
	c.glide_t = 0
	c.glide_dur = dur
	c.zooming = false
}

// Fits the box lo..hi (km) into the screen rect r (px) from above, north up, in CAM_FIT_S.
cam_fit :: proc(w: ^World, lo, hi: [2]f32, r: rl.Rectangle) {
	c := &w.cam
	c.mode = .Free
	screen := c.screen
	size := linalg.max(hi - lo, [2]f32{1, 1})
	ppk := min(r.width / size.x, r.height / size.y)
	zoom := math.log2(ppk / cam_fit_scale(screen))
	// The box centre goes to the rect centre: shift the screen centre by the rect offset in km.
	mid := (lo + hi) / 2
	offset :=
		([2]f32{r.x + r.width / 2, r.y + r.height / 2} - screen / 2) /
		(cam_fit_scale(screen) * math.pow(f32(2), clamp(zoom, ZOOM_MIN, ZOOM_MAX)))
	cam_glide(w, {pan = mid - offset - [2]f32{MAP_W_KM, MAP_H_KM} / 2, zoom = zoom}, CAM_FIT_S)
}

// Tilted chase camera behind the ship, dives in CAM_CHASE_S.
cam_chase :: proc(w: ^World) {
	c := &w.cam
	c.mode = .Chase
	c.dragged = false
	c.orbit_yaw, c.orbit_tilt = 0, 0
	cam_glide(w, cam_chase_pose(w, CAM_CHASE_ZOOM), CAM_CHASE_S)
}

cam_chase_pose :: proc(w: ^World, zoom: f32) -> Cam_Pose {
	p := w.pose
	c := &w.cam
	ppk := cam_fit_scale(c.screen) * math.pow(f32(2), zoom)
	ahead := CAM_CHASE_AHEAD * c.screen.y / ppk
	yaw := p.heading + c.orbit_yaw
	fwd := [2]f32{math.sin(yaw), -math.cos(yaw)}
	return {
		pan = [2]f32{f32(p.pos.x), f32(p.pos.y)} + fwd * ahead - [2]f32{MAP_W_KM, MAP_H_KM} / 2,
		zoom = zoom,
		yaw = yaw,
		tilt = clamp(CAM_CHASE_TILT + c.orbit_tilt, 0, view_max_tilt(w)),
	}
}

// Back to the ship after a drag.
cam_recentre :: proc(w: ^World) {
	cam_chase(w)
}

// The whole map, north up, from above.
cam_overview :: proc(w: ^World) {
	w.cam.mode = .Free
	cam_glide(w, {}, CAM_FIT_S)
}

// North up again (compass button), keeps position and zoom.
cam_north :: proc(w: ^World) {
	to := w.cam.pose
	to.yaw = 0
	cam_glide(w, to, CAM_ZOOM_GLIDE_S)
}

// Flies the chosen route from A to B in CAM_PREVIEW_S, tilted, easing in and out (uses route_sample).
cam_preview :: proc(w: ^World, mode: Route_Mode) {
	c := &w.cam
	if !w.routes[mode].ok do return
	c.mode = .Preview
	c.preview_t = 0
	c.preview_mode = mode
	pos, heading := route_sample(w, mode, 0)
	cam_glide(
		w,
		{pan = pos.xy - [2]f32{MAP_W_KM, MAP_H_KM} / 2, zoom = 4.5, yaw = heading, tilt = 0.8},
		CAM_FIT_S,
	)
}

// Zoom by steps (wheel notches, zoom buttons) around a screen point, gliding in CAM_ZOOM_GLIDE_S.
cam_zoom_by :: proc(w: ^World, steps: f32, anchor: [2]f32) {
	c := &w.cam
	if !c.zooming do c.zoom_goal = c.pose.zoom
	if steps > 0 && c.zoom_goal + steps > ZOOM_MAX && c.pose.zoom > ZOOM_MAX - 0.05 do c.zoom_past = true
	c.zoom_goal = clamp(c.zoom_goal + steps, cam_min_zoom(w), ZOOM_MAX)
	c.zoom_anchor = anchor
	c.zooming = true
}

// Once per frame before anything is drawn: input (when the mouse is not on the UI), glides, following the ship
// or the preview, then the raylib camera for this frame. Drawing only, frame time is fine.
cam_update :: proc(w: ^World, mouse_free: bool, controls_pan: bool) {
	c := &w.cam
	dt := frame_time(w)
	c.screen = {f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	c.view, c.px_per_km = cam_build(c.pose, c.screen)
	pan0 := c.pose.pan // where the screen centre was last frame, over Belgium (see the end)

	// Input. The keyboard / stick pan only on the plan screen (in navigation they steer the ship).
	{
		pan_px: [2]f32
		if controls_pan {
			k := w.controls
			pan_px = {k.turn, -k.throttle} * PAN_PX_PER_S * dt
			if k.climb != 0 do cam_zoom_by(w, k.climb * ZOOM_PER_S * dt, c.screen / 2)
		}
		if mouse_free && rl.IsMouseButtonDown(.LEFT) && c.mode != .Preview {
			d := rl.GetMouseDelta()
			if d != {} {
				pan_px -= d
				if c.mode == .Chase {
					c.mode = .Free
					c.dragged = true
				}
			}
		}
		// Right drag turns the camera around the screen centre: sideways turns, up tilts towards the horizon. The
		// chase camera keeps following the ship while turned (Re-centre puts it behind again).
		flat := c.pose.globe_rot == {} && c.pose.zoom >= 0
		if mouse_free && rl.IsMouseButtonDown(.RIGHT) && flat && c.mode != .Preview {
			if d := rl.GetMouseDelta(); d != {} {
				turn, tilt := d.x * CAM_ORBIT_RAD_PER_PX, -d.y * CAM_ORBIT_RAD_PER_PX
				if c.mode == .Chase {
					c.orbit_yaw = math.mod(c.orbit_yaw + turn + 3 * math.PI, math.TAU) - math.PI
					lo, hi := f32(-CAM_CHASE_TILT), view_max_tilt(w) - CAM_CHASE_TILT
					c.orbit_tilt = clamp(c.orbit_tilt + tilt, lo, hi)
					c.dragged = true
				} else {
					c.pose.yaw = math.mod(c.pose.yaw + turn + 3 * math.PI, math.TAU) - math.PI
					c.pose.tilt = clamp(c.pose.tilt + tilt, 0, view_max_tilt(w))
					c.glide_dur = 0
				}
			}
		}
		if pan_px != {} {
			// Screen pixels to km on the ground, turned by the yaw.
			s, co := math.sin(c.pose.yaw), math.cos(c.pose.yaw)
			v := pan_px / c.px_per_km
			move := [2]f32{v.x * co - v.y * s, v.x * s + v.y * co}
			if c.pose.zoom < 0 || c.pose.globe_rot != {} {
				lat_rad := clamp(
					BELGIUM_LAT0 * math.RAD_PER_DEG + c.pose.globe_rot.y,
					-85 * math.RAD_PER_DEG,
					85 * math.RAD_PER_DEG,
				)
				c.pose.globe_rot.x =
					math.mod(
						c.pose.globe_rot.x +
						move.x / (EARTH_RADIUS_KM * max(math.cos(lat_rad), 0.15)) +
						3 * math.PI,
						math.TAU,
					) -
					math.PI
				lo_lat := f32(-85 * math.RAD_PER_DEG - BELGIUM_LAT0 * math.RAD_PER_DEG)
				hi_lat := f32(85 * math.RAD_PER_DEG - BELGIUM_LAT0 * math.RAD_PER_DEG)
				c.pose.globe_rot.y = clamp(c.pose.globe_rot.y - move.y / EARTH_RADIUS_KM, lo_lat, hi_lat)
				// Snap cleanly back onto Belgium when panning near it at zoom >= -0.25.
				if c.pose.zoom >= -0.25 && linalg.length(c.pose.globe_rot) < 0.015 do c.pose.globe_rot = {}
			} else {
				c.pose.pan += move
			}
			c.glide_dur = 0
		}
		if wheel := mouse_wheel(w); mouse_free && wheel != 0 {
			// A scripted run (debug.odin) has no real mouse: it zooms around the middle of the screen.
			cam_zoom_by(w, wheel * WHEEL_ZOOM_STEP, w.script.on ? c.screen / 2 : rl.GetMousePosition())
		}
	}

	if c.zooming {
		use_anchor := c.mode == .Free && c.pose.globe_rot == {} && c.pose.zoom >= 0 && c.zoom_goal >= 0
		before, before_ok := cam_ground_at(w, c.zoom_anchor)
		k := 1 - math.exp(-dt * 5 / CAM_ZOOM_GLIDE_S)
		c.pose.zoom += (c.zoom_goal - c.pose.zoom) * k
		if abs(c.zoom_goal - c.pose.zoom) < 1e-3 {
			c.pose.zoom = c.zoom_goal
			c.zooming = false
		}
		if c.pose.zoom < 0 {
			c.pose.pan *= 1 - k
		} else if c.pose.globe_rot != {} && linalg.length(c.pose.globe_rot) < 0.03 {
			c.pose.globe_rot *= 1 - k
			if linalg.length(c.pose.globe_rot) < 1e-4 do c.pose.globe_rot = {}
		}
		c.view, c.px_per_km = cam_build(c.pose, c.screen)
		after, after_ok := cam_ground_at(w, c.zoom_anchor)
		if use_anchor && before_ok && after_ok do c.pose.pan += before - after
	}

	switch c.mode {
	case .Free:
	case .Chase:
		goal := cam_chase_pose(w, c.zooming ? c.zoom_goal : c.pose.zoom)
		goal.zoom = c.pose.zoom
		if c.glide_dur > 0 {
			// Follow the ship while gliding in, but keep the glide's own zoom goal.
			goal.zoom = c.glide_to.zoom
			c.glide_to = goal
		} else {
			k := 1 - math.exp(-dt * CAM_FOLLOW_RATE)
			c.pose.pan += (goal.pan - c.pose.pan) * k
			c.pose.yaw = angle_lerp(c.pose.yaw, goal.yaw, k)
			c.pose.tilt = goal.tilt
		}
	case .Preview:
		if c.glide_dur == 0 {
			c.preview_t += dt
			t := ease_in_out(c.preview_t / CAM_PREVIEW_S)
			pos, heading := route_sample(w, c.preview_mode, t)
			k := 1 - math.exp(-dt * CAM_FOLLOW_RATE)
			c.pose.pan = pos.xy - [2]f32{MAP_W_KM, MAP_H_KM} / 2
			c.pose.yaw = angle_lerp(c.pose.yaw, heading, k)
			if c.preview_t >= CAM_PREVIEW_S {
				c.mode = .Free
				r := &w.routes[c.preview_mode]
				lo, hi := path_bounds(r.path)
				cam_fit(w, lo, hi, plan_map_rect(w))
			}
		}
	}

	if c.glide_dur > 0 {
		c.glide_t += dt
		t := ease_out(c.glide_t / c.glide_dur)
		a, b := c.glide_from, c.glide_to
		c.pose = {
			pan       = linalg.lerp(a.pan, b.pan, t),
			globe_rot = linalg.lerp(a.globe_rot, b.globe_rot, t),
			zoom      = a.zoom + (b.zoom - a.zoom) * t,
			yaw       = angle_lerp(a.yaw, b.yaw, t),
			tilt      = a.tilt + (b.tilt - a.tilt) * t,
		}
		if c.glide_t >= c.glide_dur do c.glide_dur = 0
	}

	c.pose.zoom = clamp(c.pose.zoom, cam_min_zoom(w), ZOOM_MAX)
	c.zoom_goal = max(c.zoom_goal, cam_min_zoom(w))
	c.view, c.px_per_km = cam_build(c.pose, c.screen)
	if c.pose.globe_rot == {} && c.pose.zoom >= 0 {
		c.pose.pan = cam_clamp_pan(w, c.pose)
		// The user can not look past Belgium (nasr, 2026-11-21): in free mode the point under the screen centre stays
		// over it. Keep the axis that stays inside, else pull toward the map centre, which lies in Belgium and keeps
		// the pan inside the clamp box. Chase and preview follow the ship and the route, those stay in Belgium.
		if c.mode == .Free {
			mid := [2]f32{MAP_W_KM, MAP_H_KM} / 2
			p := c.pose.pan
			if !belgium_inside(w, mid.x + p.x, mid.y + p.y) {
				STEPS :: 16
				for k in 0 ..= STEPS + 2 {
					q :=
						k == 0 ? [2]f32{p.x, pan0.y} : k == 1 ? [2]f32{pan0.x, p.y} : p * f32(STEPS + 2 - k) / STEPS
					pose := c.pose
					pose.pan = q
					q = cam_clamp_pan(w, pose)
					if belgium_inside(w, mid.x + q.x, mid.y + q.y) {
						c.pose.pan = q
						break
					}
				}
			}
		}
		c.view, c.px_per_km = cam_build(c.pose, c.screen)
	}
}

// The zoom that fits the whole globe on the plan screen, or Belgium in navigation.
cam_min_zoom :: proc(w: ^World) -> f32 {
	if w.screen == .Plan do return ZOOM_MIN
	screen := w.cam.screen
	if screen.x <= 0 || screen.y <= 0 do return ZOOM_MIN
	ppk := min(screen.x / MAP_W_KM, screen.y / MAP_H_KM)
	return clamp(math.log2(ppk / cam_fit_scale(screen)), ZOOM_MIN, 0)
}

// Keeps the map on the screen: per axis, a view smaller than the map stays inside it, a view larger than the map
// keeps the whole map in view. The view is the screen rect turned by the yaw, measured at the screen centre.
cam_clamp_pan :: proc(w: ^World, p: Cam_Pose) -> [2]f32 {
	c := &w.cam
	if c.px_per_km <= 0 do return p.pan
	half_view := c.screen / 2 / c.px_per_km
	s, co := abs(math.sin(p.yaw)), abs(math.cos(p.yaw))
	view := [2]f32{half_view.x * co + half_view.y * s, half_view.x * s + half_view.y * co}
	half_map := [2]f32{MAP_W_KM, MAP_H_KM} / 2
	room := linalg.abs(half_map - view)
	return linalg.clamp(p.pan, -room, room)
}

// Smallest box around a path (km).
path_bounds :: proc(path: [][3]f32) -> (lo, hi: [2]f32) {
	if len(path) == 0 do return {}, {MAP_W_KM, MAP_H_KM}
	lo, hi = path[0].xy, path[0].xy
	for p in path {
		lo = linalg.min(lo, p.xy)
		hi = linalg.max(hi, p.xy)
	}
	return
}
