extends Node

const MAP_WIDTH: int = 51
const MAP_HEIGHT: int = 51

# ASCII integer values instead of Strings
const TILE_WALL: int = 35   # ASCII for '#'
const TILE_FLOOR: int = 46  # ASCII for '.'
const TILE_DOOR: int = 43   # ASCII for '+'

# Directions for maze generation (Up, Down, Left, Right) scaled by 2
const DIRECTIONS: Array[Vector2i] = [
	Vector2i(0, -2),
	Vector2i(0, 2),
	Vector2i(-2, 0),
	Vector2i(2, 0)
]

# Directions for checking immediate neighbors (1 tile away)
const NEIGHBORS: Array[Vector2i] = [
	Vector2i(0, -1),
	Vector2i(0, 1),
	Vector2i(-1, 0),
	Vector2i(1, 0)
]

# PackedByteArray is highly optimized for memory and speed
var map_data: PackedByteArray = PackedByteArray()

# Array to store the dimensions and coordinates of all successfully placed rooms
var rooms: Array[Rect2i] = []

@export var map_display: RichTextLabel

func _ready() -> void:
	initialize_map()
	generate_rooms(151, 15) # 150 attempts, stop at 12 rooms
	generate_mazes()
	connect_regions()
	remove_dead_ends()
	update_debug_ui()

# Phase 1: Fill the map instantly without loops
func initialize_map() -> void:
	# 1. Calculate the total number of cells (51 * 51 = 2601)
	var total_cells: int = MAP_WIDTH * MAP_HEIGHT
	
	# 2. Allocate the exact amount of memory needed all at once
	map_data.resize(total_cells)
	
	# 3. Fill the entire array at engine-level speed
	map_data.fill(TILE_WALL)

# Helper function: Converts 2D coordinates into a 1D array index
func coords_to_index(x: int, y: int) -> int:
	return y * MAP_WIDTH + x

# Helper function: Safely set a tile
func set_tile(x: int, y: int, tile_type: int) -> void:
	map_data[coords_to_index(x, y)] = tile_type

# Helper function: Safely get a tile
func get_tile(x: int, y: int) -> int:
	return map_data[coords_to_index(x, y)]
	
# Phase 2: Attempt to place random non-overlapping rooms
func generate_rooms(placement_attempts: int, max_rooms: int) -> void:
	rooms.clear()
	var possible_sizes: Array[int] = [5, 7, 9]
	
	for i in range(placement_attempts):
		# If we hit our room limit, stop the loop immediately
		if rooms.size() >= max_rooms:
			break
		# Pick random sizes from our approved list
		var room_width: int = possible_sizes.pick_random()
		var room_height: int = possible_sizes.pick_random()
		
		# Calculate the maximum possible grid index we can start a room on
		# We subtract 1 to ensure we don't carve into the outermost boundary walls
		var max_x: int = int((MAP_WIDTH - room_width - 1) / 2.0)
		var max_y: int = int((MAP_HEIGHT - room_height - 1) / 2.0)
		
		# Multiply by 2 and add 1 to guarantee the coordinate is always an odd number
		var room_x: int = randi_range(0, max_x) * 2 + 1
		var room_y: int = randi_range(0, max_y) * 2 + 1
		
		# Create a mathematical rectangle to represent our proposed room
		var new_room := Rect2i(room_x, room_y, room_width, room_height)
		
		# Check if it overlaps with any previously placed rooms
		if can_place_room(new_room):
			carve_room(new_room)
			rooms.append(new_room)
			
# Helper function: Checks if a new room intersects with any existing ones
func can_place_room(new_room: Rect2i) -> bool:
	for existing_room in rooms:
		# .intersects() is a built-in Godot function for Rect2i
		if new_room.intersects(existing_room):
			return false
	return true

# Helper function: Writes the room into our 1D byte array
func carve_room(room: Rect2i) -> void:
	# Loop through the Y and X coordinates defined by the room's rectangle
	for y in range(room.position.y, room.position.y + room.size.y):
		for x in range(room.position.x, room.position.x + room.size.x):
			set_tile(x, y, TILE_FLOOR)

# Phase 3: Fill empty space with a Growing Tree maze
func generate_mazes() -> void:
	# Loop through every odd coordinate on the entire map
	for y in range(1, MAP_HEIGHT, 2):
		for x in range(1, MAP_WIDTH, 2):
			# If we find a completely uncarved spot, plant a new maze seed there
			if get_tile(x, y) == TILE_WALL:
				grow_maze(Vector2i(x, y))

# Helper function: The core Growing Tree algorithm
func grow_maze(start_pos: Vector2i) -> void:
	var cells: Array[Vector2i] = [] 
	
	# Carve the starting cell and add it to our active list
	set_tile(start_pos.x, start_pos.y, TILE_FLOOR)
	cells.append(start_pos)
	
	while cells.size() > 0:
		# Always pick the NEWEST cell for twisty corridors.
		# (If you wanted Prim's algorithm, you would change this to randi() % cells.size())
		var index: int = cells.size() - 1 
		var cell: Vector2i = cells[index]
		
		var unmade_cells: Array[Vector2i] = []
		
		# Check all 4 directions to see where we can legally dig
		for dir in DIRECTIONS:
			var next_pos: Vector2i = cell + dir
			if can_carve(next_pos):
				unmade_cells.append(dir)
				
		if unmade_cells.size() > 0:
			# If we have valid directions, pick a random one
			var dir: Vector2i = unmade_cells.pick_random()
			var next_pos: Vector2i = cell + dir
			
			# Calculate the wall between our current cell and the next cell
			# (Using 2.0 to avoid the integer division warning)
			var middle_pos: Vector2i = cell + Vector2i(int(dir.x / 2.0), int(dir.y / 2.0))
			
			# Carve through the wall and the destination cell
			set_tile(middle_pos.x, middle_pos.y, TILE_FLOOR)
			set_tile(next_pos.x, next_pos.y, TILE_FLOOR)
			
			# Add the new cell to our active list
			cells.append(next_pos)
		else:
			# If we hit a dead end, remove the current cell so we can backtrack
			cells.remove_at(index)

# Helper function: Ensures we only dig into solid rock and stay within map bounds
func can_carve(pos: Vector2i) -> bool:
	# Prevent digging out of the map boundaries
	if pos.x <= 0 or pos.x >= MAP_WIDTH - 1 or pos.y <= 0 or pos.y >= MAP_HEIGHT - 1:
		return false
		
	# We can only carve into a tile if it is currently a wall
	return get_tile(pos.x, pos.y) == TILE_WALL

# Phase 4: Connect rooms to the maze network with doors (1 per wall limit)
func connect_regions() -> void:
	for room in rooms:
		# Group potential doors by the wall they sit on
		var top_doors: Array[Vector2i] = []
		var bottom_doors: Array[Vector2i] = []
		var left_doors: Array[Vector2i] = []
		var right_doors: Array[Vector2i] = []
		
		# Scan top and bottom perimeters
		for x in range(room.position.x, room.position.x + room.size.x):
			var top_y: int = room.position.y - 1
			var bottom_y: int = room.position.y + room.size.y
			
			if top_y - 1 > 0 and get_tile(x, top_y - 1) == TILE_FLOOR:
				top_doors.append(Vector2i(x, top_y))
				
			if bottom_y + 1 < MAP_HEIGHT - 1 and get_tile(x, bottom_y + 1) == TILE_FLOOR:
				bottom_doors.append(Vector2i(x, bottom_y))

		# Scan left and right perimeters
		for y in range(room.position.y, room.position.y + room.size.y):
			var left_x: int = room.position.x - 1
			var right_x: int = room.position.x + room.size.x
			
			if left_x - 1 > 0 and get_tile(left_x - 1, y) == TILE_FLOOR:
				left_doors.append(Vector2i(left_x, y))
				
			if right_x + 1 < MAP_WIDTH - 1 and get_tile(right_x + 1, y) == TILE_FLOOR:
				right_doors.append(Vector2i(right_x, y))
				
		# Compile a list of walls that actually have at least one valid connection point
		var valid_walls: Array = []
		if top_doors.size() > 0: valid_walls.append(top_doors)
		if bottom_doors.size() > 0: valid_walls.append(bottom_doors)
		if left_doors.size() > 0: valid_walls.append(left_doors)
		if right_doors.size() > 0: valid_walls.append(right_doors)
		
		if valid_walls.size() > 0:
			valid_walls.shuffle()
			# Determine how many walls will get a door (1 to 3)
			var doors_to_place: int = randi_range(1, 3) 
			# Ensure we don't try to place more doors than there are valid walls
			doors_to_place = min(doors_to_place, valid_walls.size())
			
			for i in range(doors_to_place):
				# Pick exactly one random coordinate from the chosen wall's array
				var chosen_door: Vector2i = valid_walls[i].pick_random()
				set_tile(chosen_door.x, chosen_door.y, TILE_DOOR)

# Phase 5: Trim dead ends from the maze
func remove_dead_ends() -> void:
	var done: bool = false
	
	# Keep sweeping the map until we do a full pass without making any changes
	while not done:
		done = true # Assume we are finished until proven otherwise
		
		# Iterate through the map, avoiding the outermost unbreakable boundary walls
		for y in range(1, MAP_HEIGHT - 1):
			for x in range(1, MAP_WIDTH - 1):
				
				# We only care about evaluating floor tiles
				if get_tile(x, y) == TILE_FLOOR:
					var adjacent_walls: int = 0
					
					# Check all 4 immediate neighbors
					for dir in NEIGHBORS:
						if get_tile(x + dir.x, y + dir.y) == TILE_WALL:
							adjacent_walls += 1
					
					# If surrounded by 3 walls, it's a dead end. Fill it in.
					if adjacent_walls >= 3:
						set_tile(x, y, TILE_WALL)
						done = false # We changed the map, so we must sweep again

# RENDER - Push the 1D array to the RichTextLabel
func update_debug_ui() -> void:
	# Safety check: if we forgot to assign the label, abort to prevent a crash
	if not map_display:
		push_warning("MapDisplay node not assigned in LevelGenerator!")
		return
		
	var full_map_string: String = ""
	
	for y in range(MAP_HEIGHT):
		var row_start: int = y * MAP_WIDTH
		var row_end: int = row_start + MAP_WIDTH
		var row_bytes: PackedByteArray = map_data.slice(row_start, row_end)
		
		# Decode the row bytes to a string and add a newline character
		full_map_string += row_bytes.get_string_from_ascii() + "\n"
		
	map_display.text = full_map_string

# Debug input listener
func _input(event: InputEvent) -> void:
	# Check if the event is a key press, not held down (echo), and specifically the R key
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			# Rerun the current generation sequence
			initialize_map()
			generate_rooms(151, 15)
			generate_mazes()
			connect_regions()
			remove_dead_ends()
			update_debug_ui()
		elif event.keycode == KEY_ESCAPE:
			# Instantly closes the Godot application
			get_tree().quit()
