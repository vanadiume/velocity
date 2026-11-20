module ir

// The opcode set in ir-instructions.md, in the order the reference lists it.
// The enum is the type the rest of the library switches on; the table is the
// one place the text spelling lives, so a name is added in exactly one place.

pub enum Opcode {
	iconst
	fconst
	null
	poison
	freeze
	iadd
	isub
	imul
	sdiv
	udiv
	srem
	urem
	ineg
	iabs
	smin
	smax
	umin
	umax
	sadd_overflow
	uadd_overflow
	ssub_overflow
	usub_overflow
	smul_overflow
	umul_overflow
	sadd_sat
	uadd_sat
	ssub_sat
	usub_sat
	smul_sat
	umul_sat
	band
	bor
	bxor
	bnot
	shl
	sshr
	ushr
	rotl
	rotr
	clz
	ctz
	popcnt
	bswap
	icmp
	fcmp
	fadd
	fsub
	fmul
	fdiv
	frem
	fneg
	fabs
	fsqrt
	fcopysign
	fma
	fmin
	fmax
	fceil
	ffloor
	ftrunc
	fnearest
	sext
	zext
	trunc
	bitcast
	ptrtoint
	inttoptr
	sitofp
	uitofp
	fptosi
	fptoui
	fpext
	fptrunc
	@select
	load
	store
	ptradd
	memcpy
	memmove
	memset
	stack_addr
	global_addr
	func_addr
	br
	condbr
	switch
	@return
	unreachable
	trap
	assume
	call
	call_indirect
	tailcall
	tailcall_indirect
	inline_asm
}

struct OpcodeName {
	name   string
	opcode Opcode
}

const opcode_names = [
	OpcodeName{'iconst', .iconst},
	OpcodeName{'fconst', .fconst},
	OpcodeName{'null', .null},
	OpcodeName{'poison', .poison},
	OpcodeName{'freeze', .freeze},
	OpcodeName{'iadd', .iadd},
	OpcodeName{'isub', .isub},
	OpcodeName{'imul', .imul},
	OpcodeName{'sdiv', .sdiv},
	OpcodeName{'udiv', .udiv},
	OpcodeName{'srem', .srem},
	OpcodeName{'urem', .urem},
	OpcodeName{'ineg', .ineg},
	OpcodeName{'iabs', .iabs},
	OpcodeName{'smin', .smin},
	OpcodeName{'smax', .smax},
	OpcodeName{'umin', .umin},
	OpcodeName{'umax', .umax},
	OpcodeName{'sadd_overflow', .sadd_overflow},
	OpcodeName{'uadd_overflow', .uadd_overflow},
	OpcodeName{'ssub_overflow', .ssub_overflow},
	OpcodeName{'usub_overflow', .usub_overflow},
	OpcodeName{'smul_overflow', .smul_overflow},
	OpcodeName{'umul_overflow', .umul_overflow},
	OpcodeName{'sadd_sat', .sadd_sat},
	OpcodeName{'uadd_sat', .uadd_sat},
	OpcodeName{'ssub_sat', .ssub_sat},
	OpcodeName{'usub_sat', .usub_sat},
	OpcodeName{'smul_sat', .smul_sat},
	OpcodeName{'umul_sat', .umul_sat},
	OpcodeName{'band', .band},
	OpcodeName{'bor', .bor},
	OpcodeName{'bxor', .bxor},
	OpcodeName{'bnot', .bnot},
	OpcodeName{'shl', .shl},
	OpcodeName{'sshr', .sshr},
	OpcodeName{'ushr', .ushr},
	OpcodeName{'rotl', .rotl},
	OpcodeName{'rotr', .rotr},
	OpcodeName{'clz', .clz},
	OpcodeName{'ctz', .ctz},
	OpcodeName{'popcnt', .popcnt},
	OpcodeName{'bswap', .bswap},
	OpcodeName{'icmp', .icmp},
	OpcodeName{'fcmp', .fcmp},
	OpcodeName{'fadd', .fadd},
	OpcodeName{'fsub', .fsub},
	OpcodeName{'fmul', .fmul},
	OpcodeName{'fdiv', .fdiv},
	OpcodeName{'frem', .frem},
	OpcodeName{'fneg', .fneg},
	OpcodeName{'fabs', .fabs},
	OpcodeName{'fsqrt', .fsqrt},
	OpcodeName{'fcopysign', .fcopysign},
	OpcodeName{'fma', .fma},
	OpcodeName{'fmin', .fmin},
	OpcodeName{'fmax', .fmax},
	OpcodeName{'fceil', .fceil},
	OpcodeName{'ffloor', .ffloor},
	OpcodeName{'ftrunc', .ftrunc},
	OpcodeName{'fnearest', .fnearest},
	OpcodeName{'sext', .sext},
	OpcodeName{'zext', .zext},
	OpcodeName{'trunc', .trunc},
	OpcodeName{'bitcast', .bitcast},
	OpcodeName{'ptrtoint', .ptrtoint},
	OpcodeName{'inttoptr', .inttoptr},
	OpcodeName{'sitofp', .sitofp},
	OpcodeName{'uitofp', .uitofp},
	OpcodeName{'fptosi', .fptosi},
	OpcodeName{'fptoui', .fptoui},
	OpcodeName{'fpext', .fpext},
	OpcodeName{'fptrunc', .fptrunc},
	OpcodeName{'select', .@select},
	OpcodeName{'load', .load},
	OpcodeName{'store', .store},
	OpcodeName{'ptradd', .ptradd},
	OpcodeName{'memcpy', .memcpy},
	OpcodeName{'memmove', .memmove},
	OpcodeName{'memset', .memset},
	OpcodeName{'stack_addr', .stack_addr},
	OpcodeName{'global_addr', .global_addr},
	OpcodeName{'func_addr', .func_addr},
	OpcodeName{'br', .br},
	OpcodeName{'condbr', .condbr},
	OpcodeName{'switch', .switch},
	OpcodeName{'return', .@return},
	OpcodeName{'unreachable', .unreachable},
	OpcodeName{'trap', .trap},
	OpcodeName{'assume', .assume},
	OpcodeName{'call', .call},
	OpcodeName{'call_indirect', .call_indirect},
	OpcodeName{'tailcall', .tailcall},
	OpcodeName{'tailcall_indirect', .tailcall_indirect},
	OpcodeName{'inline_asm', .inline_asm},
]

// all_opcodes is the canonical list in the order ir-instructions.md gives it.
pub fn all_opcodes() []Opcode {
	mut opcodes := []Opcode{cap: opcode_names.len}
	for entry in opcode_names {
		opcodes << entry.opcode
	}
	return opcodes
}

// opcode_names_list is the text spelling of every opcode, in the same order.
pub fn opcode_names_list() []string {
	mut names := []string{cap: opcode_names.len}
	for entry in opcode_names {
		names << entry.name
	}
	return names
}

pub fn opcode_from_name(name string) ?Opcode {
	for entry in opcode_names {
		if entry.name == name {
			return entry.opcode
		}
	}
	return none
}

pub fn (op Opcode) name() string {
	for entry in opcode_names {
		if entry.opcode == op {
			return entry.name
		}
	}
	return 'unknown'
}

// is_terminator is the set from ir-model.md: an instruction that ends its block
// and is stored apart from the block's instruction list.
pub fn (op Opcode) is_terminator() bool {
	return match op {
		.br, .condbr, .switch, .@return, .tailcall, .tailcall_indirect, .unreachable, .trap {
			true
		}
		else { false }
	}
}

// fixed_result_count is how many result names the text must give: two for an
// overflow pair, none for an instruction that computes nothing, and -1 where
// the count comes from somewhere else (the callee's signature, or the inline
// asm outputs).
pub fn (op Opcode) fixed_result_count() int {
	return match op {
		.sadd_overflow, .uadd_overflow, .ssub_overflow, .usub_overflow, .smul_overflow,
		.umul_overflow {
			2
		}
		.store, .memcpy, .memmove, .memset, .assume, .br, .condbr, .switch, .@return,
		.unreachable, .trap, .tailcall, .tailcall_indirect {
			0
		}
		.call, .call_indirect, .inline_asm {
			-1
		}
		else { 1 }
	}
}
