extends Node

# Exports

# Signals

# State
var game_data: Dictionary
# References

# Define the path to the folder and resource file where the Game data will be stored
var data_folder_path := 'user://SaveData/Game'
var data_resource_path := 'user://SaveData/Game/GameData.tres'


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	game_data = get_data().data
	
	# --- CONNECT TO SIGNALS ---
	pass 



# --- CRUD DATA ---
# Function to load the Game data from the resource file or create new data if it doesn't exist
func get_data() -> GameData:
	var loaded_data: GameData = null
	if ResourceLoader.exists(data_resource_path):
		loaded_data = load(data_resource_path)
	
	if OS.has_feature("standalone") or loaded_data:
		return loaded_data
	else:
		# Create new Game Data
		return new_data()

# Function to create new Game data
func new_data() -> GameData:
	var new_data = GameData.new()
	
	# If the data folder already exists, save the new data to the resource file
	if DirAccess.dir_exists_absolute(data_folder_path):
		ResourceSaver.save(new_data, data_resource_path)
		return new_data
	else:
		# If the data folder doesn't exist, create it and save the new data to the resource file
		DirAccess.make_dir_absolute(data_folder_path)
		ResourceSaver.save(new_data, data_resource_path)
		return new_data

# Function to save the Game data to the resource file
func save_data() -> void:
	var loaded_data: GameData = get_data()
	if game_data: loaded_data.data = game_data
	ResourceSaver.save(loaded_data, data_resource_path)



# --- HANDLE SIGNALS ---
