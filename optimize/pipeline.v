module optimize

import vanadiume.velocity.ir

// The pipeline: constant folding then dead code elimination, and the two entry
// points a caller who does not want to think about passes calls. Each pass
// iterates inside itself, so one pass over the list is enough.

pub fn (mut pm PassManager) add_constant_fold() {
	pm.add(constant_fold())
}

pub fn (mut pm PassManager) add_dead_code_elim() {
	pm.add(dead_code_elim())
}

pub fn default_pipeline() PassManager {
	mut manager := new_pass_manager()
	manager.add_constant_fold()
	manager.add_dead_code_elim()
	return manager
}

pub fn optimize_function(mut module ir.Module, mut function ir.Function) bool {
	mut manager := default_pipeline()
	return manager.run_function(module, mut function)
}

pub fn optimize_module(mut module ir.Module) bool {
	mut manager := default_pipeline()
	return manager.run_module(mut module)
}
