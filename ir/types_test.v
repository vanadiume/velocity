module ir

fn test_type_spellings() {
	assert ty_i1.str() == 'i1'
	assert ty_i8.str() == 'i8'
	assert int_type(24).str() == 'i24'
	assert ty_i32.str() == 'i32'
	assert ty_i128.str() == 'i128'
	assert ty_f16.str() == 'f16'
	assert ty_f128.str() == 'f128'
	assert ty_ptr.str() == 'ptr'
	assert ty_unknown.str() == 'untyped'
}

fn test_every_integer_width_parses() {
	for width in 1 .. 129 {
		typ := type_from_text('i${width}') or { panic('i${width} was refused: ${err.msg()}') }
		assert typ.is_int()
		assert typ.bits == u16(width)
	}
}

fn test_float_and_pointer_spellings_parse() {
	assert type_from_text('f16')! == ty_f16
	assert type_from_text('f32')! == ty_f32
	assert type_from_text('f64')! == ty_f64
	assert type_from_text('f128')! == ty_f128
	assert type_from_text('ptr')! == ty_ptr
}

fn test_unknown_types_are_refused() {
	for text in ['i0', 'i129', 'i256', 'f8', 'f256', 'bool', 'void', 'i', 'i01', 'f'] {
		typ := type_from_text(text) or {
			assert err.msg().contains('unknown type')
			continue
		}
		assert false, '${text} was accepted as a type (${typ})'
	}
}

fn test_sizes() {
	assert ty_i1.size(64) == 1
	assert ty_i8.size(64) == 1
	assert int_type(24).size(64) == 3
	assert ty_i32.size(64) == 4
	assert ty_i64.size(64) == 8
	assert ty_i128.size(64) == 16
	assert int_type(97).size(64) == 13
	assert ty_f16.size(64) == 2
	assert ty_f32.size(64) == 4
	assert ty_f64.size(64) == 8
	assert ty_f128.size(64) == 16
	assert ty_ptr.size(64) == 8
	assert ty_ptr.size(32) == 4
}

fn test_bit_sizes() {
	assert ty_i1.bit_size(64) == 1
	assert int_type(97).bit_size(64) == 97
	assert ty_f128.bit_size(64) == 128
	assert ty_ptr.bit_size(64) == 64
	assert ty_ptr.bit_size(32) == 32
	assert ty_unknown.bit_size(64) == 0
}

// Only a byte-sized integer, a float or a pointer may be loaded, stored, or
// given a slot or a global. The rule in ir-types.md is N % 8 == 0, so i1 and i3
// are values and i24 is a memory type.
fn test_memory_types() {
	assert ty_i1.is_memory() == false
	assert int_type(3).is_memory() == false
	assert int_type(24).is_memory()
	assert ty_i8.is_memory()
	assert int_type(97).is_memory() == false
	assert ty_i128.is_memory()
	assert ty_f16.is_memory()
	assert ty_f64.is_memory()
	assert ty_ptr.is_memory()
	assert ty_unknown.is_memory() == false
}

fn test_type_equality_is_spelling() {
	assert ty_i32 == int_type(32)
	assert ty_i32 != ty_i64
	assert ty_ptr != ty_i64
	assert ty_f32 != ty_i32
}

fn test_type_kinds() {
	assert ty_i32.is_int()
	assert ty_i32.is_float() == false
	assert ty_f64.is_float()
	assert ty_ptr.is_ptr()
	assert ty_ptr.is_scalar()
	assert ty_unknown.is_unknown()
	assert ty_unknown.is_scalar() == false
}

// The three aggregate forms print in full and lay out by ir-types.md: fields
// at their own alignment, the size rounded up to the struct's, an array by its
// element, and a vector aligned to its size rounded up to a power of two.
fn test_aggregate_types_print_and_lay_out() {
	pair := struct_type([ty_i32, ty_i8])
	assert pair.str() == '{i32, i8}'
	assert pair.size(64) == 8
	assert pair.align_natural() == 4

	row := array_type(ty_f32, 4)
	assert row.str() == '[4 x f32]'
	assert row.size(64) == 16
	assert row.align_natural() == 4

	lanes := vector_type(ty_i16, 8)
	assert lanes.str() == '<8 x i16>'
	assert lanes.size(64) == 16
	assert lanes.align_natural() == 16

	nested := struct_type([ty_ptr, array_type(ty_i32, 4)])
	assert nested.str() == '{ptr, [4 x i32]}'
	assert nested.size(64) == 24
	assert nested.align_natural() == 8

	// i24 is three bytes and aligns to one, so the struct's size is the sum
	// rounded to the largest field alignment, which is still one.
	odd := struct_type([int_type(24), ty_i8])
	assert odd.size(64) == 4
	assert odd.align_natural() == 1

	// A 32-bit target lays a pointer out at four bytes and four-byte alignment.
	small := struct_type([ty_i8, ty_ptr])
	assert small.size_for(TargetInfo{
		pointer_width: 32
		pointer_align: 4
		endian:        .little
	}) == 8
	assert small.align_of(TargetInfo{
		pointer_width: 32
		pointer_align: 4
		endian:        .little
	}) == 4
}

fn test_aggregate_memory_types() {
	assert struct_type([ty_i32, ty_i8]).is_memory()
	assert struct_type([ty_i1]).is_memory() == false
	assert array_type(ty_i32, 4).is_memory()
	assert array_type(ty_i1, 4).is_memory() == false
	assert vector_type(ty_f32, 4).is_memory()
	assert vector_type(ty_ptr, 2).is_memory()
	assert struct_type([ty_i32]).is_aggregate()
	assert vector_type(ty_i32, 4).is_aggregate()
	assert array_type(ty_i32, 4).is_aggregate()
	assert ty_i32.is_aggregate() == false
}
