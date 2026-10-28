@tool
extends "res://addons/dot_server/client/dot_client_link_connect.gd"

## The challenge, credentials and content sync of [DotClientLink].


## Refuses a server whose RPC set or protocol differs: Godot would silently drop every
## message after the first, which the player sees as a spinner and "Timed out".
func _revision_compatible(challenge: Dictionary) -> bool:
	var ours := DotSignon.revision([DotClientLink])
	var theirs := str(challenge.get("signon", ""))

	# Kept before the refusal so a shell can tell the page which build the server wants.
	server_signon = theirs

	if not DotSignon.compatible(ours, theirs):
		var mismatch := DotSignon.explain(ours, theirs)
		DotLog.error(CHANNEL, "signon revision mismatch", {
			"server": theirs, "client": ours, "host": server_hostname
		})
		_fail(mismatch)
		disconnect_from_server(mismatch.message)
		return false

	# A kind that kept its name and changed its meaning; see [constant DotSignon.PROTOCOL].
	var protocol := int(DotEnvelope.number(challenge, "protocol", DotSignon.PROTOCOL))
	if protocol != DotSignon.PROTOCOL:
		var differs := DotSignon.explain_protocol(DotSignon.PROTOCOL, protocol)
		DotLog.error(CHANNEL, "signon protocol mismatch", {
			"server": protocol, "client": DotSignon.PROTOCOL, "host": server_hostname
		})
		_fail(differs)
		disconnect_from_server(differs.message)
		return false
	return true


## The server asking us to identify ourselves.
func _on_challenge(_peer_id: int, challenge: Dictionary) -> void:
	server_hostname = str(challenge.get("hostname", ""))
	server_id = str(challenge.get("server_id", ""))
	server_join_audience = str(challenge.get("join_audience", ""))
	_ticket_nonce = str(challenge.get("ticket_nonce", ""))
	var addons: Variant = challenge.get("addons", [])
	server_addons = (addons as Array).duplicate(true) if addons is Array else []

	# Where those addons are published, for a client with no content origin of its own
	# yet (see `DotServer._handshake_challenge`). The same adoption `content.sync` does.
	if challenge.has("content_base_urls"):
		var cloud := DotRegistry.get_service(cloud_service)
		if cloud != null:
			_adopt_content_bases(cloud, challenge.get("content_base_urls"))

	if not _revision_compatible(challenge):
		return

	# What the server knows, so nothing it has never heard of is sent to it. Not refused
	# here: the server compares both adverts at the credentials and refuses in words.
	var adopted := envelope.adopt(1, challenge.get("kinds"), false)
	if not adopted.ok:
		DotLog.debug(CHANNEL, "the server's kinds do not cover this client's", {
			"why": adopted.error.message, "detail": adopted.error.detail,
		})

	# Challenged: whatever fails after this is reported against its own stage.
	if _signon_watchdog != null:
		_signon_watchdog.stop()

	server_info.emit(challenge)

	DotLog.info(
		CHANNEL,
		"server challenge",
		{
			"hostname": server_hostname,
			"auth": str(challenge.get("auth", "none")),
			"password": bool(challenge.get("needs_password", false)),
		}
	)

	var payload := {
		"name": player_name,
		# Stable per install, so a guest can be muted or kicked for a session
		# without anything that survives a reinstall.
		"device_id": Credentials.device_id(),
		# What this client can say and hear. The server decides from it whether the two
		# can play; see [DotEnvelope].
		"kinds": envelope.advert(),
		# What kind of client this is, so a server whose owner has turned a platform
		# off can say so in a sentence. A payload field, not an RPC: the signon
		# revision does not move, and a server from before this ignores it.
		"platform": platform_kind(),
	}

	if bool(challenge.get("needs_password", false)):
		payload["password"] = _password

	var strategy := str(challenge.get("auth", "none")).to_lower()
	if not _may_send_credential_here(strategy):
		return
	if not await _creds.attach_credential(payload, strategy):
		return

	send_kind(DotEnvelope.CREDENTIALS, payload)


## Whether this link's transport may carry the credential [param strategy] needs.
##
## [b]ENet is not encrypted.[/b] A ticket is safe to send in the clear — single-use,
## minutes long, and good for this server alone — but an access token (introspect)
## or a password (local) is a bearer secret that anybody on the path could replay
## anywhere. Neither goes over UDP: the link rejoins over WebSocket, which is TLS
## wherever it is wss://, and sends nothing at all on the UDP connection. DTLS would
## fix it at the cost of a certificate, which is the thing the native path exists to
## not need. (A server's join password is shared, not an account's, and is sent as
## before.)
func _may_send_credential_here(strategy: String) -> bool:
	if transport_used != "enet" or not strategy in ["introspect", "local"]:
		return true

	if transport_preference == "udp":
		_fail(DotError.make(
			DotError.CODE_UNSUPPORTED,
			"This server's sign-in cannot be sent over UDP.",
			"strategy %s sends a secret and UDP is unencrypted; connect over WebSocket" % strategy
		))
		disconnect_from_server()
		return false

	DotLog.info(
		CHANNEL,
		"this server's sign-in sends a secret and UDP is unencrypted; rejoining over WebSocket",
		{"strategy": strategy}
	)
	_rejoin_over_websocket.call_deferred()
	return false


## `web`, `mobile` or `desktop`: the class of client, which is a policy fact an owner
## chooses by, not a capability -- so it is the one place the family asks about the
## platform itself rather than about what it can do.
static func platform_kind() -> String:
	if OS.has_feature("web"):
		return "web"
	if OS.has_feature("mobile"):
		return "mobile"
	return "desktop"


func _rejoin_over_websocket() -> void:
	_secure_rejoin = true
	disconnect_from_server()
	await connect_to_server(_last_address, _password)
	_secure_rejoin = false


## Connects once, keeping the Callable: a fresh lambda never matched `is_connected`, so every
## game change added another subscriber and the server got one progress RPC per copy.
func _watch_cloud_progress(cloud: Object) -> void:
	if not cloud.has_signal("progress_changed"):
		return
	if _progress_handler.is_null():
		_progress_handler = _on_cloud_progress
	if not cloud.is_connected("progress_changed", _progress_handler):
		cloud.connect("progress_changed", _progress_handler)


## Fetches the packs the game needs beside its own (maps, shared assets), by id and version,
## before `content.ready`. False when one failed; the link has already failed.
func _ensure_extra_content(cloud: Object, info: Dictionary) -> bool:
	content_extra = PackedStringArray()
	for extra in info.get("content_extra", []):
		content_extra.append(str(extra))

	for extra in info.get("content_extra", []):
		var key := str(extra)
		var at := key.rfind("@")
		var dep_id := key.substr(0, at) if at > 0 else key
		var dep_version := key.substr(at + 1) if at > 0 else ""

		if dep_id == "" or dep_version == "":
			_fail(DotError.make(
				DotError.CODE_INVALID,
				"This server named a dependency without a version: %s" % key
			))
			return false

		var got: Variant = await cloud.call("ensure", dep_id, dep_version)

		if not (got is DotResult) or not (got as DotResult).ok:
			var why := (got as DotResult).error if got is DotResult else DotError.make(
				DotError.CODE_INTERNAL, "Content download failed."
			)
			_fail(DotError.make(
				why.code,
				"This game needs %s, which could not be downloaded." % key,
				str(why)
			))
			return false
	return true


## The server telling us to fetch content before we can play.
func _on_content_sync(_peer_id: int, info: Dictionary) -> void:
	var manifest_url := str(info.get("manifest_url", ""))
	var content_key := str(info.get("content_key", ""))

	_set_phase(Phase.DOWNLOADING, "Downloading game content…")

	var cloud := DotRegistry.get_service(cloud_service)

	if cloud == null:
		# Pretending to be ready would put the player in a world of missing assets.
		DotLog.error(
			CHANNEL,
			"this server requires downloadable content but dot-cloud is not installed"
		)
		_fail(DotError.make(
			DotError.CODE_UNSUPPORTED,
			"This server needs downloadable content, which this build cannot fetch."
		))
		return

	_watch_cloud_progress(cloud)

	_adopt_content_bases(cloud, info.get("content_base_urls", []))

	DotLog.info(
		CHANNEL, "syncing content", {"content": content_key, "url": manifest_url}
	)

	var groups := PackedStringArray()
	for group in info.get("content_groups", []):
		groups.append(str(group))

	# By id and version, the URL only an override: `ensure` refuses a manifest answering to
	# another id or version, so a server cannot make the client mount a pack it never asked for.
	var parts := content_key.split("@", true, 1)
	var want_id := parts[0] if parts.size() > 0 else ""
	var want_version := parts[1] if parts.size() > 1 else ""

	if want_id == "":
		# A URL with no content key is old or broken; mounting blind is what `ensure` prevents.
		_fail(DotError.make(
			DotError.CODE_INVALID,
			"This server asked for content without saying what it is."
		))
		return

	var res: Variant = await cloud.call(
		"ensure", want_id, want_version, groups, manifest_url
	)

	if not (res is DotResult) or not (res as DotResult).ok:
		var err := (res as DotResult).error if res is DotResult else DotError.make(
			DotError.CODE_INTERNAL, "Content download failed."
		)
		_fail(err)
		return

	if not await _ensure_extra_content(cloud, info):
		return

	send_kind(DotEnvelope.CONTENT_READY, {"content_key": content_key})


## Adds the server's content addresses after the client's own (a LAN mirror still wins). Only
## somewhere to ask: the manifest must still carry a signature from a key the client holds.
## Duck-typed, since dot-server does not depend on dot-cloud.
func _adopt_content_bases(cloud: Object, urls: Variant) -> void:
	# [b]`PackedStringArray is Array` is FALSE, and this silently dropped everything
	# the server sent.[/b] The packed arrays are their own Variant types rather than
	# specialisations of [Array], so a `urls is Array` guard rejects exactly the value
	# the config holds and the RPC carries -- no error, no warning, just a client that
	# never learns the address. Found by the check below failing with "it had []" on a
	# payload that was demonstrably being sent.
	var list: Array = []
	if urls is PackedStringArray:
		list = Array(urls as PackedStringArray)
	elif urls is Array:
		list = urls as Array

	if list.is_empty():
		return
	if not (cloud.get("http_base_urls") is PackedStringArray):
		return

	var bases: PackedStringArray = cloud.get("http_base_urls")
	var added := PackedStringArray()

	for u in list:
		var one := str(u).strip_edges()
		# Re-sent on every game change, so without this the list grows by the same
		# addresses each time and every miss costs one more request than the last.
		if one != "" and not bases.has(one):
			bases.append(one)
			added.append(one)

	if added.is_empty():
		return

	cloud.set("http_base_urls", bases)
	DotLog.info(
		CHANNEL,
		"the server said where its content is",
		{"added": ", ".join(added)}
	)


func _on_cloud_progress(p: Dictionary) -> void:
	var fraction := float(p.get("fraction", 0.0))
	send_kind(DotEnvelope.CONTENT_PROGRESS, {"fraction": fraction})
	download_progress.emit(fraction, _progress_text(p))


static func _progress_text(p: Dictionary) -> String:
	var done := int(p.get("done_bytes", 0))
	var total := int(p.get("total_bytes", 0))
	if total <= 0:
		return "Downloading…"
	return "Downloading %s of %s" % [
		DotPaths.format_bytes(done), DotPaths.format_bytes(total)
	]
