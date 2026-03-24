extends Node

const MAP_WIDTH: int = 51
const MAP_HEIGHT: int = 51

const TILE_WALL: int = 35   # ASCII for '#'
const TILE_FLOOR: int = 46  # ASCII for '.'
const TILE_DOOR: int = 43   # ASCII for '+'
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
	initialize_map()
	generate_rooms(151, 15)
	generate_mazes()
	connect_regions()
	remove_dead_ends()
	remove_redundant_walls()
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

# Phase 4: Room Connectivity
func connect_regions() -> void:
	for room in rooms:
		var top_doors: Array[Vector2i] = []
		var bottom_doors: Array[Vector2i] = []
		var left_doors: Array[Vector2i] = []
		var right_doors: Array[Vector2i] = []
		
		var top_has_door: bool = false
		var bottom_has_door: bool = false
		var left_has_door: bool = false
		var right_has_door: bool = false
		
		for x in range(room.position.x, room.position.x + room.size.x):
			var top_y: int = room.position.y - 1
			var bottom_y: int = room.position.y + room.size.y
			
			if get_tile(x, top_y) == TILE_DOOR: top_has_door = true
			elif top_y - 1 > 0 and get_tile(x, top_y - 1) == TILE_FLOOR:
				top_doors.append(Vector2i(x, top_y))
				
			if get_tile(x, bottom_y) == TILE_DOOR: bottom_has_door = true
			elif bottom_y + 1 < MAP_HEIGHT - 1 and get_tile(x, bottom_y + 1) == TILE_FLOOR:
				bottom_doors.append(Vector2i(x, bottom_y))
				
		for y in range(room.position.y, room.position.y + room.size.y):
			var left_x: int = room.position.x - 1
			var right_x: int = room.position.x + room.size.x
			
			if get_tile(left_x, y) == TILE_DOOR: left_has_door = true
			elif left_x - 1 > 0 and get_tile(left_x - 1, y) == TILE_FLOOR:
				left_doors.append(Vector2i(left_x, y))
				
			if get_tile(right_x, y) == TILE_DOOR: right_has_door = true
			elif right_x + 1 < MAP_WIDTH - 1 and get_tile(right_x + 1, y) == TILE_FLOOR:
				right_doors.append(Vector2i(right_x, y))
		
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

func has_adjacent_door(pos: Vector2i) -> bool:
	for dir in NEIGHBORS:
		if get_tile(pos.x + dir.x, pos.y + dir.y) == TILE_DOOR:
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
