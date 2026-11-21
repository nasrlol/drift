// author: andrei
// Carpool relay: stores signed messages and hands them to whoever asks, in arrival order.
//   odin build relay -out:build/relay && ./build/relay [port] [store file]
// Defaults: port 7419, store cache/relay.log. Plain TCP, one request per connection:
//   'P' + one message (MSG_SIZE bytes)  -> status u8 (0 stored, 1 rejected) + index u64le
//   'G' + after u64le + max u32le        -> count u32le + count messages, starting at index `after`
// Subscribers poll 'G' with the index after the last message they have. The relay does not check
// signatures (clients do, with game.msg_read), only size, magic, version and kind, so it needs
// nothing from the game package. The store is the messages back to back, index = offset / MSG_SIZE.
package relay

import "core:fmt"
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
		case:
			fmt.eprintfln("[relay] %s: unknown request %d", from, op[0])
		}
		net.close(client)
		free_all(context.temp_allocator)
	}
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
