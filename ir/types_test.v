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
// are values and i24 is a memory type; the example line under that rule says
// i24 is not, which contradicts the rule it follows.
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
