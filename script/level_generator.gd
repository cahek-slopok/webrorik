extends Node

const MAP_WIDTH: int = 51
const MAP_HEIGHT: int = 51

const TILE_WALL: int = 35   # ASCII for '#'
const TILE_FLOOR: int = 46  # ASCII for '.'
const TILE_DOOR: int = 88   # ASCII for 'X'
const TILE_VOID: int = 32   # ASCII for space ' '

const DIRECTIONS: Array[Vector2i] = [
	Vector2i(0, -2), Vector2i(0, 2),
	Vector2i(-2, 0), Vector2i(2, 0)
]

const NEIGHBORS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(0, 1),
	Vector2i(-1, 0), Vector2i(1, 0)
]

var map_data: PackedByteArray = PackedByteArray()
var region_data: PackedInt32Array = PackedInt32Array() # NEW: Tracks regions
var rooms: Array[Rect2i] = []
var current_region: int = 0 # NEW: Unique ID for each room and maze

@export var map_display: RichTextLabel

func _ready() -> void:
	run_generation()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			run_generation()
		elif event.keycode == KEY_ESCAPE:
			get_tree().quit()

func run_generation() -> void:
	var max_attempts: int = 10
	var attempts: int = 0
	var is_valid: bool = false
	
	while attempts < max_attempts and not is_valid:
		attempts += 1
		initialize_map()
		generate_rooms(151, 15)
		generate_mazes()
		connect_regions() # Now uses Minimum Spanning Tree
		remove_dead_ends()
		remove_redundant_walls()
		is_valid = validate_dungeon()
		
		if not is_valid:
			print("Failed on attempt %d. Regenerating..." % attempts)
			
	if is_valid:
		print("Ready in %d attempt(s)." % attempts)
	else:
		push_error("CRITICAL: Failed to generate a valid dungeon.")
		
	update_debug_ui()

# Phase 1: Solid Canvas
func initialize_map() -> void:
	map_data.resize(MAP_WIDTH * MAP_HEIGHT)
	map_data.fill(TILE_WALL)
	
	region_data.resize(MAP_WIDTH * MAP_HEIGHT)
	region_data.fill(-1) # -1 means no region assigned yet
	current_region = 0

func coords_to_index(x: int, y: int) -> int:
	return y * MAP_WIDTH + x

# UPDATED: Now sets both the visual tile and its logical region
func set_tile(x: int, y: int, tile_type: int, region: int = -1) -> void:
	var idx: int = coords_to_index(x, y)
	map_data[idx] = tile_type
	region_data[idx] = region

func get_tile(x: int, y: int) -> int:
	return map_data[coords_to_index(x, y)]
	
# Phase 2: Room Carving
func generate_rooms(placement_attempts: int, max_rooms: int) -> void:
	rooms.clear()
	var possible_sizes: Array[int] = [5, 7, 9]
	
	for i in range(placement_attempts):
		if rooms.size() >= max_rooms: break
			
		var room_width: int = possible_sizes.pick_random()
		var room_height: int = possible_sizes.pick_random()
		
		var max_x: int = int((MAP_WIDTH - room_width - 1) / 2.0)
		var max_y: int = int((MAP_HEIGHT - room_height - 1) / 2.0)
		
		var room_x: int = randi_range(0, max_x) * 2 + 1
		var room_y: int = randi_range(0, max_y) * 2 + 1
		
		var new_room := Rect2i(room_x, room_y, room_width, room_height)
		
		if can_place_room(new_room):
			current_region += 1 # Assign a unique ID to this room
			carve_room(new_room, current_region)
			rooms.append(new_room)
			
func can_place_room(new_room: Rect2i) -> bool:
	for existing_room in rooms:
		if new_room.intersects(existing_room):
			return false
	return true

func carve_room(room: Rect2i, region: int) -> void:
	for y in range(room.position.y, room.position.y + room.size.y):
		for x in range(room.position.x, room.position.x + room.size.x):
			set_tile(x, y, TILE_FLOOR, region)

# Phase 3: Prim's Maze
func generate_mazes() -> void:
	for y in range(1, MAP_HEIGHT, 2):
		for x in range(1, MAP_WIDTH, 2):
			if get_tile(x, y) == TILE_WALL:
				current_region += 1 # Assign a unique ID to this maze branch
				grow_maze(Vector2i(x, y), current_region)

func grow_maze(start_pos: Vector2i, region: int) -> void:
	var cells: Array[Vector2i] = [] 
	
	set_tile(start_pos.x, start_pos.y, TILE_FLOOR, region)
	cells.append(start_pos)
	
	while cells.size() > 0:
		var index: int = randi() % cells.size() 
		var cell: Vector2i = cells[index]
		var unmade_cells: Array[Vector2i] = []
		
		for dir in DIRECTIONS:
			var next_pos: Vector2i = cell + dir
			if can_carve(next_pos):
				unmade_cells.append(dir)
				
		if unmade_cells.size() > 0:
			var dir: Vector2i = unmade_cells.pick_random()
			var next_pos: Vector2i = cell + dir
			var middle_pos: Vector2i = cell + Vector2i(int(dir.x / 2.0), int(dir.y / 2.0))
			
			set_tile(middle_pos.x, middle_pos.y, TILE_FLOOR, region)
			set_tile(next_pos.x, next_pos.y, TILE_FLOOR, region)
			cells.append(next_pos)
		else:
			cells.remove_at(index)

func can_carve(pos: Vector2i) -> bool:
	if pos.x <= 0 or pos.x >= MAP_WIDTH - 1 or pos.y <= 0 or pos.y >= MAP_HEIGHT - 1:
		return false
	return get_tile(pos.x, pos.y) == TILE_WALL

# Phase 4: Minimum Spanning Tree Connectivity (Strictly 1 door per pair)
func connect_regions() -> void:
	var connectors: Array[Vector2i] = []
	
	# 1. Find all walls that sit between two DIFFERENT regions
	for y in range(1, MAP_HEIGHT - 1):
		for x in range(1, MAP_WIDTH - 1):
			if get_tile(x, y) == TILE_WALL:
				var touching: Array[int] = get_touching_regions(x, y)
				if touching.size() >= 2:
					connectors.append(Vector2i(x, y))
					
	connectors.shuffle()
	
	# 2. Setup Union-Find array to track merged networks
	var merged: PackedInt32Array = PackedInt32Array()
	merged.resize(current_region + 1)
	for i in range(merged.size()):
		merged[i] = i
		
	# NEW: A lightweight dictionary to track direct connections
	var direct_connections: Dictionary = {}
		
	# 3. Merge the dungeon
	for pos in connectors:
		var touching: Array[int] = get_touching_regions(pos.x, pos.y)
		if touching.size() < 2: continue 
		
		var r1: int = touching[0]
		var r2: int = touching[1]
		
		var root1: int = find_root(r1, merged)
		var root2: int = find_root(r2, merged)
		
		# Create a unique string key for this specific pair of regions (e.g., "3_7")
		var pair_key: String = str(min(r1, r2)) + "_" + str(max(r1, r2))
		
		if root1 != root2:
			# These regions are disconnected. Connect them!
			merged[root1] = root2
			set_tile(pos.x, pos.y, TILE_DOOR) 
			# Log that these two regions now share a direct door
			direct_connections[pair_key] = true
		else:
			# These regions are in the same network.
			# ONLY allow an extra loop door if they don't ALREADY share a direct door
			if not direct_connections.has(pair_key):
				# 4% chance to place an extra door to create a fun loop/flank route
				if randf() < 0.04 and not has_adjacent_door(pos):
					set_tile(pos.x, pos.y, TILE_DOOR)
					direct_connections[pair_key] = true

func get_touching_regions(x: int, y: int) -> Array[int]:
	var touching: Array[int] = []
	for dir in NEIGHBORS:
		var r: int = region_data[coords_to_index(x + dir.x, y + dir.y)]
		if r != -1 and not touching.has(r):
			touching.append(r)
	return touching

func find_root(region: int, merged: PackedInt32Array) -> int:
	var current: int = region
	while merged[current] != current:
		merged[current] = merged[merged[current]] # Path compression
		current = merged[current]
	return current

# Helper function updated to prevent both cardinal AND diagonal doors
func has_adjacent_door(pos: Vector2i) -> bool:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0: 
				continue
			
			if get_tile(pos.x + dx, pos.y + dy) == TILE_DOOR:
				return true
	return false

# Phase 5: Reverted Sweeping Backtracker
func remove_dead_ends() -> void:
	var done: bool = false
	while not done:
		done = true 
		for y in range(1, MAP_HEIGHT - 1):
			for x in range(1, MAP_WIDTH - 1):
				var current_tile: int = get_tile(x, y)
				
				if current_tile == TILE_FLOOR or current_tile == TILE_DOOR:
					var adjacent_walls: int = 0
					for dir in NEIGHBORS:
						if get_tile(x + dir.x, y + dir.y) == TILE_WALL:
							adjacent_walls += 1
					
					if adjacent_walls >= 3:
						if current_tile == TILE_DOOR or randf() < 0.90:
							set_tile(x, y, TILE_WALL, -1) # Clearing to wall removes region
							done = false 

# Phase 6: Inlined Culling
func remove_redundant_walls() -> void:
	for y in range(MAP_HEIGHT):
		for x in range(MAP_WIDTH):
			var idx: int = y * MAP_WIDTH + x
			if map_data[idx] == TILE_WALL:
				if not has_adjacent_walkable(x, y):
					map_data[idx] = TILE_VOID

func has_adjacent_walkable(x: int, y: int) -> bool:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0: continue
			var check_x: int = x + dx
			var check_y: int = y + dy
			
			if check_x >= 0 and check_x < MAP_WIDTH and check_y >= 0 and check_y < MAP_HEIGHT:
				var tile: int = get_tile(check_x, check_y)
				if tile == TILE_FLOOR or tile == TILE_DOOR:
					return true
	return false

# Phase 7: Flood fill validation
func validate_dungeon() -> bool:
	if rooms.size() <= 1: return true 
		
	var visited: PackedByteArray = PackedByteArray()
	visited.resize(MAP_WIDTH * MAP_HEIGHT)
	visited.fill(0)
	
	var start_pos: Vector2i = rooms[0].get_center()
	var queue: Array[Vector2i] = [start_pos]
	visited[coords_to_index(start_pos.x, start_pos.y)] = 1
	
	while queue.size() > 0:
		var current: Vector2i = queue.pop_front()
		for dir in NEIGHBORS:
			var next_pos: Vector2i = current + dir
			var idx: int = coords_to_index(next_pos.x, next_pos.y)
			
			if next_pos.x > 0 and next_pos.x < MAP_WIDTH - 1 and next_pos.y > 0 and next_pos.y < MAP_HEIGHT - 1:
				if visited[idx] == 0:
					var tile: int = map_data[idx]
					if tile == TILE_FLOOR or tile == TILE_DOOR:
						visited[idx] = 1
						queue.append(next_pos)
						
	for room in rooms:
		var room_center: Vector2i = room.get_center()
		if visited[coords_to_index(room_center.x, room_center.y)] == 0:
			return false
	return true

# UI Updates
func update_debug_ui() -> void:
	if not map_display: return
		
	var final_string: String = ""
	
	for y in range(MAP_HEIGHT):
		var row_string: String = ""
		for x in range(MAP_WIDTH):
			var idx: int = y * MAP_WIDTH + x
			var tile: int = map_data[idx]
			
			if tile == TILE_WALL:
				var up: bool = y > 0 and (map_data[(y - 1) * MAP_WIDTH + x] == TILE_WALL or map_data[(y - 1) * MAP_WIDTH + x] == TILE_DOOR)
				var down: bool = y < MAP_HEIGHT - 1 and (map_data[(y + 1) * MAP_WIDTH + x] == TILE_WALL or map_data[(y + 1) * MAP_WIDTH + x] == TILE_DOOR)
				var left: bool = x > 0 and (map_data[y * MAP_WIDTH + (x - 1)] == TILE_WALL or map_data[y * MAP_WIDTH + (x - 1)] == TILE_DOOR)
				var right: bool = x < MAP_WIDTH - 1 and (map_data[y * MAP_WIDTH + (x + 1)] == TILE_WALL or map_data[y * MAP_WIDTH + (x + 1)] == TILE_DOOR)
				
				var is_vertical: bool = up or down
				var is_horizontal: bool = left or right
				
				if is_vertical and is_horizontal: row_string += "+"
				elif is_vertical: row_string += "|"
				elif is_horizontal: row_string += "-"
				else: row_string += "#"
			elif tile == TILE_FLOOR: row_string += "."
			elif tile == TILE_DOOR: row_string += "X"
			elif tile == TILE_VOID: row_string += " "
				
		final_string += row_string + "\n"
		
	map_display.text = final_string
