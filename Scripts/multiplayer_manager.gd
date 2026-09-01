extends Node


var is_host: bool = false
var is_client: bool = false
var peer: WebRTCMultiplayerPeer = WebRTCMultiplayerPeer.new()
var own_peer_id: int = 0
var host_peer_id: int = 0
var current_room_code: String = ""

@export var signaling_url: String = "ws://127.0.0.1:8080"
@export var debug_logs_enabled: bool = true

var _socket: WebSocketPeer = WebSocketPeer.new()
var _signal_connected: bool = false
var _pending_role: String = ""
var _pending_room_code: String = ""
var _pending_join_after_check: bool = false
var _join_result_ready: bool = false
var _join_result_success: bool = false

@export var join_timeout_seconds: float = 8.0

# peer_id -> WebRTCPeerConnection
var _webrtc_peers: Dictionary = {}

# peer_id -> Array[Dictionary{route: String, payload: Dictionary}]
var _pending_peer_messages: Dictionary = {}

var _client_message_subscribers: Array[Callable] = []
var _host_message_subscribers: Array[Callable] = []
var _started_hosting_subscribers: Array[Callable] = []
var _join_room_subscribers: Array[Callable] = []
var _peer_join_room_subscribers: Array[Callable] = []
var _peer_leave_room_subscribers: Array[Callable] = []


func _ready() -> void:
  set_process(true)
  _debug_log("ready", {
    "signaling_url": signaling_url
  })


func _process(_delta: float) -> void:
  if _signal_connected:
    _socket.poll()

    if _socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
      _signal_connected = false

    while _socket.get_available_packet_count() > 0:
      var packet: String = _socket.get_packet().get_string_from_utf8()
      _handle_server_message(packet)

  for remote_peer_id in _webrtc_peers.keys():
    var rtc: WebRTCPeerConnection = _webrtc_peers[remote_peer_id]
    rtc.poll()

  _flush_pending_peer_messages()


func start_as_host():
  is_host = true
  is_client = false
  _pending_role = "host"
  _pending_room_code = ""
  _debug_log("start_as_host", {
    "own_peer_id": own_peer_id
  })
  if not _connect_signaling():
    _debug_log("start_as_host_connect_failed")
    return

  _send_pending_role_handshake()

func start_as_client(room_code: String) -> bool:
  var normalized_room_code := room_code.strip_edges().to_upper()
  if normalized_room_code.is_empty():
    _debug_log("start_as_client_empty_code")
    push_warning("Join failed: room code is empty.")
    return false

  _join_result_ready = false
  _join_result_success = false

  is_client = true
  is_host = false
  _pending_role = "client"
  _pending_room_code = normalized_room_code
  _pending_join_after_check = true
  _debug_log("start_as_client", {
    "room_code": normalized_room_code,
    "own_peer_id": own_peer_id
  })

  var connected := _connect_signaling()
  if not connected:
    _debug_log("start_as_client_connect_failed")
    _complete_join_attempt(false, "Join failed: could not connect to signaling server.")
    return false

  _send_pending_role_handshake()

  var timeout_timer := get_tree().create_timer(join_timeout_seconds)

  while not _join_result_ready and timeout_timer.time_left > 0.0:
    await get_tree().process_frame

  if not _join_result_ready:
    _complete_join_attempt(false, "Join failed: timed out waiting for server response.")

  return _join_result_success


func subscribe_to_client_messages(callback: Callable) -> void:
  _client_message_subscribers.append(callback)
  _debug_log("subscribed_client_messages", {
    "count": _client_message_subscribers.size()
  })


func subscribe_to_host_messages(callback: Callable) -> void:
  _host_message_subscribers.append(callback)
  _debug_log("subscribed_host_messages", {
    "count": _host_message_subscribers.size()
  })


func subscribe_to_all_clients_messages(callback: Callable) -> void:
  # Backward compatibility alias: host broadcasts are now part of host messages.
  _host_message_subscribers.append(callback)
  _debug_log("subscribed_all_clients_alias", {
    "host_sub_count": _host_message_subscribers.size()
  })


func subscribe_to_started_hosting(callback: Callable) -> void:
  _started_hosting_subscribers.append(callback)
  _debug_log("subscribed_started_hosting", {
    "count": _started_hosting_subscribers.size()
  })


func subscribe_to_join_room(callback: Callable) -> void:
  _join_room_subscribers.append(callback)


func subscribe_to_peer_join_room(callback: Callable) -> void:
  _peer_join_room_subscribers.append(callback)


func subscribe_to_peer_leave_room(callback: Callable) -> void:
  _peer_leave_room_subscribers.append(callback)


func send_to_host(payload: Dictionary) -> bool:
  if own_peer_id == 0 or not _signal_connected:
    _debug_log("send_to_host_blocked", {
      "reason": "not_ready",
      "own_peer_id": own_peer_id,
      "signal_connected": _signal_connected
    })
    return false

  if is_host:
    _debug_log("send_to_host_blocked", {
      "reason": "called_from_host"
    })
    return false

  if host_peer_id == 0 or not _webrtc_peers.has(host_peer_id):
    _debug_log("send_to_host_blocked", {
      "reason": "host_not_registered",
      "host_peer_id": host_peer_id,
      "known_webrtc_peers": _webrtc_peers.keys()
    })
    return false

  if not _has_mesh_peer(host_peer_id):
    _debug_log("send_to_host_blocked", {
      "reason": "host_missing_in_mesh",
      "host_peer_id": host_peer_id
    })
    _drop_stale_peer_reference(host_peer_id)
    return false

  _send_or_queue_peer_message(host_peer_id, "to_host", payload)
  _debug_log("send_to_host_accepted", {
    "host_peer_id": host_peer_id,
    "payload_type": str(payload.get("type", ""))
  })
  return true


func send_to_client(client_peer_id: int, payload: Dictionary) -> bool:
  if own_peer_id == 0 or not _signal_connected:
    _debug_log("send_to_client_blocked", {
      "reason": "not_ready",
      "target_peer_id": client_peer_id
    })
    return false

  if not is_host:
    _debug_log("send_to_client_blocked", {
      "reason": "caller_not_host",
      "target_peer_id": client_peer_id
    })
    return false

  if client_peer_id == own_peer_id or not _webrtc_peers.has(client_peer_id):
    _debug_log("send_to_client_blocked", {
      "reason": "target_not_registered",
      "target_peer_id": client_peer_id,
      "known_webrtc_peers": _webrtc_peers.keys()
    })
    return false

  if not _has_mesh_peer(client_peer_id):
    _debug_log("send_to_client_blocked", {
      "reason": "target_missing_in_mesh",
      "target_peer_id": client_peer_id
    })
    _drop_stale_peer_reference(client_peer_id)
    return false

  _send_or_queue_peer_message(client_peer_id, "to_client", payload)
  _debug_log("send_to_client_accepted", {
    "target_peer_id": client_peer_id,
    "payload_type": str(payload.get("type", ""))
  })
  return true


func send_to_all_clients(payload: Dictionary) -> bool:
  if own_peer_id == 0 or not _signal_connected:
    _debug_log("send_to_all_clients_blocked", {
      "reason": "not_ready",
      "own_peer_id": own_peer_id,
      "signal_connected": _signal_connected,
      "payload_type": str(payload.get("type", ""))
    })
    return false

  if not is_host:
    _debug_log("send_to_all_clients_blocked", {
      "reason": "caller_not_host",
      "payload_type": str(payload.get("type", ""))
    })
    return false

  var sent_any := false
  var stale_peer_ids: Array[int] = []
  for remote_peer_id in _webrtc_peers.keys():
    var target_peer_id := int(remote_peer_id)
    if target_peer_id == own_peer_id:
      continue

    if not _has_mesh_peer(target_peer_id):
      _debug_log("send_to_all_clients_skip", {
        "reason": "target_missing_in_mesh",
        "target_peer_id": target_peer_id
      })
      stale_peer_ids.append(target_peer_id)
      continue

    _send_or_queue_peer_message(target_peer_id, "to_client", payload)
    sent_any = true

  for stale_id in stale_peer_ids:
    _drop_stale_peer_reference(stale_id)

  _debug_log("send_to_all_clients_done", {
    "sent_any": sent_any,
    "targets": _webrtc_peers.keys(),
    "payload_type": str(payload.get("type", ""))
  })

  return sent_any


func _is_multiplayer_connected() -> bool:
  if multiplayer.multiplayer_peer == null:
    return false

  return multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _has_mesh_peer(remote_peer_id: int) -> bool:
  if peer == null:
    return false

  if peer.has_method("has_peer"):
    return bool(peer.call("has_peer", remote_peer_id))

  return _webrtc_peers.has(remote_peer_id)


func _is_rpc_target_available(remote_peer_id: int) -> bool:
  if multiplayer.multiplayer_peer == null:
    return false

  if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
    return false

  var known_scene_peers: PackedInt32Array = multiplayer.get_peers()
  return known_scene_peers.has(remote_peer_id)


func _drop_stale_peer_reference(remote_peer_id: int) -> void:
  if not _webrtc_peers.has(remote_peer_id):
    return

  var rtc: WebRTCPeerConnection = _webrtc_peers[remote_peer_id]
  rtc.close()
  _webrtc_peers.erase(remote_peer_id)
  _pending_peer_messages.erase(remote_peer_id)
  _debug_log("dropped_stale_peer", {
    "peer_id": remote_peer_id
  })


func _send_or_queue_peer_message(target_peer_id: int, route: String, payload: Dictionary) -> void:
  if _is_peer_connected(target_peer_id):
    _debug_log("send_immediate", {
      "target_peer_id": target_peer_id,
      "route": route,
      "payload_type": str(payload.get("type", ""))
    })
    if _send_routed_peer_message(target_peer_id, route, payload):
      return

  if not _pending_peer_messages.has(target_peer_id):
    _pending_peer_messages[target_peer_id] = []

  var queue: Array = _pending_peer_messages[target_peer_id]
  queue.append({
    "route": route,
    "payload": payload
  })
  _pending_peer_messages[target_peer_id] = queue
  _debug_log("message_queued", {
    "target_peer_id": target_peer_id,
    "route": route,
    "payload_type": str(payload.get("type", "")),
    "queue_size": queue.size(),
    "connection_state": _get_peer_connection_state_name(target_peer_id)
  })


func _send_routed_peer_message(target_peer_id: int, route: String, payload: Dictionary) -> bool:
  if not _has_mesh_peer(target_peer_id):
    _debug_log("send_routed_dropped", {
      "reason": "target_missing_in_mesh",
      "target_peer_id": target_peer_id,
      "route": route,
      "payload_type": str(payload.get("type", ""))
    })
    _drop_stale_peer_reference(target_peer_id)
    return false

  if not _is_rpc_target_available(target_peer_id):
    _debug_log("send_routed_deferred", {
      "reason": "target_missing_in_scene_multiplayer",
      "target_peer_id": target_peer_id,
      "route": route,
      "payload_type": str(payload.get("type", ""))
    })
    return false

  _debug_log("send_routed", {
    "target_peer_id": target_peer_id,
    "route": route,
    "payload_type": str(payload.get("type", ""))
  })
  if route == "to_host":
    _rpc_receive_from_client.rpc_id(target_peer_id, payload)
  else:
    _rpc_receive_from_host.rpc_id(target_peer_id, payload)

  return true


func _is_peer_connected(remote_peer_id: int) -> bool:
  if not _webrtc_peers.has(remote_peer_id):
    return false

  var rtc: WebRTCPeerConnection = _webrtc_peers[remote_peer_id]
  return rtc.get_connection_state() == WebRTCPeerConnection.STATE_CONNECTED and _is_rpc_target_available(remote_peer_id)


func _flush_pending_peer_messages() -> void:
  if _pending_peer_messages.is_empty():
    return

  var peer_ids: Array = _pending_peer_messages.keys()
  for raw_peer_id in peer_ids:
    var peer_id := int(raw_peer_id)

    if not _webrtc_peers.has(peer_id):
      _debug_log("flush_drop_missing_peer", {
        "peer_id": peer_id
      })
      _pending_peer_messages.erase(peer_id)
      continue

    if not _has_mesh_peer(peer_id):
      _debug_log("flush_drop_missing_mesh_peer", {
        "peer_id": peer_id
      })
      _drop_stale_peer_reference(peer_id)
      continue

    if not _is_peer_connected(peer_id):
      continue

    var queue: Array = _pending_peer_messages.get(peer_id, [])
    _debug_log("flush_sending_queue", {
      "peer_id": peer_id,
      "queue_size": queue.size()
    })
    var remaining_queue: Array = []
    for item in queue:
      var route := str(item.get("route", "to_client"))
      var msg_payload: Dictionary = item.get("payload", {})
      var sent := _send_routed_peer_message(peer_id, route, msg_payload)
      if not sent:
        remaining_queue.append(item)

    if remaining_queue.is_empty():
      _pending_peer_messages.erase(peer_id)
    else:
      _pending_peer_messages[peer_id] = remaining_queue
      _debug_log("flush_retained_queue", {
        "peer_id": peer_id,
        "remaining_queue_size": remaining_queue.size()
      })


func _connect_signaling() -> bool:
  if _signal_connected and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
    return true

  if _signal_connected and _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
    _socket.close()
    _signal_connected = false

  var err := _socket.connect_to_url(signaling_url)
  if err != OK:
    _debug_log("connect_signaling_failed", {
      "error": error_string(err)
    })
    push_error("Failed to connect to signaling server: %s" % error_string(err))
    return false

  _signal_connected = true
  _debug_log("connect_signaling_started")
  return true


func _send_signal(payload: Dictionary) -> void:
  if not _signal_connected:
    return

  if _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
    return

  _socket.send_text(JSON.stringify(payload))


func _send_pending_role_handshake() -> void:
  if _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
    return

  if own_peer_id == 0:
    return

  if _pending_role == "host":
    _send_signal({"type": "create_room"})
  elif _pending_role == "client" and _pending_join_after_check:
    _send_signal({"type": "check_room", "room": _pending_room_code})


func _handle_server_message(raw_message: String) -> void:
  var data: Variant = JSON.parse_string(raw_message)
  if typeof(data) != TYPE_DICTIONARY:
    return

  var msg: Dictionary = data
  var msg_type: String = str(msg.get("type", ""))
  _debug_log("server_message", {
    "type": msg_type
  })

  match msg_type:
    "welcome":
      own_peer_id = int(msg.get("peer_id", 0))
      _send_pending_role_handshake()
    "room_check_result":
      var checked_code := str(msg.get("room", ""))
      var exists := bool(msg.get("exists", false))
      if _pending_role == "client" and _pending_join_after_check and checked_code == _pending_room_code:
        if exists:
          _pending_join_after_check = false
          _send_signal({"type": "join_room", "room": _pending_room_code})
        else:
          _complete_join_attempt(false, "Join failed: room code '%s' does not exist." % _pending_room_code)
    "room_created":
      host_peer_id = own_peer_id
      current_room_code = str(msg.get("room", ""))
      _setup_webrtc_mesh()
      _debug_log("room_created", {
        "room_code": current_room_code,
        "own_peer_id": own_peer_id
      })
      var started_hosting_info := {
        "room_code": current_room_code,
        "host_peer_id": host_peer_id,
        "own_peer_id": own_peer_id
      }
      _notify_subscribers(_started_hosting_subscribers, started_hosting_info)
      print("Created room code: %s as host id %d" % [current_room_code, own_peer_id])
    "room_joined":
      host_peer_id = int(msg.get("host_id", 0))
      current_room_code = str(msg.get("room", ""))
      _setup_webrtc_mesh()
      _debug_log("room_joined", {
        "room_code": current_room_code,
        "host_peer_id": host_peer_id,
        "own_peer_id": own_peer_id
      })
      var peers: Array = msg.get("peers", [])
      for p in peers:
        var remote_id := int(p)
        if remote_id != own_peer_id:
          # Existing peers will offer to this newly joined peer on peer_joined.
          _ensure_peer_connection(remote_id, false)
      var joined_info := {
        "room_code": current_room_code,
        "host_peer_id": host_peer_id,
        "own_peer_id": own_peer_id,
        "peers": peers
      }
      _notify_subscribers(_join_room_subscribers, joined_info)
      _complete_join_attempt(true)
      print("Joined room code: %s as client id %d" % [current_room_code, own_peer_id])
    "peer_joined":
      var joined_peer_id := int(msg.get("peer_id", 0))
      if joined_peer_id != 0 and joined_peer_id != own_peer_id:
        # Register the peer before notifying subscribers so any immediate
        # send_to_client/send_to_all_clients call can route or queue to it.
        _ensure_peer_connection(joined_peer_id, true)
        _debug_log("peer_joined", {
          "joined_peer_id": joined_peer_id
        })
        var peer_join_info := {
          "joined_peer_id": joined_peer_id,
          "room_code": current_room_code,
          "host_peer_id": host_peer_id,
          "own_peer_id": own_peer_id
        }
        _notify_subscribers(_peer_join_room_subscribers, peer_join_info)
    "peer_left":
      var left_peer_id := int(msg.get("peer_id", 0))
      _debug_log("peer_left", {
        "left_peer_id": left_peer_id
      })
      var peer_leave_info := {
        "left_peer_id": left_peer_id,
        "room_code": current_room_code,
        "host_peer_id": host_peer_id,
        "own_peer_id": own_peer_id
      }
      _notify_subscribers(_peer_leave_room_subscribers, peer_leave_info)
      _remove_webrtc_peer(left_peer_id)
    "signal":
      _handle_signal_payload(msg)
    "error":
      if _pending_role == "client" and not _join_result_ready:
        _complete_join_attempt(false, "Join failed: %s" % str(msg.get("message", "Unknown error")))
      push_warning("Signaling server error: %s" % str(msg.get("message", "Unknown error")))


func _complete_join_attempt(success: bool, warning_message: String = "") -> void:
  _join_result_ready = true
  _join_result_success = success
  _pending_join_after_check = false

  if success:
    _pending_role = ""
    return

  is_client = false
  _pending_role = ""

  if warning_message != "":
    push_warning(warning_message)


func _setup_webrtc_mesh() -> void:
  for remote_peer_id in _webrtc_peers.keys():
    var old_rtc: WebRTCPeerConnection = _webrtc_peers[remote_peer_id]
    old_rtc.close()
  _webrtc_peers.clear()
  _pending_peer_messages.clear()

  if multiplayer.multiplayer_peer != null:
    multiplayer.multiplayer_peer = null

  peer = WebRTCMultiplayerPeer.new()
  peer.create_mesh(own_peer_id)
  multiplayer.multiplayer_peer = peer


func _ensure_peer_connection(remote_peer_id: int, create_offer: bool = false) -> void:
  if _webrtc_peers.has(remote_peer_id):
    return

  var rtc := WebRTCPeerConnection.new()
  var config := {
    "iceServers": [
      {"urls": ["stun:stun.l.google.com:19302"]}
    ]
  }

  var init_err := rtc.initialize(config)
  if init_err != OK:
    push_error("Failed to initialize WebRTC peer %d" % remote_peer_id)
    return

  rtc.session_description_created.connect(_on_session_description_created.bind(remote_peer_id))
  rtc.ice_candidate_created.connect(_on_ice_candidate_created.bind(remote_peer_id))

  var add_err := peer.add_peer(rtc, remote_peer_id)
  if add_err != OK:
    _debug_log("add_peer_failed", {
      "remote_peer_id": remote_peer_id,
      "error": error_string(add_err)
    })
    push_error("Failed to add peer %d to multiplayer mesh" % remote_peer_id)
    rtc.close()
    return

  _webrtc_peers[remote_peer_id] = rtc
  _debug_log("peer_connection_added", {
    "remote_peer_id": remote_peer_id,
    "create_offer": create_offer
  })

  if create_offer:
    rtc.create_offer()


func _remove_webrtc_peer(remote_peer_id: int) -> void:
  if not _webrtc_peers.has(remote_peer_id):
    return

  var rtc: WebRTCPeerConnection = _webrtc_peers[remote_peer_id]

  # Remove from multiplayer mesh before closing; closing first can auto-drop
  # internal peer state and make remove_peer() fail with peer_map warnings.
  if peer != null:
    if peer.has_method("has_peer"):
      var has_remote_peer := bool(peer.call("has_peer", remote_peer_id))
      if has_remote_peer:
        peer.remove_peer(remote_peer_id)
    else:
      peer.remove_peer(remote_peer_id)

  rtc.close()
  _webrtc_peers.erase(remote_peer_id)
  _pending_peer_messages.erase(remote_peer_id)


func _handle_signal_payload(msg: Dictionary) -> void:
  var from_peer_id := int(msg.get("from_peer", 0))
  var payload: Dictionary = msg.get("data", {})
  var signal_type: String = str(payload.get("type", ""))

  if signal_type == "offer":
    _ensure_peer_connection(from_peer_id, false)

  if not _webrtc_peers.has(from_peer_id):
    return

  var rtc: WebRTCPeerConnection = _webrtc_peers[from_peer_id]

  match signal_type:
    "offer":
      rtc.set_remote_description("offer", str(payload.get("sdp", "")))
    "answer":
      rtc.set_remote_description("answer", str(payload.get("sdp", "")))
    "ice":
      rtc.add_ice_candidate(
        str(payload.get("media", "")),
        int(payload.get("index", 0)),
        str(payload.get("name", ""))
      )
    "custom":
      push_warning("Received legacy signaling custom payload; gameplay messages should use WebRTC RPC.")


func _on_session_description_created(type: String, sdp: String, remote_peer_id: int) -> void:
  if not _webrtc_peers.has(remote_peer_id):
    return

  var rtc: WebRTCPeerConnection = _webrtc_peers[remote_peer_id]
  rtc.set_local_description(type, sdp)
  _debug_log("session_description_created", {
    "remote_peer_id": remote_peer_id,
    "type": type
  })

  _send_signal({
    "type": "signal",
    "to_peer": remote_peer_id,
    "data": {
      "type": type,
      "sdp": sdp
    }
  })


func _on_ice_candidate_created(media: String, index: int, candidate_name: String, remote_peer_id: int) -> void:
  _debug_log("ice_candidate_created", {
    "remote_peer_id": remote_peer_id,
    "media": media,
    "index": index
  })
  _send_signal({
    "type": "signal",
    "to_peer": remote_peer_id,
    "data": {
      "type": "ice",
      "media": media,
      "index": index,
      "name": candidate_name
    }
  })


@rpc("any_peer", "call_remote", "reliable")
func _rpc_receive_from_client(payload: Dictionary) -> void:
  if not is_host:
    _debug_log("rpc_from_client_dropped", {
      "reason": "not_host"
    })
    return

  var sender_peer_id := multiplayer.get_remote_sender_id()
  _debug_log("rpc_from_client_received", {
    "from_peer_id": sender_peer_id,
    "payload_type": str(payload.get("type", ""))
  })
  _notify_peer_message_subscribers(_client_message_subscribers, sender_peer_id, payload)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_receive_from_host(payload: Dictionary) -> void:
  if not is_client:
    _debug_log("rpc_from_host_dropped", {
      "reason": "not_client"
    })
    return

  var sender_peer_id := multiplayer.get_remote_sender_id()
  if host_peer_id != 0 and sender_peer_id != host_peer_id:
    _debug_log("rpc_from_host_dropped", {
      "reason": "sender_not_host",
      "sender_peer_id": sender_peer_id,
      "host_peer_id": host_peer_id
    })
    return

  _debug_log("rpc_from_host_received", {
    "from_peer_id": sender_peer_id,
    "payload_type": str(payload.get("type", ""))
  })
  _notify_peer_message_subscribers(_host_message_subscribers, sender_peer_id, payload)


func _notify_peer_message_subscribers(subscribers: Array[Callable], from_peer_id: int, payload: Dictionary) -> void:
  _debug_log("notify_peer_message_subscribers", {
    "count": subscribers.size(),
    "from_peer_id": from_peer_id,
    "payload_type": str(payload.get("type", ""))
  })
  for callback in subscribers:
    if callback.is_valid():
      callback.call(from_peer_id, payload)


func _notify_subscribers(subscribers: Array[Callable], message: Dictionary) -> void:
  for callback in subscribers:
    if callback.is_valid():
      callback.call(message)


func _get_peer_connection_state_name(remote_peer_id: int) -> String:
  if not _webrtc_peers.has(remote_peer_id):
    return "missing"

  var rtc: WebRTCPeerConnection = _webrtc_peers[remote_peer_id]
  var state := rtc.get_connection_state()

  match state:
    WebRTCPeerConnection.STATE_NEW:
      return "new"
    WebRTCPeerConnection.STATE_CONNECTING:
      return "connecting"
    WebRTCPeerConnection.STATE_CONNECTED:
      return "connected"
    WebRTCPeerConnection.STATE_DISCONNECTED:
      return "disconnected"
    WebRTCPeerConnection.STATE_FAILED:
      return "failed"
    WebRTCPeerConnection.STATE_CLOSED:
      return "closed"
    _:
      return "unknown"


func _debug_log(event: String, details: Dictionary = {}) -> void:
  if not debug_logs_enabled:
    return

  print("[multiplayer_manager] ", event, " ", details)
