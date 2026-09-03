extends Sprite2D


@export var camera: Camera2D
@export var border: Sprite2D
@export var foot_step_node: Node2D
@export var game_manager: Node
@export var multiplayer_manager: Node
@export var colliders_node: Node2D
@export var clothes_color: Color = Color(1, 1, 1, 1)
@export var plr_class: String = "None"
@export var is_wolf: bool = false
@export var in_wolf_form: bool = false
@export var client_controlled: bool = true
@export var health: float = 100.0

var survivor_speed: float = 650.0
var wolf_speed: float = 800.0
var drag: float = 5000.0
var velocity: Vector2 = Vector2.ZERO
var move_direction: Vector2 = Vector2.ZERO

var smooth_to_position: Vector2 = Vector2.ZERO
var smooth_to_rotation: float = 0.0
var smooth_to_scale: Vector2 = Vector2.ONE

var step_timer: float = 0.0
var step_tilt: float = 0.24
var step_frequency: float = 4.0
var squash_strength: float = 0.18
var original_scale: Vector2 = Vector2.ONE
var last_rotation: float = 0.0

var camera_speed: float = 5.0

var clothes
var shadow


# Called when the node enters the scene obj for the first time.
func _ready() -> void:
  original_scale = scale
  clothes = get_node("Clothes")
  shadow = get_node("Shadow")

  clothes.modulate = clothes_color

  if multiplayer_manager:
    multiplayer_manager.subscribe_to_host_messages(func(_peer_id, message):
      if multiplayer_manager.is_client and message["type"] == "player-move" and game_manager and message["peer_id"] != multiplayer_manager.own_peer_id:
        var player_node = game_manager.get_node_or_null(str(message["peer_id"]))
        if player_node:
          player_node.smooth_to_position = message["position"]
          player_node.smooth_to_rotation = message["rotation"]
          player_node.smooth_to_scale = message["scale"]
          player_node.flip_h = message["flip_h"]
    )
    multiplayer_manager.subscribe_to_client_messages(func(_peer_id, message):
      if multiplayer_manager.is_host and message["type"] == "player-move" and message["peer_id"] != multiplayer_manager.own_peer_id and game_manager:
        var player_node = game_manager.get_node_or_null(str(message["peer_id"]))
        if player_node:
          player_node.smooth_to_position = message["position"]
          player_node.smooth_to_rotation = message["rotation"]
          player_node.smooth_to_scale = message["scale"]
          player_node.flip_h = message["flip_h"]

          for peer_id in game_manager.connected_peers:
            multiplayer_manager.send_to_client(peer_id, {
              "type": "player-move",
              "peer_id": message["peer_id"],
              "position": message["position"],
              "rotation": message["rotation"],
              "scale": message["scale"],
              "flip_h": message["flip_h"]
            })
    )
    multiplayer_manager.subscribe_to_started_hosting(func(_info):
      name = str(multiplayer_manager.own_peer_id)
    )
    multiplayer_manager.subscribe_to_join_room(func(_info):
      name = str(multiplayer_manager.own_peer_id)
    )

func _unhandled_input(event: InputEvent) -> void:
  if event is InputEventKey:
    if event.pressed:
      match event.keycode:
        KEY_W:
          move_direction.y += -1
        KEY_S:
          move_direction.y += 1
        KEY_A:
          move_direction.x += -1
        KEY_D:
          move_direction.x += 1
    else:
      match event.keycode:
        KEY_W:
          move_direction.y += 1
        KEY_S:
          move_direction.y += -1
        KEY_A:
          move_direction.x += 1
        KEY_D:
          move_direction.x += -1
  # controller
  if event is InputEventJoypadMotion:
    if event.axis == JOY_AXIS_LEFT_X or event.axis == JOY_AXIS_RIGHT_X:
      move_direction.x = event.axis_value
    elif event.axis == JOY_AXIS_LEFT_Y or event.axis == JOY_AXIS_RIGHT_Y:
      move_direction.y = event.axis_value


func update_non_client(delta: float) -> void:
  clothes.flip_h = flip_h
  shadow.flip_h = flip_h

  if rotation / step_tilt * 2 >= 0.95 and last_rotation / step_tilt * 2 < 0.95 and foot_step_node:
    foot_step_node.create_foot_print(preload("res://Sprites/Footstep.png"), position + Vector2(0, 8), Vector2(0.75, 0.75), 7.5)
  if rotation / step_tilt * 2 <= -0.95 and last_rotation / step_tilt * 2 > -0.95 and foot_step_node:
    foot_step_node.create_foot_print(preload("res://Sprites/Footstep.png"), position + Vector2(0, 8), Vector2(0.75, 0.75), 7.5)
  last_rotation = rotation

  if in_wolf_form:
    clothes.visible = false
    texture = preload("res://Sprites/Woof.png")
  else:
    clothes.visible = true
    texture = preload("res://Sprites/PlayerTest (1).png")

  if health <= 0.0:
    rotation = PI / 2
    modulate = Color(1, 0.5, 0.5, 1)
    var init_size = scale
    scale = Vector2(init_size.x * 0.75, init_size.y)

  if multiplayer_manager and multiplayer_manager.own_peer_id != int(name):
    position = position.lerp(smooth_to_position, min(30.0 * delta, 1.0))
    rotation = lerp(rotation, smooth_to_rotation, min(48.0 * delta, 1.0))
    scale = scale.lerp(smooth_to_scale, min(48.0 * delta, 1.0))


func update_multiplayer_state() -> void:
  if multiplayer_manager and multiplayer_manager.is_connected:
    if multiplayer_manager.is_client:
      multiplayer_manager.send_to_host({
        "type": "player-move",
        "peer_id": multiplayer_manager.own_peer_id,
        "position": position,
        "rotation": rotation,
        "scale": scale,
        "flip_h": flip_h
      })
    if multiplayer_manager.is_host:
      multiplayer_manager.send_to_all_clients({
        "type": "player-move",
        "peer_id": multiplayer_manager.own_peer_id,
        "position": position,
        "rotation": rotation,
        "scale": scale,
        "flip_h": flip_h
      })


func update_collisions() -> void:
  for other_plr in game_manager.get_children():
    if other_plr is Sprite2D and other_plr != self:
      var distance: float = position.distance_to(other_plr.position)
      var min_distance: float = 16.0
      if distance < min_distance:
        var overlap: float = min_distance - distance
        var direction: Vector2 = (position - other_plr.position).normalized()
        velocity += direction * overlap * 2.0

  for obj in colliders_node.get_children():
    if obj is Sprite2D:
      var obj_pos = obj.position + (Vector2.ZERO if not obj.has_meta("CollisionOffset") else obj.get_meta("CollisionOffset"))
      var distance: float = position.distance_to(obj_pos)
      var min_distance: float = obj.get_meta("Size") if obj.has_meta("Size") else 16.0
      if distance < min_distance:
        var overlap: float = min_distance - distance
        var direction: Vector2 = (position - obj_pos).normalized()
        velocity += direction * overlap * 2.0


func _physics_process(delta: float) -> void:
  update_non_client(delta)

  if not client_controlled:
    return

  update_multiplayer_state()

  update_collisions()

  move_direction = Vector2.ZERO

  if Input.is_key_pressed(KEY_W):
    move_direction.y -= 1
  if Input.is_key_pressed(KEY_S):
    move_direction.y += 1
  if Input.is_key_pressed(KEY_A):
    move_direction.x -= 1
  if Input.is_key_pressed(KEY_D):
    move_direction.x += 1

  move_direction = move_direction.normalized()

  var speed: float = wolf_speed if in_wolf_form else survivor_speed
  velocity += move_direction * speed * delta
  velocity /= pow(1 + drag, delta)
  position += velocity * delta

  if move_direction.length() > 0.0:
    step_timer += delta * step_frequency * clamp(velocity.length() / max(speed, 1.0), 0.5, 1.0)

    var step_wave: float = sin(step_timer * TAU)
    var target_rotation: float = step_wave * step_tilt
    rotation = lerp(rotation, target_rotation, 12.0 * delta)

    var squash_amount: float = 1.0 - abs(step_wave)
    var target_scale_x: float = original_scale.x * (1.0 + squash_amount * squash_strength)
    var target_scale_y: float = original_scale.y * (1.0 - squash_amount * (squash_strength * 1.6))
    scale.x = lerp(scale.x, target_scale_x, 12.0 * delta)
    scale.y = lerp(scale.y, target_scale_y, 12.0 * delta)
  else:
    step_timer = 0.0
    rotation = lerp(rotation, 0.0, 10.0 * delta)
    scale.x = lerp(scale.x, original_scale.x, 12.0 * delta)
    scale.y = lerp(scale.y, original_scale.y, 12.0 * delta)

  rotation /= pow(1 + drag, delta)

  if move_direction.x > 0.0:
    flip_h = false
  elif move_direction.x < 0.0:
    flip_h = true

  clothes.flip_h = flip_h
  shadow.flip_h = flip_h

  clothes.modulate = clothes_color

  if camera and border:
    var border_size: Vector2 = border.texture.get_size() * border.scale
    camera.position = camera.position.lerp(position, camera_speed * delta)
  # keep camera within the border
    var camera_viewport_size: Vector2 = camera.get_viewport_rect().size
    camera_viewport_size /= camera.zoom
    camera.position.x = clamp(camera.position.x, camera_viewport_size.x / 2, border_size.x - camera_viewport_size.x / 2)
    camera.position.y = clamp(camera.position.y, camera_viewport_size.y / 2, border_size.y - camera_viewport_size.y / 2)

    position.x = clamp(position.x, 0, border_size.x)
    position.y = clamp(position.y, 0, border_size.y)
