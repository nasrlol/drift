// author: andrei
package game

import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

// The soundtrack (Andrei, 2026-11-21: "kun je ook een soundtrack erin steken"): a calm synth loop made here in
// code, no audio file. Am F C G, two bars per chord at MUSIC_BPM: a soft pad, a bass on the root, a plucked
// arpeggio with a ping-pong echo, a quiet hi-hat on the off-beats and a soft kick on every bar. N turns it on
// and off, the choice is saved in MUSIC_PATH. Filled from the frame loop (no audio callback thread). Notes,
// sounds and levels are ours.
MUSIC_RATE :: 44100
MUSIC_BPM :: 84
MUSIC_VOLUME :: 0.5
MUSIC_PATH :: "cache/music.txt"
MUSIC_CHUNK :: 4096 // frames per stream buffer, about 93 ms
MUSIC_ECHO_MAX :: 32768 // frames per echo channel
MUSIC_BEAT_FRAMES :: MUSIC_RATE * 60 / MUSIC_BPM
MUSIC_ECHO_FRAMES :: MUSIC_BEAT_FRAMES * 3 / 4 // a dotted eighth
#assert(MUSIC_ECHO_FRAMES < MUSIC_ECHO_MAX)
MUSIC_PAD_FADE_S :: 0.6
MUSIC_KICK_SWEEP_HZ :: 75.0

// MIDI notes per chord: bass, then the three pad tones (the arpeggio plays them an octave up).
MUSIC_CHORDS :: [4][4]int {
	{45, 57, 60, 64}, // Am
	{41, 57, 60, 65}, // F
	{48, 55, 60, 64}, // C
	{43, 55, 59, 62}, // G
}
// Chord tone per eighth note: 0-2 the pad tones, 3 the root an octave up.
MUSIC_ARP :: [8]int{0, 1, 2, 3, 2, 1, 2, 1}

Music_Edit :: struct {
	volume:     f32,
	bpm:        f32,
	pad_fade_s: f32,
	pad_gain:   f32,
	bass_gain:  f32,
	arp_gain:   f32,
	kick_gain:  f32,
	hat_gain:   f32,
	echo_gain:  f32,
}

music_edit_defaults :: proc() -> Music_Edit {
	return {
		volume = MUSIC_VOLUME,
		bpm = MUSIC_BPM,
		pad_fade_s = MUSIC_PAD_FADE_S,
		pad_gain = 0.07,
		bass_gain = 0.22,
		arp_gain = 0.12,
		kick_gain = 0.25,
		hat_gain = 0.025,
		echo_gain = 0.5,
	}
}

Soundtrack :: struct {
	stream:  rl.AudioStream,
	ready:   bool,
	off:     bool,
	frame:   i64, // frames written since the start
	echo:    [2][MUSIC_ECHO_MAX]f32,
	echo_at: int,
	pad_lp:  [2]f32, // one-pole low-pass state of the pad
	noise:   u32,
	buf:     [MUSIC_CHUNK * 2]f32,
}

// Opens the audio device and starts the stream (window up, not headless).
music_start :: proc(w: ^World) {
	m := &w.music
	// Off by default (nasr, 2026-11-21), on only when N saved "on". game_init runs before game_update points
	// context.temp_allocator at the frame arena.
	data, err := os.read_entire_file(MUSIC_PATH, virtual.arena_allocator(&w.frame))
	m.off = err != nil || strings.trim_space(string(data)) != "on"
	if !rl.IsAudioDeviceReady() do rl.InitAudioDevice()
	if !rl.IsAudioDeviceReady() {
		logf(w, "music", "no audio device, the game stays silent")
		return
	}
	rl.SetAudioStreamBufferSizeDefault(MUSIC_CHUNK)
	m.stream = rl.LoadAudioStream(MUSIC_RATE, 32, 2)
	m.noise = 0x9e3779b9
	m.ready = true
	rl.PlayAudioStream(m.stream)
	if m.off do rl.PauseAudioStream(m.stream)
	logf(w, "music", "soundtrack %s (N)", m.off ? "off" : "on")
}

music_stop :: proc(w: ^World) {
	m := &w.music
	if !m.ready do return
	rl.UnloadAudioStream(m.stream)
	rl.CloseAudioDevice()
	m.ready = false
}

music_toggle :: proc(w: ^World) {
	m := &w.music
	if !m.ready do return
	m.off = !m.off
	if m.off {
		rl.PauseAudioStream(m.stream)
	} else {
		rl.ResumeAudioStream(m.stream)
	}
	if err := os.write_entire_file(MUSIC_PATH, m.off ? "off" : "on"); err != nil {
		logf(w, "music", "cannot save %s: %v", MUSIC_PATH, err)
	}
	logf(w, "music", "soundtrack %s", m.off ? "off" : "on")
}

// Speaker button (plan map buttons, navigation button column): lit while the music plays, same as N.
music_button :: proc(w: ^World, r: rl.Rectangle) {
	m := &w.music
	on := m.ready && !m.off
	ui_tip(w, r, on ? "Mute music (M)" : "Play music (M)")
	if !ui_round_button(w, r, on ? .Speaker : .Speaker_Off, on) do return
	if !m.ready {
		ui_toast(w, "No audio device")
		return
	}
	music_toggle(w)
	ui_toast(w, m.off ? "Music off" : "Music on")
}

// Refills every stream buffer the device has played.
music_frame :: proc(w: ^World) {
	m := &w.music
	if !m.ready || m.off do return
	for rl.IsAudioStreamProcessed(m.stream) {
		music_fill(m, &w.music_edit)
		rl.UpdateAudioStream(m.stream, &m.buf, MUSIC_CHUNK)
	}
}

music_hz :: proc(note: int) -> f64 {
	return 440 * math.pow(2, f64(note - 69) / 12)
}

// A sine with a little second and third harmonic, warmer than a bare sine.
music_tone :: proc(hz, t: f64) -> f64 {
	p := math.TAU * hz * t
	return math.sin(p) + 0.25 * math.sin(2 * p) + 0.08 * math.sin(3 * p)
}

music_pad :: proc(pad: ^[2]f64, chord: [4]int, t, gain: f64) {
	for k in 1 ..< 4 {
		hz := music_hz(chord[k])
		pad[0] += music_tone(hz * 0.997, t) * gain
		pad[1] += music_tone(hz * 1.003, t) * gain
	}
}

music_fill :: proc(m: ^Soundtrack, me: ^Music_Edit) {
	chords := MUSIC_CHORDS
	arp := MUSIC_ARP
	bpm := max(f64(me.bpm), 30)
	beat_s := 60.0 / bpm
	eighth_s := beat_s / 2
	chord_s := beat_s * 8
	pad_fade_s := max(f64(me.pad_fade_s), 0.05)
	for i in 0 ..< MUSIC_CHUNK {
		t := f64(m.frame) / MUSIC_RATE
		m.frame += 1
		chord_i := int(t / chord_s) % 4
		chord := chords[chord_i]
		tc := math.mod(t, chord_s)

		// Pad: two detuned voices per tone, cross-faded from the last chord over pad_fade_s, slowly
		// breathing.
		pad: [2]f64
		fade := min(tc / pad_fade_s, 1)
		breath := 0.8 + 0.2 * math.sin(math.TAU * t / (chord_s / 2))
		music_pad(&pad, chord, t, fade)
		if fade < 1 && t >= chord_s do music_pad(&pad, chords[(chord_i + 3) % 4], t, 1 - fade)
		for c in 0 ..< 2 {
			m.pad_lp[c] += (f32(pad[c] * breath) - m.pad_lp[c]) * 0.06
		}

		// Bass on beats 1 and 3.
		tb := math.mod(t, beat_s * 2)
		bass := music_tone(music_hz(chord[0]), t) * min(tb / 0.01, 1) * math.exp(-tb * 1.8)

		// Arpeggio: one plucked note per eighth, panned left and right in turn.
		eighth := int(t / eighth_s)
		te := t - f64(eighth) * eighth_s
		step := arp[eighth % 8]
		note := step == 3 ? chord[0] + 24 : chord[step + 1] + 12
		pluck := math.sin(math.TAU * music_hz(note) * t) * min(te / 0.004, 1) * math.exp(-te * 7)
		pan := eighth % 2 == 0 ? 0.35 : -0.35

		// Hi-hat on the off-beats, from seeded noise.
		m.noise ~= m.noise << 13
		m.noise ~= m.noise >> 17
		m.noise ~= m.noise << 5
		white := f64(m.noise) / f64(max(u32)) * 2 - 1
		hat := eighth % 2 == 1 ? white * math.exp(-te * 70) : 0

		// Soft kick on the first beat of every bar: a sine falling from 45 + MUSIC_KICK_SWEEP_HZ to 45 Hz. The phase
		// is the integral of that pitch.
		tk := math.mod(t, beat_s * 4)
		sweep := MUSIC_KICK_SWEEP_HZ / 30 * (1 - math.exp(-tk * 30))
		kick := math.sin(math.TAU * (45 * tk + sweep)) * math.exp(-tk * 9)

		at := m.echo_at
		from := (at - MUSIC_ECHO_FRAMES + MUSIC_ECHO_MAX) % MUSIC_ECHO_MAX
		late := [2]f32{m.echo[0][from], m.echo[1][from]}
		for c in 0 ..< 2 {
			side := c == 0 ? 1 - pan : 1 + pan
			dry :=
				f64(m.pad_lp[c]) * f64(me.pad_gain) +
				bass * f64(me.bass_gain) +
				kick * f64(me.kick_gain) +
				hat * f64(me.hat_gain)
			wet := pluck * f64(me.arp_gain) * side
			// Ping-pong: each side echoes what the other side had.
			m.echo[c][at] = f32(wet) + late[1 - c] * 0.42
			out := (dry + wet + f64(late[c]) * f64(me.echo_gain)) * f64(me.volume)
			m.buf[i * 2 + c] = f32(math.tanh(out))
		}
		m.echo_at = (at + 1) % MUSIC_ECHO_MAX
	}
}

music_tab :: proc(w: ^World, x, y, width: f32, drag: ^int) -> f32 {
	e := &w.music_edit
	def := w.setting_defaults.music
	rows := [?]Editor_Slider {
		{"Volume", &e.volume, def.volume, 0, 1.2, "%.2f"},
		{"Tempo", &e.bpm, def.bpm, 40, 150, "%.0f bpm"},
		{"Pad fade", &e.pad_fade_s, def.pad_fade_s, 0.05, 3, "%.2f s"},
		{"Pad level", &e.pad_gain, def.pad_gain, 0, 0.25, "%.3f"},
		{"Bass level", &e.bass_gain, def.bass_gain, 0, 0.6, "%.2f"},
		{"Arp level", &e.arp_gain, def.arp_gain, 0, 0.4, "%.2f"},
		{"Kick level", &e.kick_gain, def.kick_gain, 0, 0.6, "%.2f"},
		{"Hi-hat level", &e.hat_gain, def.hat_gain, 0, 0.15, "%.3f"},
		{"Echo level", &e.echo_gain, def.echo_gain, 0, 1, "%.2f"},
	}
	return settings_sliders(w, x, y, width, rows[:], drag, 1, 2)
}
