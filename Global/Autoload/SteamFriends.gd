extends Node

# Read-only view of which Steam friends are currently in this game and joinable.
# All Steam friend-presence querying lives here so the lobby UI and game root stay
# free of raw Steam calls. Safe to call even when Steam isn't initialised (returns []).

# A friend is "joinable" when Steam reports them inside a lobby for this same app. The
# lobby id is what we hand to joinLobby() to drop in beside them.
func list_friends_in_game() -> Array:
	if not _steam_ready():
		return []
	var our_app: int = Steam.getAppID()
	var out: Array = []
	var count: int = Steam.getFriendCount(Steam.FRIEND_FLAG_IMMEDIATE)
	for i in count:
		var friend_id: int = Steam.getFriendByIndex(i, Steam.FRIEND_FLAG_IMMEDIATE)
		var played: Dictionary = Steam.getFriendGamePlayed(friend_id)
		# getFriendGamePlayed returns {} when the friend isn't in a game.
		if played.is_empty() or int(played.get("id", 0)) != our_app:
			continue
		out.append({
			"steam_id": friend_id,
			"name": Steam.getFriendPersonaName(friend_id),
			"lobby_id": int(played.get("lobby", 0)),
		})
	return out

# Friends who have played this game: everyone currently in-game, plus everyone Steam's coplay
# history says we've recently played THIS game with (online or offline). Steam's client API can't
# enumerate game owners, so coplay is the closest signal for "has played this game". Each entry
# carries in_game/online flags and a lobby_id (non-zero only when joinable). Sorted in-game, then
# online, then offline.
func list_played_with() -> Array:
	if not _steam_ready():
		return []
	var our_app: int = Steam.getAppID()
	# Keyed by steam id so a friend who is both in-game and in coplay history appears once.
	var by_id: Dictionary = {}
	for entry in list_friends_in_game():
		var fid: int = entry["steam_id"]
		by_id[fid] = {
			"steam_id": fid,
			"name": entry["name"],
			"lobby_id": entry["lobby_id"],
			"in_game": true,
			"online": true,
			# Map + lobby status come from the friend's rich presence (set by game.gd). Empty/false
			# for friends on an older build that doesn't publish it.
			"map": Steam.getFriendRichPresence(fid, "map"),
			"in_lobby": Steam.getFriendRichPresence(fid, "in_lobby") == "1",
		}
	var count: int = Steam.getCoplayFriendCount()
	for i in count:
		var fid: int = Steam.getCoplayFriend(i)
		if Steam.getFriendCoplayGame(fid) != our_app or by_id.has(fid):
			continue
		by_id[fid] = {
			"steam_id": fid,
			"name": Steam.getFriendPersonaName(fid),
			"lobby_id": 0,
			"in_game": false,
			"online": Steam.getFriendPersonaState(fid) != Steam.PERSONA_STATE_OFFLINE,
			"map": "",
			"in_lobby": false,
		}
	var out: Array = by_id.values()
	out.sort_custom(_by_status)
	return out

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
