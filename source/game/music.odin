// author: andrei
package game

import "core:math"
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

// MIDI notes per chord: bass, then the three pad tones (the arpeggio plays them an octave up).
MUSIC_CHORDS :: [4][4]int {
	{45, 57, 60, 64}, // Am
	{41, 57, 60, 65}, // F
	{48, 55, 60, 64}, // C
	{43, 55, 59, 62}, // G
}
// Chord tone per eighth note: 0-2 the pad tones, 3 the root an octave up.
MUSIC_ARP :: [8]int{0, 1, 2, 3, 2, 1, 2, 1}

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
	data, err := os.read_entire_file(MUSIC_PATH, context.temp_allocator)
	if err == nil do m.off = strings.trim_space(string(data)) == "off"
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

// Refills every stream buffer the device has played.
music_frame :: proc(w: ^World) {
	m := &w.music
	if !m.ready || m.off do return
	for rl.IsAudioStreamProcessed(m.stream) {
		music_fill(m)
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

music_fill :: proc(m: ^Soundtrack) {
	chords := MUSIC_CHORDS
	arp := MUSIC_ARP
	beat_s := 60.0 / f64(MUSIC_BPM)
	eighth_s := beat_s / 2
	chord_s := beat_s * 8
	for i in 0 ..< MUSIC_CHUNK {
		t := f64(m.frame) / MUSIC_RATE
		m.frame += 1
		chord_i := int(t / chord_s) % 4
		chord := chords[chord_i]
		tc := math.mod(t, chord_s)

		// Pad: two detuned voices per tone, faded in and out round each chord change, slowly breathing.
		pad: [2]f64
		fade := min(tc / 0.6, 1) * min((chord_s - tc) / 0.4, 1)
		breath := 0.8 + 0.2 * math.sin(math.TAU * t / (chord_s / 2))
		for k in 1 ..< 4 {
			hz := music_hz(chord[k])
			pad[0] += music_tone(hz * 0.997, t)
			pad[1] += music_tone(hz * 1.003, t)
		}
		for c in 0 ..< 2 {
			m.pad_lp[c] += (f32(pad[c] * fade * breath) - m.pad_lp[c]) * 0.06
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

		// Soft kick on the first beat of every bar: a falling sine.
		tk := math.mod(t, beat_s * 4)
		kick := math.sin(math.TAU * (45 * tk + 40 * (1 - math.exp(-tk * 30)))) * math.exp(-tk * 9)

		at := m.echo_at
		from := (at - MUSIC_ECHO_FRAMES + MUSIC_ECHO_MAX) % MUSIC_ECHO_MAX
		late := [2]f32{m.echo[0][from], m.echo[1][from]}
		for c in 0 ..< 2 {
			side := c == 0 ? 1 - pan : 1 + pan
			dry := f64(m.pad_lp[c]) * 0.07 + bass * 0.22 + kick * 0.25 + hat * 0.025
			wet := pluck * 0.12 * side
			// Ping-pong: each side echoes what the other side had.
			m.echo[c][at] = f32(wet) + late[1 - c] * 0.42
			out := (dry + wet + f64(late[c]) * 0.5) * MUSIC_VOLUME
			m.buf[i * 2 + c] = f32(math.tanh(out))
		}
		m.echo_at = (at + 1) % MUSIC_ECHO_MAX
	}
}
