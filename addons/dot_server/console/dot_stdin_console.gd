class_name DotStdinConsole
extends Node

## Runs what an operator types into the server's own terminal, as the CONSOLE source. The
## engine only offers a blocking read, run as the engine's own call, never a GDScript loop
## (see [method _start_tap]). Fully trusted: whoever types here owns the machine.

const CHANNEL := "console.stdin"

## How many bytes to ask for per read. One line is far below this; the size only
## bounds a paste.
const BUFFER := 4096

## How many empty reads in a row mean end of input. The engine returns "" for both an empty
## line and end of input, so sixty-four in a row is a file or hangup, not a person.
const EOF_EMPTY_READS := 64

## Seconds between looks at the tap file (see [method _start_tap]).
const TAP_POLL_SEC := 0.1

## Where typed lines are attributed from: [constant DotCmdContext.Source.CONSOLE], like a
## startup `.cfg`. It bypasses the rcon and chat gates, which bound REMOTE callers.
@export var source: DotCmdContext.Source = DotCmdContext.Source.CONSOLE

## Print each line back before running it. Off: a terminal already shows it; useful for a pipe.
@export var echo: bool = false

## Also read stdin when it is a pipe, socket or device. Off, because a pipe nobody closes hangs
## the process at exit; turn on ([member DotServerConfig.stdin_console_pipes]) for a supervisor
## feeding commands down a pipe, and close the pipe to stop the server.
@export var read_pipes: bool = false

var server: DotServer = null

var _thread: Thread = null
var _stop := false
var _empty_reads := 0
var _tap_pid := -1
var _tap_error := ""
var _tap_path := ""
var _tap_offset := 0
var _tap_partial := ""
var _tap_clock := 0.0


## Starts reading, or explains why it will not.
func setup(p_server: DotServer) -> DotResult:
	server = p_server

	if server == null or server.console == null:
		return DotResult.fail(
			DotError.CODE_STATE, "A stdin console needs a server with a console."
		)

	# No terminal is the ordinary case (container without `-i`, systemd unit, CI): a reader
	# there would spin on instant EOF or block forever.
	var kind := OS.get_stdin_type()

	if kind == OS.STD_HANDLE_INVALID:
		DotLog.info(CHANNEL, "no terminal on stdin; console input is off", {
			"hint": "run the server in the foreground, or use RCON"
		})
		return DotResult.success(false)

	if not should_read(kind, read_pipes):
		DotLog.info(CHANNEL, "stdin is not a terminal or a file; console input is off", {
			"stdin": kind,
			"hint": "set stdin_console_pipes to read a pipe, and close it to stop"
		})
		return DotResult.success(false)

	if not DotPlatform.has_threads():
		# The browser, and any export built without threads. A server does not run
		# there, but this class must not be the reason a build refuses to load.
		DotLog.info(CHANNEL, "no threads on this platform; console input is off")
		return DotResult.success(false)

	if kind != OS.STD_HANDLE_FILE and _start_tap():
		set_process(true)
		DotLog.info(CHANNEL, "console input is on; type a command and press enter", {
			"stdin": kind, "reader": "helper process"
		})
		return DotResult.success(true)

	if kind != OS.STD_HANDLE_FILE and kind != OS.STD_HANDLE_CONSOLE:
		# A blocked read thread on a pipe keeps the process from exiting (quit(75) is lost).
		DotLog.warn(CHANNEL, "console input is off: the stdin helper process could not start", {
			"reason": _tap_error
		})
		return DotResult.success(false)

	if not _start_read():
		return DotResult.fail(
			DotError.CODE_INTERNAL, "Could not start the stdin reader thread."
		)

	set_process(true)
	DotLog.info(CHANNEL, "console input is on; type a command and press enter", {
		"stdin": kind
	})

	return DotResult.success(true)


## Whether a stdin of this [method OS.get_stdin_type] is read at all: a terminal and a file are;
## a pipe and UNKNOWN only when [member read_pipes], since a never-closing read blocks exit.
## Static so a suite can check every kind of handle.
static func should_read(kind: int, pipes: bool) -> bool:
	match kind:
		OS.STD_HANDLE_CONSOLE, OS.STD_HANDLE_FILE:
			return true
		OS.STD_HANDLE_PIPE, OS.STD_HANDLE_UNKNOWN:
			return pipes
	return false


func _process(delta: float) -> void:
	if _tap_pid > 0:
		_poll_tap(delta)
		return

	if _thread == null or _thread.is_alive():
		return

	var chunk: String = _thread.wait_to_finish()
	_thread = null

	if chunk == "":
		_empty_reads += 1
		# The reader stops at end of input -- a piped script that ran out, or a terminal
		# that was closed. Said once, so `./server < commands.txt` does not look hung.
		if _empty_reads >= EOF_EMPTY_READS:
			set_process(false)
			DotLog.info(CHANNEL, "end of input; console input is off")
			return
	else:
		_empty_reads = 0
		for line in chunk.split("\n", false):
			_run(line)

	# [b]No next read once the server is down.[/b] `quit` ran on the line just collected;
	# a read started now would block until exit and leave a thread the engine warns about.
	if _stop or (server != null and server.state == DotServer.State.STOPPED):
		set_process(false)
		return

	_start_read()


## Starts one blocking read on its own thread. See the class comment for why the thread
## runs the engine's method and not one of ours.
func _start_read() -> bool:
	_thread = Thread.new()

	if _thread.start(OS.read_string_from_stdin.bind(BUFFER)) != OK:
		_thread = null
		return false

	return true


## Reads stdin through a helper process instead of a thread, where there is a shell. A thread
## blocked in the engine's read holds stdio's lock and hangs the process at exit (so `quit(75)`
## never arrives). The helper (`cat`) appends to a file and is killed in [method _exit_tree].
func _start_tap() -> bool:
	if OS.get_name() not in ["Linux", "FreeBSD", "NetBSD", "OpenBSD", "macOS"]:
		_tap_error = "no shell on this platform"
		return false
	if not FileAccess.file_exists("/bin/sh") or OS.get_environment("DOT_STDIN_NO_HELPER") != "":
		_tap_error = "/bin/sh unavailable"
		return false

	var dir := OS.get_user_data_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	_tap_path = dir.path_join("stdin-%d.tap" % OS.get_process_id())
	var f := FileAccess.open(_tap_path, FileAccess.WRITE)
	if f == null:
		_tap_error = "cannot write %s" % _tap_path
		return false
	f.close()

	_tap_pid = OS.create_process("/bin/sh", ["-c", "exec cat >> \"$1\"", "sh", _tap_path])
	if _tap_pid <= 0:
		_tap_pid = -1
		DirAccess.remove_absolute(_tap_path)
		_tap_error = "create_process failed"
		return false
	_tap_offset = 0
	_tap_partial = ""
	return true


func _poll_tap(delta: float) -> void:
	_tap_clock += delta
	if _tap_clock < TAP_POLL_SEC:
		return
	_tap_clock = 0.0

	var alive := OS.is_process_running(_tap_pid)
	var f := FileAccess.open(_tap_path, FileAccess.READ)
	var got := ""
	if f != null:
		var size := f.get_length()
		if size > _tap_offset:
			f.seek(_tap_offset)
			got = f.get_buffer(size - _tap_offset).get_string_from_utf8()
			_tap_offset = size
		f.close()

	if got != "":
		_tap_partial += got
		var lines := _tap_partial.split("\n")
		_tap_partial = lines[lines.size() - 1]
		lines.remove_at(lines.size() - 1)
		for line in lines:
			if line.strip_edges() != "":
				_run(line)
		return

	if not alive:
		set_process(false)
		DotLog.info(CHANNEL, "end of input; console input is off")


func _run(line: String) -> void:
	var text := line.strip_edges()

	if text == "":
		return

	if echo:
		print("> %s" % text)

	var ctx := DotCmdContext.new()
	ctx.source = source

	# ROOT, as a startup `.cfg` gets it: this IS the terminal. It must be granted explicitly,
	# because `_run_command` checks `ctx.has_permission` and does not consult `ctx.is_trusted()`.
	ctx.permissions = PackedStringArray([DotAdminFlags.ROOT])
	ctx.immunity = DotAdminFlags.MAX_IMMUNITY
	ctx.address = "stdin"

	# So a command that answers -- `status`, `games` -- prints to the terminal the
	# person is looking at, rather than into a log sink they are not.
	ctx.reply_sink = func(text: String) -> void: print(text)

	var res: DotResult = server.console.execute(text, ctx)

	# Printed rather than logged. A person typed this and is looking at the terminal
	# waiting for an answer; a log line routed somewhere else is not an answer.
	if res != null and not res.ok:
		printerr("  %s" % str(res.error))


func _exit_tree() -> void:
	_stop = true

	if _tap_pid > 0:
		OS.kill(_tap_pid)
		_tap_pid = -1
		DirAccess.remove_absolute(_tap_path)
		return

	if _thread == null:
		return

	# Joined only when finished: a blocked engine read cannot be cancelled, so joining it
	# would make ctrl-c hang. This path is only a file, or a host with no shell (see
	# _start_tap); a terminal or pipe never has a blocked thread to leave behind.
	if not _thread.is_alive():
		_thread.wait_to_finish()

	_thread = null


func describe() -> Dictionary:
	return {
		"reading": _tap_pid > 0 or (_thread != null and _thread.is_alive()),
		"helper": _tap_pid > 0,
		"stdin_type": OS.get_stdin_type(),
		"read_pipes": read_pipes,
		"empty_reads": _empty_reads,
		"source": source,
	}
