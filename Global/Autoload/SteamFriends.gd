extends Node

# Read-only view of which Steam friends are currently in this game and joinable.
# All Steam friend-presence querying lives here so the lobby UI and game root stay
# free of raw Steam calls. Safe to call even when Steam isn't initialised (returns []).

# Emitted when a friend's avatar finishes downloading, so a row that asked for it can swap in the
# texture (the request is async; get_avatar returns null until then).
signal avatar_updated(steam_id: int, texture: Texture2D)

# Avatar cache + in-flight request set, keyed by steam id. Steam delivers avatars once via
# avatar_loaded; we hold the texture so later rows reuse it without re-requesting.
var _avatars: Dictionary = {}
var _avatar_requested: Dictionary = {}

func _ready() -> void:
	if Engine.has_singleton("Steam"):
		Steam.avatar_loaded.connect(_on_avatar_loaded)

# Cached avatar texture, or null while it loads. First call kicks off the async Steam fetch; the
# avatar_updated signal fires when it's ready.
func get_avatar(steam_id: int) -> Texture2D:
	if _avatars.has(steam_id):
		return _avatars[steam_id]
	if not _steam_ready() or _avatar_requested.has(steam_id):
		return null
	_avatar_requested[steam_id] = true
	Steam.getPlayerAvatar(Steam.AVATAR_MEDIUM, steam_id)
	return null

# avatar_loaded(avatar_id, size, data): Steam avatars are square, so size is both width and height.
func _on_avatar_loaded(avatar_id: int, size: int, data: PackedByteArray) -> void:
	if size <= 0 or data.is_empty():
		return
	var image := Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, data)
	var tex := ImageTexture.create_from_image(image)
	_avatars[avatar_id] = tex
	avatar_updated.emit(avatar_id, tex)

# Friends who have played this game: everyone currently in-game, plus everyone Steam's coplay
# history says we've recently played THIS game with (online or offline). Steam's client API can't
# enumerate game owners, so coplay is the closest signal for "has played this game". Sorted
# in-game, then online, then offline.
func list_played_with() -> Array:
	if not _steam_ready():
		return []
	var our_app: int = Steam.getAppID()
	# Friends Steam's coplay history pairs with this game.
	var coplay: Dictionary = {}
	for i in Steam.getCoplayFriendCount():
		var cid: int = Steam.getCoplayFriend(i)
		if Steam.getFriendCoplayGame(cid) == our_app:
			coplay[cid] = true
	var out: Array = []
	for i in Steam.getFriendCount(Steam.FRIEND_FLAG_IMMEDIATE):
		var fid: int = Steam.getFriendByIndex(i, Steam.FRIEND_FLAG_IMMEDIATE)
		var entry: Dictionary = _entry_for(fid)
		if entry["in_game"] or coplay.has(fid):
			out.append(entry)
	out.sort_custom(_by_status)
	return out

# Every immediate Steam friend, played-this-game or not. Used by the menu's "See all" toggle so
# you can invite friends who haven't played yet. Same entry shape and sort as list_played_with.
func list_all_friends() -> Array:
	if not _steam_ready():
		return []
	var out: Array = []
	for i in Steam.getFriendCount(Steam.FRIEND_FLAG_IMMEDIATE):
		var fid: int = Steam.getFriendByIndex(i, Steam.FRIEND_FLAG_IMMEDIATE)
		out.append(_entry_for(fid))
	out.sort_custom(_by_status)
	return out

# Full status entry for one friend. in_game/lobby_id come from getFriendGamePlayed; map + in_lobby
# from the rich presence game.gd publishes (empty/false for friends not in this game or on an older
# build); online from persona state (in-game implies online).
func _entry_for(fid: int) -> Dictionary:
	var played: Dictionary = Steam.getFriendGamePlayed(fid)
	var in_game: bool = not played.is_empty() and int(played.get("id", 0)) == Steam.getAppID()
	var persona: int = Steam.getFriendPersonaState(fid)
	var in_lobby: bool = in_game and Steam.getFriendRichPresence(fid, "in_lobby") == "1"
	var party: bool = in_game and Steam.getFriendRichPresence(fid, "party") == "1"
	var map: String = Steam.getFriendRichPresence(fid, "map") if in_game else ""
	return {
		"steam_id": fid,
		"name": Steam.getFriendPersonaName(fid),
		"lobby_id": int(played.get("lobby", 0)) if in_game else 0,
		"in_game": in_game,
		"online": in_game or persona != Steam.PERSONA_STATE_OFFLINE,
		"map": map,
		"in_lobby": in_lobby,
		"status": _status_text(in_game, party, in_lobby, map, persona),
	}

# The small line under a friend's name. In-game state wins (party / lobby / the map they're playing
# when not partied); otherwise it reflects their Steam persona state.
func _status_text(in_game: bool, party: bool, in_lobby: bool, map: String, persona: int) -> String:
	if in_game:
		if party:
			return "In party"
		if in_lobby:
			return "In Lobby"
		return map if map != "" else "In game"
	match persona:
		Steam.PERSONA_STATE_OFFLINE:
			return "Offline"
		Steam.PERSONA_STATE_AWAY, Steam.PERSONA_STATE_SNOOZE:
			return "Away"
		Steam.PERSONA_STATE_BUSY:
			return "Busy"
		Steam.PERSONA_STATE_LOOKING_TO_PLAY:
			return "In Queue"
		_:
			return "Online"

# In-game first, then online, then offline; alphabetical within a tier.
func _by_status(a: Dictionary, b: Dictionary) -> bool:
	var ra: int = _status_rank(a)
	var rb: int = _status_rank(b)
	if ra != rb:
		return ra < rb
	return String(a["name"]).naturalnocasecmp_to(b["name"]) < 0

func _status_rank(entry: Dictionary) -> int:
	if entry["in_game"]:
		return 0
	return 1 if entry["online"] else 2

# True when we can drop into this friend: they're in a joinable lobby AND waiting in the lobby map
# (you can't join a friend who's mid-match).
func can_join(entry: Dictionary) -> bool:
	return int(entry.get("lobby_id", 0)) != 0 and bool(entry.get("in_lobby", false))

func _steam_ready() -> bool:
	return Engine.has_singleton("Steam") and Steam.isSteamRunning()
