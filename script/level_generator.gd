extends Node

@export_category("Gold Distribution")
## Baseline chance for gold on the golden path.
@export_range(0.0, 0.05, 0.001) var gold_base_chance: float = 0.005 
## Maximum bonus chance added at the furthest tile.
@export_range(0.0, 0.15, 0.001) var gold_max_bonus: float = 0.045
## Percentage of the map distance (0.0 to 1.0) that receives zero bonus.
@export_range(0.0, 1.0, 0.05) var gold_safe_zone: float = 0.20
## 1.0 is linear. > 1.0 pushes gold further to the edges. < 1.0 pulls gold closer to the center.
@export_range(0.1, 4.0, 0.1) var gold_curve_power: float = 1.0

const MAP_WIDTH: int = 51
const MAP_HEIGHT: int = 51

const TILE_WALL: int = 35   # ASCII for '#'
const TILE_FLOOR: int = 46  # ASCII for '.'
const TILE_DOOR: int = 88   # ASCII for 'X'
const TILE_VOID: int = 32   # ASCII for ' '
const TILE_EXIT: int = 62    # ASCII for '>'
const TILE_PLAYER: int = 64  # ASCII for '@'
const TILE_AMMO: int = 65    # ASCII for 'A'
const TILE_JUICE: int = 67   # ASCII for 'C'
const TILE_SIZZLE: int = 83  # ASCII for 'S'
const TILE_MALIBU: int = 77  # ASCII for 'M'
const TILE_GOLD: int = 36    # ASCII for '$'

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
		print("Dungeon successfully validated in %d attempt(s)." % attempts)
		spawn_entities() 
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

# ==========================================
# ENTITY SPAWNING PIPELINE
# ==========================================

func spawn_entities() -> void:
	var analysis: Dictionary = analyze_dungeon()
	var available_rooms: Array = analysis["rooms"] 
	var map_center: Vector2i = analysis["map_center"]
	
	# Extract the freestanding columns found during the pre-requisite scan
	var columns: Array[Vector2i] = analysis["columns"] 
	
	# Phase A: Player & Exit
	available_rooms = spawn_phase_a_player_and_exit(available_rooms, map_center)
	
	# Phase B: Gold Spawns (The Golden Path)
	spawn_phase_b_gold(available_rooms)
	
	# Phase C: Dispensers & Ammo
	spawn_phase_c_dispensers(available_rooms, columns)
	
	# Phase D: Enemies
	# ... coming next

# Pre-requisite: Gather all structural data needed for intelligent placement
func analyze_dungeon() -> Dictionary:
	var map_center := Vector2i(MAP_WIDTH / 2, MAP_HEIGHT / 2) # Opt 11: Compute once
	var room_data: Array = []
	var columns: Array[Vector2i] = []
	
	# 1. Analyze Rooms (Opt 1: Struct-like array -> [Rect2i, Vector2i, dist_sq])
	for room in rooms:
		var center: Vector2i = room.get_center()
		room_data.append([room, center, center.distance_squared_to(map_center)])
		
	# 2. Find Freestanding Columns
	for y in range(2, MAP_HEIGHT - 2):
		var row_base := y * MAP_WIDTH
		for x in range(2, MAP_WIDTH - 2):
			var idx := row_base + x
			if map_data[idx] == TILE_WALL:
				var w := MAP_WIDTH
				
				var up: int = map_data[idx - w]
				var down: int = map_data[idx + w]
				var left: int = map_data[idx - 1]
				var right: int = map_data[idx + 1]
				
				# Opt 3: Fully inlined logic, 0 array allocations
				if (up == TILE_FLOOR or up == TILE_DOOR) and \
				   (down == TILE_FLOOR or down == TILE_DOOR) and \
				   (left == TILE_FLOOR or left == TILE_DOOR) and \
				   (right == TILE_FLOOR or right == TILE_DOOR):
					columns.append(Vector2i(x, y))
					
	return {
		"rooms": room_data,
		"columns": columns,
		"map_center": map_center
	}

# Phase A: Spawns the exit in the Upper half, Player in the Lower half
func spawn_phase_a_player_and_exit(pool: Array, map_center: Vector2i) -> Array:
	var upper_pool: Array = []
	var lower_pool: Array = []
	var center_y := map_center.y

	for r in pool:
		if r[1].y < center_y: # r[1] is the center Vector2i
			upper_pool.append(r)
		else:
			lower_pool.append(r)

	# Opt 2: Shallow copy only when fallback is triggered
	if upper_pool.size() == 0: upper_pool = pool.duplicate(false)
	if lower_pool.size() == 0: lower_pool = pool.duplicate(false)

	var exit_pos := Vector2i(-1, -1)
	var exit_data: Dictionary = place_void_entity(upper_pool, map_center, true)
	
	if exit_data.has("pos"):
		exit_pos = exit_data["pos"]
		map_data[exit_pos.y * MAP_WIDTH + exit_pos.x] = TILE_EXIT
		fast_remove(pool, exit_data["room"])
		fast_remove(lower_pool, exit_data["room"])

	# Opt 9: Use squared distance for math ops
	var min_sep_sq: float = (MAP_HEIGHT / 3.0) * (MAP_HEIGHT / 3.0)
	var safe_lower_pool: Array = []
	
	if exit_pos != Vector2i(-1, -1):
		for r in lower_pool:
			if r[1].distance_squared_to(exit_pos) >= min_sep_sq:
				safe_lower_pool.append(r)
				
	if safe_lower_pool.size() == 0:
		safe_lower_pool = lower_pool

	var player_data: Dictionary = place_void_entity(safe_lower_pool, map_center, false)
	if player_data.has("pos"):
		var p: Vector2i = player_data["pos"]
		map_data[p.y * MAP_WIDTH + p.x] = TILE_PLAYER
		fast_remove(pool, player_data["room"])

	return pool

# Helper 1: Evaluates rooms and executes outward-weighted random selection
func place_void_entity(hemisphere_pool: Array, map_center: Vector2i, is_wall_entity: bool) -> Dictionary:
	var valid_rooms: Array = []
	var require_void: bool = true
	var clearance: int = 2

	while valid_rooms.size() == 0 and clearance >= 0:
		for room in hemisphere_pool:
			var spawns: Array[Vector2i] = get_valid_spawns(room, require_void, clearance, is_wall_entity)
			if spawns.size() > 0:
				valid_rooms.append([room, spawns, 0.0]) # Struct: [room_data, spawns, weight]
				
		if valid_rooms.size() == 0:
			clearance -= 1
			if clearance < 0 and require_void:
				require_void = false
				clearance = 2 

	if valid_rooms.size() == 0:
		return {}

	var total_weight: float = 0.0
	for vr in valid_rooms:
		# Opt 8: Reuse the precomputed squared distance (vr[0][2]) instead of recalculating
		var weight: float = vr[0][2] + 10.0 
		vr[2] = weight
		total_weight += weight

	var roll: float = randf() * total_weight
	var current: float = 0.0
	var chosen_vr: Array = valid_rooms.back()

	for vr in valid_rooms:
		current += vr[2]
		if roll <= current:
			chosen_vr = vr
			break

	var spawns: Array[Vector2i] = chosen_vr[1]
	# Opt 12: Direct index randomization avoids array .pick_random() overhead
	return {"room": chosen_vr[0], "pos": spawns[randi() % spawns.size()]}

# Helper 2: O(1) Array Removal (Opt 10)
func fast_remove(arr: Array, item) -> void:
	var i: int = arr.find(item)
	if i != -1:
		arr[i] = arr.back()
		arr.pop_back()

# Helper 3: Inlined, Zero-Allocation Edge Scanner (Opts 4, 5, 6, 13)
func get_valid_spawns(room_data: Array, require_void: bool, clearance: int, is_wall: bool) -> Array[Vector2i]:
	var rect: Rect2i = room_data[0]
	var spawns: Array[Vector2i] = []
	
	var rx: int = rect.position.x
	var ry: int = rect.position.y
	var rw: int = rect.size.x
	var rh: int = rect.size.y

	# Top Edge
	for x in range(rx + 1, rx + rw - 1):
		var wy: int = ry - 1
		if map_data[wy * MAP_WIDTH + x] == TILE_WALL:
			var valid: bool = true
			if require_void:
				var vy: int = ry - 2
				if vy < 0 or map_data[vy * MAP_WIDTH + x] != TILE_VOID:
					valid = false
			if valid and is_safe_distance_from_doors(x, ry, clearance):
				spawns.append(Vector2i(x, wy) if is_wall else Vector2i(x, ry))
				
	# Bottom Edge
	for x in range(rx + 1, rx + rw - 1):
		var fy: int = ry + rh - 1
		var wy: int = ry + rh
		if map_data[wy * MAP_WIDTH + x] == TILE_WALL:
			var valid: bool = true
			if require_void:
				var vy: int = ry + rh + 1
				if vy >= MAP_HEIGHT or map_data[vy * MAP_WIDTH + x] != TILE_VOID:
					valid = false
			if valid and is_safe_distance_from_doors(x, fy, clearance):
				spawns.append(Vector2i(x, wy) if is_wall else Vector2i(x, fy))

	# Left Edge
	for y in range(ry + 1, ry + rh - 1):
		var wx: int = rx - 1
		if map_data[y * MAP_WIDTH + wx] == TILE_WALL:
			var valid: bool = true
			if require_void:
				var vx: int = rx - 2
				if vx < 0 or map_data[y * MAP_WIDTH + vx] != TILE_VOID:
					valid = false
			if valid and is_safe_distance_from_doors(rx, y, clearance):
				spawns.append(Vector2i(wx, y) if is_wall else Vector2i(rx, y))

	# Right Edge
	for y in range(ry + 1, ry + rh - 1):
		var fx: int = rx + rw - 1
		var wx: int = rx + rw
		if map_data[y * MAP_WIDTH + wx] == TILE_WALL:
			var valid: bool = true
			if require_void:
				var vx: int = rx + rw + 1
				if vx >= MAP_WIDTH or map_data[y * MAP_WIDTH + vx] != TILE_VOID:
					valid = false
			if valid and is_safe_distance_from_doors(fx, y, clearance):
				spawns.append(Vector2i(wx, y) if is_wall else Vector2i(fx, y))

	return spawns

# Helper 4: Radial Door Scanner
func is_safe_distance_from_doors(pos_x: int, pos_y: int, min_dist: int) -> bool:
	for dy in range(-min_dist, min_dist + 1):
		for dx in range(-min_dist, min_dist + 1):
			var check_x: int = pos_x + dx
			var check_y: int = pos_y + dy
			if check_x >= 0 and check_x < MAP_WIDTH and check_y >= 0 and check_y < MAP_HEIGHT:
				if map_data[check_y * MAP_WIDTH + check_x] == TILE_DOOR:
					return false
	return true
	
# Phase B: Traces the shortest path from Player to Exit and spawns gold based on distance
func spawn_phase_b_gold(pool: Array) -> void:
	# --- ADJUSTABLE PARAMETERS (Per-Tile Probability) ---
	var base_tile_chance: float = 0.005 # 0.5% chance for a floor tile on the Golden Path
	var max_tile_bonus: float = 0.045   # Up to +4.5% chance for the most remote tiles
	# ----------------------------------------------------
	
	var total_tiles := MAP_WIDTH * MAP_HEIGHT
	var w := MAP_WIDTH
	
	# --- 1. Find player & exit (fast, safe)
	var p_idx := -1
	var e_idx := -1
	
	for i in range(total_tiles):
		var t := map_data[i]
		if t == TILE_PLAYER:
			p_idx = i
		elif t == TILE_EXIT:
			e_idx = i
			
	if p_idx == -1 or e_idx == -1:
		push_error("Phase B Aborted: Missing Player or Exit.")
		return
	
	# --- 2. BFS (single source)
	var parents := PackedInt32Array()
	parents.resize(total_tiles)
	parents.fill(-1)
	
	var queue := PackedInt32Array()
	queue.resize(total_tiles)
	
	var head := 0
	var tail := 0
	
	queue[tail] = p_idx
	tail += 1
	parents[p_idx] = p_idx
	
	var found_exit := false
	
	while head < tail:
		var curr := queue[head]
		head += 1
		
		if curr == e_idx:
			found_exit = true
			break
		
		var x := curr % w
		
		# UP
		var n := curr - w
		if n >= 0 and parents[n] == -1:
			var t := map_data[n]
			if t == TILE_FLOOR or t == TILE_DOOR or t == TILE_EXIT:
				parents[n] = curr
				queue[tail] = n
				tail += 1
		
		# DOWN
		n = curr + w
		if n < total_tiles and parents[n] == -1:
			var t := map_data[n]
			if t == TILE_FLOOR or t == TILE_DOOR or t == TILE_EXIT:
				parents[n] = curr
				queue[tail] = n
				tail += 1
		
		# LEFT (prevent wrap)
		if x > 0:
			n = curr - 1
			if parents[n] == -1:
				var t := map_data[n]
				if t == TILE_FLOOR or t == TILE_DOOR or t == TILE_EXIT:
					parents[n] = curr
					queue[tail] = n
					tail += 1
		
		# RIGHT (prevent wrap)
		if x < w - 1:
			n = curr + 1
			if parents[n] == -1:
				var t := map_data[n]
				if t == TILE_FLOOR or t == TILE_DOOR or t == TILE_EXIT:
					parents[n] = curr
					queue[tail] = n
					tail += 1
	
	if not found_exit:
		push_error("Phase B Aborted: No path to exit.")
		return
	
	# --- 3. Reconstruct path (SAFE)
	var path_indices := PackedInt32Array()
	var curr_path := e_idx
	
	while curr_path != p_idx:
		path_indices.append(curr_path)
		curr_path = parents[curr_path]
		
		if curr_path == -1:
			push_error("Phase B Aborted: Broken parent chain.")
			return
	
	path_indices.append(p_idx)
	
	# --- 4. Multi-source BFS (distance field)
	var dist_map := PackedInt32Array()
	dist_map.resize(total_tiles)
	dist_map.fill(-1)
	
	head = 0
	tail = 0
	
	for p in path_indices:
		queue[tail] = p
		tail += 1
		dist_map[p] = 0
	
	var max_dist := 1
	
	while head < tail:
		var curr := queue[head]
		head += 1
		
		var d := dist_map[curr]
		var x := curr % w
		
		# UP
		var n := curr - w
		if n >= 0 and dist_map[n] == -1:
			var t := map_data[n]
			if t == TILE_FLOOR or t == TILE_DOOR or t == TILE_PLAYER or t == TILE_EXIT:
				dist_map[n] = d + 1
				queue[tail] = n
				tail += 1
				if d + 1 > max_dist: max_dist = d + 1
		
		# DOWN
		n = curr + w
		if n < total_tiles and dist_map[n] == -1:
			var t := map_data[n]
			if t == TILE_FLOOR or t == TILE_DOOR or t == TILE_PLAYER or t == TILE_EXIT:
				dist_map[n] = d + 1
				queue[tail] = n
				tail += 1
				if d + 1 > max_dist: max_dist = d + 1
		
		# LEFT
		if x > 0:
			n = curr - 1
			if dist_map[n] == -1:
				var t := map_data[n]
				if t == TILE_FLOOR or t == TILE_DOOR or t == TILE_PLAYER or t == TILE_EXIT:
					dist_map[n] = d + 1
					queue[tail] = n
					tail += 1
					if d + 1 > max_dist: max_dist = d + 1
		
		# RIGHT
		if x < w - 1:
			n = curr + 1
			if dist_map[n] == -1:
				var t := map_data[n]
				if t == TILE_FLOOR or t == TILE_DOOR or t == TILE_PLAYER or t == TILE_EXIT:
					dist_map[n] = d + 1
					queue[tail] = n
					tail += 1
					if d + 1 > max_dist: max_dist = d + 1
	
# --- 5. Spawn gold (Organic Probability Field with Curve Shaping)
	for i in range(total_tiles):
		if map_data[i] == TILE_FLOOR:
			var d := dist_map[i]
			if d < 0: d = 0
			
			# Raw distance percentage (0.0 to 1.0)
			var dist_ratio := float(d) / float(max_dist)
			var active_ratio := 0.0
			
			# Only apply bonus if outside the safe zone
			if dist_ratio > gold_safe_zone:
				# Normalize the remaining distance back to a 0.0 - 1.0 scale
				active_ratio = (dist_ratio - gold_safe_zone) / (1.0 - gold_safe_zone)
				
			# Apply exponential curve shaping
			var shaped_ratio := pow(active_ratio, gold_curve_power)
			var spawn_chance := gold_base_chance + (gold_max_bonus * shaped_ratio)
			
			if randf() <= spawn_chance:
				map_data[i] = TILE_GOLD

# Phase C: Distributes dispensers evenly, prioritizing columns then falling back to walls
func spawn_phase_c_dispensers(pool: Array, columns: Array[Vector2i]) -> void:
	# --- ADJUSTABLE PARAMETERS ---
	var min_same_type_dist_sq: int = 100 # Keep identical dispensers at least 10 tiles apart (10^2)
	# -----------------------------
	
	var roster: Array[int] = []
	for i in range(randi_range(2, 3)): roster.append(TILE_JUICE)
	for i in range(randi_range(1, 2)): roster.append(TILE_SIZZLE)
	for i in range(randi_range(1, 2)): roster.append(TILE_AMMO)
	for i in range(randi_range(0, 1)): roster.append(TILE_MALIBU)
	
	roster.shuffle()
	
	var placed_positions: Array[Vector2i] = []
	var placed_types: Array[int] = []
	var available_cols: Array[Vector2i] = columns.duplicate()
	
	# Priority 1: Expend available columns using Furthest Point Sampling
	while roster.size() > 0 and available_cols.size() > 0:
		var best_idx: int = get_furthest_candidate_index(available_cols, placed_positions)
		var chosen_pos: Vector2i = available_cols[best_idx]
		
		# Smart pop an item that isn't too close to its twin
		var d_type: int = pop_safe_dispenser(roster, chosen_pos, placed_positions, placed_types, min_same_type_dist_sq)
		
		map_data[chosen_pos.y * MAP_WIDTH + chosen_pos.x] = d_type
		placed_positions.append(chosen_pos)
		placed_types.append(d_type)
		
		available_cols[best_idx] = available_cols[available_cols.size() - 1]
		available_cols.pop_back()
		
	# Priority 2: Fallback to room walls
	if roster.size() > 0:
		var valid_walls: Array[Vector2i] = []
		for r in pool:
			var spawns: Array[Vector2i] = get_valid_spawns(r, false, 1, true)
			valid_walls.append_array(spawns)
			
		while roster.size() > 0 and valid_walls.size() > 0:
			var best_idx: int = get_furthest_candidate_index(valid_walls, placed_positions)
			var chosen_pos: Vector2i = valid_walls[best_idx]
			
			var d_type: int = pop_safe_dispenser(roster, chosen_pos, placed_positions, placed_types, min_same_type_dist_sq)
			
			map_data[chosen_pos.y * MAP_WIDTH + chosen_pos.x] = d_type
			placed_positions.append(chosen_pos)
			placed_types.append(d_type)
			
			valid_walls[best_idx] = valid_walls[valid_walls.size() - 1]
			valid_walls.pop_back()

# Helper: Executes max-min distance calculation for even distribution
func get_furthest_candidate_index(candidates: Array[Vector2i], placed: Array[Vector2i]) -> int:
	if placed.size() == 0:
		return randi() % candidates.size()
		
	var best_idx: int = -1
	var max_min_dist_sq: float = -1.0
	
	# For every candidate, find its distance to the *closest* placed entity
	for i in range(candidates.size()):
		var c: Vector2i = candidates[i]
		var min_dist_sq: float = 1e9 # Arbitrary huge number
		
		for p in placed:
			var d_sq: float = c.distance_squared_to(p)
			if d_sq < min_dist_sq:
				min_dist_sq = d_sq
				
		# We want the candidate whose closest neighbor is as far away as possible
		if min_dist_sq > max_min_dist_sq:
			max_min_dist_sq = min_dist_sq
			best_idx = i
			
	return best_idx

# Helper: Extracts a dispenser type from the roster that isn't too close to its twins
func pop_safe_dispenser(roster: Array[int], chosen_pos: Vector2i, placed_pos: Array[Vector2i], placed_types: Array[int], min_dist_sq: int) -> int:
	var chosen_idx: int = roster.size() - 1
	
	# Scan the roster backwards to find a valid, isolated candidate type
	for i in range(roster.size() - 1, -1, -1):
		var candidate: int = roster[i]
		var is_safe: bool = true
		
		# Check if this type exists nearby in the already placed list
		for p_idx in range(placed_pos.size()):
			if placed_types[p_idx] == candidate:
				if chosen_pos.distance_squared_to(placed_pos[p_idx]) < min_dist_sq:
					is_safe = false
					break
					
		if is_safe:
			chosen_idx = i
			break
			
	# If no safe type exists (map is tiny), gracefully fallback to the default pick
	var chosen_type: int = roster[chosen_idx]
	
	# O(1) array removal
	roster[chosen_idx] = roster[roster.size() - 1]
	roster.pop_back()
	
	return chosen_type

# UI Updates
func update_debug_ui() -> void:
	if not map_display: return
		
	# Use PackedStringArray to avoid massive memory reallocation during concatenation
	var final_text := PackedStringArray()
	
	for y in range(MAP_HEIGHT):
		var row_string := PackedStringArray()
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
				
				var char_str: String = "#"
				if is_vertical and is_horizontal: char_str = "+"
				elif is_vertical: char_str = "|"
				elif is_horizontal: char_str = "-"
				
				row_string.append("[color=#888888]" + char_str + "[/color]") # Gray walls
				
			elif tile == TILE_FLOOR: row_string.append("[color=#444444].[/color]") # Dark gray floor
			elif tile == TILE_DOOR: row_string.append("[color=#cd853f]X[/color]")  # Brown door
			elif tile == TILE_VOID: row_string.append(" ")
			elif tile == TILE_EXIT: row_string.append("[color=#ff00ff]>[/color]")  # Magenta exit
			elif tile == TILE_PLAYER: row_string.append("[color=#00ff00]@[/color]") # Green player
			elif tile == TILE_AMMO: row_string.append("[color=#ff4500]A[/color]")   # Orange-red ammo
			elif tile == TILE_JUICE: row_string.append("[color=#ff8c00]C[/color]")  # Orange juice
			elif tile == TILE_SIZZLE: row_string.append("[color=#00bfff]S[/color]") # Light blue sizzle
			elif tile == TILE_MALIBU: row_string.append("[color=#ff1493]M[/color]") # Pink malibu
			elif tile == TILE_GOLD: row_string.append("[color=#ffd700]$[/color]")   # Yellow gold

		# Join the row instantly, then add to final array
		final_text.append("".join(row_string))
		
	# Join all rows with linebreaks instantly
	map_display.text = "\n".join(final_text)
