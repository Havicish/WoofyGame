extends Control


@export var game_manager: Node
@export var multiplayer_manager: Node
var host_button: Button
var join_button: Button
var room_code_input: LineEdit


func _ready() -> void:
  host_button = $HostButton
  join_button = $JoinButton
  room_code_input = $RoomCodeInput

  host_button.pressed.connect(_on_host_button_pressed)
  join_button.pressed.connect(_on_join_button_pressed)

func _on_host_button_pressed() -> void:
  game_manager.in_main_menu = false
  multiplayer_manager.start_as_host()

func _on_join_button_pressed() -> void:
  var room_code := room_code_input.text.strip_edges()
  if room_code.is_empty():
    push_warning("Please enter a room code before joining.")
    room_code_input.text = ""
    room_code_input.placeholder_text = "Enter a room code"
    await get_tree().create_timer(2.0).timeout
    room_code_input.placeholder_text = "Room code"
    return

  join_button.disabled = true
  var joined: bool = await multiplayer_manager.start_as_client(room_code)
  join_button.disabled = false

  if joined:
    game_manager.in_main_menu = false
  else:
    room_code_input.text = ""
    room_code_input.placeholder_text = "Something went wrong"
    await get_tree().create_timer(2.0).timeout
    room_code_input.placeholder_text = "Room code"
