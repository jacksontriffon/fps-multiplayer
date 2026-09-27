extends Node

# Exports
@export var all_audio: Array[AudioDetailsResource]

# Signals
signal play_sound(sound_title: String, volume_db: float, loop: bool)
signal stop_sound(sound_title: String)
func NEVER_EMIT() -> void:
	emit_signal("play_sound")
	emit_signal("stop_sound")
# State
var audio_recently_played := {
	# AudioResource: Array[AudioStream],
	# ...
}
# References


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	play_sound.connect(handle_play_sound)
	stop_sound.connect(handle_stop_sound)

func get_existing_player(audio_title: String) -> AudioStreamPlayer:
	for child in get_children():
		if child.name == audio_title:
			return child
	return null

func get_audio_from_title(audio_title: String) -> AudioDetailsResource:
	for audio in all_audio:
		if audio.audio_title == audio_title:
			return audio
	return null

func get_rand_audio_stream(audio_resource: AudioDetailsResource) -> AudioStream:
	var all_streams: Array[AudioStream] = audio_resource.audio_list
	# Prevent repeating the same audio
	# TODO - Filter any audio streams recently played
#	if audio_resource in audio_recently_played:
#		var streams_recently_played: Array[AudioStream] = audio_recently_played[audio_resource]
#		for stream in streams_recently_played:
#			all_streams.filter(func(stream_to_filter: AudioStream): stream_to_filter == stream)


	# Get stream to play
	var rand_stream = all_streams.pick_random()
	# Update audio recently played
	if audio_resource in audio_recently_played:
		# Remove streams that were played awhile ago
		var streams_to_skip = 2
		var streams_recently_played: Array[AudioStream] = audio_recently_played[audio_resource]
		if streams_recently_played.size() >= streams_to_skip:
			streams_recently_played.pop_back()
		# Add recent stream
		streams_recently_played.append(rand_stream)
	else:
		# First time played
		# Add recent stream
		audio_recently_played[audio_resource] = [rand_stream] as Array[AudioStream]
	return rand_stream

func play_audio(audio_title: String, volume_db: float = 0.0) -> void:
	var audio: AudioDetailsResource = get_audio_from_title(audio_title)
	if volume_db == 0.0:
		volume_db = audio.volume_db
	var existing_player := get_existing_player(audio_title)
	if existing_player:
		existing_player.stream = get_rand_audio_stream(audio)
		existing_player.volume_db = volume_db
#		printerr('playing existing player for: ', audio_title)
		existing_player.play()
	else:
		var player = AudioStreamPlayer.new()
		player.stream = get_rand_audio_stream(audio)
		player.name = audio_title
		player.volume_db = volume_db
		add_child(player)
		player.play()

func stop_audio(audio_title: String) -> void:
	var existing_player := get_existing_player(audio_title)
	if existing_player is AudioStreamPlayer:
		remove_child(existing_player)


# --- HANDLE SIGNALS ---
func handle_play_sound(audio_title: String, volume_db: float = 0.0) -> void:
	play_audio(audio_title, volume_db)

func handle_stop_sound(audio_title: String) -> void:
	stop_audio(audio_title)


