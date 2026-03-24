extends Node

const MAP_WIDTH: int = 51
const MAP_HEIGHT: int = 51

# ASCII integer values instead of Strings
const TILE_WALL: int = 35   # ASCII for '#'
const TILE_FLOOR: int = 46  # ASCII for '.'
const TILE_DOOR: int = 43   # ASCII for '+'
const TILE_VOID: int = 32   # ASCII for space ' '

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
	remove_redundant_walls()
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
		# Pick a RANDOM cell for Prim's Algorithm (web-like, highly branching)
		var index: int = randi() % cells.size() 
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
		
		# Flags to detect if a neighboring room already placed a door here
		var top_has_door: bool = false
		var bottom_has_door: bool = false
		var left_has_door: bool = false
		var right_has_door: bool = false
		
		# Scan top and bottom perimeters
		for x in range(room.position.x, room.position.x + room.size.x):
			var top_y: int = room.position.y - 1
			var bottom_y: int = room.position.y + room.size.y
			
			if get_tile(x, top_y) == TILE_DOOR: top_has_door = true
			elif top_y - 1 > 0 and get_tile(x, top_y - 1) == TILE_FLOOR:
				top_doors.append(Vector2i(x, top_y))
				
			if get_tile(x, bottom_y) == TILE_DOOR: bottom_has_door = true
			elif bottom_y + 1 < MAP_HEIGHT - 1 and get_tile(x, bottom_y + 1) == TILE_FLOOR:
				bottom_doors.append(Vector2i(x, bottom_y))
				
		# Scan left and right perimeters
		for y in range(room.position.y, room.position.y + room.size.y):
			var left_x: int = room.position.x - 1
			var right_x: int = room.position.x + room.size.x
			
			if get_tile(left_x, y) == TILE_DOOR: left_has_door = true
			elif left_x - 1 > 0 and get_tile(left_x - 1, y) == TILE_FLOOR:
				left_doors.append(Vector2i(left_x, y))
				
			if get_tile(right_x, y) == TILE_DOOR: right_has_door = true
			elif right_x + 1 < MAP_WIDTH - 1 and get_tile(right_x + 1, y) == TILE_FLOOR:
				right_doors.append(Vector2i(right_x, y))
		
		# Only add walls that have valid points AND do not already contain a door
		var valid_walls: Array = []
		if not top_has_door and top_doors.size() > 0: valid_walls.append(top_doors)
		if not bottom_has_door and bottom_doors.size() > 0: valid_walls.append(bottom_doors)
		if not left_has_door and left_doors.size() > 0: valid_walls.append(left_doors)
		if not right_has_door and right_doors.size() > 0: valid_walls.append(right_doors)
		
		if valid_walls.size() > 0:
			valid_walls.shuffle()
			var doors_to_place: int = randi_range(1, 3) 
			doors_to_place = min(doors_to_place, valid_walls.size())
			
			for i in range(doors_to_place):
				valid_walls[i].shuffle()
				for chosen_door in valid_walls[i]:
					if not has_adjacent_door(chosen_door):
						set_tile(chosen_door.x, chosen_door.y, TILE_DOOR)
						break

# Helper function to prevent adjacent doors
func has_adjacent_door(pos: Vector2i) -> bool:
	for dir in NEIGHBORS:
		if get_tile(pos.x + dir.x, pos.y + dir.y) == TILE_DOOR:
			return true
	return false

# Phase 5: Trim dead ends from the maze
func remove_dead_ends() -> void:
	var done: bool = false

	# Keep sweeping the map until we do a full pass without making any changes
	while not done:
		done = true # Assume we are finished until proven otherwise
		
		# We evaluate both floors and doors
		for y in range(1, MAP_HEIGHT - 1):
			for x in range(1, MAP_WIDTH - 1):
					var current_tile: int = get_tile(x, y)
					
					if current_tile == TILE_FLOOR or current_tile == TILE_DOOR:
						var adjacent_walls: int = 0

						for dir in NEIGHBORS:
							if get_tile(x + dir.x, y + dir.y) == TILE_WALL:
								adjacent_walls += 1
					
					# If surrounded by 3 walls, it's a dead end. Fill it in.
						if adjacent_walls >= 3:
							set_tile(x, y, TILE_WALL)
							done = false # We changed the map, so we must sweep again
# Phase 6: Remove solid walls that do not border any playable area
func remove_redundant_walls() -> void:
	for y in range(MAP_HEIGHT):
		for x in range(MAP_WIDTH):
			if get_tile(x, y) == TILE_WALL:
				if not has_adjacent_walkable(x, y):
					set_tile(x, y, TILE_VOID)

# Helper function to check 8-way adjacency for floors or doors
func has_adjacent_walkable(x: int, y: int) -> bool:
	# Loop from -1 to 1 for both X and Y to check a 3x3 grid around the target tile
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			# Skip the center tile (the wall itself)
			if dx == 0 and dy == 0:
				continue
				
			var check_x: int = x + dx
			var check_y: int = y + dy
			
			# Ensure we don't check outside the array bounds
			if check_x >= 0 and check_x < MAP_WIDTH and check_y >= 0 and check_y < MAP_HEIGHT:
				var tile: int = get_tile(check_x, check_y)
				if tile == TILE_FLOOR or tile == TILE_DOOR:
					return true
					
	return false

# Pushes the data to the UI, formatting walls dynamically
func update_debug_ui() -> void:
	if not map_display:
		push_warning("MapDisplay node not assigned in LevelGenerator!")
		return
		
	var full_map_string: String = ""
	
	for y in range(MAP_HEIGHT):
		var row_string: String = ""
		
		for x in range(MAP_WIDTH):
			var tile: int = get_tile(x, y)
			
			if tile == TILE_WALL:
				# Check the 4 immediate neighbors for architectural connections
				var up: bool = is_wall_connection(x, y - 1)
				var down: bool = is_wall_connection(x, y + 1)
				var left: bool = is_wall_connection(x - 1, y)
				var right: bool = is_wall_connection(x + 1, y)
				
				var is_vertical: bool = up or down
				var is_horizontal: bool = left or right
				
				# Assign the correct ASCII character based on connections
				if is_vertical and is_horizontal:
					row_string += "+" # Corner or T-junction
				elif is_vertical:
					row_string += "|" # Vertical wall
				elif is_horizontal:
					row_string += "-" # Horizontal wall
				else:
					row_string += "#" # Fallback for isolated pillars
					
			elif tile == TILE_FLOOR:
				row_string += "."
			elif tile == TILE_DOOR:
				row_string += "X"
			elif tile == TILE_VOID:
				row_string += " "
				
		full_map_string += row_string + "\n"
		
	map_display.text = full_map_string

# Helper function to check if a tile visually connects as a wall
func is_wall_connection(x: int, y: int) -> bool:
	# Ignore out-of-bounds checks
	if x < 0 or x >= MAP_WIDTH or y < 0 or y >= MAP_HEIGHT:
		return false
		
	var t: int = get_tile(x, y)
	# Both Walls and Doors count as architectural connections
	return t == TILE_WALL or t == TILE_DOOR

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
			remove_redundant_walls()
			update_debug_ui()
		elif event.keycode == KEY_ESCAPE:
			# Instantly closes the Godot application
			get_tree().quit()
