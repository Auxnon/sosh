-- sosh — a little social plaza. Petrichor64 client for the Phoenix server.
--
-- Runs unchanged as a desktop app and in the browser: all UI is drawn on the
-- engine's gui layer, and the network is the engine's websocket `conn`
-- speaking the Phoenix Channels protocol (phx.lua).
--
-- On the web the page is served by Phoenix, so the client connects back to
-- its own origin and skips the server field. A desktop build asks for the
-- server address.

SOCKET_PATH = "/socket/websocket?vsn=2.0.0"
DEFAULT_SERVER = "ws://localhost:4000"
CHAT_MAX = 280
CHAT_LOG_MAX = 50
CHAT_SHOWN = 8
CHAT_FADE = 600 -- frames a line stays fully visible in the log

-- camera: orbits the local avatar
CAM = { x = 0, y = 0, z = 0, az = 0, alt = -0.55, dist = 9 }

function main()
	attr({ title = "sosh", modernize = true })
	UI.init()
	world_build()

	APP = {}
	APP.screen = "connect"
	APP.focus = 1
	APP.name = UI.field("", 16)
	APP.server = UI.field(DEFAULT_SERVER, 64)
	APP.status = ""
	APP.web = detect_web()
	APP.players = {}
	APP.order = {}
	APP.me = nil
	APP.my_id = nil
	APP.chat = {}
	APP.typing = false
	APP.draft = UI.field("", CHAT_MAX)
	APP.move_tick = 0
	APP.last_sent_x = 0
	APP.last_sent_y = 0
	APP.drag = false

	-- something to look at behind the connect screen
	CAM.az = 0.6
	cout("sosh: " .. (APP.web and "web build" or "desktop build"))
end

-- A page-relative websocket path only resolves on the web; on desktop conn()
-- rejects it immediately. The probe socket is closed straight away.
function detect_web()
	local ok, sock = pcall(conn, SOCKET_PATH)
	if ok and sock ~= nil then
		sock:kill()
		return true
	end
	return false
end

function loop()
	UI.begin()
	if APP.screen == "connect" then
		connect_screen()
	else
		world_frame()
	end
end

function draw() end

-- ---------------------------------------------------------------------------
-- connect screen

function connect_screen()
	-- slow orbit of the empty plaza
	CAM.az = CAM.az + 0.0015
	place_camera(0, 0)

	local w = 260
	local h = 150
	if APP.web then
		h = 112
	end
	local x = flr((gui.w - w) / 2)
	local y = flr((gui.h - h) / 2)
	UI.panel(x, y, w, h)
	UI.text("sosh", x + PAD * 3, y + PAD * 3, C_ACCENT)
	UI.text("a little plaza to hang out in", x + PAD * 3, y + PAD * 3 + LH + 2, C_DIM)

	local fx = x + PAD * 3
	local fw = w - PAD * 6
	local fy = y + 40
	if UI.draw_field("your name", APP.name, fx, fy, fw, APP.focus == 1) then
		APP.focus = 1
	end
	if not APP.web then
		if UI.draw_field("server", APP.server, fx, fy + 38, fw, APP.focus == 2) then
			APP.focus = 2
		end
	end

	local go = UI.button("join", x + w - PAD * 3 - 64, y + h - PAD * 3 - 18, 64, 18)
	if APP.status ~= "" then
		UI.text(APP.status, fx, y + h - PAD * 3 - 13, C_BAD)
	end

	local f = APP.name
	if APP.focus == 2 then
		f = APP.server
	end
	local res = UI.type_into(f)
	if key("tab", true) and not APP.web then
		APP.focus = 3 - APP.focus
	end
	if res == "enter" then
		go = true
	end
	if go then
		start_session()
	end
end

function start_session()
	local name = U.trim(APP.name.text)
	if name == "" then
		APP.status = "pick a name first"
		APP.focus = 1
		return
	end
	local url = SOCKET_PATH
	if not APP.web then
		local server = U.trim(APP.server.text)
		if server:sub(#server) == "/" then
			server = server:sub(1, #server - 1)
		end
		if server:sub(1, 5) ~= "ws://" and server:sub(1, 6) ~= "wss://" then
			server = "ws://" .. server
		end
		url = server .. SOCKET_PATH
	end
	APP.status = ""
	APP.my_name = name

	PHX = Phx.new(url)
	local sx = rnd() * 4 - 2
	local sy = rnd() * 4 - 2
	local params = {}
	params.name = name
	local vec = { sx, sy, GROUND_Z }
	params.vec = vec
	params.face = 0
	params.animation = 0
	LOBBY = PHX:channel("room:lobby", params)
	bind_lobby(LOBBY)
	PHX:connect()

	APP.spawn_x = sx
	APP.spawn_y = sy
	APP.screen = "world"
	CAM.az = 0.6
	add_chat(nil, "connecting to " .. url, C_DIM)
end

-- ---------------------------------------------------------------------------
-- network

function bind_lobby(ch)
	ch.on_join = function(reply)
		APP.my_id = reply.user_id
		if APP.me == nil then
			APP.me = Avatar.new(reply.user_id, APP.my_name, APP.spawn_x, APP.spawn_y, 0, 0)
		else
			-- rejoined after a drop: new id, same body (LOBBY.params has
			-- kept up with position/face/pose, so others see us as we were)
			APP.me.id = reply.user_id
		end
		add_chat(nil, "joined the plaza", C_OK)
	end
	ch.on_error = function(reply)
		local why = "join refused"
		if reply ~= nil and reply.reason ~= nil then
			why = why .. ": " .. tostring(reply.reason)
		end
		add_chat(nil, why, C_BAD)
	end

	ch.on["snapshot"] = function(p)
		-- the authoritative list: drop anyone we have who isn't in it
		local seen = {}
		local list = p.players
		for i = 1, #list do
			local pl = list[i]
			seen[pl.user_id] = true
			upsert_player(pl, true)
		end
		local gone = {}
		for i = 1, #APP.order do
			local id = APP.order[i]
			if not seen[id] then
				table.insert(gone, id)
			end
		end
		for i = 1, #gone do
			remove_player(gone[i])
		end
	end
	ch.on["joined"] = function(p)
		if p.user_id ~= APP.my_id and APP.players[p.user_id] == nil then
			upsert_player(p, true)
			add_chat(nil, p.name .. " arrived", C_DIM)
		end
	end
	ch.on["left"] = function(p)
		local av = APP.players[p.user_id]
		if av ~= nil then
			add_chat(nil, av.name .. " left", C_DIM)
			remove_player(p.user_id)
		end
	end
	ch.on["move"] = function(p)
		local av = APP.players[p.user_id]
		if av ~= nil and p.vec ~= nil then
			av:walk_to(p.vec[1], p.vec[2])
		end
	end
	ch.on["face"] = function(p)
		local av = APP.players[p.user_id]
		if av ~= nil then
			av:set_face(p.face)
		end
	end
	ch.on["animation"] = function(p)
		local av = APP.players[p.user_id]
		if av ~= nil then
			av:set_anim(p.animation)
		end
	end
	ch.on["new_msg"] = function(p)
		local av = nil
		local name = p.name or "?"
		if p.user_id == APP.my_id then
			av = APP.me
		else
			av = APP.players[p.user_id]
		end
		if av ~= nil then
			name = av.name
			av:say(p.body)
		end
		local hex = C_TEXT
		if p.user_id ~= nil then
			hex = U.hex_for(p.user_id)
		end
		add_chat(name, p.body, hex)
	end
end

function upsert_player(p, snap)
	if p.user_id == APP.my_id then
		return
	end
	local x = 0
	local y = 0
	if p.vec ~= nil then
		x = p.vec[1]
		y = p.vec[2]
	end
	local av = APP.players[p.user_id]
	if av == nil then
		av = Avatar.new(p.user_id, p.name or "guest", x, y, p.face or 0, p.animation or 0)
		APP.players[p.user_id] = av
		table.insert(APP.order, p.user_id)
	else
		if snap then
			av:walk_to(x, y)
		end
		av:set_face(p.face or 0)
		av:set_anim(p.animation or 0)
	end
end

function remove_player(id)
	local av = APP.players[id]
	if av == nil then
		return
	end
	av:remove()
	APP.players[id] = nil
	for i = 1, #APP.order do
		if APP.order[i] == id then
			table.remove(APP.order, i)
			return
		end
	end
end

function add_chat(name, body, col)
	local line = {}
	line.name = name
	line.body = body
	line.col = col
	line.age = 0
	table.insert(APP.chat, line)
	while #APP.chat > CHAT_LOG_MAX do
		table.remove(APP.chat, 1)
	end
end

function send_move(x, y)
	APP.last_sent_x = x
	APP.last_sent_y = y
	local vec = { x, y, GROUND_Z }
	local payload = {}
	payload.vec = vec
	-- a reconnect rejoins with these params
	LOBBY.params.vec = vec
	PHX:push(LOBBY, "move", payload)
end

-- ---------------------------------------------------------------------------
-- world

function world_frame()
	PHX:update()

	local me = APP.me
	if me ~= nil then
		local acted = false
		if APP.typing then
			chat_typing()
		else
			acted = world_keys(me)
		end
		world_pointer(me)
		me:update()
		-- while walking by keys, keep remote copies following
		APP.move_tick = APP.move_tick + 1
		if acted and APP.move_tick >= 6 then
			APP.move_tick = 0
			send_move(me.tx, me.ty)
		end
	end

	for i = 1, #APP.order do
		APP.players[APP.order[i]]:update()
	end

	if me ~= nil then
		place_camera(me.x, me.y)
	else
		CAM.az = CAM.az + 0.0015
		place_camera(0, 0)
	end

	draw_hud()
end

-- WASD / arrows walk relative to the camera; Q/E turn it; F/G cycle face and
-- pose; Enter opens chat. Returns true if the avatar was steered.
function world_keys(me)
	if key("enter", true) then
		APP.typing = true
		APP.draft.text = ""
		cin() -- swallow anything typed this frame
		return false
	end
	if key("f", true) then
		change_face(1)
	end
	if key("g", true) then
		change_anim(1)
	end
	if key("q") then
		CAM.az = CAM.az + 0.03
	end
	if key("e") then
		CAM.az = CAM.az - 0.03
	end

	local fwd = 0
	local side = 0
	if key("w") or key("up") then
		fwd = fwd + 1
	end
	if key("s") or key("down") then
		fwd = fwd - 1
	end
	if key("a") or key("left") then
		side = side + 1
	end
	if key("d") or key("right") then
		side = side - 1
	end
	if fwd == 0 and side == 0 then
		return false
	end
	if me.anim == 1 then
		change_anim(1) -- stand up to walk
	end
	local fx = cos(CAM.az)
	local fy = sin(CAM.az)
	local dx = fx * fwd - fy * side
	local dy = fy * fwd + fx * side
	local l = sqrt(dx * dx + dy * dy)
	local tx = me.x + dx / l * 0.9
	local ty = me.y + dy / l * 0.9
	if world_walkable(tx, ty) then
		me:walk_to(tx, ty)
		return true
	end
	return false
end

-- Left click on the ground walks there; right-drag orbits; scroll zooms.
function world_pointer(me)
	local m = UI.mouse
	if m.m2 then
		CAM.az = CAM.az - m.dx * 4
		CAM.alt = U.clamp(CAM.alt + m.dy * 2, -1.3, -0.15)
	end
	if m.scroll ~= 0 then
		CAM.dist = U.clamp(CAM.dist - m.scroll * 1.5, 4, 22)
	end
	-- Buttons are drawn after this runs, so hit-test the HUD region directly.
	if UI.clicked and not hud_hit(UI.mx, UI.my) then
		local vz = m.vz
		if vz < -0.01 then
			local t = (GROUND_Z - CAM.z) / vz
			local gx = CAM.x + m.vx * t
			local gy = CAM.y + m.vy * t
			if not world_walkable(gx, gy) then
				local p = world_clamp(gx, gy)
				gx = p[1]
				gy = p[2]
			end
			if world_walkable(gx, gy) then
				if me.anim == 1 then
					change_anim(1)
				end
				me:walk_to(gx, gy)
				send_move(gx, gy)
			end
		end
	end
end

function chat_typing()
	local res = UI.type_into(APP.draft)
	if res == "escape" then
		APP.typing = false
	elseif res == "enter" then
		local body = U.trim(APP.draft.text)
		APP.typing = false
		if body ~= "" then
			local payload = {}
			payload.body = body
			if not PHX:push(LOBBY, "new_msg", payload) then
				add_chat(nil, "not connected, message not sent", C_BAD)
			end
		end
	end
end

function change_face(d)
	local me = APP.me
	me:set_face(me.face + d)
	local payload = {}
	payload.face = me.face
	LOBBY.params.face = me.face
	PHX:push(LOBBY, "face", payload)
end

function change_anim(d)
	local me = APP.me
	me:set_anim(me.anim + d)
	local payload = {}
	payload.animation = me.anim
	LOBBY.params.animation = me.anim
	PHX:push(LOBBY, "animation", payload)
end

function place_camera(x, y)
	local cl = cos(CAM.alt)
	local fx = cos(CAM.az) * cl
	local fy = sin(CAM.az) * cl
	local fz = sin(CAM.alt)
	local focus_z = GROUND_Z + 1.1
	CAM.x = x - fx * CAM.dist
	CAM.y = y - fy * CAM.dist
	CAM.z = focus_z - fz * CAM.dist
	local pos = { CAM.x, CAM.y, CAM.z }
	local rot = { CAM.az, CAM.alt }
	cam({ pos = pos, rot = rot })
end

-- ---------------------------------------------------------------------------
-- HUD

HUD_BTN_W = 92
HUD_BTN_H = 18

function hud_buttons_x()
	return gui.w - HUD_BTN_W - PAD * 2
end

function hud_hit(x, y)
	-- status strip, button column, chat box
	if y < LH + PAD * 2 then
		return true
	end
	local bx = hud_buttons_x()
	if x >= bx and y >= gui.h - (HUD_BTN_H + PAD) * 3 - PAD then
		return true
	end
	if APP.typing and y >= gui.h - LH - PAD * 4 then
		return true
	end
	return false
end

function draw_hud()
	-- avatars' overlays first so panels sit on top of them
	for i = 1, #APP.order do
		UI.avatar_overlay(APP.players[APP.order[i]], false)
	end
	if APP.me ~= nil then
		UI.avatar_overlay(APP.me, true)
	end

	-- top strip: connection + who's here
	local online = #APP.order
	if APP.me ~= nil then
		online = online + 1
	end
	UI.panel(0, 0, gui.w, LH + PAD * 2, "0A0E16B0")
	local st = PHX.state
	local label = "connecting..."
	local col = C_ACCENT
	if st == "open" then
		label = "connected"
		col = C_OK
	elseif st == "waiting" then
		label = "reconnecting in " .. tostring(flr(PHX.retry_in / FPS) + 1) .. "s"
		col = C_BAD
	end
	UI.text("sosh", PAD * 2, PAD + 1, C_ACCENT)
	UI.text(label, PAD * 2 + 6 * CH, PAD + 1, col)
	local here = tostring(online) .. " here"
	local hx = gui.w - UI.text_w(here) - PAD * 2
	UI.text(here, hx, PAD + 1, C_DIM)

	draw_chat()
	draw_buttons()
end

function draw_buttons()
	local me = APP.me
	if me == nil then
		return
	end
	local x = hud_buttons_x()
	local y = gui.h - (HUD_BTN_H + PAD) * 3
	local face_label = "face " .. tostring(me.face + 1) .. "/" .. tostring(FACE_COUNT)
	if UI.button(face_label, x, y, HUD_BTN_W, HUD_BTN_H) then
		change_face(1)
	end
	y = y + HUD_BTN_H + PAD
	local pose_label = me:anim_name()
	if UI.button(pose_label, x, y, HUD_BTN_W, HUD_BTN_H) then
		change_anim(1)
	end
	y = y + HUD_BTN_H + PAD
	if UI.button("chat", x, y, HUD_BTN_W, HUD_BTN_H) then
		APP.typing = not APP.typing
		APP.draft.text = ""
	end
end

function draw_chat()
	local w = flr(gui.w * 0.45)
	if w < 220 then
		w = 220
	end
	local cols = flr((w - PAD * 2) / CH)
	local bottom = gui.h - PAD
	if APP.typing then
		bottom = bottom - (LH + PAD * 3)
	end

	-- gather wrapped lines from the newest message back
	local rows = {}
	local i = #APP.chat
	while i >= 1 and #rows < CHAT_SHOWN do
		local c = APP.chat[i]
		c.age = c.age + 1
		if c.age < CHAT_FADE or APP.typing then
			local text = c.body
			if c.name ~= nil then
				text = c.name .. ": " .. c.body
			end
			local wrapped = U.wrap(text, cols)
			local j = #wrapped
			while j >= 1 and #rows < CHAT_SHOWN do
				local row = {}
				row.text = wrapped[j]
				row.col = c.col
				table.insert(rows, row)
				j = j - 1
			end
		end
		i = i - 1
	end
	-- still age the rest
	while i >= 1 do
		APP.chat[i].age = APP.chat[i].age + 1
		i = i - 1
	end

	if #rows > 0 then
		local h = #rows * LH + PAD * 2
		gui:rrect(PAD, bottom - h, w, h, 3, "0A0E1690")
		for r = 1, #rows do
			UI.text(rows[r].text, PAD * 2, bottom - PAD - r * LH + 1, rows[r].col)
		end
	end

	if APP.typing then
		local y = gui.h - LH - PAD * 3
		UI.panel(PAD, y, w, LH + PAD * 2, C_PANEL_HI)
		local shown = "> " .. APP.draft.text
		if #shown > cols - 1 then
			shown = shown:sub(#shown - cols + 2)
		end
		if UI.blink < 30 then
			shown = shown .. "_"
		end
		UI.text(shown, PAD * 2, y + PAD + 1, C_TEXT)
	elseif APP.me ~= nil then
		UI.text("enter: chat   wasd/click: walk   f: face   g: pose   q/e/right-drag: look", PAD * 2, gui.h - LH - PAD, "FFFFFF70")
	end
end
