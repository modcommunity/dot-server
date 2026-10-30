@tool
extends "res://addons/dot_server/server/dot_server_teardown.gd"

## Address and identity admission, ban enforcement and the query host of [DotServer].

## Plugs a query responder (dot-server-query's [code]DotQueryHost[/code], duck-typed) into this server.
## Opened once the server is running, or at once when it attaches later, as a runtime-loaded module does.
## See [member query_host].
func attach_query_host(host: Object) -> DotResult:
	if host == null:
		return DotResult.fail(DotError.CODE_INVALID, "A query host cannot be null.")

	if not host.has_method("open"):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A query host needs an open() method.",
			"got a %s" % host.get_class()
		)

	if query_host != null and query_host != host:
		# Two responders would bind the same port, and the second failure would be
		# reported as a bind error rather than as the configuration mistake it is.
		return DotResult.fail(
			DotError.CODE_STATE,
			"This server already has a query host.",
			"attached: %s" % query_host.get_class()
		)

	query_host = host

	if state == State.RUNNING:
		return host.call("open") as DotResult

	return DotResult.success(host)


## Opens the attached query host, if there is one. Called once the server is up.
func _open_query_host() -> void:
	if query_host == null or not is_instance_valid(query_host):
		return

	var opened := query_host.call("open") as DotResult

	if opened != null and not opened.ok:
		# Warned, never fatal. A server that is running and unlisted is worth far
		# more than one that refused to boot because a query port was taken.
		DotLog.warn(
			CHANNEL,
			"the query host could not open its listeners",
			{"detail": opened.error.message}
		)


## Whether a peer at [param address] may connect at all, before a session exists: the ban list, an
## optional external ban source and the per-address limit.
## The identity half is [method check_identity_admission].
func check_address_admission(address: String) -> DotResult:
	if bans != null:
		var banned := bans.check_address(address)
		if not banned.ok:
			return banned

	var source := _ban_source()
	if source != null:
		var external: Variant = source.call("check_admission", "", address)
		if external is DotResult and not (external as DotResult).ok:
			return external

	if address_guard != null:
		var allowed := address_guard.check(address, addresses_in_use())
		if not allowed.ok:
			return allowed

	return DotResult.success(null)


## Whether an authenticated session may stay.
##
## Checks the account and the address: a client connected before a ban has passed only the address half.
func check_identity_admission(session: DotClientSession) -> DotResult:
	if session == null:
		return DotResult.fail(DotError.CODE_INVALID, "No session.")

	if bans != null:
		var banned := bans.check_session(session)
		if not banned.ok:
			return banned

	var source := _ban_source()
	if source != null:
		var external: Variant = source.call(
			"check_admission", session.uid(), session.address
		)
		if external is DotResult and not (external as DotResult).ok:
			return external

	return DotResult.success(null)


## Follows the external ban source's [code]punished[/code] and [code]revoked[/code] signals so its
## account bans get the same guests-only address ban as [method DotBanManager.ban_session].
func watch_ban_source() -> void:
	var bus := DotRegistry.signals()
	if not bus.service_registered.is_connected(_on_service_registered):
		bus.service_registered.connect(_on_service_registered)
	_hook_ban_source(DotRegistry.get_service(BAN_SOURCE))


func _on_service_registered(service_name: StringName, instance: Object) -> void:
	if service_name == BAN_SOURCE:
		_hook_ban_source(instance)


func _hook_ban_source(source: Object) -> void:
	if source == null or not source.has_signal("punished") or not source.has_signal("revoked"):
		return
	if not source.is_connected("punished", _on_source_punished):
		source.connect("punished", _on_source_punished)
		source.connect("revoked", _on_source_revoked)


func _source_uid(punishment: Object) -> String:
	if punishment == null or int(punishment.get("kind")) != 0:
		return ""
	var subject := str(punishment.get("subject"))
	if subject.begins_with("ip:"):
		return ""
	return subject.trim_prefix("uid:")


func _on_source_punished(punishment: Object) -> void:
	var uid := _source_uid(punishment)
	if uid == "" or bans == null:
		return
	var expires := int(punishment.get("expires_at"))
	var duration := 0
	if expires > 0:
		duration = maxi(1, expires - int(Time.get_unix_time_from_system()))
	for session in sessions():
		if session.is_account() and session.uid().trim_prefix("uid:") == uid:
			await bans.ban_guests_at(
				session.address, uid, str(punishment.get("reason")), duration,
				str(punishment.get("issuer")), session.display_name
			)


func _on_source_revoked(punishment: Object, _by: String) -> void:
	var uid := _source_uid(punishment)
	if uid != "" and bans != null:
		await bans.lift_guest_bans(uid)


## An externally registered ban list ([code]dot_ban_source[/code], from dot-moderation), or null.
## Checked, not assumed: a registration that cannot answer the method is reported once, loudly,
## instead of silently skipped.
func _ban_source() -> Object:
	var source := DotRegistry.get_service(BAN_SOURCE)

	if source == null:
		return null

	if not source.has_method("check_admission"):
		if not _warned_about_ban_source:
			_warned_about_ban_source = true
			DotLog.error(
				CHANNEL,
				"a dot_ban_source is registered but cannot answer check_admission(uid, address); "
				+ "its bans are enforced by nothing",
				{"service": str(source)}
			)
		return null

	return source


## Re-checks every connected player against the ban list and removes those now banned.
##
## Otherwise a ban against somebody connected takes effect only on their next join. Returns how many were removed.
func enforce_bans(reason: String = "") -> int:
	var removed := 0

	for session in sessions():
		if not session.is_active():
			continue

		var admitted := check_identity_admission(session)
		if admitted.ok:
			continue

		kick(session, reason if reason != "" else admitted.error.message)
		removed += 1

	return removed
