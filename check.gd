extends SceneTree
## check.gd -- shared base for every godot-port check script.
##
## WHY THIS EXISTS. A failed assert() halts the script but leaves the SceneTree
## running. A check whose assertion fails therefore does not FAIL -- it HANGS,
## producing no output at all, until whatever invoked it times out. That is
## worse than a plain failure in two ways: the run reads as slow rather than
## broken, and the empty output hides which assertion went. It cost one 280 s
## run and a misdiagnosis (autoresearch row 745, where the symptom sent me
## measuring Sacred.Items -- 35 ms, not the cause) before being spotted.
##
## HOW IT WORKS. Every check in this directory completes inside _init and exits
## through finish(). Reaching the first PROCESSED FRAME therefore means _init
## did not reach any exit -- it aborted -- and the failsafe turns that into
## exit 1 immediately.
##
## TWO RULES A CHECK MUST FOLLOW, both measured rather than assumed:
##
##   1. Call super() as the FIRST line of its own _init. GDScript does NOT call
##      a base _init automatically when the child defines one; without super()
##      the failsafe is never armed and the hang comes straight back.
##   2. Exit through finish(), never quit(). quit() leaves _finished false, so
##      the failsafe fires on a SUCCESSFUL run and reports exit 1 -- the
##      opposite failure, and a confusing one.
##
## Overriding SceneTree.quit() to enforce rule 2 automatically was tried first
## and is not possible here: this project treats the "overrides a native
## method" warning as an error, so it will not compile.
var _finished := false


func _init() -> void:
	process_frame.connect(_failsafe)


## The only exit. Takes the same exit code quit() would, so converting a check
## is a one-token change per call site and a computed code
## (`finish(0 if ok else 1)`) keeps working unchanged.
func finish(exit_code: int = 0) -> void:
	_finished = true
	quit(exit_code)


## Not connected ONE_SHOT: after finish() the tree still emits one more frame
## before it exits, and this must stay harmless on that frame rather than
## race the shutdown.
func _failsafe() -> void:
	if _finished:
		return
	printerr("check aborted: _init returned without reaching finish(), which is exactly what a failed assert() looks like -- exiting 1 instead of hanging until the caller's timeout")
	quit(1)
