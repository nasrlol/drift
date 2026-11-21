#+build !windows
// author: andrei
package game

import "core:net"
import "core:sync"
import "core:sys/posix"

// net.dial_tcp has no connect timeout: an unreachable peer would hold the sync thread for a minute or more,
// and node_stop (before every hot reload) waits for that thread. So: non-blocking connect, wait until the
// socket is writable, NET_TIMEOUT_MS passed or stop^ is set (checked every 100 ms), then back to blocking
// with timeouts.
net_dial :: proc(ep: net.Endpoint, stop: ^bool) -> (s: net.TCP_Socket, ok: bool) {
	sock, err := net.create_socket(net.family_from_endpoint(ep), .TCP)
	if err != nil do return
	s = sock.(net.TCP_Socket)
	defer if !ok do net.close(s)
	if net.set_blocking(s, false) != nil do return
	sa: posix.sockaddr_storage
	switch a in ep.address {
	case net.IP4_Address:
		sin := (^posix.sockaddr_in)(&sa)
		sin.sin_family = .INET
		sin.sin_port = u16be(ep.port)
		sin.sin_addr = transmute(posix.in_addr)a
		when ODIN_OS != .Linux do sin.sin_len = size_of(posix.sockaddr_in)
	case net.IP6_Address:
		sin6 := (^posix.sockaddr_in6)(&sa)
		sin6.sin6_family = .INET6
		sin6.sin6_port = u16be(ep.port)
		sin6.sin6_addr = transmute(posix.in6_addr)a
		when ODIN_OS != .Linux do sin6.sin6_len = size_of(posix.sockaddr_in6)
	}
	_, is6 := ep.address.(net.IP6_Address)
	size := posix.socklen_t(is6 ? size_of(posix.sockaddr_in6) : size_of(posix.sockaddr_in))
	if posix.connect(posix.FD(s), (^posix.sockaddr)(&sa), size) != .OK && posix.errno() != .EINPROGRESS {
		return
	}
	pfd := posix.pollfd {
		fd     = posix.FD(s),
		events = {.OUT},
	}
	for waited := 0; ; waited += 100 {
		if waited >= NET_TIMEOUT_MS || sync.atomic_load(stop) do return
		r := posix.poll(&pfd, 1, 100)
		if r < 0 do return
		if r == 1 do break
	}
	so_err: i32
	so_len := posix.socklen_t(size_of(so_err))
	if posix.getsockopt(posix.FD(s), posix.SOL_SOCKET, .ERROR, &so_err, &so_len) != .OK do return
	if so_err != 0 do return
	if net.set_blocking(s, true) != nil || !net_timeouts(s) do return
	return s, true
}
