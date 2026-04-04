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
var region_data: PackedInt32Array = PackedInt32Array() 
var rooms: Array[Rect2i] = []
var current_region: int = 0 

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
		connect_regions()
		remove_dead_ends()
		remove_redundant_walls()
		is_valid = validate_dungeon()
		
		if not is_valid:
			print("Validation failed on attempt %d. Regenerating..." % attempts)
			
	if is_valid:
		print("Dungeon ready in %d attempt(s)." % attempts)
	else:
		push_error("CRITICAL: Failed to generate a valid dungeon.")
		
	update_debug_ui()

# Phase 1: Solid Canvas
func initialize_map() -> void:
	var total: int = MAP_WIDTH * MAP_HEIGHT
	map_data.resize(total)
	map_data.fill(TILE_WALL)
	
	region_data.resize(total)
	region_data.fill(-1)
	current_region = 0

# Phase 2: Room Carving (Shifted to Even Coordinates)
func generate_rooms(placement_attempts: int, max_rooms: int) -> void:
	rooms.clear()
	var possible_sizes: Array[int] = [5, 7, 9]
	
	for i in range(placement_attempts):
		if rooms.size() >= max_rooms: break
			
		var room_width: int = possible_sizes.pick_random()
		var room_height: int = possible_sizes.pick_random()
		
		# -4 ensures rooms never touch the outermost 1-tile wall buffer
		var max_x: int = int((MAP_WIDTH - room_width - 4) / 2.0)
		var max_y: int = int((MAP_HEIGHT - room_height - 4) / 2.0)
		
		var room_x: int = randi_range(0, max_x) * 2 + 2
		var room_y: int = randi_range(0, max_y) * 2 + 2
		
		var new_room := Rect2i(room_x, room_y, room_width, room_height)
		
		var overlaps := false
		for existing_room in rooms:
			if new_room.intersects(existing_room):
				overlaps = true
				break
				
		if not overlaps:
			current_region += 1 
			for y in range(room_y, room_y + room_height):
				var row_base := y * MAP_WIDTH
				for x in range(room_x, room_x + room_width):
					map_data[row_base + x] = TILE_FLOOR
					region_data[row_base + x] = current_region
			rooms.append(new_room)

# Phase 3: Prim's Maze (Shifted to Even Coordinates)
func generate_mazes() -> void:
	for y in range(2, MAP_HEIGHT - 2, 2):
		var row_base := y * MAP_WIDTH
		for x in range(2, MAP_WIDTH - 2, 2):
			if map_data[row_base + x] == TILE_WALL:
				current_region += 1 
				grow_maze(Vector2i(x, y), current_region)

func grow_maze(start_pos: Vector2i, region: int) -> void:
	var cells: Array[Vector2i] = [] 
	
	var start_idx := start_pos.y * MAP_WIDTH + start_pos.x
	map_data[start_idx] = TILE_FLOOR
	region_data[start_idx] = region
	cells.append(start_pos)
	
	var unmade_cells: Array[Vector2i] = [Vector2i.ZERO, Vector2i.ZERO, Vector2i.ZERO, Vector2i.ZERO]
	
	while cells.size() > 0:
		var index: int = randi() % cells.size() 
		var cell: Vector2i = cells[index]
		var count: int = 0
		
		for dir in DIRECTIONS:
			var nx: int = cell.x + dir.x
			var ny: int = cell.y + dir.y
			# Playable bounds are strictly > 1 and < MAP-2
			if nx > 1 and nx < MAP_WIDTH - 2 and ny > 1 and ny < MAP_HEIGHT - 2:
				if map_data[ny * MAP_WIDTH + nx] == TILE_WALL:
					unmade_cells[count] = dir
					count += 1
				
		if count > 0:
			var dir: Vector2i = unmade_cells[randi() % count]
			var next_pos: Vector2i = cell + dir
			var middle_idx: int = (cell.y + (dir.y >> 1)) * MAP_WIDTH + (cell.x + (dir.x >> 1))
			var next_idx: int = next_pos.y * MAP_WIDTH + next_pos.x
			
			map_data[middle_idx] = TILE_FLOOR
			region_data[middle_idx] = region
			map_data[next_idx] = TILE_FLOOR
			region_data[next_idx] = region
			
			cells.append(next_pos)
		else:
			cells.remove_at(index)

# Phase 4: Minimum Spanning Tree Connectivity
func connect_regions() -> void:
	var connectors: Array[Vector2i] = []
	var internal_maze_walls: Array[Vector2i] = []
	
	for y in range(1, MAP_HEIGHT - 1):
		var row_base := y * MAP_WIDTH
		for x in range(1, MAP_WIDTH - 1):
			var idx := row_base + x
			if map_data[idx] == TILE_WALL:
				var touching: Array[int] = get_touching_regions(idx)
				
				if touching.size() >= 2:
					connectors.append(Vector2i(x, y))
				elif touching.size() == 1:
					var up := map_data[idx - MAP_WIDTH]
					var down := map_data[idx + MAP_WIDTH]
					var left := map_data[idx - 1]
					var right := map_data[idx + 1]
					
					var horiz: bool = (left == TILE_FLOOR) and (right == TILE_FLOOR)
					var vert: bool = (up == TILE_FLOOR) and (down == TILE_FLOOR)
					if horiz or vert:
						internal_maze_walls.append(Vector2i(x, y))
						
	connectors.shuffle()
	internal_maze_walls.shuffle()
	
	var merged: PackedInt32Array = PackedInt32Array()
	merged.resize(current_region + 1)
	for i in range(merged.size()): merged[i] = i
		
	var placed_doors: Array[Vector2i] = []
	
	for pos in connectors:
		var idx := pos.y * MAP_WIDTH + pos.x
		var touching: Array[int] = get_touching_regions(idx)
		if touching.size() < 2: continue 
		
		var r1: int = touching[0]
		var r2: int = touching[1]
		
		var root1: int = find_root(r1, merged)
		var root2: int = find_root(r2, merged)
		
		if root1 != root2:
			merged[root1] = root2
			map_data[idx] = TILE_DOOR
			placed_doors.append(pos)
		else:
			if randf() < 0.15 and not has_adjacent_door(idx):
				var is_far: bool = true
				for d in placed_doors:
					if pos.distance_squared_to(d) < 81.0: 
						is_far = false
						break
				if is_far:
					map_data[idx] = TILE_DOOR
					placed_doors.append(pos)
					
	for pos in internal_maze_walls:
		if randf() < 0.04:
			map_data[pos.y * MAP_WIDTH + pos.x] = TILE_FLOOR

func get_touching_regions(idx: int) -> Array[int]:
	var r1: int = -1
	var r2: int = -1
	
	for offset in [-MAP_WIDTH, MAP_WIDTH, -1, 1]:
		var r: int = region_data[idx + offset]
		if r == -1: continue
		if r1 == -1:
			r1 = r
		elif r != r1:
			r2 = r
			break 
			
	if r2 != -1: return [r1, r2]
	if r1 != -1: return [r1]
	return []

func find_root(region: int, merged: PackedInt32Array) -> int:
	var current: int = region
	while merged[current] != current:
		merged[current] = merged[merged[current]] 
		current = merged[current]
	return current

func has_adjacent_door(base_idx: int) -> bool:
	var w: int = MAP_WIDTH
	if map_data[base_idx - w - 1] == TILE_DOOR: return true
	if map_data[base_idx - w] == TILE_DOOR: return true
	if map_data[base_idx - w + 1] == TILE_DOOR: return true
	if map_data[base_idx - 1] == TILE_DOOR: return true
	if map_data[base_idx + 1] == TILE_DOOR: return true
	if map_data[base_idx + w - 1] == TILE_DOOR: return true
	if map_data[base_idx + w] == TILE_DOOR: return true
	if map_data[base_idx + w + 1] == TILE_DOOR: return true
	return false

# Phase 5: Stack-Based Backtracker (Bounds Shifted)
func remove_dead_ends() -> void:
	var stack: Array[Vector2i] = []
	
	for y in range(2, MAP_HEIGHT - 2):
		var row_base := y * MAP_WIDTH
		for x in range(2, MAP_WIDTH - 2):
			var idx := row_base + x
			var tile := map_data[idx]
			if tile == TILE_FLOOR or tile == TILE_DOOR:
				var walls: int = 0
				if map_data[idx - MAP_WIDTH] == TILE_WALL: walls += 1
				if map_data[idx + MAP_WIDTH] == TILE_WALL: walls += 1
				if map_data[idx - 1] == TILE_WALL: walls += 1
				if map_data[idx + 1] == TILE_WALL: walls += 1
				
				if walls >= 3:
					stack.append(Vector2i(x, y))

	while stack.size() > 0:
		var pos: Vector2i = stack.pop_back()
		var idx := pos.y * MAP_WIDTH + pos.x
		var tile := map_data[idx]
		
		if tile == TILE_FLOOR or tile == TILE_DOOR:
			var walls: int = 0
			if map_data[idx - MAP_WIDTH] == TILE_WALL: walls += 1
			if map_data[idx + MAP_WIDTH] == TILE_WALL: walls += 1
			if map_data[idx - 1] == TILE_WALL: walls += 1
			if map_data[idx + 1] == TILE_WALL: walls += 1
			
			if walls >= 3:
				map_data[idx] = TILE_WALL
				region_data[idx] = -1
				
				# Push adjacent walkable tiles strictly inside bounds
				if pos.y > 2: stack.append(Vector2i(pos.x, pos.y - 1))
				if pos.y < MAP_HEIGHT - 3: stack.append(Vector2i(pos.x, pos.y + 1))
				if pos.x > 2: stack.append(Vector2i(pos.x - 1, pos.y))
				if pos.x < MAP_WIDTH - 3: stack.append(Vector2i(pos.x + 1, pos.y))

# Phase 6: Inlined Redundant Wall Culling
func remove_redundant_walls() -> void:
	for y in range(1, MAP_HEIGHT - 1):
		var row_base := y * MAP_WIDTH
		for x in range(1, MAP_WIDTH - 1):
			var idx: int = row_base + x
			if map_data[idx] == TILE_WALL:
				var w: int = MAP_WIDTH
				var has_walkable := false
				
				if map_data[idx - w - 1] == TILE_FLOOR or map_data[idx - w - 1] == TILE_DOOR: has_walkable = true
				elif map_data[idx - w] == TILE_FLOOR or map_data[idx - w] == TILE_DOOR: has_walkable = true
				elif map_data[idx - w + 1] == TILE_FLOOR or map_data[idx - w + 1] == TILE_DOOR: has_walkable = true
				elif map_data[idx - 1] == TILE_FLOOR or map_data[idx - 1] == TILE_DOOR: has_walkable = true
				elif map_data[idx + 1] == TILE_FLOOR or map_data[idx + 1] == TILE_DOOR: has_walkable = true
				elif map_data[idx + w - 1] == TILE_FLOOR or map_data[idx + w - 1] == TILE_DOOR: has_walkable = true
				elif map_data[idx + w] == TILE_FLOOR or map_data[idx + w] == TILE_DOOR: has_walkable = true
				elif map_data[idx + w + 1] == TILE_FLOOR or map_data[idx + w + 1] == TILE_DOOR: has_walkable = true
				
				if not has_walkable:
					map_data[idx] = TILE_VOID

	# Unconditionally wipe the absolute outer perimeter to create the visual void wrapper
	for x in range(MAP_WIDTH):
		map_data[x] = TILE_VOID 
		map_data[(MAP_HEIGHT - 1) * MAP_WIDTH + x] = TILE_VOID 
	for y in range(MAP_HEIGHT):
		map_data[y * MAP_WIDTH] = TILE_VOID 
		map_data[y * MAP_WIDTH + MAP_WIDTH - 1] = TILE_VOID 

# Phase 7: Flood fill validation (Bounds Shifted)
func validate_dungeon() -> bool:
	if rooms.size() <= 1: return true 
		
	var visited: PackedByteArray = PackedByteArray()
	visited.resize(MAP_WIDTH * MAP_HEIGHT)
	visited.fill(0)
	
	var start_pos: Vector2i = rooms[0].get_center()
	var queue: Array[Vector2i] = [start_pos]
	var head: int = 0
	
	visited[start_pos.y * MAP_WIDTH + start_pos.x] = 1
	
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1 
		
		for dir in NEIGHBORS:
			var nx: int = current.x + dir.x
			var ny: int = current.y + dir.y
			
			if nx > 1 and nx < MAP_WIDTH - 2 and ny > 1 and ny < MAP_HEIGHT - 2:
				var idx: int = ny * MAP_WIDTH + nx
				if visited[idx] == 0:
					var tile: int = map_data[idx]
					if tile == TILE_FLOOR or tile == TILE_DOOR:
						visited[idx] = 1
						queue.append(Vector2i(nx, ny))
						
	for room in rooms:
		var room_center: Vector2i = room.get_center()
		if visited[room_center.y * MAP_WIDTH + room_center.x] == 0:
			return false
	return true

# UI Updates
func update_debug_ui() -> void:
	if not map_display: return
		
	var final_string: String = ""
	
	for y in range(MAP_HEIGHT):
		var row_string: String = ""
		var row_base := y * MAP_WIDTH
		for x in range(MAP_WIDTH):
			var idx: int = row_base + x
			var tile: int = map_data[idx]
			
			if tile == TILE_WALL:
				var up: bool = y > 0 and (map_data[idx - MAP_WIDTH] == TILE_WALL or map_data[idx - MAP_WIDTH] == TILE_DOOR)
				var down: bool = y < MAP_HEIGHT - 1 and (map_data[idx + MAP_WIDTH] == TILE_WALL or map_data[idx + MAP_WIDTH] == TILE_DOOR)
				var left: bool = x > 0 and (map_data[idx - 1] == TILE_WALL or map_data[idx - 1] == TILE_DOOR)
				var right: bool = x < MAP_WIDTH - 1 and (map_data[idx + 1] == TILE_WALL or map_data[idx + 1] == TILE_DOOR)
				
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
