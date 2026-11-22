// author: lars
package game

import "core:math/linalg"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

// The street view's picture after the scene (Lars, 2026-11-22: "het lijkt te veel op Roblox, ik wil het
// realistischer, zoals GTA 6"; first step "Light, glass, grading"). The scene draws linear light into a float
// target (RGBA16F) with a depth texture; then:
//   ao     ambient occlusion at half resolution from the depth: POST_AO_SAMPLES points in the half sphere over
//          each pixel, POST_AO_RADIUS_M around it, gone beyond POST_AO_FAR_M. The ground writes a layered far
//          depth (STREET_GROUND_FS), so its points come from the ground plane under the eye instead.
//   bloom  POST_BLOOM_LEVELS halvings of the picture (the first weighted against single bright pixels, so a
//          sun glint does not sparkle), added back up with a tent filter: bright glass and sky glow a little.
//   final  bloom and AO in, exposure, a little less saturation, warm highlights and cool shadows, ACES, a mild
//          S-curve, a soft vignette and a film grain of +-0.5 %, into an 8 bit target with the luma in alpha.
//   fxaa   strong edges only smoothed along their luma gradient (the float target has no MSAA) onto the screen;
//          the first, unthresholded version smeared windows and grass up to 8 px, it looked like motion blur.
// The default framebuffer keeps its MSAA for the map; the HUD is drawn after.
POST_BLOOM_LEVELS :: 5
POST_BLOOM :: 0.03 // share of the bloom in the picture
POST_AO_SAMPLES :: 12
POST_AO_RADIUS_M :: 1.2
POST_AO_FAR_M :: [2]f32{70, 180} // AO fades out between these distances
POST_AO_STRENGTH :: 0.85
POST_EXPOSURE :: 1.0
POST_SATURATION :: 0.97
POST_CONTRAST :: 0.3 // share of a smoothstep S-curve after the tone curve
POST_VIGNETTE :: 0.16
POST_GRAIN :: 0.01

Post_Edit :: struct {
	ao_on:       bool,
	bloom_on:    bool,
	fxaa_on:     bool,
	exposure:    f32,
	saturation:  f32,
	contrast:    f32,
	bloom:       f32,
	ao_strength: f32,
	ao_radius_m: f32,
	vignette:    f32,
	grain:       f32,
}

post_edit_defaults :: proc() -> Post_Edit {
	return {
		ao_on = true,
		bloom_on = true,
		fxaa_on = true,
		exposure = POST_EXPOSURE,
		saturation = POST_SATURATION,
		contrast = POST_CONTRAST,
		bloom = POST_BLOOM,
		ao_strength = POST_AO_STRENGTH,
		ao_radius_m = POST_AO_RADIUS_M,
		vignette = POST_VIGNETTE,
		grain = POST_GRAIN,
	}
}

Post :: struct {
	size:   [2]i32, // render size the targets were made for
	hdr:    rl.RenderTexture2D, // RGBA16F + depth texture
	ao:     rl.RenderTexture2D, // half size, RGBA8
	ao2:    rl.RenderTexture2D, // ao blurred
	bloom:  [POST_BLOOM_LEVELS]rl.RenderTexture2D, // RGBA16F, 1/2 .. 1/32
	ldr:    rl.RenderTexture2D, // RGBA8, luma in alpha
	sh_ao:  rl.Shader,
	sh_bl:  rl.Shader,
	sh_dn:  rl.Shader,
	sh_up:  rl.Shader,
	sh_fin: rl.Shader,
	sh_aa:  rl.Shader,
	ready:  bool,
	frame:  u32,
}

// The camera of this frame, for the AO's view-space positions.
Post_View :: struct {
	tan_half: [2]f32,
	up_vs:    [3]f32, // world up in view space
	eye_h:    f32, // m over the ground
}

POST_AO_FS ::
	`#version 330
uniform sampler2D depth_tex;
uniform vec2 size;
uniform vec2 tan_half;
uniform vec2 clip;
uniform vec3 up_vs;
uniform float eye_h;
uniform float radius;
uniform vec2 far_fade;
out vec4 finalColor;
float lin_z(float d) {
	float z = d * 2.0 - 1.0;
	return 2.0 * clip.x * clip.y / (clip.y + clip.x - z * (clip.y - clip.x));
}
// View-space position under uv: the ground plane where the ground wrote its layered depth (just below 1),
// nothing for the sky (1, the clear value).
bool pos_at(vec2 uv, out vec3 p) {
	p = vec3(0.0);
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) return false;
	float d = texture(depth_tex, uv).r;
	if (d >= 1.0) return false;
	vec3 dir = vec3((uv * 2.0 - 1.0) * tan_half, -1.0);
	if (d > 0.999998) {
		float k = dot(dir, up_vs);
		if (k >= -1e-4) return false;
		p = dir * (-eye_h / k);
		return true;
	}
	p = dir * lin_z(d);
	return true;
}
float ign(vec2 p) { return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))); }
void main() {
	vec2 px = 1.0 / size;
	vec2 uv = gl_FragCoord.xy * px;
	vec3 p, pl, pr, pd, pu;
	if (!pos_at(uv, p)) { finalColor = vec4(1.0); return; }
	vec3 n;
	if (texture(depth_tex, uv).r > 0.999998) {
		n = up_vs;
	} else {
		// From the neighbour on the same surface on each axis (the nearer depth), so silhouettes keep their
		// own normal instead of one bent towards the background.
		bool okl = pos_at(uv - vec2(px.x, 0.0), pl), okr = pos_at(uv + vec2(px.x, 0.0), pr);
		bool okd = pos_at(uv - vec2(0.0, px.y), pd), oku = pos_at(uv + vec2(0.0, px.y), pu);
		float el = okl ? abs(p.z - pl.z) : 1e9, er = okr ? abs(pr.z - p.z) : 1e9;
		float ed = okd ? abs(p.z - pd.z) : 1e9, eu = oku ? abs(pu.z - p.z) : 1e9;
		vec3 dx = er < el ? pr - p : p - pl;
		vec3 dy = eu < ed ? pu - p : p - pd;
		n = min(el, er) < 1e8 && min(ed, eu) < 1e8 ? normalize(cross(dx, dy)) : -normalize(p);
		if (dot(n, p) > 0.0) n = -n;
	}
	vec3 t = normalize(cross(n, abs(n.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
	vec3 b = cross(n, t);
	float a0 = ign(gl_FragCoord.xy) * 6.2832;
	float occ = 0.0;
	for (int i = 0; i < ` +
	POST_AO_SAMPLES_STR +
	`; i++) {
		float f = (float(i) + 0.5) / ` +
	POST_AO_SAMPLES_STR +
	`.0;
		float ang = a0 + float(i) * 2.39996;
		float r = sqrt(f);
		vec3 s = p + (t * cos(ang) * r + b * sin(ang) * r + n * sqrt(1.0 - f)) * radius * (0.25 + 0.75 * f);
		vec2 suv = s.xy / (-s.z * tan_half) * 0.5 + 0.5;
		vec3 q;
		if (!pos_at(suv, q)) continue;
		occ += step(0.04, q.z - s.z) * smoothstep(0.0, 1.0, radius / abs(q.z - p.z));
	}
	float ao = 1.0 - occ / ` +
	POST_AO_SAMPLES_STR +
	`.0;
	finalColor = vec4(vec3(mix(ao, 1.0, smoothstep(far_fade.x, far_fade.y, -p.z))), 1.0);
}
`

POST_AO_SAMPLES_STR :: "12"
#assert(POST_AO_SAMPLES == 12)

// The AO's noise smoothed: a 4 x 4 box from 4 bilinear taps on texel corners.
POST_BLUR_FS :: `#version 330
uniform sampler2D src;
uniform vec2 size;
out vec4 finalColor;
void main() {
	vec2 px = 1.0 / size;
	vec2 uv = gl_FragCoord.xy * px;
	float o = texture(src, uv + px * vec2(-1.0, -1.0)).r + texture(src, uv + px * vec2(1.0, -1.0)).r
		+ texture(src, uv + px * vec2(-1.0, 1.0)).r + texture(src, uv + px * vec2(1.0, 1.0)).r;
	finalColor = vec4(vec3(o * 0.25), 1.0);
}
`

// Down: the average of 4 bilinear taps (4 x 4 source texels); the first level weights each by 1 / (1 + luma).
POST_DOWN_FS :: `#version 330
uniform sampler2D src;
uniform vec2 src_size;
uniform vec2 size;
uniform float karis;
out vec4 finalColor;
vec3 tap(vec2 uv, inout float wsum) {
	vec3 c = texture(src, uv).rgb;
	float w = karis > 0.5 ? 1.0 / (1.0 + dot(c, vec3(0.2126, 0.7152, 0.0722))) : 1.0;
	wsum += w;
	return c * w;
}
void main() {
	vec2 uv = gl_FragCoord.xy / size;
	vec2 px = 1.0 / src_size;
	float wsum = 0.0;
	vec3 c = tap(uv + px * vec2(-1.0, -1.0), wsum) + tap(uv + px * vec2(1.0, -1.0), wsum)
		+ tap(uv + px * vec2(-1.0, 1.0), wsum) + tap(uv + px * vec2(1.0, 1.0), wsum);
	finalColor = vec4(c / wsum, 1.0);
}
`

// Up: a 3 x 3 tent of the smaller level, added onto the larger one (additive blending).
POST_UP_FS :: `#version 330
uniform sampler2D src;
uniform vec2 src_size;
uniform vec2 size;
out vec4 finalColor;
void main() {
	vec2 uv = gl_FragCoord.xy / size;
	vec2 px = 1.0 / src_size;
	vec3 c = texture(src, uv).rgb * 4.0;
	c += (texture(src, uv + vec2(px.x, 0.0)).rgb + texture(src, uv - vec2(px.x, 0.0)).rgb
		+ texture(src, uv + vec2(0.0, px.y)).rgb + texture(src, uv - vec2(0.0, px.y)).rgb) * 2.0;
	c += texture(src, uv + px).rgb + texture(src, uv - px).rgb
		+ texture(src, uv + vec2(px.x, -px.y)).rgb + texture(src, uv + vec2(-px.x, px.y)).rgb;
	finalColor = vec4(c / 16.0, 1.0);
}
`

POST_FINAL_FS ::
	`#version 330
uniform sampler2D hdr;
uniform sampler2D bloom;
uniform sampler2D ao;
uniform vec2 size;
uniform float bloom_k;
uniform float ao_k;
uniform float exposure;
uniform float saturation;
uniform float contrast;
uniform float vignette;
uniform float grain;
uniform float frame;
out vec4 finalColor;
float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
void main() {
	vec2 uv = gl_FragCoord.xy / size;
	vec3 c = texture(hdr, uv).rgb;
	c = mix(c, texture(bloom, uv).rgb / float(` +
	POST_BLOOM_LEVELS_STR +
	`), bloom_k);
	float o = texture(ao, uv).r;
	c *= mix(1.0, o, ao_k);
	c *= exposure;
	float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
	c = max(mix(vec3(l), c, saturation), 0.0);
	// Warm light, cool shade: a hint of orange in the highlights and of blue in the shadows.
	float hl = smoothstep(0.15, 1.2, l);
	c *= mix(vec3(0.97, 0.99, 1.04), vec3(1.03, 1.0, 0.95), hl);
	c = clamp((c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14), 0.0, 1.0);
	c = sqrt(c);
	c = mix(c, c * c * (3.0 - 2.0 * c), contrast);
	vec2 q = uv - 0.5;
	c *= mix(1.0, 1.0 - vignette, smoothstep(0.25, 0.85, dot(q, q) * 2.2));
	c += (hash12(gl_FragCoord.xy + frame * 17.0) - 0.5) * grain;
	finalColor = vec4(c, dot(c, vec3(0.299, 0.587, 0.114)));
}
`

POST_BLOOM_LEVELS_STR :: "5"
#assert(POST_BLOOM_LEVELS == 5)

// FXAA (Timothy Lottes' short form): on edges whose luma contrast passes POST_FXAA_EDGE, blends along the edge by
// its luma gradient over at most POST_FXAA_SPAN pixels, kept when the result stays in range.
POST_FXAA_EDGE_STR :: "0.08"
POST_FXAA_SPAN_STR :: "4.0"
POST_FXAA_FS ::
	`#version 330
uniform sampler2D tex;
uniform vec2 size;
uniform float enable;
out vec4 finalColor;
void main() {
	vec2 px = 1.0 / size;
	vec2 uv = gl_FragCoord.xy * px;
	vec3 m = texture(tex, uv).rgb;
	if (enable < 0.5) { finalColor = vec4(m, 1.0); return; }
	float lm = texture(tex, uv).a;
	float lnw = texture(tex, uv + vec2(-px.x, px.y)).a;
	float lne = texture(tex, uv + px).a;
	float lsw = texture(tex, uv - px).a;
	float lse = texture(tex, uv + vec2(px.x, -px.y)).a;
	float lmin = min(lm, min(min(lnw, lne), min(lsw, lse)));
	float lmax = max(lm, max(max(lnw, lne), max(lsw, lse)));
	// Only real edges: a pixel whose neighbours stay within the contrast threshold keeps its own colour, so
	// windows, bricks and grass are not smeared (they looked like motion blur, Lars 2026-11-22).
	if (lmax - lmin < max(` +
	POST_FXAA_EDGE_STR +
	`, lmax * 0.2)) { finalColor = vec4(m, 1.0); return; }
	vec2 dir = vec2(-((lnw + lne) - (lsw + lse)), (lnw + lsw) - (lne + lse));
	float reduce = max((lnw + lne + lsw + lse) * 0.03125, 1.0 / 128.0);
	dir = clamp(dir / (min(abs(dir.x), abs(dir.y)) + reduce), -` +
	POST_FXAA_SPAN_STR +
	`, ` +
	POST_FXAA_SPAN_STR +
	`) * px;
	vec3 a = 0.5 * (texture(tex, uv - dir / 6.0).rgb + texture(tex, uv + dir / 6.0).rgb);
	vec3 b = a * 0.5 + 0.25 * (texture(tex, uv - dir * 0.5).rgb + texture(tex, uv + dir * 0.5).rgb);
	float lb = dot(b, vec3(0.299, 0.587, 0.114));
	finalColor = vec4(lb < lmin || lb > lmax ? a : b, 1.0);
}
`

// A colour target of size and format, filtered bilinear and clamped; with a depth texture when depth.
post_target :: proc(size: [2]i32, format: rl.PixelFormat, depth: bool) -> rl.RenderTexture2D {
	rt: rl.RenderTexture2D
	rt.id = rlgl.LoadFramebuffer()
	if rt.id == 0 do return {}
	rlgl.EnableFramebuffer(rt.id)
	rt.texture = {
		id      = rlgl.LoadTexture(nil, size.x, size.y, i32(format), 1),
		width   = size.x,
		height  = size.y,
		mipmaps = 1,
		format  = format,
	}
	rlgl.FramebufferAttach(
		rt.id,
		rt.texture.id,
		i32(rlgl.FramebufferAttachType.COLOR_CHANNEL0),
		i32(rlgl.FramebufferAttachTextureType.TEXTURE2D),
		0,
	)
	if depth {
		rt.depth = {
			id      = rlgl.LoadTextureDepth(size.x, size.y, false),
			width   = size.x,
			height  = size.y,
			mipmaps = 1,
		}
		rlgl.FramebufferAttach(
			rt.id,
			rt.depth.id,
			i32(rlgl.FramebufferAttachType.DEPTH),
			i32(rlgl.FramebufferAttachTextureType.TEXTURE2D),
			0,
		)
	}
	ok := rlgl.FramebufferComplete(rt.id)
	rlgl.DisableFramebuffer()
	if !ok {
		rl.UnloadRenderTexture(rt)
		return {}
	}
	rl.SetTextureFilter(rt.texture, .BILINEAR)
	rl.SetTextureWrap(rt.texture, .CLAMP)
	return rt
}

post_unload_targets :: proc(p: ^Post) {
	if p.hdr.id != 0 do rl.UnloadRenderTexture(p.hdr)
	if p.ao.id != 0 do rl.UnloadRenderTexture(p.ao)
	if p.ao2.id != 0 do rl.UnloadRenderTexture(p.ao2)
	if p.ldr.id != 0 do rl.UnloadRenderTexture(p.ldr)
	for b in p.bloom do if b.id != 0 do rl.UnloadRenderTexture(b)
	p.hdr, p.ao, p.ao2, p.ldr, p.bloom = {}, {}, {}, {}, {}
	p.size = {}
}

post_unload :: proc(p: ^Post) {
	post_unload_targets(p)
	if !p.ready do return
	for sh in ([6]rl.Shader{p.sh_ao, p.sh_bl, p.sh_dn, p.sh_up, p.sh_fin, p.sh_aa}) do rl.UnloadShader(sh)
	p.ready = false
}

// Before the scene: (re)makes the targets for the render size and starts drawing into the float target.
// false: no float target on this machine, the scene goes straight to the screen as before.
post_begin :: proc(w: ^World) -> bool {
	p := &w.street.post
	if !p.ready {
		p.sh_ao = rl.LoadShaderFromMemory(nil, POST_AO_FS)
		p.sh_bl = rl.LoadShaderFromMemory(nil, POST_BLUR_FS)
		p.sh_dn = rl.LoadShaderFromMemory(nil, POST_DOWN_FS)
		p.sh_up = rl.LoadShaderFromMemory(nil, POST_UP_FS)
		p.sh_fin = rl.LoadShaderFromMemory(nil, POST_FINAL_FS)
		p.sh_aa = rl.LoadShaderFromMemory(nil, POST_FXAA_FS)
		for sh in ([6]rl.Shader{p.sh_ao, p.sh_bl, p.sh_dn, p.sh_up, p.sh_fin, p.sh_aa}) {
			if !rl.IsShaderValid(sh) do logf(w, "post", "a post shader did not compile")
		}
		p.ready = true
	}
	size := [2]i32{rl.GetRenderWidth(), rl.GetRenderHeight()}
	if size != p.size {
		post_unload_targets(p)
		p.size = size
		half := linalg.max(size / 2, 1)
		p.hdr = post_target(size, .UNCOMPRESSED_R16G16B16A16, true)
		p.ao = post_target(half, .UNCOMPRESSED_R8G8B8A8, false)
		p.ao2 = post_target(half, .UNCOMPRESSED_R8G8B8A8, false)
		p.ldr = post_target(size, .UNCOMPRESSED_R8G8B8A8, false)
		s := size
		for &b in p.bloom {
			s = linalg.max(s / 2, 1)
			b = post_target(s, .UNCOMPRESSED_R16G16B16A16, false)
		}
		if p.hdr.id == 0 do logf(w, "post", "no float render target, the street view draws without post effects")
	}
	if p.hdr.id == 0 do return false
	rl.BeginTextureMode(p.hdr)
	return true
}

Post_Tex :: struct {
	name: cstring,
	tex:  rl.Texture2D,
}

// One full-target pass of shader sh into dst, or onto the screen when dst has no id (its other uniforms set
// before). The textures are bound inside: raylib forgets bound samplers whenever it flushes its batch, which
// changing the target does.
post_pass :: proc(dst: rl.RenderTexture2D, sh: rl.Shader, texs: []Post_Tex, blend := false) {
	if dst.id != 0 do rl.BeginTextureMode(dst)
	rlgl.DrawRenderBatchActive()
	// Replace, never blend, unless asked: raylib blends by alpha by default, and the final pass keeps the luma
	// in alpha, so every frame was mixed with the one before (ghost copies when turning, Lars 2026-11-22:
	// "te veel motion blur, als ik snel draai vervagen veel zaken").
	if blend do rl.BeginBlendMode(.ADDITIVE)
	else do rlgl.DisableColorBlend()
	rl.BeginShaderMode(sh)
	for t in texs do rl.SetShaderValueTexture(sh, rl.GetShaderLocation(sh, t.name), t.tex)
	size :=
		dst.id != 0 ? [2]i32{dst.texture.width, dst.texture.height} : [2]i32{rl.GetScreenWidth(), rl.GetScreenHeight()}
	rl.DrawRectangle(0, 0, size.x, size.y, rl.WHITE)
	rl.EndShaderMode()
	if blend do rl.EndBlendMode()
	else do rlgl.EnableColorBlend()
	if dst.id != 0 do rl.EndTextureMode()
}

post_size :: proc(sh: rl.Shader, name: cstring, t: rl.Texture2D) {
	v := [2]f32{f32(t.width), f32(t.height)}
	rl.SetShaderValue(sh, rl.GetShaderLocation(sh, name), &v, .VEC2)
}

post_float :: proc(sh: rl.Shader, name: cstring, v: f32) {
	v := v
	rl.SetShaderValue(sh, rl.GetShaderLocation(sh, name), &v, .FLOAT)
}

// After the scene: AO, bloom, grading and FXAA onto the screen (the default framebuffer).
post_end :: proc(w: ^World, view: Post_View) {
	prof_zone(w, .Post)
	p := &w.street.post
	pe := &w.post_edit
	rl.EndTextureMode()
	p.frame += 1

	if pe.ao_on {
		sh := p.sh_ao
		post_size(sh, "size", p.ao.texture)
		th, up := view.tan_half, view.up_vs
		clip := [2]f32{STREET_NEAR_M, STREET_FAR_M}
		far := POST_AO_FAR_M
		rl.SetShaderValue(sh, rl.GetShaderLocation(sh, "tan_half"), &th, .VEC2)
		rl.SetShaderValue(sh, rl.GetShaderLocation(sh, "clip"), &clip, .VEC2)
		rl.SetShaderValue(sh, rl.GetShaderLocation(sh, "up_vs"), &up, .VEC3)
		rl.SetShaderValue(sh, rl.GetShaderLocation(sh, "far_fade"), &far, .VEC2)
		post_float(sh, "eye_h", view.eye_h)
		post_float(sh, "radius", pe.ao_radius_m)
		post_pass(p.ao, sh, {{"depth_tex", p.hdr.depth}})
		post_size(p.sh_bl, "size", p.ao2.texture)
		post_pass(p.ao2, p.sh_bl, {{"src", p.ao.texture}})
	}

	if pe.bloom_on {
		for b, i in p.bloom {
			sh := p.sh_dn
			src := i == 0 ? p.hdr.texture : p.bloom[i - 1].texture
			post_size(sh, "src_size", src)
			post_size(sh, "size", b.texture)
			post_float(sh, "karis", i == 0 ? 1 : 0)
			post_pass(b, sh, {{"src", src}})
		}
		for i := POST_BLOOM_LEVELS - 1; i > 0; i -= 1 {
			sh := p.sh_up
			post_size(sh, "src_size", p.bloom[i].texture)
			post_size(sh, "size", p.bloom[i - 1].texture)
			post_pass(p.bloom[i - 1], sh, {{"src", p.bloom[i].texture}}, true)
		}
	}

	{
		sh := p.sh_fin
		post_size(sh, "size", p.ldr.texture)
		post_float(sh, "bloom_k", pe.bloom_on ? pe.bloom : 0)
		post_float(sh, "ao_k", pe.ao_on ? pe.ao_strength : 0)
		post_float(sh, "exposure", pe.exposure)
		post_float(sh, "saturation", pe.saturation)
		post_float(sh, "contrast", pe.contrast)
		post_float(sh, "vignette", pe.vignette)
		post_float(sh, "grain", pe.grain)
		post_float(sh, "frame", f32(p.frame % 1024))
		texs := [3]Post_Tex{{"hdr", p.hdr.texture}, {"bloom", p.bloom[0].texture}, {"ao", p.ao2.texture}}
		post_pass(p.ldr, sh, texs[:])
	}

	{
		sh := p.sh_aa
		post_size(sh, "size", p.ldr.texture)
		post_float(sh, "enable", pe.fxaa_on ? 1 : 0)
		post_pass({}, sh, {{"tex", p.ldr.texture}})
	}
}

post_tab :: proc(w: ^World, x, y, width: f32, drag: ^int) -> f32 {
	e := &w.post_edit
	pal := palette(w)
	def := w.setting_defaults.post
	y := y
	if !w.street.on {
		ui_text(
			w,
			{x, y},
			"Zoom in to the car (street view) to see post effects.",
			.Roboto_400,
			13,
			pal.text_2,
		)
		y += 26
	}
	y = settings_toggles(
		w,
		x,
		y,
		width,
		{{"Ambient occlusion", &e.ao_on}, {"Bloom", &e.bloom_on}, {"Edge FXAA", &e.fxaa_on}},
	)
	rows := [?]Editor_Slider {
		{"Exposure", &e.exposure, def.exposure, 0.3, 2.5, "%.2f"},
		{"Saturation", &e.saturation, def.saturation, 0, 2, "%.2f"},
		{"Contrast", &e.contrast, def.contrast, 0, 1, "%.2f"},
		{"Bloom", &e.bloom, def.bloom, 0, 0.25, "%.3f"},
		{"AO strength", &e.ao_strength, def.ao_strength, 0, 1.5, "%.2f"},
		{"AO radius", &e.ao_radius_m, def.ao_radius_m, 0.2, 4, "%.2f m"},
		{"Vignette", &e.vignette, def.vignette, 0, 0.5, "%.2f"},
		{"Film grain", &e.grain, def.grain, 0, 0.04, "%.3f"},
	}
	return settings_sliders(w, x, y, width, rows[:], drag, 1, 2)
}
