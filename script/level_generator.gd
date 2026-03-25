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
var rooms: Array[Rect2i] = []

@export var map_display: RichTextLabel

func _ready() -> void:
	run_generation()

# Input listener consolidated to call the same run function
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
		connect_regions()
		remove_dead_ends()
		remove_redundant_walls()
		
		# Phase 7: Run the validator
		is_valid = validate_dungeon()
		
		if not is_valid:
			print("Validation failed on attempt %d." % attempts)
			
	if is_valid:
		print("Dungeon ready in %d attempt(s)." % attempts)
	else:
		push_error("CRITICAL: Failed to generate a valid dungeon after %d attempts." % max_attempts)
		
	update_debug_ui()

# Phase 1: Solid Canvas
func initialize_map() -> void:
	map_data.resize(MAP_WIDTH * MAP_HEIGHT)
	map_data.fill(TILE_WALL)

func coords_to_index(x: int, y: int) -> int:
	return y * MAP_WIDTH + x

func set_tile(x: int, y: int, tile_type: int) -> void:
	map_data[coords_to_index(x, y)] = tile_type

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
			carve_room(new_room)
			rooms.append(new_room)
			
func can_place_room(new_room: Rect2i) -> bool:
	for existing_room in rooms:
		if new_room.intersects(existing_room):
			return false
	return true

func carve_room(room: Rect2i) -> void:
	for y in range(room.position.y, room.position.y + room.size.y):
		for x in range(room.position.x, room.position.x + room.size.x):
			set_tile(x, y, TILE_FLOOR)

# Phase 3: Prim's Maze
func generate_mazes() -> void:
	for y in range(1, MAP_HEIGHT, 2):
		for x in range(1, MAP_WIDTH, 2):
			if get_tile(x, y) == TILE_WALL:
				grow_maze(Vector2i(x, y))

func grow_maze(start_pos: Vector2i) -> void:
	var cells: Array[Vector2i] = [] 
	
	set_tile(start_pos.x, start_pos.y, TILE_FLOOR)
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
			
			set_tile(middle_pos.x, middle_pos.y, TILE_FLOOR)
			set_tile(next_pos.x, next_pos.y, TILE_FLOOR)
			cells.append(next_pos)
		else:
			cells.remove_at(index)

func can_carve(pos: Vector2i) -> bool:
	if pos.x <= 0 or pos.x >= MAP_WIDTH - 1 or pos.y <= 0 or pos.y >= MAP_HEIGHT - 1:
		return false
	return get_tile(pos.x, pos.y) == TILE_WALL

# Phase 4: Room Connectivity and Optional Loops
func connect_regions() -> void:
	for room in rooms:
		var top_maze: Array[Vector2i] = []; var top_room: Array[Vector2i] = []
		var bottom_maze: Array[Vector2i] = []; var bottom_room: Array[Vector2i] = []
		var left_maze: Array[Vector2i] = []; var left_room: Array[Vector2i] = []
		var right_maze: Array[Vector2i] = []; var right_room: Array[Vector2i] = []

		var top_has_door: bool = false
		var bottom_has_door: bool = false
		var left_has_door: bool = false
		var right_has_door: bool = false

		# Scan Top and Bottom
		for x in range(room.position.x, room.position.x + room.size.x):
			var top_y: int = room.position.y - 1
			if get_tile(x, top_y) == TILE_DOOR: top_has_door = true
			elif top_y - 1 > 0 and get_tile(x, top_y - 1) == TILE_FLOOR:
				# Use our new helper to distinguish the maze from other rooms
				if is_in_room(x, top_y - 1): top_room.append(Vector2i(x, top_y))
				else: top_maze.append(Vector2i(x, top_y))

			var bottom_y: int = room.position.y + room.size.y
			if get_tile(x, bottom_y) == TILE_DOOR: bottom_has_door = true
			elif bottom_y + 1 < MAP_HEIGHT - 1 and get_tile(x, bottom_y + 1) == TILE_FLOOR:
				if is_in_room(x, bottom_y + 1): bottom_room.append(Vector2i(x, bottom_y))
				else: bottom_maze.append(Vector2i(x, bottom_y))

		# Scan Left and Right
		for y in range(room.position.y, room.position.y + room.size.y):
			var left_x: int = room.position.x - 1
			if get_tile(left_x, y) == TILE_DOOR: left_has_door = true
			elif left_x - 1 > 0 and get_tile(left_x - 1, y) == TILE_FLOOR:
				if is_in_room(left_x - 1, y): left_room.append(Vector2i(left_x, y))
				else: left_maze.append(Vector2i(left_x, y))

			var right_x: int = room.position.x + room.size.x
			if get_tile(right_x, y) == TILE_DOOR: right_has_door = true
			elif right_x + 1 < MAP_WIDTH - 1 and get_tile(right_x + 1, y) == TILE_FLOOR:
				if is_in_room(right_x + 1, y): right_room.append(Vector2i(right_x, y))
				else: right_maze.append(Vector2i(right_x, y))

		# Package the maze-connected walls
		var maze_walls: Array = []
		if not top_has_door and top_maze.size() > 0: maze_walls.append({"array": top_maze, "dir": "top"})
		if not bottom_has_door and bottom_maze.size() > 0: maze_walls.append({"array": bottom_maze, "dir": "bottom"})
		if not left_has_door and left_maze.size() > 0: maze_walls.append({"array": left_maze, "dir": "left"})
		if not right_has_door and right_maze.size() > 0: maze_walls.append({"array": right_maze, "dir": "right"})

		var connected_to_maze: bool = false

		# Step 1: Force exactly 1 connection to the global maze network
		if maze_walls.size() > 0:
			maze_walls.shuffle()
			var primary: Dictionary = maze_walls[0]
			var chosen_door: Vector2i = primary["array"].pick_random()
			if not has_adjacent_door(chosen_door):
				set_tile(chosen_door.x, chosen_door.y, TILE_DOOR)
				connected_to_maze = true
				if primary["dir"] == "top": top_has_door = true
				if primary["dir"] == "bottom": bottom_has_door = true
				if primary["dir"] == "left": left_has_door = true
				if primary["dir"] == "right": right_has_door = true

		# Step 2: Fallback - if landlocked, guarantee it connects to a neighboring room
		if not connected_to_maze and not (top_has_door or bottom_has_door or left_has_door or right_has_door):
			var room_walls: Array = []
			if not top_has_door and top_room.size() > 0: room_walls.append({"array": top_room, "dir": "top"})
			if not bottom_has_door and bottom_room.size() > 0: room_walls.append({"array": bottom_room, "dir": "bottom"})
			if not left_has_door and left_room.size() > 0: room_walls.append({"array": left_room, "dir": "left"})
			if not right_has_door and right_room.size() > 0: room_walls.append({"array": right_room, "dir": "right"})

			if room_walls.size() > 0:
				room_walls.shuffle()
				var primary: Dictionary = room_walls[0]
				var chosen_door: Vector2i = primary["array"].pick_random()
				if not has_adjacent_door(chosen_door):
					set_tile(chosen_door.x, chosen_door.y, TILE_DOOR)
					if primary["dir"] == "top": top_has_door = true
					if primary["dir"] == "bottom": bottom_has_door = true
					if primary["dir"] == "left": left_has_door = true
					if primary["dir"] == "right": right_has_door = true

		# Step 3: Optional loops - Give all remaining walls a 15% chance to spawn an extra door
		var extra_walls: Array = []
		if not top_has_door:
			var combined: Array = top_maze + top_room
			if combined.size() > 0: extra_walls.append(combined)
		if not bottom_has_door:
			var combined: Array = bottom_maze + bottom_room
			if combined.size() > 0: extra_walls.append(combined)
		if not left_has_door:
			var combined: Array = left_maze + left_room
			if combined.size() > 0: extra_walls.append(combined)
		if not right_has_door:
			var combined: Array = right_maze + right_room
			if combined.size() > 0: extra_walls.append(combined)

		for wall_array in extra_walls:
			if randf() < 0.15: 
				wall_array.shuffle()
				for chosen_door in wall_array:
					if not has_adjacent_door(chosen_door):
						set_tile(chosen_door.x, chosen_door.y, TILE_DOOR)
						break

func has_adjacent_door(pos: Vector2i) -> bool:
	for dir in NEIGHBORS:
		if get_tile(pos.x + dir.x, pos.y + dir.y) == TILE_DOOR:
			return true
	return false

# Helper function: Instantly checks if a coordinate is inside a room
func is_in_room(x: int, y: int) -> bool:
	var pos := Vector2i(x, y)
	for room in rooms:
		if room.has_point(pos):
			return true
	return false

# Phase 5: Reverted to the Sweeping Backtracker for mathematical parity
func remove_dead_ends() -> void:
	var done: bool = false
	
	while not done:
		done = true 
		
		# Sweeping strictly from 1 to MAP-1 prevents out-of-bounds array wrapping
		for y in range(1, MAP_HEIGHT - 1):
			for x in range(1, MAP_WIDTH - 1):
				var current_tile: int = get_tile(x, y)
				
				if current_tile == TILE_FLOOR or current_tile == TILE_DOOR:
					var adjacent_walls: int = 0
					
					for dir in NEIGHBORS:
						if get_tile(x + dir.x, y + dir.y) == TILE_WALL:
							adjacent_walls += 1
					
					if adjacent_walls >= 3:
						# Sweeping re-evaluates the 90% chance on every pass, properly cleaning the map
						if current_tile == TILE_DOOR or randf() < 0.90:
							set_tile(x, y, TILE_WALL)
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

# Phase 7: Flood fill validation to ensure 100% room connectivity
func validate_dungeon() -> bool:
	if rooms.size() <= 1:
		return true # A map with 0 or 1 room is tecrhnically always connected
		
	# Create a temporary array to track where our flood fill has reached
	var visited: PackedByteArray = PackedByteArray()
	visited.resize(MAP_WIDTH * MAP_HEIGHT)
	visited.fill(0)
	
	# Start the flood fill from the center of the very first room
	var start_pos: Vector2i = rooms[0].get_center()
	var queue: Array[Vector2i] = [start_pos]
	
	# Mark the starting tile as visited (1)
	visited[coords_to_index(start_pos.x, start_pos.y)] = 1
	
	# Pour through the dungeon map
	while queue.size() > 0:
		# Pop from the front to act as a Breadth-First Search (BFS)
		var current: Vector2i = queue.pop_front()
		
		for dir in NEIGHBORS:
			var next_pos: Vector2i = current + dir
			var idx: int = coords_to_index(next_pos.x, next_pos.y)
			
			# Ensure we don't check outside the array bounds
			if next_pos.x > 0 and next_pos.x < MAP_WIDTH - 1 and next_pos.y > 0 and next_pos.y < MAP_HEIGHT - 1:
				# If we haven't visited this tile yet...
				if visited[idx] == 0:
					var tile: int = map_data[idx]
					# ...and it is a walkable surface, spread the water to it
					if tile == TILE_FLOOR or tile == TILE_DOOR:
						visited[idx] = 1
						queue.append(next_pos)
						
	# Once the flood fill is completely done, check every generated room
	for room in rooms:
		var room_center: Vector2i = room.get_center()
		var center_idx: int = coords_to_index(room_center.x, room_center.y)
		
		# If the water never reached the center of this room, the dungeon is broken
		if visited[center_idx] == 0:
			return false
			
	# If we checked every room and they were all wet, the dungeon is fully connected!
	return true

# UI Updates: Memory-optimized PackedStringArrays and inlined math
func update_debug_ui() -> void:
	if not map_display: return
		
	var rows: PackedStringArray = PackedStringArray()
	
	for y in range(MAP_HEIGHT):
		var row_chars: PackedStringArray = PackedStringArray()
		
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
				
				if is_vertical and is_horizontal: row_chars.append("+")
				elif is_vertical: row_chars.append("|")
				elif is_horizontal: row_chars.append("-")
				else: row_chars.append("#")
			elif tile == TILE_FLOOR: row_chars.append(".")
			elif tile == TILE_DOOR: row_chars.append("X")
			elif tile == TILE_VOID: row_chars.append(" ")
				
		rows.append("".join(row_chars))
		
	map_display.text = "\n".join(rows)
