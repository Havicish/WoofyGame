extends Node


@export var main_menu: Control
@export var game_hud: Control
@export var multiplayer_manager: Node
@export var foot_step_node: Node2D
@export var player_tscn: PackedScene
@export var time: float = 0.0
@export var in_main_menu: bool = true

var connected_peers: Array = []


func _ready() -> void:
  main_menu.visible = in_main_menu
  game_hud.visible = not in_main_menu

  multiplayer_manager.subscribe_to_started_hosting(func(_info):
    connected_peers.append(multiplayer_manager.own_peer_id)
  )

  multiplayer_manager.subscribe_to_peer_join_room(func(info):
    connected_peers.append(info.joined_peer_id)
    var new_player = player_tscn.instantiate()
    new_player.name = str(info.joined_peer_id)
    new_player.client_controlled = false
    new_player.game_manager = self
    new_player.multiplayer_manager = multiplayer_manager
    new_player.foot_step_node = foot_step_node
    add_child(new_player)

    multiplayer_manager.send_to_all_clients({
      "type": "player-join",
      "joined_peer_id": info.joined_peer_id,
      "position": new_player.position,
      "rotation": new_player.rotation,
      "scale": new_player.scale,
      "flip_h": new_player.flip_h
    })

    for peer_id in connected_peers:
      multiplayer_manager.send_to_all_clients({
        "type": "player-join",
        "joined_peer_id": peer_id,
        "position": new_player.position,
        "rotation": new_player.rotation,
        "scale": new_player.scale,
        "flip_h": new_player.flip_h
      })
  )

  multiplayer_manager.subscribe_to_peer_leave_room(func(info):
    connected_peers.erase(info.left_peer_id)
    var player_node = get_node_or_null(str(info.left_peer_id))
    if player_node:
      player_node.queue_free()
  )

  multiplayer_manager.subscribe_to_host_messages(func(_peer_id, message):
    if multiplayer_manager.is_client and message["type"] == "player-join" and message["joined_peer_id"] != multiplayer_manager.own_peer_id:
      var new_player = player_tscn.instantiate()
      new_player.name = str(message["joined_peer_id"])
      new_player.client_controlled = false
      new_player.position = message["position"]
      new_player.rotation = message["rotation"]
      new_player.scale = message["scale"]
      new_player.flip_h = message["flip_h"]
      new_player.game_manager = self
      new_player.multiplayer_manager = multiplayer_manager
      new_player.foot_step_node = foot_step_node
      new_player.name = str(message["joined_peer_id"])
      new_player.client_controlled = false
      add_child(new_player)
  )

  # multiplayer_manager.subscribe_to_client_messages(func(_peer_id, message):
  #   print("Host received message from client: ", message)
  # )

func _process(_delta: float) -> void:
  main_menu.visible = in_main_menu
  game_hud.visible = not in_main_menu
  game_hud.get_node("RoomCode").text = "Room code: " + multiplayer_manager.current_room_code
  game_hud.get_node("RoomCode").get_node("Shadow").text = "Room code: " + multiplayer_manager.current_room_code
