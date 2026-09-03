extends Control


@export var game_manager: Node
@export var multiplayer_manager: Node
@export var player_card_tscn: PackedScene

@onready var title_center: CenterContainer = $CenterContainer
@onready var title_label: Label = title_center.get_node("Title")
@onready var title_shadow: Label = title_label.get_node("Shadow")
@onready var ready_button: Button = $ReadyButton
@onready var ready_label: Label = ready_button.get_node("Label")
@onready var name_input: LineEdit = $NameInput

var player_cards: Array = []


func _set_player_card_host_state(player_card: Node, is_host_card: bool) -> void:
  player_card.set_meta("is_host", is_host_card)
  player_card.get_node("Ready").get_node("Ready").get_node("Host").visible = is_host_card
  if is_host_card:
    player_card.get_node("Ready").get_node("Ready").get_node("Ready").visible = false
    player_card.get_node("Ready").get_node("Ready").get_node("NotReady").visible = false


func _ready() -> void:
  multiplayer_manager.subscribe_to_started_hosting(func(_info):
    var new_player_card = player_card_tscn.instantiate()
    new_player_card.name = str(multiplayer_manager.own_peer_id)
    new_player_card.get_node("VBoxContainer").get_node("PlrName").text = "Player %s" % multiplayer_manager.own_peer_id
    _set_player_card_host_state(new_player_card, true)
    player_cards.append(new_player_card)
    get_node("PlayerList").get_node("ScrollContainer").get_node("VBoxContainer").add_child(new_player_card)
  )

  ready_button.pressed.connect(_on_ready_button_pressed)
  name_input.text_changed.connect(_on_name_input_text_changed)

  multiplayer_manager.subscribe_to_host_messages(func(_peer_id, message):
    if multiplayer_manager.is_client and message["type"] == "game-started":
      game_manager.in_lobby_menu = false
      game_manager.main_menu.visible = false
      game_manager.game_hud.visible = true
    if multiplayer_manager.is_client and message["type"] == "player-join":
      var joined_peer_id := int(message.get("joined_peer_id", 0))
      var is_host_card := bool(message.get("is_host", joined_peer_id == multiplayer_manager.host_peer_id))
      var player_card = get_node("PlayerList").get_node("ScrollContainer").get_node("VBoxContainer").get_node_or_null(str(joined_peer_id))
      if not player_card:
        var new_player_card = player_card_tscn.instantiate()
        new_player_card.name = str(joined_peer_id)
        new_player_card.get_node("VBoxContainer").get_node("PlrName").text = "Player %s" % joined_peer_id
        _set_player_card_host_state(new_player_card, is_host_card)
        player_cards.append(new_player_card)
        get_node("PlayerList").get_node("ScrollContainer").get_node("VBoxContainer").add_child(new_player_card)
      else:
        if bool(player_card.get_meta("is_host", false)):
          is_host_card = true
        _set_player_card_host_state(player_card, is_host_card)
    if multiplayer_manager.is_client and message["type"] == "player-leave":
      var player_card = get_node("PlayerList").get_node("ScrollContainer").get_node("VBoxContainer").get_node_or_null(str(message["left_peer_id"]))
      if player_card:
        player_card.queue_free()
        player_cards.erase(player_card)
    if multiplayer_manager.is_client and message["type"] == "player-ready":
      var player_card = get_node("PlayerList").get_node("ScrollContainer").get_node("VBoxContainer").get_node_or_null(str(message["peer_id"]))
      if player_card:
        player_card.get_node("Ready").get_node("Ready").get_node("Ready").visible = true
        player_card.get_node("Ready").get_node("Ready").get_node("NotReady").visible = false
        if player_card.get_meta("is_host"):
          player_card.get_node("Ready").get_node("Ready").get_node("Ready").visible = false
          player_card.get_node("Ready").get_node("Ready").get_node("NotReady").visible = false
          player_card.get_node("Ready").get_node("Ready").get_node("Host").visible = true
    if multiplayer_manager.is_client and message["type"] == "player-unready":
      var player_card = get_node("PlayerList").get_node("ScrollContainer").get_node("VBoxContainer").get_node_or_null(str(message["peer_id"]))
      if player_card and not player_card.get_meta("is_host"):
        player_card.get_node("Ready").get_node("Ready").get_node("Ready").visible = false
        player_card.get_node("Ready").get_node("Ready").get_node("NotReady").visible = true
        if player_card.get_meta("is_host"):
          player_card.get_node("Ready").get_node("Ready").get_node("Ready").visible = false
          player_card.get_node("Ready").get_node("Ready").get_node("NotReady").visible = false
          player_card.get_node("Ready").get_node("Ready").get_node("Host").visible = true
    if multiplayer_manager.is_client and message["type"] == "player-name-change":
      var player_card = get_node("PlayerList").get_node("ScrollContainer").get_node("VBoxContainer").get_node_or_null(str(message["peer_id"]))
      if player_card:
        if message["new_name"].strip_edges() == "":
          player_card.get_node("VBoxContainer").get_node("PlrName").text = "Player %s" % message["peer_id"]
        else:
          player_card.get_node("VBoxContainer").get_node("PlrName").text = message["new_name"]
    if multiplayer_manager.is_client and message["type"] == "game-started":
      game_manager.in_lobby_menu = false
      game_manager.main_menu.visible = false
      game_manager.game_hud.visible = true
      game_manager.start_game(false)
  )

  multiplayer_manager.subscribe_to_client_messages(func(_peer_id, message):
    if multiplayer_manager.is_host and message["type"] == "player-ready":
      var player_card = get_node("PlayerList").get_node("ScrollContainer").get_node("VBoxContainer").get_node_or_null(str(message["peer_id"]))
      if player_card:
        player_card.get_node("Ready").get_node("Ready").get_node("Ready").visible = true
        player_card.get_node("Ready").get_node("Ready").get_node("NotReady").visible = false
      multiplayer_manager.send_to_all_clients({
        "type": "player-ready",
        "peer_id": message["peer_id"]
      }, true)
    elif multiplayer_manager.is_host and message["type"] == "player-unready":
      var player_card = get_node("PlayerList").get_node("ScrollContainer").get_node("VBoxContainer").get_node_or_null(str(message["peer_id"]))
      if player_card:
        player_card.get_node("Ready").get_node("Ready").get_node("Ready").visible = false
        player_card.get_node("Ready").get_node("Ready").get_node("NotReady").visible = true
      multiplayer_manager.send_to_all_clients({
        "type": "player-unready",
        "peer_id": message["peer_id"]
      }, true)
    elif multiplayer_manager.is_host and message["type"] == "player-name-change":
      var player_card = get_node("PlayerList").get_node("ScrollContainer").get_node("VBoxContainer").get_node_or_null(str(message["peer_id"]))
      if player_card:
        if message["new_name"].strip_edges() == "":
          player_card.get_node("VBoxContainer").get_node("PlrName").text = "Player %s" % message["peer_id"]
        else:
          player_card.get_node("VBoxContainer").get_node("PlrName").text = message["new_name"]
      multiplayer_manager.send_to_all_clients({
        "type": "player-name-change",
        "peer_id": message["peer_id"],
        "new_name": message["new_name"]
      }, true)
  )

  multiplayer_manager.subscribe_to_peer_join_room(func(info):
    var new_player_card = player_card_tscn.instantiate()
    new_player_card.name = str(info.joined_peer_id)
    new_player_card.get_node("VBoxContainer").get_node("PlrName").text = "Player %s" % info.joined_peer_id
    player_cards.append(new_player_card)
    get_node("PlayerList").get_node("ScrollContainer").get_node("VBoxContainer").add_child(new_player_card)

    multiplayer_manager.send_to_all_clients({
      "type": "player-join",
      "joined_peer_id": info.joined_peer_id,
      "is_host": false
    }, true)

    for card in player_cards:
      var card_peer_id := int(str(card.name))
      multiplayer_manager.send_to_client(info.joined_peer_id, {
        "type": "player-join",
        "joined_peer_id": card_peer_id,
        "is_host": bool(card.get_meta("is_host", false))
      })
  )

  multiplayer_manager.subscribe_to_peer_leave_room(func(info):
    var player_card = get_node("PlayerList").get_node("ScrollContainer").get_node("VBoxContainer").get_node_or_null(str(info.left_peer_id))
    if player_card:
      player_card.queue_free()
      player_cards.erase(player_card)
    
    multiplayer_manager.send_to_all_clients({
      "type": "player-leave",
      "left_peer_id": info.left_peer_id
    }, true)
  )


func _on_name_input_text_changed(new_text: String) -> void:
  if multiplayer_manager.is_host:
    multiplayer_manager.send_to_all_clients({
      "type": "player-name-change",
      "peer_id": multiplayer_manager.own_peer_id,
      "new_name": new_text,
      "is_host": true
    }, true)
  else:
    multiplayer_manager.send_to_host({
      "type": "player-name-change",
      "peer_id": multiplayer_manager.own_peer_id,
      "new_name": new_text
    }, true)
  var own_player_card = get_node("PlayerList").get_node("ScrollContainer").get_node("VBoxContainer").get_node_or_null(str(multiplayer_manager.own_peer_id))
  if own_player_card:
    if new_text.strip_edges() == "":
      own_player_card.get_node("VBoxContainer").get_node("PlrName").text = "Player %s" % multiplayer_manager.own_peer_id
    else:
      own_player_card.get_node("VBoxContainer").get_node("PlrName").text = new_text


func _on_ready_button_pressed() -> void:
  if multiplayer_manager.is_host:
    game_manager.in_lobby_menu = false
    game_manager.main_menu.visible = false
    game_manager.game_hud.visible = true

    multiplayer_manager.send_to_all_clients({
      "type": "game-started"
    }, true)

    game_manager.start_game(true)
  else:
    if ready_label.text == "ready":
      ready_label.text = "unready"

      multiplayer_manager.send_to_host({
        "type": "player-ready",
        "peer_id": multiplayer_manager.own_peer_id
      }, true)
    else:
      ready_label.text = "ready"

      multiplayer_manager.send_to_host({
        "type": "player-unready",
        "peer_id": multiplayer_manager.own_peer_id
      }, true)


func _process(_delta: float) -> void:
  if multiplayer_manager.is_host:
    ready_label.text = "Start Game"

  if multiplayer_manager.current_room_code and title_label:
    title_label.text = "Lobby | Code: %s" % multiplayer_manager.current_room_code
    title_shadow.text = title_label.text
  elif title_label:
    title_label.text = "Lobby | Code: ??????"
    title_shadow.text = title_label.text
