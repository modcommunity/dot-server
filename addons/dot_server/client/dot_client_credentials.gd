extends RefCounted
## The credential half of the sign-in: what to attach to the CREDENTIALS payload for the
## server's strategy, and the stable device id. Owned by [DotClientLink], which supplies the state.

const CHANNEL := "client"

var link: DotClientLink


func _init(owner: DotClientLink) -> void:
	link = owner


## Adds only the credential the server's strategy asks for. INTROSPECT gets a join token
## (first-party audience) or a ticket, else a refusal. False: the join is already failed.
func attach_credential(payload: Dictionary, strategy: String) -> bool:
	var auth := DotRegistry.get_service(link.auth_service)

	if auth == null:
		if strategy != "none" and strategy != "anonymous":
			DotLog.warn(
				CHANNEL,
				"this server wants authentication but dot-auth is not installed",
				{"strategy": strategy}
			)
		return true

	match strategy:
		"ticket":
			await _attach_ticket(payload, auth)

		"introspect":
			return await _attach_introspect(payload, auth)

		"local":
			# Username and password for a LOCAL-strategy server come from a UI this
			# node does not own; a game sets them before connecting.
			pass

	return true


## A connect ticket for the address this client DIALLED, never the one the server announced
## (a hostile server naming another's id would get a ticket valid there), bound to the
## challenge nonce. Returns whether one was attached.
func _attach_ticket(payload: Dictionary, auth: Object) -> bool:
	var ticket: Variant = null
	if auth.has_method("request_ticket_for_address"):
		var dialled := link._last_address.strip_edges()
		if dialled == "":
			return false
		if link._ticket_nonce != "" and auth.get_method_argument_count("request_ticket_for_address") >= 3:
			ticket = await auth.call("request_ticket_for_address", dialled, "", link._ticket_nonce)
		else:
			ticket = await auth.call("request_ticket_for_address", dialled)
	elif auth.has_method("request_ticket"):
		var issuer := _issuer_url()
		if issuer == "" or link.server_id == "":
			DotLog.warn(CHANNEL, "cannot ask for a ticket: no issuer or no server_id")
			return false
		ticket = await auth.call("request_ticket", issuer, link.server_id)
	else:
		return false

	if ticket is DotResult and (ticket as DotResult).ok:
		payload["ticket"] = str((ticket as DotResult).value)
		return true
	var err: DotError = (ticket as DotResult).error if ticket is DotResult else null
	DotLog.warn(CHANNEL, "no connect ticket for this server", {
		"address": link._last_address,
		"why": err.message if err != null else "unexpected reply",
		"code": err.detail if err != null else "",
	})
	return false


func _attach_introspect(payload: Dictionary, auth: Object) -> bool:
	var audience := link.server_join_audience

	# First-party: a join token. A server that lies about its audience gains nothing
	# — the backbone spends the token only for the credential that audience names.
	if audience != "" and auth.has_method("is_first_party") \
			and bool(auth.call("is_first_party", audience)) \
			and auth.has_method("request_join_token"):
		var minted: Variant = await auth.call("request_join_token", audience)
		if minted is DotResult and (minted as DotResult).ok:
			payload["access_token"] = str((minted as DotResult).value)
			return true
		var err: DotError = (minted as DotResult).error if minted is DotResult else null
		_refuse_introspect(
			err.message if err != null else "Could not get a sign-in for this server.",
			"join token mint failed for %s" % audience
		)
		return false

	# Not one of ours: a connect ticket for the address we dialled.
	if await _attach_ticket(payload, auth):
		return true

	_refuse_introspect(
		"This server asks for your account sign-in, which this game only gives to its own servers.",
		"introspect refused: audience %s is not first-party and no ticket was available" % (
			audience if audience != "" else "(not announced)"
		)
	)
	return false


func _refuse_introspect(message: String, detail: String) -> void:
	var err := DotError.make(DotError.CODE_FORBIDDEN, message, detail)
	DotLog.warn(CHANNEL, "not signing in to this server", {
		"why": detail, "host": link.server_hostname,
	})
	link._fail(err)
	link.disconnect_from_server(err.message)


func _issuer_url() -> String:
	var auth := DotRegistry.get_service(link.auth_service)
	if auth == null:
		return ""
	var config: Variant = auth.get("config")
	if config == null:
		return ""
	var url: Variant = config.get("ticket_issuer_url")
	return str(url) if url != null else ""


static func device_id() -> String:
	# DotPlatform, not OS.get_unique_id(), which pushes an engine error on web and iOS.
	var unique := DotPlatform.unique_id()
	if unique != "":
		return unique
	# Web and some sandboxes have no unique id. A stored random value is stable
	# enough for the session-scoped uses this has.
	var path := "user://dot_device_id"
	if FileAccess.file_exists(path):
		var read := DotPaths.read_text(path)
		if read.ok and str(read.value) != "":
			return str(read.value)
	var generated := DotHash.random_hex(16)
	DotPaths.write_text(path, generated)
	return generated
