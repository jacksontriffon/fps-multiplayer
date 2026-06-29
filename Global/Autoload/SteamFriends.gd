extends Node

# Read-only view of which Steam friends are currently in this game and joinable.
# All Steam friend-presence querying lives here so the lobby UI and game root stay
# free of raw Steam calls. Safe to call even when Steam isn't initialised (returns []).

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
	return {
		"steam_id": fid,
		"name": Steam.getFriendPersonaName(fid),
		"lobby_id": int(played.get("lobby", 0)) if in_game else 0,
		"in_game": in_game,
		"online": in_game or Steam.getFriendPersonaState(fid) != Steam.PERSONA_STATE_OFFLINE,
		"map": Steam.getFriendRichPresence(fid, "map") if in_game else "",
		"in_lobby": (Steam.getFriendRichPresence(fid, "in_lobby") == "1") if in_game else false,
	}

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
