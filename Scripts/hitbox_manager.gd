class_name HitboxManager

extends Node

@export var multiplayer_manager: Node

var hurtboxes: Array = []
var hitboxes: Array = []


class Hurtbox:
  var parent: Node
  var position_offset: Vector2
  var size: float
  var should_show: bool = true

  func _init(_parent: Node, _position: Vector2, _size: float, _should_show: bool = true) -> void:
    parent = _parent
    position_offset = _position
    size = _size
    should_show = _should_show

  func get_position() -> Vector2:
    if parent == null:
      return position_offset
    return parent.global_position + position_offset


class Hitbox:
  var position: Vector2
  var size: float
  var start_time: float = Time.get_ticks_msec() / 1000.0
  var should_show: bool = true
  var on_hit_callback: Callable = Callable()

  func _init(_position: Vector2, _size: float, _callback: Callable = Callable(), _should_show: bool = true) -> void:
    position = _position
    size = _size
    on_hit_callback = _callback
    should_show = _should_show

  func check_collision_against(hurtboxes: Array) -> bool:
    for hurtbox in hurtboxes:
      var hurtbox_pos: Vector2 = hurtbox.get_position()
      var distance: float = position.distance_to(hurtbox_pos)
      if distance < size + hurtbox.size:
        return true
    return false

  func calculate_hit(hurtboxes: Array, multiplayer_manager: Node) -> void:
    var client_thinks_it_hit: bool = check_collision_against(hurtboxes)

    if multiplayer_manager != null and multiplayer_manager.is_client:
      multiplayer_manager.send_to_host({
        "type": "hitbox-check",
        "position": position,
        "size": size,
        "client_thinks_it_hit": client_thinks_it_hit
      }, true)

    if not multiplayer_manager or not multiplayer_manager.is_client:
      if client_thinks_it_hit and on_hit_callback.is_valid():
        on_hit_callback.call()


func _ready() -> void:
  if multiplayer_manager == null:
    return

  multiplayer_manager.subscribe_to_client_messages(func(_peer_id, message):
    if multiplayer_manager.is_host and message["type"] == "hitbox-check":
      var hitbox_position: Vector2 = message["position"]
      var hitbox_size: float = message["size"]
      var client_thinks_it_hit: bool = bool(message.get("client_thinks_it_hit", false))

      var server_thinks_it_hit: bool = false
      for hurtbox in hurtboxes:
        var hurtbox_position: Vector2 = hurtbox.get_position()
        var distance: float = hitbox_position.distance_to(hurtbox_position)
        if distance < hitbox_size + hurtbox.size:
          server_thinks_it_hit = true
          break

      if client_thinks_it_hit and server_thinks_it_hit:
        for hitbox in hitboxes:
          if hitbox.check_collision_against(hurtboxes):
            if hitbox.on_hit_callback.is_valid():
              hitbox.on_hit_callback.call()
  )

  multiplayer_manager.subscribe_to_host_messages(func(_peer_id, message):
    if multiplayer_manager.is_client and message["type"] == "hitbox-result":
      if bool(message.get("did_hit", false)):
        for hitbox in hitboxes:
          if hitbox.on_hit_callback.is_valid():
            hitbox.on_hit_callback.call()
  )


func create_hurtbox(parent: Node, position_offset: Vector2, size: float) -> void:
  var new_hurtbox = Hurtbox.new(parent, position_offset, size)
  hurtboxes.append(new_hurtbox)


func create_hitbox(position: Vector2, size: float, on_hit_callback: Callable) -> void:
  var new_hitbox = Hitbox.new(position, size, on_hit_callback)
  hitboxes.append(new_hitbox)
  new_hitbox.calculate_hit(hurtboxes, multiplayer_manager)


func resolve_hitbox_overlap() -> void:
  for hitbox in hitboxes:
    if hitbox.check_collision_against(hurtboxes) and hitbox.on_hit_callback.is_valid():
      hitbox.on_hit_callback.call()
