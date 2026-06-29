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

# True when this friend entry carries a lobby we can drop into.
func can_join(entry: Dictionary) -> bool:
	return int(entry.get("lobby_id", 0)) != 0

func _steam_ready() -> bool:
	return Engine.has_singleton("Steam") and Steam.isSteamRunning()
