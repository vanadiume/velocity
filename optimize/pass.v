module optimize

import vanadiume.velocity.ir

// A pass takes a function and answers whether it changed it. A pass manager
// runs an ordered list of them, and holds the IR to the verifier after every
// pass that reported a change.

pub type PassFn = fn (mut function ir.Function) bool

pub struct Pass {
pub:
	name string
	run  PassFn @[required]
}

pub struct PassManager {
pub mut:
	passes []Pass
	verify bool // run the verifier after each pass that changed something
}

pub fn new_pass_manager() PassManager {
	return PassManager{
		verify: true
	}
}

pub fn (mut pm PassManager) add(pass Pass) {
	pm.passes << pass
}

// run_function runs the passes in order on one function and answers whether any
// of them changed it. The module is the verifier's input as much as the
// function's: a call names a symbol, and symbol checks read the module.
pub fn (pm &PassManager) run_function(module &ir.Module, mut function ir.Function) bool {
	mut changed := false
	for pass in pm.passes {
		if !pass.run(mut function) {
			continue
		}
		changed = true
		if pm.verify {
			check_pass(pass, module, function)
		}
	}
	return changed
}

// run_module runs every pass on every defined function, in module order, and
// skips the declarations.
pub fn (pm &PassManager) run_module(mut module ir.Module) bool {
	mut changed := false
	for i in 0 .. module.functions.len {
		if !module.functions[i].defined {
			continue
		}
		mut function := module.functions[i]
		if pm.run_function(module, mut function) {
			changed = true
		}
		module.functions[i] = function
	}
	return changed
}

// check_pass panics when a pass leaves IR the verifier refuses. That is an
// internal invariant of the library, not input to recover from, and the message
// names the pass before it names the rule.
fn check_pass(pass Pass, module &ir.Module, function &ir.Function) {
	errors := ir.verify_function(module, function)
	if errors.len == 0 {
		return
	}
	first := errors[0]
	panic("optimize: pass '${pass.name}' left @${function.name} unverifiable: ${first.code}: ${first.message}")
}
