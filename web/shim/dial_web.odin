// author: dario
// Copied into the staged game package instead of dial_posix.odin / dial_windows.odin. A browser has no sockets.
package game

import "core:net"

net_dial :: proc(ep: net.Endpoint, stop: ^bool) -> (s: net.TCP_Socket, ok: bool) {
	return
}
