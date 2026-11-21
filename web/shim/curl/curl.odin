// author: dario
// The browser build has no libcurl. net.odin compiles unchanged against this package: every request reports that
// it could not start, and the game keeps the embedded weather snapshot.
package curl

import "core:c"

CURL :: struct {}
off_t :: i64

GLOBAL_ALL :: 3

code :: enum c.int {
	E_OK,
	E_FAILED_INIT,
}

option :: enum c.int {
	URL,
	NOPROGRESS,
	XFERINFOFUNCTION,
	XFERINFODATA,
	WRITEFUNCTION,
	WRITEDATA,
	TIMEOUT_MS,
	FAILONERROR,
	USERAGENT,
}

global_init :: proc(flags: c.long) -> code {
	return .E_OK
}

easy_init :: proc() -> ^CURL {
	return nil
}

easy_cleanup :: proc(h: ^CURL) {}

easy_setopt :: proc(h: ^CURL, opt: option, args: ..any) -> code {
	return .E_FAILED_INIT
}

easy_perform :: proc(h: ^CURL) -> code {
	return .E_FAILED_INIT
}

easy_strerror :: proc(res: code) -> cstring {
	return "no libcurl in the browser build"
}
