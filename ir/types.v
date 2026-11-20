module ir

// The type model in ir-types.md: integers of every width from 1 to 128, four
// float widths, and one opaque pointer. A type is structural, has no name, and
// two types are equal when their spelling is equal.

pub enum TypeKind {
	unknown // not stated by the text at this place
	int
	float
	ptr
}

pub struct Type {
pub:
	kind TypeKind
	bits u16
}

// The pointer-width integers, and the scalars the text form spells most often.
pub const ty_i1 = Type{
	kind: .int
	bits: 1
}

pub const ty_i8 = Type{
	kind: .int
	bits: 8
}

pub const ty_i16 = Type{
	kind: .int
	bits: 16
}

pub const ty_i32 = Type{
	kind: .int
	bits: 32
}

pub const ty_i64 = Type{
	kind: .int
	bits: 64
}

pub const ty_i128 = Type{
	kind: .int
	bits: 128
}

pub const ty_f16 = Type{
	kind: .float
	bits: 16
}

pub const ty_f32 = Type{
	kind: .float
	bits: 32
}

pub const ty_f64 = Type{
	kind: .float
	bits: 64
}

pub const ty_f128 = Type{
	kind: .float
	bits: 128
}

pub const ty_ptr = Type{
	kind: .ptr
}

// ty_unknown is what an operand or a result carries when the text does not say
// its type. The parser records it rather than guessing; the verifier is where a
// value with no type is rejected.
pub const ty_unknown = Type{
	kind: .unknown
}

pub fn int_type(bits u16) Type {
	return Type{
		kind: .int
		bits: bits
	}
}

pub fn float_type(bits u16) Type {
	return Type{
		kind: .float
		bits: bits
	}
}

pub fn (t Type) is_int() bool {
	return t.kind == .int
}

pub fn (t Type) is_float() bool {
	return t.kind == .float
}

pub fn (t Type) is_ptr() bool {
	return t.kind == .ptr
}

pub fn (t Type) is_unknown() bool {
	return t.kind == .unknown
}

pub fn (t Type) is_scalar() bool {
	return t.kind in [.int, .float, .ptr]
}

// bit_size is the width of the type in bits. A pointer's width is a target
// fact, so it is passed in rather than stored on the type.
pub fn (t Type) bit_size(pointer_width u16) int {
	return match t.kind {
		.int, .float { int(t.bits) }
		.ptr { int(pointer_width) }
		.unknown { 0 }
	}
}

// size is the byte size from ir-types.md: ceil(N / 8) for an integer, the
// width over eight for a float, and the pointer width over eight for a pointer.
pub fn (t Type) size(pointer_width u16) int {
	bits := t.bit_size(pointer_width)
	return (bits + 7) / 8
}

// is_memory reports whether a value of this type may be loaded, stored, or given
// a stack slot or a global. ty_i1 and i3 are values but not memory types.
pub fn (t Type) is_memory() bool {
	return match t.kind {
		.int { t.bits % 8 == 0 && t.bits > 0 }
		.float { true }
		.ptr { true }
		.unknown { false }
	}
}

pub fn (t Type) str() string {
	return match t.kind {
		.int { 'i${t.bits}' }
		.float { 'f${t.bits}' }
		.ptr { 'ptr' }
		.unknown { 'untyped' }
	}
}

// type_from_text reads the one spelling a type has. An integer width outside
// 1..128 and a float width that is not 16, 32, 64 or 128 are refused here
// rather than carried as a type no rule covers.
pub fn type_from_text(text string) !Type {
	if text == 'ptr' {
		return ty_ptr
	}
	if text.len < 2 {
		return error("unknown type '${text}'")
	}
	match text[0] {
		`i` {
			digits := text[1..]
			if !digits.bytes().all(it >= `0` && it <= `9`) {
				return error("unknown type '${text}'")
			}
			width := digits.int()
			if width < 1 || width > 128 {
				return error("unknown type '${text}': an integer width is 1 to 128")
			}
			if text != 'i${width}' {
				return error("unknown type '${text}'")
			}
			return int_type(u16(width))
		}
		`f` {
			match text {
				'f16' { return ty_f16 }
				'f32' { return ty_f32 }
				'f64' { return ty_f64 }
				'f128' { return ty_f128 }
				else { return error("unknown type '${text}': a float width is 16, 32, 64 or 128") }
			}
		}
		else {
			return error("unknown type '${text}'")
		}
	}
}
