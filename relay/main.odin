// author: andrei
// Carpool relay: stores signed messages and hands them to whoever asks, in arrival order.
//   odin build relay -out:build/relay && ./build/relay [port] [store file] [weather dir]
// Defaults: port 7419, store cache/relay.log, snapshots in cache/relay_weather/<sha256 hex>.snap.
// Plain TCP, one request per connection:
//   'P' + one message (MSG_SIZE bytes)  -> status u8 (0 stored, 1 rejected) + index u64le
//   'G' + after u64le + max u32le        -> count u32le + count messages, starting at index `after`
//   'W' + one weather snapshot (SNAPSHOT_SIZE bytes) -> status u8 (0 stored or already there, 1 rejected)
//   'H' + sha256 (32 bytes)              -> status u8 (0 found, 1 not found) + the snapshot when found
// Subscribers poll 'G' with the index after the last message they have. The relay does not check
// signatures (clients do, with game.msg_read), only size, magic, version and kind, so it needs
// nothing from the game package. The store is the messages back to back, index = offset / MSG_SIZE.
package relay

import "core:crypto/hash"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:strconv"
import "core:time"

// Keep in sync with Message in source/game/net.odin.
MSG_SIZE :: 184
MSG_MAGIC :: 0x534d5244
MSG_VERSION :: 1
MSG_KINDS :: 4

// Keep in sync with Snapshot in source/game/net.odin: header (magic, version, fetched_at, sha256 of the
// weather bytes) + Weather. The relay checks the hash so a snapshot can only be stored under its own name.
SNAPSHOT_SIZE :: 22736
SNAPSHOT_HEADER :: 48
SNAPSHOT_MAGIC :: 0x53575244
SNAPSHOT_VERSION :: 1

MAX_GET :: 256
TIMEOUT :: 5 * time.Second

main :: proc() {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		fmt.eprintln("[relay] cannot create arena:", err)
		os.exit(1)
	}
	context.allocator = virtual.arena_allocator(&arena)

	port := 7419
	path := "cache/relay.log"
	if len(os.args) > 1 {
		ok: bool
		if port, ok = strconv.parse_int(os.args[1]); !ok || port <= 0 || port > 65535 {
			fmt.eprintfln("[relay] port %q is not a number in 1..65535", os.args[1])
			os.exit(1)
		}
	}
	if len(os.args) > 2 do path = os.args[2]
	weather_dir := len(os.args) > 3 ? os.args[3] : "cache/relay_weather"
	if err := os.make_directory_all(weather_dir); err != nil && err != .Exist {
		fmt.eprintfln("[relay] cannot create %s: %v", weather_dir, err)
		os.exit(1)
	}

	// All messages stay in memory as well: 10k messages are 1.8 MB.
	store: [dynamic]u8
	if os.exists(path) {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil || len(data) % MSG_SIZE != 0 {
			fmt.eprintfln(
				"[relay] %s: %v, %d bytes is not a multiple of %d, refusing to start",
				path,
				err,
				len(data),
				MSG_SIZE,
			)
			os.exit(1)
		}
		append(&store, ..data)
	}
	perm := os.Permissions{.Read_User, .Write_User, .Read_Group, .Read_Other}
	file, ferr := os.open(path, {.Write, .Create, .Append}, perm)
	if ferr != nil {
		fmt.eprintfln("[relay] cannot open %s for appending: %v", path, ferr)
		os.exit(1)
	}
	sock, lerr := net.listen_tcp({net.IP4_Any, port})
	if lerr != nil {
		fmt.eprintfln("[relay] cannot listen on port %d: %v", port, lerr)
		os.exit(1)
	}
	fmt.eprintfln("[relay] listening on port %d, %d messages in %s", port, len(store) / MSG_SIZE, path)

	// One connection at a time. A slow or silent client costs at most TIMEOUT per direction.
	for {
		client, source, aerr := net.accept_tcp(sock)
		if aerr != nil {
			fmt.eprintln("[relay] accept failed:", aerr)
			continue
		}
		net.set_option(client, .Receive_Timeout, TIMEOUT)
		net.set_option(client, .Send_Timeout, TIMEOUT)
		from := net.endpoint_to_string(source, context.temp_allocator)

		op: [1]u8
		if !recv_full(client, op[:]) {
			net.close(client)
			continue
		}
		switch op[0] {
		case 'P':
			msg: [MSG_SIZE]u8
			if !recv_full(client, msg[:]) {
				fmt.eprintfln("[relay] %s: post cut off", from)
				break
			}
			reply: [9]u8
			magic := (^u32le)(&msg[0])^
			kind := msg[5]
			if magic != MSG_MAGIC || msg[4] != MSG_VERSION || kind < 1 || kind > MSG_KINDS {
				reply[0] = 1
				fmt.eprintfln("[relay] %s: rejected, magic %x version %d kind %d", from, magic, msg[4], kind)
			} else if _, werr := os.write(file, msg[:]); werr != nil {
				reply[0] = 1
				fmt.eprintfln("[relay] %s: cannot write %s: %v, not stored", from, path, werr)
			} else {
				(^u64le)(&reply[1])^ = u64le(len(store) / MSG_SIZE)
				append(&store, ..msg[:])
				fmt.eprintfln("[relay] %s: stored #%d, kind %d", from, len(store) / MSG_SIZE - 1, kind)
			}
			send_all(client, reply[:])
		case 'G':
			req: [12]u8
			if !recv_full(client, req[:]) {
				fmt.eprintfln("[relay] %s: get cut off", from)
				break
			}
			total := len(store) / MSG_SIZE
			after := int(min(u64((^u64le)(&req[0])^), u64(total)))
			count := min(int((^u32le)(&req[8])^), MAX_GET, total - after)
			head: [4]u8
			(^u32le)(&head[0])^ = u32le(count)
			if send_all(client, head[:]) {
				send_all(client, store[after * MSG_SIZE:][:count * MSG_SIZE])
			}
			fmt.eprintfln("[relay] %s: sent %d from #%d (%d stored)", from, count, after, total)
		case 'W':
			snap := make([]u8, SNAPSHOT_SIZE, context.temp_allocator)
			if !recv_full(client, snap) {
				fmt.eprintfln("[relay] %s: weather cut off", from)
				break
			}
			status := [1]u8{1}
			digest: [32]u8
			hash.hash_bytes_to_buffer(.SHA256, snap[SNAPSHOT_HEADER:], digest[:])
			name := snapshot_path(weather_dir, snap[16:48])
			if (^u32le)(&snap[0])^ != SNAPSHOT_MAGIC || (^u32le)(&snap[4])^ != SNAPSHOT_VERSION {
				fmt.eprintfln("[relay] %s: weather rejected, wrong magic or version", from)
			} else if mem.compare(digest[:], snap[16:48]) != 0 {
				fmt.eprintfln("[relay] %s: weather rejected, sha256 does not match its header", from)
			} else if os.exists(name) {
				status[0] = 0
				fmt.eprintfln("[relay] %s: weather %s already stored", from, name)
			} else if err := os.write_entire_file(name, snap); err != nil {
				fmt.eprintfln("[relay] %s: cannot write %s: %v", from, name, err)
			} else {
				status[0] = 0
				fmt.eprintfln("[relay] %s: stored weather %s", from, name)
			}
			send_all(client, status[:])
		case 'H':
			want: [32]u8
			if !recv_full(client, want[:]) {
				fmt.eprintfln("[relay] %s: weather request cut off", from)
				break
			}
			name := snapshot_path(weather_dir, want[:])
			snap, err := os.read_entire_file(name, context.temp_allocator)
			if err != nil || len(snap) != SNAPSHOT_SIZE {
				fmt.eprintfln("[relay] %s: no weather %s (%v)", from, name, err)
				send_all(client, {1})
				break
			}
			if send_all(client, {0}) do send_all(client, snap)
			fmt.eprintfln("[relay] %s: sent weather %s", from, name)
		case:
			fmt.eprintfln("[relay] %s: unknown request %d", from, op[0])
		}
		net.close(client)
		free_all(context.temp_allocator)
	}
}

// Names come only from hex digits of the hash, so a request cannot point outside weather_dir.
snapshot_path :: proc(dir: string, sha: []u8) -> string {
	digits := "0123456789abcdef"
	hex: [64]u8
	for b, i in sha[:32] {
		hex[2 * i] = digits[b >> 4]
		hex[2 * i + 1] = digits[b & 15]
	}
	return fmt.tprintf("%s/%s.snap", dir, string(hex[:]))
}

recv_full :: proc(s: net.TCP_Socket, buf: []u8) -> bool {
	for got := 0; got < len(buf); {
		n, err := net.recv_tcp(s, buf[got:])
		if err != nil || n == 0 do return false
		got += n
	}
	return true
}

send_all :: proc(s: net.TCP_Socket, buf: []u8) -> bool {
	for sent := 0; sent < len(buf); {
		n, err := net.send_tcp(s, buf[sent:])
		if err != nil do return false
		sent += n
	}
	return true
}
