class_name DotStdinConsole
extends Node

## Runs what an operator types into the server's own terminal.
##
## [b]`DotCmdContext.Source.CONSOLE` has been documented as "the server's own terminal
## or startup config" since the console was written, and nothing ever fed it from a
## terminal.[/b] A dedicated server's console is the oldest interface this genre has --
## you start srcds, you type `status`, it answers -- and here the only ways in were RCON
## and a chat trigger. An operator standing at the machine, with the process in the
## foreground, typing `status` into it, got silence: nothing in the project read stdin at
## all, so the characters were the shell echoing and the server never saw a byte.
##
## [b]A thread, because the engine only offers a blocking read.[/b] `OS` exposes
## `read_string_from_stdin` and nothing that polls, so the choice is a thread or a
## server that stops simulating between keystrokes. Lines cross back under a mutex and
## are run on the main thread, where every command in this family expects to be.
##
## [b]Fully trusted, and that is not a shortcut.[/b] Whoever can type here can already
## edit `cfg/`, read `rcon.yml` and restart the process. A permission check against the
## terminal would be a lock on a door standing in open ground -- see [member source].

const CHANNEL := "console.stdin"

## How many bytes to ask for per read. One line is far below this; the size only
## bounds a paste.
const BUFFER := 4096

## Where typed lines are attributed from.
##
## [constant DotCmdContext.Source.CONSOLE] -- the same source a startup `.cfg` uses, and
## the one the enum documents for this. It bypasses the `rcon_allowed` and chat gates
## deliberately: those exist to bound a REMOTE caller, and this caller owns the machine.
@export var source: DotCmdContext.Source = DotCmdContext.Source.CONSOLE

## Print each line back before running it.
##
## Off by default: a terminal already shows what was typed, and echoing it again gives
## every command a double. Worth turning on when the input is a pipe, where nothing
## echoed it in the first place.
@export var echo: bool = false

## Also read stdin when it is a pipe, a socket or a device, rather than only a terminal
## or a file.
##
## [b]Off, because a reader on a pipe nobody closes makes the process unable to exit.[/b]
## The read cannot be cancelled (see [method _exit_tree]), and on a terminal or a file
## that costs one warning at exit -- but on a pipe whose writer stays open (`sleep 600 |
## godot ...`, a CI step, a supervisor that spawned this with `OS.execute_with_pipe`,
## `docker run -i` without `-t`) Godot 4.7.2 prints everything, its leak report included,
## and then hangs inside its own exit. Every suite in the family that booted a server
## under a runner's pipe hung that way until each turned the whole console off by hand.
##
## A terminal is still read, which is the operator at the machine and a panel that
## attaches one; a regular file is still read (`./server < commands.txt`), because it
## ends. Turn this on for a supervisor that feeds commands down a pipe -- and close the
## pipe to stop the server, because nothing else will wake the reader.
## [member DotServerConfig.stdin_console_pipes] sets it.
@export var read_pipes: bool = false

var server: DotServer = null

var _thread: Thread = null
var _mutex: Mutex = Mutex.new()
var _pending: PackedStringArray = PackedStringArray()
var _stop := false
var _eof := false


## Starts reading, or explains why it will not.
func setup(p_server: DotServer) -> DotResult:
	server = p_server

	if server == null or server.console == null:
		return DotResult.fail(
			DotError.CODE_STATE, "A stdin console needs a server with a console."
		)

	# [b]No terminal is the ordinary case, not a failure.[/b] A container without `-i`,
	# a systemd unit with no stdin, a CI run: all of them report INVALID, and a reader
	# thread there would either spin on instant EOF or block forever on a handle nobody
	# can type into.
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

	_thread = Thread.new()

	var started := _thread.start(_read_loop)

	if started != OK:
		_thread = null
		return DotResult.fail(
			DotError.CODE_INTERNAL, "Could not start the stdin reader thread."
		)

	set_process(true)
	DotLog.info(CHANNEL, "console input is on; type a command and press enter", {
		"stdin": kind
	})

	return DotResult.success(true)


## Whether a stdin of this [method OS.get_stdin_type] is read at all.
##
## A terminal and a regular file are: the first is a person, the second ends. A pipe, and
## UNKNOWN -- which is `/dev/null`, a socket, a character device -- only when asked,
## because a blocked read on one that never closes keeps the process from exiting. See
## [member read_pipes]. Static so a suite can check the rule for every kind of handle
## without having to be started under each.
static func should_read(kind: int, pipes: bool) -> bool:
	match kind:
		OS.STD_HANDLE_CONSOLE, OS.STD_HANDLE_FILE:
			return true
		OS.STD_HANDLE_PIPE, OS.STD_HANDLE_UNKNOWN:
			return pipes
	return false


func _process(_delta: float) -> void:
	if _pending.is_empty() and not _eof:
		return

	var lines := PackedStringArray()

	_mutex.lock()
	lines = _pending.duplicate()
	_pending = PackedStringArray()
	_mutex.unlock()

	for line in lines:
		_run(line)

	# The reader stops at end of input -- a piped script that ran out, or a terminal
	# that was closed. Said once, so `./server < commands.txt` does not look hung.
	if _eof:
		_eof = false
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

	# [b]ROOT, for the same reason a startup `.cfg` gets it[/b] -- and that file's own
	# comment says it: "a config file on disk is as trusted as the terminal, whoever
	# wrote it already had filesystem access to the server". This IS the terminal.
	#
	# It has to be granted explicitly. `_run_command` gates on `ctx.has_permission`,
	# which reads this array and does NOT consult `ctx.is_trusted()` -- so a context
	# that merely said CONSOLE would be refused every command that needs a flag, which
	# is every command worth typing. An operator would get "You do not have permission
	# to use 'changelevel'" from the machine's own keyboard.
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


## Runs on the reader thread. Nothing here touches the scene tree.
func _read_loop() -> void:
	while not _stop:
		var chunk := OS.read_string_from_stdin(BUFFER)

		# [b]An empty read is end of input, not an empty line.[/b] A closed or exhausted
		# stdin returns "" immediately and forever, so without this the thread spins a
		# core for the life of the process.
		if chunk == "":
			_eof = true
			return

		_mutex.lock()
		for line in chunk.split("\n", false):
			_pending.append(line)
		_mutex.unlock()


func _exit_tree() -> void:
	_stop = true

	if _thread == null:
		return

	# [b]Joined only when it has already finished.[/b] A reader blocked in
	# `read_string_from_stdin` cannot be woken -- the engine offers no way to cancel one
	# -- so `wait_to_finish()` on it would hang the shutdown until somebody pressed
	# enter, turning ctrl-c into a server that will not stop. Measured: leaving it
	# costs one "Thread object is being destroyed" warning at exit and the process
	# still exits 0, which is the better of the two — ON A TERMINAL OR A FILE. On an
	# open pipe that is never closed (`sleep 60 | godot ...`, a CI step, a parent that
	# spawned this with `OS.execute_with_pipe`) it is not: the process prints everything,
	# its leak report included, and then hangs inside its own exit (Godot 4.7.2). Nothing
	# here can cancel the read, so [method setup] does not START one on a pipe unless
	# [member read_pipes] says to -- and whoever says so owns closing the pipe.
	if not _thread.is_alive():
		_thread.wait_to_finish()

	_thread = null


func describe() -> Dictionary:
	return {
		"reading": _thread != null and _thread.is_alive(),
		"stdin_type": OS.get_stdin_type(),
		"read_pipes": read_pipes,
		"queued": _pending.size(),
		"source": source,
	}
