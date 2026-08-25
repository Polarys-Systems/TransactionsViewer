package profiler

import "core:fmt"
import "core:time"

import "core:log"
import "core:testing"

/*
Lightweight CPU scope profiler.

Example:
	prof_init("Main")
	prof_begin("Update")
	// update work
	prof_leaf()
*/

Prof_Scope_T :: struct {
	name:         string,
	start_ns:     i64,
	parent:       ^Prof_Scope_T,
	children:     [dynamic]Prof_Scope_T,
	depth:        i32,
}

Prof_Instance_Data_T :: struct {
	name:            string,
	start_ns:        i64,
	duration:        i64,
	flame_direction: i64,
}

@(thread_local)
tl_scope_root: Prof_Scope_T
@(thread_local)
tl_current_scope: ^Prof_Scope_T
@(thread_local)
tl_current_depth: i64
@(thread_local)
tl_prof_full_instance: [dynamic]Prof_Instance_Data_T

prof_delete_scope_children :: proc(scope: ^Prof_Scope_T) {
	if scope == nil || scope.children == nil {
		return
	}

	for &c in scope.children {
		prof_delete_scope_children(&c)
	}
	delete(scope.children)
	scope.children = nil
}

prof_end :: proc() {
	when ODIN_TEST {
		log.info("[INFO] Profiler finished")
	}
	fmt.println("[INFO] Profiler finished")
	prof_delete_scope_children(&tl_scope_root)

	when ODIN_TEST {
		for instance in tl_prof_full_instance {
			log.info("[", instance.name,"]")
			log.info("\t Duration: ", instance.duration)
		}
	}
	delete(tl_prof_full_instance)
}

@(deferred_none = prof_end)
prof_init :: proc(name: string) {
	tl_scope_root = Prof_Scope_T {
		name     = name,
		start_ns = now_ns(),
		parent   = nil,
		children = make([dynamic]Prof_Scope_T),
		depth    = 0,
	}

	tl_current_scope = &tl_scope_root
	tl_current_depth = 0
	tl_prof_full_instance = make([dynamic]Prof_Instance_Data_T)
}

prof_begin :: proc(name: string) {
	if tl_current_scope.children == nil {
		tl_current_scope.children = make([dynamic]Prof_Scope_T)
	}

	child := Prof_Scope_T{
		name     = name,
		start_ns = now_ns(),
		parent   = tl_current_scope,
		depth    = tl_current_scope.depth + 1,
	}
	append(&tl_current_scope.children, child)
	tl_current_scope = &tl_current_scope.children[len(tl_current_scope.children) - 1]
	tl_current_depth += 1

	append(&tl_prof_full_instance, Prof_Instance_Data_T{
		name            = name,
		start_ns        = child.start_ns,
		flame_direction = 1,
	})
}

prof_leaf :: proc() {
	end := now_ns()
	closing_scope := tl_current_scope
	parent := closing_scope.parent
	duration := end - tl_current_scope.start_ns

	append(&tl_prof_full_instance, Prof_Instance_Data_T{
		name            = tl_current_scope.name,
		start_ns        = tl_current_scope.start_ns,
		duration        = duration,
		flame_direction = -1,
	})

	if parent != nil {
		if parent == &tl_scope_root {
			prof_delete_scope_children(closing_scope)
			clear(&tl_scope_root.children)
		}
		tl_current_scope = parent
		tl_current_depth -= 1
	}
}

now_ns :: proc() -> i64 {
	return time.time_to_unix_nano(time.now())
}

@(test)
init_simple :: proc(t: ^testing.T) {
	_ = t
	prof_init("New thread")
	log.info("Created thread")
}
