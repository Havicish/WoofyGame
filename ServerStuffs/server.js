const WebSocket = require("ws");

const PORT = Number(process.env.PORT || 8080);
const HOST = process.env.HOST || "0.0.0.0";

const wss = new WebSocket.Server({ host: HOST, port: PORT });

let nextClientId = 1;

// roomName -> { hostId: number | null, clients: Set<number> }
const rooms = new Map();

// clientId -> { socket: WebSocket, room: string | null }
const clients = new Map();

const ROOM_CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXY23456789";

function logEvent(event, details = {}) {
	const timestamp = new Date().toISOString();
	console.log(`[${timestamp}] [${event}]`, details);
}

function generateRoomCode(length = 6) {
	let code = "";
	for (let i = 0; i < length; i += 1) {
		const idx = Math.floor(Math.random() * ROOM_CODE_CHARS.length);
		code += ROOM_CODE_CHARS[idx];
	}
	return code;
}

function createUniqueRoomCode() {
	let attempts = 0;
	while (attempts < 1000) {
		const code = generateRoomCode();
		if (!rooms.has(code)) {
			return code;
		}
		attempts += 1;
	}

	throw new Error("Failed to create unique room code.");
}

function send(socket, payload) {
	if (socket.readyState === WebSocket.OPEN) {
		socket.send(JSON.stringify(payload));
	}
}

function sendToClient(clientId, payload) {
	const client = clients.get(clientId);
	if (!client) {
		return;
	}
	send(client.socket, payload);
}

function broadcastToRoom(roomName, payload, excludeClientId = null) {
	const room = rooms.get(roomName);
	if (!room) {
		return;
	}

	for (const clientId of room.clients) {
		if (excludeClientId !== null && clientId === excludeClientId) {
			continue;
		}
		sendToClient(clientId, payload);
	}
}

function getOrCreateRoom(roomName) {
	if (!rooms.has(roomName)) {
		rooms.set(roomName, {
			hostId: null,
			clients: new Set()
		});
	}
	return rooms.get(roomName);
}

function removeClientFromRoom(clientId) {
	const client = clients.get(clientId);
	if (!client || !client.room) {
		return;
	}

	const roomName = client.room;
	const room = rooms.get(roomName);
	if (!room) {
		client.room = null;
		return;
	}

	room.clients.delete(clientId);

	if (room.hostId === clientId) {
		logEvent("room_host_left", { room: roomName, hostId: clientId });
		room.hostId = null;
	}

	broadcastToRoom(
		roomName,
		{
			type: "peer_left",
			peer_id: clientId
		},
		clientId
	);

	client.room = null;

	logEvent("room_peer_left", {
		room: roomName,
		peerId: clientId,
		remainingPeers: room.clients.size
	});

	if (room.clients.size === 0) {
		rooms.delete(roomName);
		logEvent("room_deleted", { room: roomName });
	}
}

function handleCreateRoom(clientId, payload) {
	let roomName = "";

	removeClientFromRoom(clientId);

	if (payload && typeof payload.room === "string" && payload.room.trim() !== "") {
		roomName = payload.room.trim().toUpperCase();
	}

	if (!roomName) {
		roomName = createUniqueRoomCode();
	}

	const room = getOrCreateRoom(roomName);

	if (room.hostId !== null && room.hostId !== clientId) {
		logEvent("room_create_failed", {
			room: roomName,
			requesterPeerId: clientId,
			reason: "host_already_exists"
		});
		sendToClient(clientId, {
			type: "error",
			message: `Room '${roomName}' already has a host.`
		});
		return;
	}

	room.hostId = clientId;
	room.clients.add(clientId);
	clients.get(clientId).room = roomName;

	sendToClient(clientId, {
		type: "room_created",
		room: roomName,
		host_id: clientId,
		peers: []
	});

	logEvent("room_created", {
		room: roomName,
		hostId: clientId,
		roomCount: rooms.size
	});
}

function handleJoinRoom(clientId, payload) {
	const roomName = String(payload.room || "").trim().toUpperCase();

	if (!roomName) {
		logEvent("room_join_failed", {
			requesterPeerId: clientId,
			reason: "missing_room_code"
		});
		sendToClient(clientId, {
			type: "error",
			message: "Room code is required."
		});
		return;
	}

	removeClientFromRoom(clientId);

	const room = rooms.get(roomName);
	if (!room || room.hostId === null) {
		logEvent("room_join_failed", {
			room: roomName,
			requesterPeerId: clientId,
			reason: "room_not_found"
		});
		sendToClient(clientId, {
			type: "error",
			message: `Room '${roomName}' does not exist.`
		});
		return;
	}

	room.clients.add(clientId);
	clients.get(clientId).room = roomName;

	const existingPeers = Array.from(room.clients).filter((id) => id !== clientId);

	sendToClient(clientId, {
		type: "room_joined",
		room: roomName,
		host_id: room.hostId,
		peers: existingPeers
	});

	broadcastToRoom(
		roomName,
		{
			type: "peer_joined",
			peer_id: clientId
		},
		clientId
	);

	logEvent("room_joined", {
		room: roomName,
		peerId: clientId,
		hostId: room.hostId,
		peerCount: room.clients.size
	});
}

function handleCheckRoom(clientId, payload) {
	const roomName = String(payload.room || "").trim().toUpperCase();
	const room = roomName ? rooms.get(roomName) : null;
	const exists = !!room && room.hostId !== null;

	logEvent("room_check", {
		requesterPeerId: clientId,
		room: roomName,
		exists
	});

	sendToClient(clientId, {
		type: "room_check_result",
		room: roomName,
		exists
	});
}

function handleSignal(clientId, payload) {
	const client = clients.get(clientId);
	if (!client || !client.room) {
		logEvent("signal_failed", {
			fromPeerId: clientId,
			reason: "not_in_room"
		});
		sendToClient(clientId, {
			type: "error",
			message: "Join or create a room before sending signaling data."
		});
		return;
	}

	const room = rooms.get(client.room);
	if (!room) {
		logEvent("signal_failed", {
			fromPeerId: clientId,
			reason: "room_missing"
		});
		sendToClient(clientId, {
			type: "error",
			message: "Room is not available."
		});
		return;
	}

	const toPeer = Number(payload.to_peer || 0);

	if (!toPeer || !room.clients.has(toPeer)) {
		logEvent("signal_failed", {
			fromPeerId: clientId,
			toPeerId: toPeer,
			room: client.room,
			reason: "invalid_target"
		});
		sendToClient(clientId, {
			type: "error",
			message: "Target peer is not in your room."
		});
		return;
	}

	sendToClient(toPeer, {
		type: "signal",
		from_peer: clientId,
		data: payload.data || {}
	});

	logEvent("signal_relayed", {
		room: client.room,
		fromPeerId: clientId,
		toPeerId: toPeer,
		signalType: payload?.data?.type || "unknown"
	});
}

function handleMessage(clientId, rawData) {
	let payload;
	try {
		payload = JSON.parse(rawData.toString());
	} catch (_error) {
		logEvent("invalid_payload", { peerId: clientId });
		sendToClient(clientId, {
			type: "error",
			message: "Invalid JSON payload."
		});
		return;
	}

	const messageType = payload.type;

	switch (messageType) {
		case "create_room":
			handleCreateRoom(clientId, payload);
			break;
		case "check_room":
			handleCheckRoom(clientId, payload);
			break;
		case "join_room":
			handleJoinRoom(clientId, payload);
			break;
		case "signal":
			handleSignal(clientId, payload);
			break;
		default:
			logEvent("unknown_message_type", {
				peerId: clientId,
				messageType: String(messageType)
			});
			sendToClient(clientId, {
				type: "error",
				message: `Unknown message type: ${String(messageType)}`
			});
			break;
	}
}

wss.on("connection", (socket) => {
	const clientId = nextClientId;
	nextClientId += 1;

	clients.set(clientId, {
		socket,
		room: null
	});

	send(socket, {
		type: "welcome",
		peer_id: clientId
	});

	logEvent("peer_connected", {
		peerId: clientId,
		connectedPeers: clients.size
	});

	socket.on("message", (data) => {
		handleMessage(clientId, data);
	});

	socket.on("close", () => {
		removeClientFromRoom(clientId);
		clients.delete(clientId);
		logEvent("peer_disconnected", {
			peerId: clientId,
			connectedPeers: clients.size
		});
	});

	socket.on("error", (error) => {
		removeClientFromRoom(clientId);
		clients.delete(clientId);
		logEvent("peer_socket_error", {
			peerId: clientId,
			error: error?.message || "unknown"
		});
	});
});

logEvent("server_started", { host: HOST, port: PORT });
