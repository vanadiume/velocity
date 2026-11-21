module ir

// The type model in ir-types.md: integers of every width from 1 to 128, four
// float widths, one opaque pointer, and the three aggregate forms. A type is
// structural, has no name, and two types are equal when their structure is
// equal. The printer writes that structure out in full, so the text form needs
// no type table.

pub enum TypeKind {
	unknown // not stated by the text at this place
	int
	float
	ptr
	struct_
	array
	vector
}

// Type is one node of a structural type. bits is the width of an integer or a
// float. count is the number of elements or lanes of an array or a vector, and
// elems holds a struct's fields in order or the one element type of an array or
// a vector. A scalar leaves count at zero and elems empty.
pub struct Type {
pub:
	kind  TypeKind
	bits  u16
	count int
	elems []Type
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

// struct_type is a struct of the fields in order. An empty struct is a type the
// verifier refuses with V023; it is built here so that a test can.
pub fn struct_type(fields []Type) Type {
	return Type{
		kind:  .struct_
		elems: fields
	}
}

// array_type is count elements of elem. A count below one is refused by V023.
pub fn array_type(elem Type, count int) Type {
	return Type{
		kind:  .array
		count: count
		elems: [elem]
	}
}

// vector_type is count lanes of elem. The element is an integer, a float or a
// pointer; a vector of an aggregate is refused by V023.
pub fn vector_type(elem Type, count int) Type {
	return Type{
		kind:  .vector
		count: count
		elems: [elem]
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

pub fn (t Type) is_struct() bool {
	return t.kind == .struct_
}

pub fn (t Type) is_array() bool {
	return t.kind == .array
}

pub fn (t Type) is_vector() bool {
	return t.kind == .vector
}

pub fn (t Type) is_aggregate() bool {
	return t.kind in [.struct_, .array, .vector]
}

pub fn (t Type) is_unknown() bool {
	return t.kind == .unknown
}

pub fn (t Type) is_scalar() bool {
	return t.kind in [.int, .float, .ptr]
}

// elem is the element type of an array or a vector. A type that is neither has
// no element, and answers ty_unknown.
pub fn (t Type) elem() Type {
	if t.kind in [.array, .vector] && t.elems.len == 1 {
		return t.elems[0]
	}
	return ty_unknown
}

// field is a struct's field at index i, or ty_unknown when the index leaves it.
pub fn (t Type) field(i int) Type {
	if t.kind == .struct_ && i >= 0 && i < t.elems.len {
		return t.elems[i]
	}
	return ty_unknown
}

// has_pointer reports whether a target's pointer width or alignment reaches the
// layout of this type.
pub fn (t Type) has_pointer() bool {
	return match t.kind {
		.ptr { true }
		.struct_ { t.elems.any(it.has_pointer()) }
		.array, .vector { t.elem().has_pointer() }
		else { false }
	}
}

// bit_size is the width of the type in bits. A pointer's width is a target
// fact, so it is passed in rather than stored on the type. An aggregate answers
// its laid-out size in bits.
pub fn (t Type) bit_size(pointer_width u16) int {
	return match t.kind {
		.int, .float { int(t.bits) }
		.ptr { int(pointer_width) }
		.struct_, .array, .vector { t.size(pointer_width) * 8 }
		.unknown { 0 }
	}
}

// size is the byte size from ir-types.md: ceil(N / 8) for an integer, the
// width over eight for a float, the pointer width over eight for a pointer, and
// the laid-out aggregate below. The pointer alignment is the natural one; a
// target that states a different one uses size_for.
pub fn (t Type) size(pointer_width u16) int {
	return t.layout_size(pointer_width, u16(pointer_width / 8))
}

// size_for is size with the target's own pointer alignment.
pub fn (t Type) size_for(target TargetInfo) int {
	return t.layout_size(target.pointer_width, target.pointer_align)
}

// align_of is the alignment from ir-types.md: the largest power of two that
// divides the size for a scalar, the target's pointer alignment for a pointer,
// the largest field alignment for a struct, and the element's for an array. A
// vector aligns to its size rounded up to a power of two.
pub fn (t Type) align_of(target TargetInfo) int {
	return t.layout_align(target.pointer_width, target.pointer_align)
}

// align_natural is the alignment a scalar or a pointerless aggregate has
// without a target: the natural pointer alignment for the width.
pub fn (t Type) align_natural() int {
	return t.layout_align(64, 8)
}

fn (t Type) layout_size(pointer_width u16, pointer_align u16) int {
	return match t.kind {
		.int, .float { (int(t.bits) + 7) / 8 }
		.ptr { int(pointer_width) / 8 }
		.struct_ {
			mut offset := 0
			mut widest := 1
			for field in t.elems {
				field_align := field.layout_align(pointer_width, pointer_align)
				offset = round_up(offset, field_align)
				offset += field.layout_size(pointer_width, pointer_align)
				if field_align > widest {
					widest = field_align
				}
			}
			round_up(offset, widest)
		}
		.array { t.count * t.elem().layout_size(pointer_width, pointer_align) }
		.vector { t.count * t.elem().layout_size(pointer_width, pointer_align) }
		.unknown { 0 }
	}
}

fn (t Type) layout_align(pointer_width u16, pointer_align u16) int {
	return match t.kind {
		.int, .float { largest_power_of_two_divisor((int(t.bits) + 7) / 8) }
		.ptr { int(pointer_align) }
		.struct_ {
			mut widest := 1
			for field in t.elems {
				field_align := field.layout_align(pointer_width, pointer_align)
				if field_align > widest {
					widest = field_align
				}
			}
			widest
		}
		.array { t.elem().layout_align(pointer_width, pointer_align) }
		.vector { next_power_of_two(t.layout_size(pointer_width, pointer_align)) }
		.unknown { 1 }
	}
}

fn round_up(value int, align int) int {
	if align <= 1 {
		return value
	}
	return ((value + align - 1) / align) * align
}

// largest_power_of_two_divisor is the alignment a byte size gives: 3 bytes
// align to 1, 4 to 4, and 0 to 1 so that no alignment is ever zero.
fn largest_power_of_two_divisor(size int) int {
	mut align := 1
	for size > 0 && align * 2 <= size && size % (align * 2) == 0 {
		align *= 2
	}
	return align
}

fn next_power_of_two(size int) int {
	if size <= 1 {
		return 1
	}
	mut power := 1
	for power < size {
		power *= 2
	}
	return power
}

// is_memory reports whether a value of this type may be loaded, stored, or given
// a stack slot or a global. ty_i1 and i3 are values but not memory types.
pub fn (t Type) is_memory() bool {
	return match t.kind {
		.int { t.bits % 8 == 0 && t.bits > 0 }
		.float { true }
		.ptr { true }
		.struct_ { t.elems.all(it.is_memory()) }
		.array, .vector { t.elem().is_memory() }
		.unknown { false }
	}
}

pub fn (t Type) str() string {
	return match t.kind {
		.int { 'i${t.bits}' }
		.float { 'f${t.bits}' }
		.ptr { 'ptr' }
		.struct_ {
			mut out := '{'
			for i, field in t.elems {
				if i > 0 {
					out += ', '
				}
				out += field.str()
			}
			out + '}'
		}
		.array { '[${t.count} x ${t.elem().str()}]' }
		.vector { '<${t.count} x ${t.elem().str()}>' }
		.unknown { 'untyped' }
	}
}

// type_from_text reads the one-token spelling of a scalar type. An aggregate is
// a sequence of tokens, so the parser reads one with expect_type instead.
// An integer width outside 1..128 and a float width that is not 16, 32, 64 or
// 128 are refused here rather than carried as a type no rule covers.
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
