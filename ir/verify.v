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
			context.error('V002', 'this is a declaration, so it has no blocks, and it has ${function.blocks.len}')
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
			context.check_uses(function, inst, idom, reachable)
		}
		context.inst = block.instructions.len
		if !block.terminator.opcode.is_terminator() {
			context.error('V003', 'the block has no terminator')
		} else {
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
		if global.init.len > int(global.size) {
			errors << VerifyError{
				code:    'V021'
				message: "the initializer for '@${global.name}' is ${global.init.len} bytes and the global is ${global.size} bytes"
			}
		}
		if !is_power_of_two(int(global.align)) {
			errors << VerifyError{
				code:    'V010'
				message: "global '@${global.name}' has align ${global.align}, expected a power of two greater than zero"
			}
		}
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
	return errors
}

// signature_text is the one line spelling a message uses for a signature.
fn signature_text(signature Signature) string {
	params := signature.params.map(it.str()).join(', ')
	results := match signature.results.len {
		0 { '' }
		1 { ' -> ${signature.results[0].str()}' }
		else { ' -> (${signature.results.map(it.str()).join(', ')})' }
	}
	return '(${params})${results}'
}

// check_signature refuses a type that the type model does not have. The parser
// cannot produce one; a builder that assembles the structs by hand can.
fn (mut c VerifyContext) check_signature(function &Function) {
	for i, typ in function.signature.params {
		problem := type_problem(typ)
		if problem != '' {
			c.error('V007', "parameter ${i + 1} of '@${function.name}' has type ${typ.str()}: ${problem}")
		}
	}
	for i, typ in function.signature.results {
		problem := type_problem(typ)
		if problem != '' {
			c.error('V007', "result ${i + 1} of '@${function.name}' has type ${typ.str()}: ${problem}")
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
		expected := function.signature.params[i]
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
			c.error('V007', 'parameter ${i + 1} of ${block_name(function, bi)} has type ${value.typ.str()}: ${problem}')
		}
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
		.unknown { 'a type' }
	}
}

// type_problem says what is wrong with a type the model states, or an empty
// string when it is one of the types in ir-types.md.
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
		.unknown { 'the type is not stated' }
	}
}
