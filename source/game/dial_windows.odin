// author: andrei
package game

import "core:net"
import "core:sync"
import win "core:sys/windows"

// See dial_posix.odin.
net_dial :: proc(ep: net.Endpoint, stop: ^bool) -> (s: net.TCP_Socket, ok: bool) {
	sock, err := net.create_socket(net.family_from_endpoint(ep), .TCP)
	if err != nil do return
	s = sock.(net.TCP_Socket)
	defer if !ok do net.close(s)
	if net.set_blocking(s, false) != nil do return
	sa: win.SOCKADDR_STORAGE_LH
	switch a in ep.address {
	case net.IP4_Address:
		(^win.sockaddr_in)(&sa)^ = {
			sin_family = u16(win.AF_INET),
			sin_port   = u16be(ep.port),
			sin_addr   = transmute(win.in_addr)a,
		}
	case net.IP6_Address:
		(^win.sockaddr_in6)(&sa)^ = {
			sin6_family = u16(win.AF_INET6),
			sin6_port   = u16be(ep.port),
			sin6_addr   = transmute(win.in6_addr)a,
		}
	}
	if win.connect(win.SOCKET(s), &sa, size_of(sa)) != 0 && win.WSAGetLastError() != win.WSAEWOULDBLOCK {
		return
	}
	pfd := win.WSA_POLLFD {
		fd     = win.SOCKET(s),
		events = win.POLLWRNORM,
	}
	for waited := 0;; waited += 100 {
		if waited >= NET_TIMEOUT_MS || sync.atomic_load(stop) do return
		r := win.WSAPoll(&pfd, 1, 100)
		if r < 0 do return
		if r == 1 do break
	}
	if pfd.revents & (win.POLLERR | win.POLLHUP) != 0 do return
	if net.set_blocking(s, true) != nil || !net_options(s) do return
	return s, true
}
