module ir

// The verifier in ir-verify.md. It runs on a parsed file and on a function a
// builder has finished, and it reports every error it finds rather than the
// first, each with a stable code and the site it names.
//
// The checks are structural and type-level. Nothing here legalizes a width that
// a target does not have, and nothing here decides undefined behavior: a flag is
// accepted as the promise the frontend made, which is what lets an optimizer
// rely on it.

pub struct VerifyError {
pub:
	code     string // V001 and so on
	function ?string
	block    ?u32
	inst     ?u32
	message  string
}

// msg is the one line form: the code, the site, and what was expected.
pub fn (e VerifyError) msg() string {
	mut site := []string{cap: 3}
	if function := e.function {
		site << 'fn @${function}'
	}
	if block := e.block {
		site << 'block ${block}'
	}
	if inst := e.inst {
		site << 'inst ${inst}'
	}
	if site.len == 0 {
		return '${e.code}: ${e.message}'
	}
	return '${e.code}: ${site.join(', ')}: ${e.message}'
}

// verify_module checks the target, the module's names and signatures, and every
// function in module order. Module errors come first, then functions in the
// order they were added, so two runs over one module report the same list.
pub fn verify_module(module &Module) []VerifyError {
	mut errors := check_module(module)
	for function in module.functions {
		errors << verify_function(module, function)
	}
	return errors
}

// verify_function checks one function against its module. It relies on the
// caller having a valid target and a resolved module: the module's own rules
// (the target, the names, the signatures in agreement) are verify_module's.
pub fn verify_function(module &Module, function &Function) []VerifyError {
	mut context := VerifyContext{
		function: function.name
		block:    -1
		inst:     -1
	}
	context.check_signature(function)
	if !function.defined {
		if function.blocks.len > 0 {
			context.error('V002', 'a declaration has no blocks, and this one has ${function.blocks.len}')
		}
		return context.errors
	}
	context.check_value_table(function)
	context.check_stack_slots(function)
	if function.blocks.len == 0 {
		context.error('V002', 'the function has no blocks, so it has no entry block')
		return context.errors
	}
	preds := predecessors(function)
	reachable := reachable_blocks(function)
	idom := dominators(function, preds)
	context.block = 0
	context.check_entry(function, preds)
	context.block = -1
	for bi in 0 .. function.blocks.len {
		context.block = bi
		context.inst = -1
		if !reachable[bi] {
			context.error('V022', '${block_name(function, bi)} is not reachable from the entry block')
		}
		context.check_block_params(function, bi)
		block := function.blocks[bi]
		for ii in 0 .. block.instructions.len {
			context.inst = ii
			inst := block.instructions[ii]
			if inst.opcode.is_terminator() {
				context.error('V003', "'${inst.opcode.name()}' is a terminator, so it ends its block and does not sit in the instruction list")
				continue
			}
			context.check_instruction(module, function, inst)
			context.check_uses(function, inst, idom, reachable)
		}
		context.inst = block.instructions.len
		if !block.terminator.opcode.is_terminator() {
			context.error('V003', 'the block has no terminator')
		} else {
			context.check_instruction(module, function, block.terminator)
			context.check_uses(function, block.terminator, idom, reachable)
		}
	}
	return context.errors
}

// VerifyContext carries the site each error is reported against. A negative
// block or instruction index means the error belongs to the function.
struct VerifyContext {
	function string
mut:
	errors []VerifyError
	block  int
	inst   int
}

fn (mut c VerifyContext) error(code string, message string) {
	c.errors << VerifyError{
		code:     code
		function: optional_text(c.function)
		block:    optional_index(c.block)
		inst:     optional_index(c.inst)
		message:  message
	}
}

fn optional_text(text string) ?string {
	if text == '' {
		return none
	}
	return text
}

fn optional_index(index int) ?u32 {
	if index < 0 {
		return none
	}
	return u32(index)
}

// check_module holds the rules that belong to the module: the target it states,
// the names it declares, and the signatures a declaration and a definition share.
fn check_module(m &Module) []VerifyError {
	mut errors := []VerifyError{}
	if m.target.pointer_width != 32 && m.target.pointer_width != 64 {
		errors << VerifyError{
			code:    'V001'
			message: "the target's pointer width is ${m.target.pointer_width}, expected 32 or 64"
		}
	}
	if !is_power_of_two(int(m.target.pointer_align)) {
		errors << VerifyError{
			code:    'V001'
			message: "the target's pointer alignment is ${m.target.pointer_align}, expected a power of two greater than zero"
		}
	}
	mut global_names := map[string]bool{}
	for global in m.globals {
		if global_names[global.name] {
			errors << VerifyError{
				code:    'V020'
				message: "global '@${global.name}' is declared more than once"
			}
		}
		global_names[global.name] = true
		errors << check_global(global, m.target)
	}
	mut declarations := map[string]int{}
	mut definitions := map[string]int{}
	mut first_declaration := map[string]Signature{}
	mut first_definition := map[string]Signature{}
	mut names := []string{cap: m.functions.len}
	mut seen := map[string]bool{}
	mut reported_clash := map[string]bool{}
	for function in m.functions {
		if global_names[function.name] && !reported_clash[function.name] {
			reported_clash[function.name] = true
			errors << VerifyError{
				code:     'V020'
				function: function.name
				message:  "the name '@${function.name}' is both a function and a global"
			}
		}
		if !seen[function.name] {
			seen[function.name] = true
			names << function.name
		}
		if function.defined {
			definitions[function.name] = definitions[function.name] + 1
			if definitions[function.name] == 1 {
				first_definition[function.name] = function.signature
			} else {
				errors << VerifyError{
					code:     'V020'
					function: function.name
					message:  "function '@${function.name}' is defined more than once"
				}
			}
		} else {
			declarations[function.name] = declarations[function.name] + 1
			if declarations[function.name] == 1 {
				first_declaration[function.name] = function.signature
			} else {
				errors << VerifyError{
					code:     'V020'
					function: function.name
					message:  "function '@${function.name}' is declared more than once"
				}
			}
		}
	}
	for name in names {
		if declarations[name] != 1 || definitions[name] != 1 {
			continue
		}
		if first_declaration[name] == first_definition[name] {
			continue
		}
		errors << VerifyError{
			code:     'V019'
			function: name
			message:  "'@${name}' is declared ${signature_text(first_declaration[name])} and defined ${signature_text(first_definition[name])}"
		}
	}
	for function in m.functions {
		errors << check_effects(function.signature.effects,
			"the signature of '@${function.name}'")
	}
	return errors
}

// check_effects holds V032: readonly and readnone are never both set. The text
// form only accepts an effect after a signature, so an effect written anywhere
// else is a parse error rather than a set the verifier could see.
fn check_effects(effects EffectSet, site string) []VerifyError {
	if effects.readonly && effects.readnone {
		return [VerifyError{
			code:    'V032'
			message: '${site} is both readonly and readnone'
		}]
	}
	return []
}

// signature_text is the one line spelling a message uses for a signature.
fn signature_text(signature Signature) string {
	params := signature.params.map(it.str()).join(', ')
	results := match signature.results.len {
		0 { '' }
		1 { ' -> ${signature.results[0].str()}' }
		else { ' -> (${signature.results.map(it.str()).join(', ')})' }
	}
	effect_text := if signature.effects.is_empty() {
		''
	} else {
		' ${signature.effects.text()}'
	}
	return '(${params})${results}${effect_text}'
}

// check_global holds what a global states: a type the model has (V023), a type
// a byte range can hold (V015), and an initializer whose shape and widths match
// that type (V033). The size and the alignment are not checked because they are
// not stored: both come from the type.
fn check_global(global Global, target TargetInfo) []VerifyError {
	mut errors := []VerifyError{}
	problem := type_problem(global.typ)
	if problem != '' {
		errors << VerifyError{
			code:    'V023'
			message: "global '@${global.name}' has type ${global.typ.str()}: ${problem}"
		}
	} else if !global.typ.is_memory() {
		errors << VerifyError{
			code:    'V015'
			message: "global '@${global.name}' has type ${global.typ.str()}, expected a memory type"
		}
	}
	if init := global.init {
		check_const(mut errors, init, global.typ, "the initializer for '@${global.name}'")
	}
	if problem == '' && global.typ.size_for(target) <= 0 {
		errors << VerifyError{
			code:    'V023'
			message: "global '@${global.name}' has type ${global.typ.str()}, whose size does not fit the address space"
		}
	}
	return errors
}

// check_const walks a global's constant tree with the type that gives each leaf
// its width and each list its length. A leaf that does not match is reported
// with the path that reached it, so a deep tree names the field or element.
fn check_const(mut errors []VerifyError, value Const, typ Type, site string) {
	if value.kind == .zero || typ.is_unknown() {
		return
	}
	match typ.kind {
		.int {
			if value.kind != .int {
				errors << const_error(site, value, 'an integer leaf')
				return
			}
			if !immediate_fits(value.bits, typ.bits) {
				errors << VerifyError{
					code:    'V033'
					message: '${site} has a value that does not fit ${typ.str()}'
				}
			}
		}
		.float {
			if value.kind != .float {
				errors << const_error(site, value, 'a float leaf')
				return
			}
			if value.typ != typ {
				errors << VerifyError{
					code:    'V033'
					message: '${site} is written ${value.typ.str()}, expected ${typ.str()}'
				}
			}
		}
		.ptr {
			if value.kind != .null {
				errors << const_error(site, value, 'null')
			}
		}
		.struct_ {
			if value.kind != .seq {
				errors << const_error(site, value, 'a struct initializer')
				return
			}
			if value.elems.len != typ.elems.len {
				errors << VerifyError{
					code:    'V033'
					message: '${site} has ${value.elems.len} leaves and ${typ.str()} has ${typ.elems.len} fields'
				}
				return
			}
			for i, elem in value.elems {
				check_const(mut errors, elem, typ.field(i), '${site} field ${i + 1}')
			}
		}
		.array, .vector {
			if value.kind != .seq {
				errors << const_error(site, value, if typ.is_array() {
					'an array initializer'
				} else {
					'a vector initializer'
				})
				return
			}
			if value.elems.len != typ.count {
				what := if typ.is_array() { 'elements' } else { 'lanes' }
				errors << VerifyError{
					code:    'V033'
					message: '${site} has ${value.elems.len} leaves and ${typ.str()} has ${typ.count} ${what}'
				}
				return
			}
			for i, elem in value.elems {
				what := if typ.is_array() { 'element' } else { 'lane' }
				check_const(mut errors, elem, typ.elem(), '${site} ${what} ${i + 1}')
			}
		}
		.unknown {}
	}
}

fn const_error(site string, value Const, expected string) VerifyError {
	return VerifyError{
		code:    'V033'
		message: '${site} is ${const_kind_text(value.kind)}, expected ${expected}'
	}
}

fn const_kind_text(kind ConstKind) string {
	return match kind {
		.zero { 'zeroinit' }
		.int { 'an integer' }
		.float { 'a float' }
		.null { 'null' }
		.seq { 'a list' }
	}
}

// check_signature refuses a type that the type model does not have. The parser
// cannot produce one; a builder that assembles the structs by hand can.
fn (mut c VerifyContext) check_signature(function &Function) {
	for i, param in function.signature.params {
		problem := type_problem(param.typ)
		if problem != '' {
			c.error('V023', "parameter ${i + 1} of '@${function.name}' has type ${param.typ.str()}: ${problem}")
		}
	}
	for i, result in function.signature.results {
		problem := type_problem(result.typ)
		if problem != '' {
			c.error('V023', "result ${i + 1} of '@${function.name}' has type ${result.typ.str()}: ${problem}")
		}
	}
}

// check_value_table walks every definition site and requires the value table to
// agree with it: each value defined once, each function parameter in the table's
// first slots in signature order, and no entry left over.
fn (mut c VerifyContext) check_value_table(function &Function) {
	param_count := function.signature.params.len
	total := function.values.len
	if total < param_count {
		c.error('V005', 'the function takes ${param_count} parameters and its value table holds ${total}')
	}
	mut defined := []bool{len: total}
	for i in 0 .. param_count {
		if i >= total {
			break
		}
		defined[i] = true
		value := function.values[i]
		expected := function.signature.params[i].typ
		if value.kind != .function_param || value.typ != expected {
			c.error('V005', 'value ${i} is not function parameter ${i + 1} of type ${expected.str()}')
		}
	}
	for bi in 0 .. function.blocks.len {
		block := function.blocks[bi]
		for i, index in block.params {
			c.define_value(function, mut defined, index, .block_param, bi, -1,
				'parameter ${i + 1} of ${block_name(function, bi)}')
		}
		for ii in 0 .. block.instructions.len {
			inst := block.instructions[ii]
			for i, index in inst.results {
				c.define_value(function, mut defined, index, .instruction_result, bi, ii,
					"result ${i + 1} of '${inst.opcode.name()}'")
			}
		}
	}
	for i in 0 .. total {
		if !defined[i] {
			c.error('V005', 'value ${i} is never defined')
		}
	}
}

fn (mut c VerifyContext) define_value(function &Function, mut defined []bool, index int,
	kind ValueKind, bi int, ii int, site string) {
	if index < 0 || index >= function.values.len {
		c.error('V005', '${site} names value ${index} and the table holds ${function.values.len}')
		return
	}
	if defined[index] {
		c.error('V005', '${site} defines value ${index}, which is already defined')
		return
	}
	defined[index] = true
	value := function.values[index]
	if value.kind != kind || value.block != bi || (kind == .instruction_result && value.inst != ii) {
		recorded := match value.kind {
			.function_param { 'a function parameter' }
			.block_param { 'a parameter of ${block_name(function, value.block)}' }
			.instruction_result {
				'a result at index ${value.inst} of ${block_name(function, value.block)}'
			}
		}
		c.error('V005', 'value ${index} is ${site}, and the table records it as ${recorded}')
	}
}

fn (mut c VerifyContext) check_stack_slots(function &Function) {
	for i, slot in function.stack_slots {
		name := slot_name(slot, i)
		if slot.size == 0 {
			c.error('V021', "stack slot '${name}' has size 0")
		}
		if !is_power_of_two(int(slot.align)) {
			c.error('V010', "stack slot '${name}' has align ${slot.align}, expected a power of two greater than zero")
		}
	}
}

// check_entry holds V002: the entry block is the first block, carries no
// parameters, and nothing jumps to it.
fn (mut c VerifyContext) check_entry(function &Function, predecessors [][]int) {
	entry := function.blocks[0]
	if entry.params.len > 0 {
		c.error('V002', 'the entry block has ${entry.params.len} parameters, expected none')
	}
	if predecessors[0].len > 0 {
		c.error('V002', 'the entry block cannot be a jump target, and ${block_name(function, predecessors[0][0])} jumps to it')
	}
}

// check_block_params requires every block parameter to be a value of this block
// with a type the model has. The table's own bookkeeping is in check_value_table.
fn (mut c VerifyContext) check_block_params(function &Function, bi int) {
	for i, index in function.blocks[bi].params {
		if index < 0 || index >= function.values.len {
			continue
		}
		value := function.values[index]
		problem := type_problem(value.typ)
		if problem != '' {
			c.error('V023', 'parameter ${i + 1} of ${block_name(function, bi)} has type ${value.typ.str()}: ${problem}')
		}
	}
}

// check_instruction holds the rules that belong to one opcode: the flags it
// accepts, how many results it produces, and the operand and result types the
// instruction reference gives it. Uses are V006's business and are checked
// beside it.
fn (mut c VerifyContext) check_instruction(module &Module, function &Function, inst Instruction) {
	c.check_flags(inst)
	c.check_result_count(inst)
	c.check_opcode(module, function, inst)
}

fn (mut c VerifyContext) check_flags(inst Instruction) {
	name := inst.opcode.name()
	if inst.flags.nsw && !accepts_flag(inst.opcode, 'nsw') {
		c.error('V008', "'${name}' does not accept the 'nsw' flag")
	}
	if inst.flags.nuw && !accepts_flag(inst.opcode, 'nuw') {
		c.error('V008', "'${name}' does not accept the 'nuw' flag")
	}
	if inst.flags.exact && !accepts_flag(inst.opcode, 'exact') {
		c.error('V008', "'${name}' does not accept the 'exact' flag")
	}
	if inst.flags.inbounds && !accepts_flag(inst.opcode, 'inbounds') {
		c.error('V008', "'${name}' does not accept the 'inbounds' flag")
	}
	if inst.flags.volatile && !accepts_flag(inst.opcode, 'volatile') {
		c.error('V008', "'${name}' does not accept the 'volatile' flag")
	}
	if inst.flags.nnan && !accepts_flag(inst.opcode, 'nnan') {
		c.error('V008', "'${name}' does not accept the 'nnan' flag")
	}
	if inst.flags.ninf && !accepts_flag(inst.opcode, 'ninf') {
		c.error('V008', "'${name}' does not accept the 'ninf' flag")
	}
	if inst.flags.nsz && !accepts_flag(inst.opcode, 'nsz') {
		c.error('V008', "'${name}' does not accept the 'nsz' flag")
	}
	if inst.flags.arcp && !accepts_flag(inst.opcode, 'arcp') {
		c.error('V008', "'${name}' does not accept the 'arcp' flag")
	}
	if inst.flags.contract && !accepts_flag(inst.opcode, 'contract') {
		c.error('V008', "'${name}' does not accept the 'contract' flag")
	}
	if inst.flags.reassoc && !accepts_flag(inst.opcode, 'reassoc') {
		c.error('V008', "'${name}' does not accept the 'reassoc' flag")
	}
	if inst.flags.afn && !accepts_flag(inst.opcode, 'afn') {
		c.error('V008', "'${name}' does not accept the 'afn' flag")
	}
}

// accepts_flag is the table from ir-instructions.md: a flag an opcode does not
// list is an error, not an ignored bit. Volatile is also an inline asm clause,
// so it is accepted in either place there. The float group is opt-in and
// applies to the arithmetic and fma; nnan and ninf also apply to fcmp.
fn accepts_flag(op Opcode, flag string) bool {
	float_ops := [Opcode.fadd, .fsub, .fmul, .fdiv, .frem, .fsqrt, .fma]
	return match flag {
		'nsw' { op in [Opcode.iadd, .isub, .imul, .ineg, .shl] }
		'nuw' { op in [Opcode.iadd, .isub, .imul, .shl] }
		'exact' { op in [Opcode.sdiv, .udiv, .srem, .urem, .sshr, .ushr] }
		'inbounds' { op == .ptradd }
		'volatile' { op in [Opcode.load, .store, .inline_asm] }
		'nnan', 'ninf' { op in float_ops || op == .fcmp }
		'nsz', 'arcp', 'contract', 'reassoc', 'afn' { op in float_ops }
		else { false }
	}
}

fn (mut c VerifyContext) check_result_count(inst Instruction) {
	expected := inst.opcode.fixed_result_count()
	if expected < 0 || inst.results.len == expected {
		return
	}
	c.error('V007', "'${inst.opcode.name()}' takes ${result_count_phrase(expected)}, found ${inst.results.len}")
}

fn (mut c VerifyContext) check_opcode(module &Module, function &Function, inst Instruction) {
	name := inst.opcode.name()
	match inst.opcode {
		.iconst {
			if !c.check_stated_type(inst, inst.typ, .int, 'the constant') {
				return
			}
			if c.expect_operand_count(inst, 1) {
				c.expect_operand(function, inst, 0, inst.typ)
				c.expect_results(function, inst, [inst.typ])
			}
		}
		.fconst {
			if !c.check_stated_type(inst, inst.typ, .float, 'the constant') {
				return
			}
			if c.expect_operand_count(inst, 1) {
				c.expect_operand(function, inst, 0, inst.typ)
				c.expect_results(function, inst, [inst.typ])
			}
		}
		.null {
			if c.expect_operand_count(inst, 0) {
				c.expect_results(function, inst, [ty_ptr])
			}
		}
		.poison {
			if c.check_type_valid(inst, inst.typ, 'the value') && c.expect_operand_count(inst, 0) {
				c.expect_results(function, inst, [inst.typ])
			}
		}
		.freeze {
			if c.expect_operand_count(inst, 1) {
				typ := c.operand_type(function, inst.operands[0])
				if typ.is_unknown() {
					c.error('V007', "operand 1 of 'freeze' has no type")
				} else {
					c.expect_results(function, inst, [typ])
				}
			}
		}
		.iadd, .isub, .imul, .sdiv, .udiv, .srem, .urem, .smin, .smax, .umin, .umax,
		.sadd_sat, .uadd_sat, .ssub_sat, .usub_sat, .smul_sat, .umul_sat, .band, .bor,
		.bxor, .shl, .sshr, .ushr, .rotl, .rotr {
			if c.expect_operand_count(inst, 2) {
				typ := c.shared_type(function, inst, 0, 2, [.int], 'an integer')
				if !typ.is_unknown() {
					c.expect_results(function, inst, [typ])
				}
			}
		}
		.sadd_overflow, .uadd_overflow, .ssub_overflow, .usub_overflow, .smul_overflow,
		.umul_overflow {
			if c.expect_operand_count(inst, 2) {
				typ := c.shared_type(function, inst, 0, 2, [.int], 'an integer')
				if !typ.is_unknown() {
					c.expect_results(function, inst, [typ, ty_i1])
				}
			}
		}
		.ineg, .iabs, .bnot, .clz, .ctz, .popcnt, .bswap {
			if c.expect_operand_count(inst, 1) {
				typ := c.shared_type(function, inst, 0, 1, [.int], 'an integer')
				if !typ.is_unknown() {
					c.expect_results(function, inst, [typ])
					if inst.opcode == .bswap && typ.bits % 8 != 0 {
						c.error('V016', "'bswap' operates on ${typ.str()}, expected a width that is a multiple of 8")
					}
				}
			}
		}
		.icmp {
			if c.expect_operand_count(inst, 2) {
				typ := c.shared_type(function, inst, 0, 2, [.int, .ptr], 'an integer or a pointer')
				if typ.is_ptr() && inst.predicate !in pointer_predicates {
					c.error('V007', "'icmp ${inst.predicate}' is not defined on pointers; only eq, ne, ult, ule, ugt and uge are")
				}
				if typ.is_int() && inst.predicate !in integer_predicates {
					c.error('V007', "'icmp ${inst.predicate}' is not an integer predicate")
				}
				if !typ.is_unknown() {
					c.expect_results(function, inst, [ty_i1])
				}
			}
		}
		.fcmp {
			if c.expect_operand_count(inst, 2) {
				typ := c.shared_type(function, inst, 0, 2, [.float], 'a float')
				if inst.predicate !in float_predicates {
					c.error('V007', "'fcmp ${inst.predicate}' is not a float predicate")
				}
				if !typ.is_unknown() {
					c.expect_results(function, inst, [ty_i1])
				}
			}
		}
		.fadd, .fsub, .fmul, .fdiv, .frem, .fcopysign, .fmin, .fmax {
			if c.expect_operand_count(inst, 2) {
				typ := c.shared_type(function, inst, 0, 2, [.float], 'a float')
				if !typ.is_unknown() {
					c.expect_results(function, inst, [typ])
				}
			}
		}
		.fma {
			if c.expect_operand_count(inst, 3) {
				typ := c.shared_type(function, inst, 0, 3, [.float], 'a float')
				if !typ.is_unknown() {
					c.expect_results(function, inst, [typ])
				}
			}
		}
		.fneg, .fabs, .fsqrt, .fceil, .ffloor, .ftrunc, .fnearest {
			if c.expect_operand_count(inst, 1) {
				typ := c.shared_type(function, inst, 0, 1, [.float], 'a float')
				if !typ.is_unknown() {
					c.expect_results(function, inst, [typ])
				}
			}
		}
		.sext, .zext {
			if c.expect_operand_count(inst, 1) {
				from, to := c.check_conversion(function, inst, .int, .int)
				if from.kind == .int && to.kind == .int && to.bits <= from.bits {
					c.error('V007', "'${name}' extends ${from.str()} to ${to.str()}, expected a wider result")
				}
			}
		}
		.trunc {
			if c.expect_operand_count(inst, 1) {
				from, to := c.check_conversion(function, inst, .int, .int)
				if from.kind == .int && to.kind == .int && to.bits >= from.bits {
					c.error('V007', "'trunc' truncates ${from.str()} to ${to.str()}, expected a narrower result")
				}
			}
		}
		.sitofp, .uitofp {
			if c.expect_operand_count(inst, 1) {
				c.check_conversion(function, inst, .int, .float)
			}
		}
		.fptosi, .fptoui {
			if c.expect_operand_count(inst, 1) {
				c.check_conversion(function, inst, .float, .int)
			}
		}
		.fpext {
			if c.expect_operand_count(inst, 1) {
				from, to := c.check_conversion(function, inst, .float, .float)
				if from.kind == .float && to.kind == .float && to.bits <= from.bits {
					c.error('V007', "'fpext' extends ${from.str()} to ${to.str()}, expected a wider result")
				}
			}
		}
		.fptrunc {
			if c.expect_operand_count(inst, 1) {
				from, to := c.check_conversion(function, inst, .float, .float)
				if from.kind == .float && to.kind == .float && to.bits >= from.bits {
					c.error('V007', "'fptrunc' narrows ${from.str()} to ${to.str()}, expected a narrower result")
				}
			}
		}
		.bitcast {
			if c.expect_operand_count(inst, 1) {
				from := c.operand_type(function, inst.operands[0])
				to := inst.typ
				if from.is_unknown() {
					c.error('V007', "operand 1 of 'bitcast' has no type")
				} else if from.is_ptr() {
					c.error('V007', "'bitcast' does not accept a pointer operand; use ptrtoint")
				} else if from.is_struct() || from.is_array() {
					c.error('V007', "'bitcast' does not accept a struct or an array")
				} else if c.check_type_valid(inst, to, 'the result') {
					if to.is_ptr() {
						c.error('V007', "'bitcast' does not accept a pointer result; use inttoptr")
					} else if to.is_struct() || to.is_array() {
						c.error('V007', "'bitcast' does not accept a struct or an array")
					} else if from.bit_size(module.target.pointer_width) != to.bit_size(module.target.pointer_width) {
						c.error('V007', "'bitcast' from ${from.str()} to ${to.str()}, expected equal bit widths")
					}
					c.expect_results(function, inst, [to])
				}
			}
		}
		.ptrtoint {
			if c.expect_operand_count(inst, 1) {
				c.expect_operand(function, inst, 0, ty_ptr)
				if c.check_stated_type(inst, inst.typ, .int, 'the result') {
					if inst.typ.bits != module.target.pointer_width {
						c.error('V017', "'ptrtoint' produces ${inst.typ.str()}, expected the pointer width i${module.target.pointer_width}")
					}
					c.expect_results(function, inst, [inst.typ])
				}
			}
		}
		.inttoptr {
			if c.expect_operand_count(inst, 1) {
				from := c.operand_type(function, inst.operands[0])
				if from.is_unknown() {
					c.error('V007', "operand 1 of 'inttoptr' has no type, expected the pointer-width integer")
				} else if !from.is_int() {
					c.error('V007', "operand 1 of 'inttoptr' has type ${from.str()}, expected an integer")
				} else if from.bits != module.target.pointer_width {
					c.error('V017', "'inttoptr' takes ${from.str()}, expected the pointer width i${module.target.pointer_width}")
				}
				if c.check_stated_type(inst, inst.typ, .ptr, 'the result') {
					c.expect_results(function, inst, [ty_ptr])
				}
			}
		}
		.@select {
			if c.expect_operand_count(inst, 3) {
				c.expect_operand(function, inst, 0, ty_i1)
				typ := c.shared_type(function, inst, 1, 2, [.int, .float, .ptr], 'a scalar')
				if !typ.is_unknown() {
					c.expect_results(function, inst, [typ])
				}
			}
		}
		.load {
			if c.expect_operand_count(inst, 1) {
				c.expect_operand(function, inst, 0, ty_ptr)
				if c.check_memory_type(inst, inst.typ, 'the result') {
					c.expect_results(function, inst, [inst.typ])
				}
				c.check_align(inst, inst.align, '')
			}
		}
		.store {
			if c.expect_operand_count(inst, 2) {
				c.expect_operand(function, inst, 0, ty_ptr)
				c.check_store_value(function, inst)
				c.check_align(inst, inst.align, '')
			}
		}
		.ptradd {
			if c.expect_operand_count(inst, 2) {
				c.expect_operand(function, inst, 0, ty_ptr)
				c.expect_integer_operand(function, inst, 1)
				c.expect_results(function, inst, [ty_ptr])
			}
		}
		.memcpy, .memmove {
			if c.expect_operand_count(inst, 3) {
				c.expect_operand(function, inst, 0, ty_ptr)
				c.expect_operand(function, inst, 1, ty_ptr)
				c.expect_integer_operand(function, inst, 2)
				c.check_align(inst, inst.align_dst, 'dst')
				c.check_align(inst, inst.align_src, 'src')
			}
		}
		.memset {
			if c.expect_operand_count(inst, 3) {
				c.expect_operand(function, inst, 0, ty_ptr)
				c.expect_operand(function, inst, 1, ty_i8)
				c.expect_integer_operand(function, inst, 2)
				c.check_align(inst, inst.align, '')
			}
		}
		.stack_addr {
			if c.expect_operand_count(inst, 1) {
				c.check_stack_operand(function, inst)
				c.expect_results(function, inst, [ty_ptr])
			}
		}
		.global_addr {
			if c.expect_operand_count(inst, 1) {
				c.check_symbol_operand(module, inst, .global)
				c.expect_results(function, inst, [ty_ptr])
			}
		}
		.func_addr {
			if c.expect_operand_count(inst, 1) {
				c.check_symbol_operand(module, inst, .function)
				c.expect_results(function, inst, [ty_ptr])
			}
		}
		.br {
			if c.expect_operand_count(inst, 0) {
				c.check_jump_target(function, inst.target, 'V004')
			}
		}
		.condbr {
			if c.expect_operand_count(inst, 1) {
				c.expect_operand(function, inst, 0, ty_i1)
				c.check_jump_target(function, inst.target, 'V004')
				c.check_jump_target(function, inst.else_target, 'V004')
			}
		}
		.switch {
			if c.expect_operand_count(inst, 1) {
				value := c.operand_type(function, inst.operands[0])
				if value.is_unknown() {
					c.error('V007', "operand 1 of 'switch' has no type")
				} else if !value.is_int() {
					c.error('V007', "operand 1 of 'switch' has type ${value.str()}, expected an integer")
				}
				c.check_jump_target(function, inst.target, 'V014')
				mut seen := []u128{}
				mut first_case := []int{}
				for i, case_ in inst.cases {
					if value.is_int() {
						if !immediate_fits(case_.value, value.bits) {
							c.error('V014', "case ${i + 1} of 'switch' does not fit ${value.str()}")
						}
						masked := mask_to(value.bits, case_.value)
						mut repeated := -1
						for j, earlier in seen {
							if earlier == masked {
								repeated = first_case[j]
								break
							}
						}
						if repeated >= 0 {
							c.error('V014', "case ${i + 1} of 'switch' repeats case ${repeated + 1}")
						} else {
							seen << masked
							first_case << i
						}
					}
					c.check_jump_target(function, case_.target, 'V014')
				}
			}
		}
		.@return {
			c.check_return(function, inst)
		}
		.unreachable, .trap {
			c.expect_operand_count(inst, 0)
		}
		.assume {
			if c.expect_operand_count(inst, 1) {
				c.expect_operand(function, inst, 0, ty_i1)
			}
		}
		.call, .tailcall {
			c.check_direct_call(module, function, inst)
		}
		.call_indirect, .tailcall_indirect {
			c.check_indirect_call(function, inst)
		}
		.inline_asm {
			c.check_inline_asm(function, inst)
		}
		else {}
	}
}

// check_jump_target holds V004 for a br or condbr edge and V014 for a switch
// edge: the block exists and the jump passes one argument per parameter with the
// parameter's type.
fn (mut c VerifyContext) check_jump_target(function &Function, target BlockTarget, code string) {
	source := if c.block >= 0 && c.block < function.blocks.len {
		block_name(function, c.block)
	} else {
		'the block'
	}
	if target.block < 0 || target.block >= function.blocks.len {
		c.error('V005', 'a jump from ${source} names block ${target.block}, and the function has ${function.blocks.len} blocks')
		return
	}
	destination := block_name(function, target.block)
	params := function.blocks[target.block].params
	if target.args.len != params.len {
		c.error(code, 'the jump from ${source} to ${destination} passes ${target.args.len} arguments, and ${destination} takes ${params.len}')
		return
	}
	for i in 0 .. params.len {
		mut expected := ty_unknown
		if params[i] >= 0 && params[i] < function.values.len {
			expected = function.values[params[i]].typ
		}
		c.expect_operand_is(function, target.args[i], expected, code,
			'argument ${i + 1} of the jump from ${source} to ${destination}')
	}
}

fn (mut c VerifyContext) check_return(function &Function, inst Instruction) {
	results := function.signature.result_types()
	if inst.operands.len != results.len {
		c.error('V011', "'return' passes ${value_count_phrase(inst.operands.len)}, and the function returns ${value_count_phrase(results.len)}")
		return
	}
	for i in 0 .. results.len {
		c.expect_operand_is(function, inst.operands[i], results[i], 'V011',
			"value ${i + 1} of 'return'")
	}
}

fn (mut c VerifyContext) check_direct_call(module &Module, function &Function, inst Instruction) {
	name := inst.opcode.name()
	if inst.operands.len == 0 {
		c.error('V012', "'${name}' has no callee")
		return
	}
	callee := inst.operands[0]
	if callee.kind != .symbol {
		c.error('V012', "the callee of '${name}' is not a symbol")
		return
	}
	kind, index := resolve_symbol(module, callee)
	if kind != .function {
		c.error('V012', "'${name}' names '@${callee.name}', which is not a declared function")
		return
	}
	callee_signature := module.functions[index].signature
	args := inst.operands[1..]
	if args.len != callee_signature.params.len {
		c.error('V012', "the call to '@${callee.name}' passes ${args.len} arguments, and the declaration takes ${callee_signature.params.len}")
	}
	for i in 0 .. args.len {
		if i >= callee_signature.params.len {
			break
		}
		c.expect_operand_is(function, args[i], callee_signature.params[i].typ, 'V012',
			"argument ${i + 1} of the call to '@${callee.name}'")
	}
	if inst.opcode == .tailcall {
		c.check_tail_results(callee_signature, function, inst)
		return
	}
	c.check_call_results(function, inst, callee_signature.result_types(), "the call to '@${callee.name}'")
}

fn (mut c VerifyContext) check_indirect_call(function &Function, inst Instruction) {
	name := inst.opcode.name()
	if inst.operands.len == 0 {
		c.error('V012', "'${name}' has no callee pointer")
		return
	}
	callee := inst.operands[0]
	if callee.kind != .value {
		c.error('V007', "operand 1 of '${name}' is not a pointer value, expected ptr")
	} else {
		typ := c.operand_type(function, callee)
		if typ.is_unknown() {
			c.error('V007', "operand 1 of '${name}' has no type, expected ptr")
		} else if !typ.is_ptr() {
			c.error('V007', "operand 1 of '${name}' has type ${typ.str()}, expected ptr")
		}
	}
	callee_signature := inst.signature
	errors := check_effects(callee_signature.effects, "the signature on '${name}'")
	for error in errors {
		c.errors << error
	}
	for i, param in callee_signature.params {
		problem := type_problem(param.typ)
		if problem != '' {
			c.error('V012', "parameter ${i + 1} of the signature on '${name}' has type ${param.typ.str()}: ${problem}")
		}
	}
	for i, result_ in callee_signature.results {
		problem := type_problem(result_.typ)
		if problem != '' {
			c.error('V012', "result ${i + 1} of the signature on '${name}' has type ${result_.typ.str()}: ${problem}")
		}
	}
	args := inst.operands[1..]
	if args.len != callee_signature.params.len {
		c.error('V012', "'${name}' carries ${callee_signature.params.len} parameters, and the call passes ${args.len} arguments")
	}
	for i in 0 .. args.len {
		if i >= callee_signature.params.len {
			break
		}
		c.expect_operand_is(function, args[i], callee_signature.params[i].typ, 'V012',
			"argument ${i + 1} of '${name}'")
	}
	if inst.opcode == .tailcall_indirect {
		c.check_tail_results(callee_signature, function, inst)
		return
	}
	c.check_call_results(function, inst, callee_signature.result_types(), name)
}

// check_call_results holds the result side of a call's signature, in the same
// place for a direct and an indirect call.
fn (mut c VerifyContext) check_call_results(function &Function, inst Instruction,
	expected []Type, site string) {
	if inst.results.len != expected.len {
		c.error('V012', '${site} returns ${expected.len} results, and ${inst.results.len} are named')
	}
	for i in 0 .. inst.results.len {
		if i >= expected.len {
			break
		}
		index := inst.results[i]
		if index < 0 || index >= function.values.len {
			continue
		}
		actual := function.values[index].typ
		if actual.is_unknown() {
			c.error('V012', 'result ${i + 1} of ${site} has no type, expected ${expected[i].str()}')
		} else if actual != expected[i] {
			c.error('V012', 'result ${i + 1} of ${site} has type ${actual.str()}, expected ${expected[i].str()}')
		}
	}
}

// check_tail_results holds V013: the callee's results are the function's, in
// order, because a tail call replaces the frame rather than returning to it.
fn (mut c VerifyContext) check_tail_results(signature Signature, function &Function,
	inst Instruction) {
	if signature.result_types() == function.signature.result_types() {
		return
	}
	c.error('V013', "'${inst.opcode.name()}' returns ${results_text(signature.result_types())}, and the function returns ${results_text(function.signature.result_types())}")
}

fn results_text(results []Type) string {
	if results.len == 0 {
		return 'nothing'
	}
	if results.len == 1 {
		return results[0].str()
	}
	return '(${results.map(it.str()).join(', ')})'
}

fn (mut c VerifyContext) check_inline_asm(function &Function, inst Instruction) {
	if inst.results.len != inst.asm.outputs.len {
		c.error('V018', "'inline_asm' has ${inst.results.len} results and declares ${inst.asm.outputs.len} outputs")
	}
	for i in 0 .. inst.results.len {
		if i >= inst.asm.outputs.len {
			break
		}
		index := inst.results[i]
		if index < 0 || index >= function.values.len {
			continue
		}
		expected := inst.asm.outputs[i].typ
		problem := type_problem(expected)
		if problem != '' {
			c.error('V023', "output ${i + 1} of 'inline_asm' has type ${expected.str()}: ${problem}")
			continue
		}
		if expected.is_struct() || expected.is_array() {
			c.error('V018', "output ${i + 1} of 'inline_asm' has type ${expected.str()}, and an aggregate is never an asm operand")
			continue
		}
		actual := function.values[index].typ
		if actual != expected {
			c.error('V018', "result ${i + 1} of 'inline_asm' has type ${actual.str()}, and the output is ${expected.str()}")
		}
	}
	for i, input in inst.asm.inputs {
		if input.constraint == '' {
			c.error('V018', "input ${i + 1} of 'inline_asm' names no constraint")
		}
		if input.value.kind == .int_imm {
			c.error('V018', "input ${i + 1} of 'inline_asm' is an integer immediate, which has no type")
		} else if input.value.kind != .value && input.value.kind != .float_imm {
			c.error('V018', "input ${i + 1} of 'inline_asm' is not a value")
		} else if input.value.kind == .value {
			typ := c.operand_type(function, input.value)
			if typ.is_struct() || typ.is_array() {
				c.error('V018', "input ${i + 1} of 'inline_asm' has type ${typ.str()}, and an aggregate is never an asm operand")
			}
		}
	}
}

fn mask_to(bits u16, value u128) u128 {
	if bits == 0 || bits >= 128 {
		return value
	}
	return value & ((u128(1) << bits) - 1)
}

const integer_predicates = ['eq', 'ne', 'slt', 'sle', 'sgt', 'sge', 'ult', 'ule', 'ugt', 'uge']

const pointer_predicates = ['eq', 'ne', 'ult', 'ule', 'ugt', 'uge']

const float_predicates = ['oeq', 'one', 'olt', 'ole', 'ogt', 'oge', 'ueq', 'une', 'ult', 'ule',
	'ugt', 'uge', 'ord', 'uno']

// operand_type is a value's type or a float immediate's stated type. An integer
// immediate has none of its own: it takes the type of the position it fills.
fn (c &VerifyContext) operand_type(function &Function, operand Operand) Type {
	match operand.kind {
		.value {
			if operand.idx >= 0 && operand.idx < function.values.len {
				return function.values[operand.idx].typ
			}
			return ty_unknown
		}
		.float_imm {
			return operand.typ
		}
		else {
			return ty_unknown
		}
	}
}

fn (mut c VerifyContext) expect_operand_count(inst Instruction, count int) bool {
	if inst.operands.len == count {
		return true
	}
	c.error('V007', "'${inst.opcode.name()}' takes ${operand_count_phrase(count)}, found ${inst.operands.len}")
	return false
}

// expect_operand checks one operand against the type its position gives it.
fn (mut c VerifyContext) expect_operand(function &Function, inst Instruction, index int,
	expected Type) bool {
	if index < 0 || index >= inst.operands.len {
		return false
	}
	return c.expect_operand_is(function, inst.operands[index], expected, 'V007',
		"operand ${index + 1} of '${inst.opcode.name()}'")
}

// expect_operand_is is the rule for one operand at any site: an instruction
// operand, a jump argument, a return value. An integer immediate is typed by the
// position, so it must fit the expected width.
fn (mut c VerifyContext) expect_operand_is(function &Function, operand Operand, expected Type,
	code string, site string) bool {
	if expected.is_unknown() {
		return true
	}
	match operand.kind {
		.value {
			if operand.idx < 0 || operand.idx >= function.values.len {
				// V005 names the index in check_use; a second error here would
				// repeat it with a worse description.
				return false
			}
			actual := c.operand_type(function, operand)
			if actual.is_unknown() {
				c.error(code, '${site} is a value with no type, expected ${expected.str()}')
				return false
			}
			if actual != expected {
				c.error(code, '${site} has type ${actual.str()}, expected ${expected.str()}')
				return false
			}
			return true
		}
		.int_imm {
			if expected.kind != .int {
				c.error(code, '${site} is an integer immediate, expected ${expected.str()}')
				return false
			}
			if !immediate_fits(operand.imm, expected.bits) {
				c.error('V009', '${site} has an immediate that does not fit ${expected.str()}')
				return false
			}
			return true
		}
		.float_imm {
			if expected.kind != .float || operand.typ != expected {
				c.error(code, '${site} is a ${operand.typ.str()} immediate, expected ${expected.str()}')
				return false
			}
			return true
		}
		.symbol {
			c.error(code, '${site} is a symbol, expected ${expected.str()}')
			return false
		}
		.stack_slot {
			c.error(code, '${site} is a stack slot, expected ${expected.str()}')
			return false
		}
	}
}

// expect_integer_operand is a position whose width the opcode does not fix: a
// ptradd offset, a memcpy length. A value must be an integer, and an immediate
// is one already.
fn (mut c VerifyContext) expect_integer_operand(function &Function, inst Instruction, index int) bool {
	if index < 0 || index >= inst.operands.len {
		return false
	}
	operand := inst.operands[index]
	site := "operand ${index + 1} of '${inst.opcode.name()}'"
	match operand.kind {
		.int_imm {
			return true
		}
		.float_imm {
			c.error('V007', '${site} is a ${operand.typ.str()} immediate, expected an integer')
			return false
		}
		.value {
			typ := c.operand_type(function, operand)
			if typ.is_unknown() {
				c.error('V007', '${site} has no type, expected an integer')
				return false
			}
			if !typ.is_int() {
				c.error('V007', '${site} has type ${typ.str()}, expected an integer')
				return false
			}
			return true
		}
		else {
			c.error('V007', '${site} is not an integer')
			return false
		}
	}
}

// shared_type is the type every operand in a range must share: the first typed
// operand gives it, and an integer immediate is then typed by it.
fn (mut c VerifyContext) shared_type(function &Function, inst Instruction, start int,
	count int, kinds []TypeKind, what string) Type {
	mut shared := ty_unknown
	mut from := -1
	for i in start .. start + count {
		if i >= inst.operands.len {
			break
		}
		typ := c.operand_type(function, inst.operands[i])
		if typ.is_unknown() {
			continue
		}
		if shared.is_unknown() {
			shared = typ
			from = i
		}
	}
	if shared.is_unknown() {
		c.error('V007', "'${inst.opcode.name()}' has no operand with a type: an immediate takes its type from the operand beside it")
		return ty_unknown
	}
	if shared.kind !in kinds {
		c.error('V007', "operand ${from + 1} of '${inst.opcode.name()}' has type ${shared.str()}, expected ${what}")
	}
	for i in start .. start + count {
		if i >= inst.operands.len {
			break
		}
		c.expect_operand(function, inst, i, shared)
	}
	return shared
}

fn (mut c VerifyContext) expect_results(function &Function, inst Instruction, expected []Type) {
	name := inst.opcode.name()
	if inst.results.len != expected.len {
		c.error('V007', "'${name}' takes ${result_count_phrase(expected.len)}, found ${inst.results.len}")
	}
	for i in 0 .. inst.results.len {
		if i >= expected.len {
			break
		}
		index := inst.results[i]
		if index < 0 || index >= function.values.len {
			continue
		}
		actual := function.values[index].typ
		if actual.is_unknown() {
			c.error('V007', "result ${i + 1} of '${name}' has no type, expected ${expected[i].str()}")
		} else if actual != expected[i] {
			c.error('V007', "result ${i + 1} of '${name}' has type ${actual.str()}, expected ${expected[i].str()}")
		}
	}
}

// check_conversion is the shape all the scalar conversions share: one typed
// operand and a stated result type. The width relation is the caller's rule
// because each opcode states its own.
fn (mut c VerifyContext) check_conversion(function &Function, inst Instruction, in_kind TypeKind,
	out_kind TypeKind) (Type, Type) {
	name := inst.opcode.name()
	mut from := ty_unknown
	if inst.operands.len > 0 {
		operand := inst.operands[0]
		if operand.kind == .int_imm {
			c.error('V007', "'${name}' needs a typed operand, and an integer immediate has no source width")
			return ty_unknown, ty_unknown
		}
		from = c.operand_type(function, operand)
		if from.is_unknown() {
			c.error('V007', "operand 1 of '${name}' has no type")
			return ty_unknown, ty_unknown
		}
		if from.kind != in_kind {
			c.error('V007', "operand 1 of '${name}' has type ${from.str()}, expected ${kind_text(in_kind)}")
			return from, ty_unknown
		}
	}
	to := inst.typ
	if !c.check_stated_type(inst, to, out_kind, 'the result') {
		return from, ty_unknown
	}
	c.expect_results(function, inst, [to])
	return from, to
}

fn (mut c VerifyContext) check_stated_type(inst Instruction, typ Type, kind TypeKind,
	what string) bool {
	if !c.check_type_valid(inst, typ, what) {
		return false
	}
	if typ.kind != kind {
		c.error('V007', "${what} of '${inst.opcode.name()}' has type ${typ.str()}, expected ${kind_text(kind)}")
		return false
	}
	return true
}

fn (mut c VerifyContext) check_type_valid(inst Instruction, typ Type, what string) bool {
	problem := type_problem(typ)
	if problem == '' {
		return true
	}
	c.error('V023', "${what} of '${inst.opcode.name()}' has type ${typ.str()}: ${problem}")
	return false
}

fn (mut c VerifyContext) check_memory_type(inst Instruction, typ Type, what string) bool {
	problem := type_problem(typ)
	if problem != '' {
		c.error('V023', "${what} of '${inst.opcode.name()}' has type ${typ.str()}: ${problem}")
		return false
	}
	if !typ.is_memory() {
		c.error('V015', "${what} of '${inst.opcode.name()}' is ${typ.str()}, expected a byte-sized type")
		return false
	}
	return true
}

fn (mut c VerifyContext) check_store_value(function &Function, inst Instruction) {
	operand := inst.operands[1]
	typ := c.operand_type(function, operand)
	if typ.is_unknown() {
		if operand.kind == .int_imm {
			c.error('V007', "operand 2 of 'store' is an integer immediate, which has no type; write an iconst for it")
		} else {
			c.error('V007', "operand 2 of 'store' has no type")
		}
		return
	}
	c.check_memory_type(inst, typ, 'the value')
}

fn (mut c VerifyContext) check_align(inst Instruction, align u16, which string) {
	if is_power_of_two(int(align)) {
		return
	}
	label := if which == '' { 'align ${align}' } else { 'align ${which} ${align}' }
	c.error('V010', "'${inst.opcode.name()}' has ${label}, expected a power of two greater than zero")
}

fn (mut c VerifyContext) check_stack_operand(function &Function, inst Instruction) {
	operand := inst.operands[0]
	if operand.kind != .stack_slot {
		c.error('V007', "operand 1 of 'stack_addr' is not a stack slot")
		return
	}
	if operand.idx < 0 || operand.idx >= function.stack_slots.len {
		c.error('V009', "stack slot '${operand.name}' is not declared by the function")
	}
}

fn (mut c VerifyContext) check_symbol_operand(module &Module, inst Instruction,
	wanted SymbolKind) {
	operand := inst.operands[0]
	if operand.kind != .symbol {
		c.error('V007', "operand 1 of '${inst.opcode.name()}' is not a symbol")
		return
	}
	kind, _ := resolve_symbol(module, operand)
	if kind != wanted {
		what := if wanted == .global { 'a global' } else { 'a function' }
		c.error('V009', "'${inst.opcode.name()}' names '@${operand.name}', which is not ${what}")
	}
}

// resolve_symbol takes the parser's resolution when it is in range and falls
// back to the name, so a module a builder assembled without resolving still
// verifies against what it declares.
fn resolve_symbol(module &Module, operand Operand) (SymbolKind, int) {
	if operand.sym == .function && operand.idx >= 0 && operand.idx < module.functions.len {
		return .function, operand.idx
	}
	if operand.sym == .global && operand.idx >= 0 && operand.idx < module.globals.len {
		return .global, operand.idx
	}
	if index := module.find_function_index(operand.name) {
		return .function, index
	}
	if index := module.find_global_index(operand.name) {
		return .global, index
	}
	return .none, -1
}

// immediate_fits is the range an immediate has in a position of the stated
// width. Text writes a negative literal as its 128-bit two's complement, so the
// value fits when it is inside the unsigned range or when it is the sign
// extension of an N-bit value. Both spellings are printable, and -200 in an i8
// position is neither: it is -56 once truncated, which is not what was written.
fn immediate_fits(value u128, bits u16) bool {
	if bits == 0 {
		return false
	}
	if bits >= 128 {
		return true
	}
	mask := (u128(1) << bits) - 1
	low := value & mask
	if value == low {
		return true
	}
	return value == (low | ~mask)
}

fn operand_count_phrase(count int) string {
	return match count {
		0 { 'no operands' }
		1 { 'one operand' }
		2 { 'two operands' }
		3 { 'three operands' }
		else { '${count} operands' }
	}
}

fn value_count_phrase(count int) string {
	return match count {
		0 { 'no values' }
		1 { 'one value' }
		else { '${count} values' }
	}
}

fn result_count_phrase(count int) string {
	return match count {
		0 { 'no results' }
		1 { 'one result' }
		2 { 'two results' }
		else { '${count} results' }
	}
}

// dominators is the immediate dominator of each reachable block, in the way
// Cooper, Harvey and Kennedy describe: walk the graph once in reverse
// postorder, then take each block's dominator as the intersection of its
// predecessors'. The entry dominates itself; an unreachable block keeps -1.
fn dominators(function &Function, preds [][]int) []int {
	mut idom := []int{len: function.blocks.len, init: -1}
	if function.blocks.len == 0 {
		return idom
	}
	idom[0] = 0
	mut postorder := []int{cap: function.blocks.len}
	mut visited := []bool{len: function.blocks.len}
	mut stack_blocks := []int{cap: function.blocks.len}
	mut stack_next := []int{cap: function.blocks.len}
	visited[0] = true
	stack_blocks << 0
	stack_next << 0
	for stack_blocks.len > 0 {
		top := stack_blocks.len - 1
		block := stack_blocks[top]
		next := stack_next[top]
		reachable_from_block := successors(function, block)
		if next < reachable_from_block.len {
			stack_next[top] = next + 1
			target := reachable_from_block[next]
			if !visited[target] {
				visited[target] = true
				stack_blocks << target
				stack_next << 0
			}
			continue
		}
		postorder << block
		stack_blocks.delete_last()
		stack_next.delete_last()
	}
	mut postnumber := []int{len: function.blocks.len, init: -1}
	for i, block in postorder {
		postnumber[block] = i
	}
	mut changed := true
	for changed {
		changed = false
		for i := postorder.len - 1; i >= 0; i-- {
			block := postorder[i]
			if block == 0 {
				continue
			}
			mut new_idom := -1
			for pred in preds[block] {
				if idom[pred] < 0 {
					continue
				}
				if new_idom < 0 {
					new_idom = pred
				} else {
					new_idom = intersect_dominators(pred, new_idom, idom, postnumber)
				}
			}
			if new_idom >= 0 && idom[block] != new_idom {
				idom[block] = new_idom
				changed = true
			}
		}
	}
	return idom
}

fn intersect_dominators(a int, b int, idom []int, postnumber []int) int {
	mut x := a
	mut y := b
	for x != y {
		for postnumber[x] < postnumber[y] {
			if idom[x] < 0 || idom[x] == x {
				return y
			}
			x = idom[x]
		}
		for postnumber[y] < postnumber[x] {
			if idom[y] < 0 || idom[y] == y {
				return x
			}
			y = idom[y]
		}
	}
	return x
}

// dominates walks the dominator tree up from the use. Two blocks in different
// unreachable components are not compared: the unreachable one already failed
// V022, and a second error there says nothing new.
fn dominates(definition int, use int, idom []int, reachable []bool) bool {
	if !reachable[definition] || !reachable[use] {
		return true
	}
	if definition == use {
		return true
	}
	mut block := use
	for {
		if block == definition {
			return true
		}
		if block == 0 {
			return false
		}
		next := idom[block]
		if next < 0 || next == block {
			return false
		}
		block = next
	}
}

// check_uses walks every operand an instruction reads, which includes the
// arguments a jump passes and the inputs an inline asm takes.
fn (mut c VerifyContext) check_uses(function &Function, inst Instruction, idom []int,
	reachable []bool) {
	mut operands := []Operand{cap: inst.operands.len}
	for operand in inst.operands {
		operands << operand
	}
	for operand in inst.target.args {
		operands << operand
	}
	for operand in inst.else_target.args {
		operands << operand
	}
	for case_ in inst.cases {
		for operand in case_.target.args {
			operands << operand
		}
	}
	for input in inst.asm.inputs {
		operands << input.value
	}
	for operand in operands {
		if operand.kind != .value {
			continue
		}
		c.check_use(function, operand, idom, reachable)
	}
}

// check_use holds V005 for a value id and V006 for the order of its definition.
fn (mut c VerifyContext) check_use(function &Function, operand Operand, idom []int,
	reachable []bool) {
	index := operand.idx
	if index < 0 || index >= function.values.len {
		c.error('V005', 'value ${index} is not in the function value table, which holds ${function.values.len}')
		return
	}
	if c.block < 0 || c.block >= function.blocks.len || !reachable[c.block] {
		return
	}
	value := function.values[index]
	match value.kind {
		.function_param {}
		.block_param {
			if value.block < 0 || value.block >= function.blocks.len {
				return
			}
			if !dominates(value.block, c.block, idom, reachable) {
				c.error('V006', '${value_name(function, index)} is a parameter of ${block_name(function, value.block)}, which does not dominate ${block_name(function, c.block)}, where it is used')
			}
		}
		.instruction_result {
			if value.block == c.block {
				if value.inst == c.inst {
					c.error('V006', '${value_name(function, index)} is used by the instruction that defines it')
				} else if value.inst > c.inst {
					c.error('V006', '${value_name(function, index)} is used at index ${c.inst} of ${block_name(function, c.block)}, before its definition at index ${value.inst}')
				}
				return
			}
			if value.block < 0 || value.block >= function.blocks.len {
				return
			}
			if !dominates(value.block, c.block, idom, reachable) {
				c.error('V006', '${value_name(function, index)} is defined in ${block_name(function, value.block)} and used in ${block_name(function, c.block)}, which ${block_name(function, value.block)} does not dominate')
			}
		}
	}
}

// successors is the set of blocks a terminator can reach. A target outside the
// block list is left to V005 and dropped here so the walks stay in bounds.
fn successors(function &Function, bi int) []int {
	terminator := function.blocks[bi].terminator
	mut out := []int{}
	match terminator.opcode {
		.br {
			out << terminator.target.block
		}
		.condbr {
			out << terminator.target.block
			out << terminator.else_target.block
		}
		.switch {
			out << terminator.target.block
			for case_ in terminator.cases {
				out << case_.target.block
			}
		}
		else {}
	}
	mut in_range := []int{cap: out.len}
	for target in out {
		if target >= 0 && target < function.blocks.len {
			in_range << target
		}
	}
	return in_range
}

fn predecessors(function &Function) [][]int {
	mut preds := [][]int{cap: function.blocks.len}
	for _ in 0 .. function.blocks.len {
		preds << []int{}
	}
	for bi in 0 .. function.blocks.len {
		for target in successors(function, bi) {
			preds[target] << bi
		}
	}
	return preds
}

// reachable_blocks marks what the entry block can reach. V022 is reported per
// block, so the walk itself says nothing.
fn reachable_blocks(function &Function) []bool {
	mut reachable := []bool{len: function.blocks.len}
	if function.blocks.len == 0 {
		return reachable
	}
	mut queue := []int{cap: function.blocks.len}
	queue << 0
	reachable[0] = true
	mut head := 0
	for head < queue.len {
		block := queue[head]
		head++
		for target in successors(function, block) {
			if !reachable[target] {
				reachable[target] = true
				queue << target
			}
		}
	}
	return reachable
}

fn block_name(function &Function, index int) string {
	if index < 0 || index >= function.blocks.len {
		return 'block ${index}'
	}
	label := function.blocks[index].label
	if label == '' {
		return 'block ${index}'
	}
	return label
}

fn value_name(function &Function, index int) string {
	if index < 0 || index >= function.values.len {
		return 'value ${index}'
	}
	name := function.values[index].name
	if name == '' {
		return 'value ${index}'
	}
	return '%${name}'
}

fn slot_name(slot StackSlot, index int) string {
	if name := slot.name {
		return name
	}
	return 'slot${index}'
}

fn is_power_of_two(value int) bool {
	return value > 0 && (value & (value - 1)) == 0
}

fn kind_text(kind TypeKind) string {
	return match kind {
		.int { 'an integer' }
		.float { 'a float' }
		.ptr { 'a pointer' }
		.struct_ { 'a struct' }
		.array { 'an array' }
		.vector { 'a vector' }
		.unknown { 'a type' }
	}
}

// type_problem says what is wrong with a type the model states, or an empty
// string when it is one of the types in ir-types.md. An aggregate carries the
// problem of the field or the element that has one.
fn type_problem(typ Type) string {
	return match typ.kind {
		.int {
			if typ.bits < 1 || typ.bits > 128 { 'an integer width is 1 to 128' } else { '' }
		}
		.float {
			if typ.bits != 16 && typ.bits != 32 && typ.bits != 64 && typ.bits != 128 {
				'a float width is 16, 32, 64 or 128'
			} else {
				''
			}
		}
		.ptr {
			if typ.bits != 0 { 'a pointer type carries no width' } else { '' }
		}
		.struct_ {
			if typ.elems.len == 0 {
				'a struct has at least one field'
			} else {
				struct_problem(typ)
			}
		}
		.array {
			if typ.count < 1 {
				'an array has at least one element'
			} else {
				element_problem(typ)
			}
		}
		.vector {
			if typ.count < 1 {
				'a vector has at least one lane'
			} else if typ.elem().is_aggregate() {
				'a vector element is an integer, a float or a pointer'
			} else {
				element_problem(typ)
			}
		}
		.unknown { 'the type is not stated' }
	}
}

fn struct_problem(typ Type) string {
	for i, field in typ.elems {
		problem := type_problem(field)
		if problem != '' {
			return 'field ${i + 1}: ${problem}'
		}
	}
	return ''
}

fn element_problem(typ Type) string {
	problem := type_problem(typ.elem())
	if problem != '' {
		return 'the element: ${problem}'
	}
	return ''
}
