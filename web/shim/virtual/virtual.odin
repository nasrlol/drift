// author: dario
// Browser stand-in for the part of core:mem/virtual the game uses. wasm has no virtual memory, so an arena is a
// chain of blocks from the Emscripten heap. Same names and lifetimes as the real package.
package virtual

import "base:runtime"
import "core:c"
import "core:mem"
import "core:reflect"

MIN_BLOCK :: 1 << 20

@(default_calling_convention = "c")
foreign _ {
	malloc :: proc(size: c.size_t) -> rawptr ---
	free :: proc(p: rawptr) ---
}

Block :: struct {
	prev: ^Block,
	used: uint,
	size: uint,
}

Arena :: struct {
	block:          ^Block,
	total_used:     uint,
	total_reserved: uint,
}

Allocator_Error :: mem.Allocator_Error

arena_block_new :: proc(a: ^Arena, need: uint) -> Allocator_Error {
	size := max(need, MIN_BLOCK)
	p := (^Block)(malloc(c.size_t(size_of(Block) + size)))
	if p == nil do return .Out_Of_Memory
	p^ = {
		prev = a.block,
		size = size,
	}
	a.block = p
	a.total_reserved += size
	return nil
}

arena_alloc :: proc(a: ^Arena, size, align: uint) -> ([]byte, Allocator_Error) {
	fit :: proc(b: ^Block, align: uint) -> uint {
		base := uint(uintptr(b)) + size_of(Block)
		return mem.align_forward_uint(base + b.used, align) - base
	}
	if a.block == nil || fit(a.block, align) + size > a.block.size {
		if err := arena_block_new(a, size + align); err != nil do return nil, err
	}
	at := fit(a.block, align)
	a.total_used += at + size - a.block.used
	a.block.used = at + size
	p :=([^]byte)(uintptr(a.block) + size_of(Block) + uintptr(at))
	return p[:size], nil
}

arena_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	a := (^Arena)(data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		b, err := arena_alloc(a, uint(size), uint(max(alignment, 1)))
		if err == nil && mode == .Alloc do mem.zero_slice(b)
		return b, err
	case .Resize, .Resize_Non_Zeroed:
		if size <= old_size && old_memory != nil do return ([^]byte)(old_memory)[:size], nil
		b, err := arena_alloc(a, uint(size), uint(max(alignment, 1)))
		if err != nil do return nil, err
		if old_memory != nil do mem.copy(raw_data(b), old_memory, old_size)
		if mode == .Resize do mem.zero_slice(b[old_size:])
		return b, nil
	case .Free_All:
		arena_free_all(a)
		return nil, nil
	case .Free:
		return nil, nil
	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Free_All, .Query_Features}
		}
		return nil, nil
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, .Mode_Not_Implemented
}

arena_allocator :: proc(a: ^Arena) -> mem.Allocator {
	return {arena_proc, a}
}

arena_init_growing :: proc(a: ^Arena, reserved: uint = MIN_BLOCK) -> Allocator_Error {
	a^ = {}
	return arena_block_new(a, reserved)
}

// Keeps the oldest block so a per-frame arena does not go back to malloc every frame.
arena_free_all :: proc(a: ^Arena) {
	if a.block == nil do return
	for a.block.prev != nil {
		prev := a.block.prev
		a.total_reserved -= a.block.size
		free(a.block)
		a.block = prev
	}
	a.block.used = 0
	a.total_used = 0
}

arena_destroy :: proc(a: ^Arena) {
	for a.block != nil {
		prev := a.block.prev
		free(a.block)
		a.block = prev
	}
	a.total_used = 0
	a.total_reserved = 0
}

arena_growing_bootstrap_new :: proc($T: typeid, field: string) -> (^T, Allocator_Error) {
	arena: Arena
	if err := arena_init_growing(&arena, size_of(T)); err != nil do return nil, err
	b, err := arena_alloc(&arena, size_of(T), align_of(T))
	if err != nil {
		arena_destroy(&arena)
		return nil, err
	}
	mem.zero_slice(b)
	t := (^T)(raw_data(b))
	f := reflect.struct_field_by_name(T, field)
	assert(f.type != nil && f.type.id == Arena, "bootstrap field must be an Arena")
	(^Arena)(uintptr(t) + f.offset)^ = arena
	return t, nil
}
