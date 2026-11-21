// author: dario
// core:os does not exist on js/wasm. The browser build has no disk: reads find nothing and writes report an error,
// which the game already handles by staying on the embedded data.
package os

import "base:runtime"

General_Error :: enum u32 {
	None,
	Exist,
	Not_Exist,
	Unsupported,
}

Error :: union #shared_nil {
	General_Error,
	runtime.Allocator_Error,
}

Permission_Flag :: enum u32 {
	Read_User,
	Write_User,
}
Permissions :: bit_set[Permission_Flag;u32]

File_Flag :: enum u32 {
	Read,
	Write,
	Create,
	Append,
}
File_Flags :: bit_set[File_Flag;u32]

File :: struct {}

File_Info :: struct {
	fullpath: string,
	name:     string,
	size:     i64,
}

exists :: proc(path: string) -> bool {
	return false
}

open :: proc(path: string, flags: File_Flags = {.Read}, perm: Permissions = {}) -> (^File, Error) {
	return nil, General_Error.Not_Exist
}

close :: proc(f: ^File) -> Error {
	return nil
}

read :: proc(f: ^File, buf: []byte) -> (int, Error) {
	return 0, General_Error.Unsupported
}

read_full :: proc(f: ^File, buf: []byte) -> (int, Error) {
	return 0, General_Error.Unsupported
}

write :: proc(f: ^File, buf: []byte) -> (int, Error) {
	return 0, General_Error.Unsupported
}

read_entire_file :: proc(path: string, allocator: runtime.Allocator) -> ([]byte, Error) {
	return nil, General_Error.Not_Exist
}

write_entire_file_bytes :: proc(path: string, data: []byte, perm: Permissions = {}) -> Error {
	return General_Error.Unsupported
}

write_entire_file_string :: proc(path: string, data: string, perm: Permissions = {}) -> Error {
	return General_Error.Unsupported
}

write_entire_file :: proc {
	write_entire_file_bytes,
	write_entire_file_string,
}

make_directory :: proc(path: string) -> Error {
	return General_Error.Unsupported
}

make_directory_all :: proc(path: string) -> Error {
	return General_Error.Unsupported
}

rename :: proc(from, to: string) -> Error {
	return General_Error.Unsupported
}

remove :: proc(path: string) -> Error {
	return General_Error.Not_Exist
}

read_all_directory_by_path :: proc(path: string, allocator: runtime.Allocator) -> ([]File_Info, Error) {
	return nil, General_Error.Not_Exist
}
