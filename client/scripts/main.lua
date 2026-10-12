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
	-- "walk", "dig", "build" or "plant"
	APP.tool = "walk"
	APP.block_i = 1
	APP.cursor = nil
	APP.target = nil
	APP.fetch_tick = 0
	Blocks.init()
	Farm.init()
	Herd.init()

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
	place_camera(0, 0, GROUND_Z)

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
	local none = {}
	ACTIONS = PHX:channel("actions:lobby", none)
	bind_actions(ACTIONS)
	PHX:connect()

	APP.spawn_x = sx
	APP.spawn_y = sy
	APP.screen = "world"
	CAM.az = 0.6
	if APP.web then
		add_chat(nil, "connecting...", C_DIM)
	else
		add_chat(nil, "connecting to " .. url, C_DIM)
	end
end

-- ---------------------------------------------------------------------------
-- network

function bind_lobby(ch)
	ch.on_join = function(reply)
		APP.my_id = reply.user_id
		if APP.me == nil then
			APP.me = Avatar.new(reply.user_id, APP.my_name, APP.spawn_x, APP.spawn_y, GROUND_Z, 0, 0)
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
	ch.on["emote"] = function(p)
		local av = APP.players[p.user_id]
		if av ~= nil then
			av:play_emote(p.emote)
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

-- World edits and chunk streaming (SoshWeb.ActionChannel).
function bind_actions(ch)
	ch.on_join = function(reply)
		-- (re)joined: anything we hold may be stale, so fetch it all again
		Blocks.have = {}
		Blocks.wanted = {}
		APP.fetch_tick = 0
		-- the reply is Sosh.Sim's snapshot: every crop and cow
		Farm.sync(reply.crops or {})
		Herd.sync(reply.cows or {})
	end
	ch.on["block_changed"] = function(p)
		local pos = p.position
		Blocks.set(pos[1], pos[2], pos[3], p.block)
	end
	ch.on["crop"] = function(p)
		Farm.set(p.position, p.stage)
	end
	ch.on["cows"] = function(p)
		local rows = p.cows
		for i = 1, #rows do
			Herd.put(rows[i])
		end
	end
	ch.on["moo"] = function(p)
		Herd.moo(p.ids)
	end
end

-- Ask for any chunks around (x, y) we don't have yet.
function request_chunks(x, y)
	local keys = Blocks.missing_around(x, y)
	if #keys == 0 then
		return
	end
	Blocks.mark_wanted(keys)
	local payload = {}
	payload.keys = keys
	local sent = PHX:push(ACTIONS, "get_chunks", payload, function(status, response)
		if status == "ok" then
			local list = response.chunks
			for i = 1, #list do
				local c = list[i]
				Blocks.apply_chunk(c.key, c.rle)
			end
		end
		-- whatever didn't come back can be asked for again
		Blocks.wanted = {}
	end)
	if not sent then
		Blocks.wanted = {}
	end
end

function upsert_player(p, snap)
	if p.user_id == APP.my_id then
		return
	end
	local x = 0
	local y = 0
	local z = GROUND_Z
	if p.vec ~= nil then
		x = p.vec[1]
		y = p.vec[2]
		z = p.vec[3]
	end
	local av = APP.players[p.user_id]
	if av == nil then
		av = Avatar.new(p.user_id, p.name or "guest", x, y, z, p.face or 0, p.animation or 0)
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
	local z = GROUND_Z
	if APP.me ~= nil then
		z = APP.me.z
	end
	local vec = { x, y, z }
	local payload = {}
	payload.vec = vec
	-- where we actually are, so the server can let us push cows
	if APP.me ~= nil then
		local at = { APP.me.x, APP.me.y, APP.me.z }
		payload.at = at
	end
	-- a reconnect rejoins with these params
	LOBBY.params.vec = vec
	PHX:push(LOBBY, "move", payload)
end

-- ---------------------------------------------------------------------------
-- world

function world_frame()
	PHX:update()

	-- keep the chunks around us loaded, a few times a second
	APP.fetch_tick = APP.fetch_tick - 1
	if ACTIONS.joined and APP.fetch_tick <= 0 then
		APP.fetch_tick = 20
		local cx = 0
		local cy = 0
		if APP.me ~= nil then
			cx = APP.me.x
			cy = APP.me.y
		end
		request_chunks(cx, cy)
	end

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
		-- while walking, keep remote copies following and the server
		-- knowing where we are
		APP.move_tick = APP.move_tick + 1
		local moving = acted or me:moving()
		if (moving and APP.move_tick >= 6) or (APP.was_moving and not moving) then
			APP.move_tick = 0
			send_move(me.tx, me.ty)
		end
		APP.was_moving = moving
	end

	for i = 1, #APP.order do
		APP.players[APP.order[i]]:update()
	end
	Herd.update(me)

	if me ~= nil then
		place_camera(me.x, me.y, me.z)
	else
		CAM.az = CAM.az + 0.0015
		place_camera(0, 0, GROUND_Z)
	end

	draw_hud()
end

-- WASD / arrows walk relative to the camera; Q/E turn it; F/G cycle face and
-- pose; 1-4 pick walk/dig/build/plant; Z/X pick the block; 5-8 emote; Enter
-- opens chat. Returns true if the avatar was steered.
function world_keys(me)
	if key("enter", true) then
		APP.typing = true
		APP.draft.text = ""
		cin() -- swallow anything typed this frame
		return false
	end
	if key("1", true) then
		APP.tool = "walk"
	end
	if key("2", true) then
		APP.tool = "dig"
	end
	if key("3", true) then
		APP.tool = "build"
	end
	if key("4", true) then
		APP.tool = "plant"
	end
	if key("z", true) then
		APP.block_i = (APP.block_i - 2) % #PLACEABLE + 1
	end
	if key("x", true) then
		APP.block_i = APP.block_i % #PLACEABLE + 1
	end
	for i = 1, #EMOTES do
		local k = tostring(i + 4)
		if key(k, true) then
			do_emote(EMOTES[i])
		end
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
	if Blocks.walkable(tx, ty, me.z) then
		me:walk_to(tx, ty)
		return true
	end
	return false
end

-- The block under the pointer drives all three tools: walk to it, dig it, or
-- build on the face it was hit through. Right-drag orbits; scroll zooms.
function world_pointer(me)
	local m = UI.mouse
	if m.m2 then
		CAM.az = CAM.az - m.dx * 4
		CAM.alt = U.clamp(CAM.alt + m.dy * 2, -1.3, -0.15)
	end
	if m.scroll ~= 0 then
		CAM.dist = U.clamp(CAM.dist - m.scroll * 1.5, 4, 22)
	end

	local hit = nil
	-- Buttons are drawn after this runs, so hit-test the HUD region directly.
	local over_hud = hud_hit(UI.mx, UI.my)
	if not over_hud then
		hit = Blocks.raycast(CAM.x, CAM.y, CAM.z, m.vx, m.vy, m.vz, 48)
	end

	-- the cell a tool would act on
	local cell = nil
	if hit ~= nil then
		if APP.tool == "dig" then
			cell = hit.hit
		elseif APP.tool == "build" then
			cell = hit.before
		elseif APP.tool == "plant" then
			cell = plant_cell(hit)
		end
	end
	if cell ~= nil and not in_reach(me, cell) then
		cell = nil
	end
	APP.target = cell
	show_cursor(cell)

	if not UI.clicked or over_hud or hit == nil then
		return
	end
	if APP.tool == "walk" then
		local h = hit.hit
		if Blocks.walkable(h[1], h[2], h[3] + 1) then
			if me.anim == 1 then
				change_anim(1)
			end
			me:walk_to(h[1], h[2])
			send_move(h[1], h[2])
		end
	elseif APP.tool == "plant" then
		if cell ~= nil then
			farm_action(cell)
		end
	elseif cell ~= nil then
		edit_block(cell)
	end
end

-- The plant tool works on the cell above the soil under the pointer: harvest
-- what grows there, or plant in it.
function plant_cell(hit)
	local h = hit.hit
	local x = h[1]
	local y = h[2]
	local z = h[3] + 1
	if Farm.get(x, y, z) == nil then
		if hit.id ~= 1 and hit.id ~= 2 then
			return nil -- grass or dirt only
		end
		if Blocks.get(x, y, z) ~= 0 then
			return nil
		end
	end
	local cell = { x, y, z }
	return cell
end

function farm_action(cell)
	local crop = Farm.get(cell[1], cell[2], cell[3])
	local pos = { cell[1], cell[2], cell[3] }
	local payload = {}
	payload.position = pos
	if crop == nil then
		PHX:push(ACTIONS, "plant_action", payload, function(status, response)
			if status ~= "ok" and response ~= nil and response.reason ~= nil then
				add_chat(nil, "can't plant: " .. tostring(response.reason), C_BAD)
			end
		end)
	elseif crop.stage < CROP_RIPE then
		add_chat(nil, "not ripe yet", C_DIM)
	else
		PHX:push(ACTIONS, "harvest_action", payload, function(status, response)
			if status == "ok" then
				Farm.carrots = Farm.carrots + 1
				add_chat(nil, "+1 carrot", C_OK)
			elseif response ~= nil and response.reason ~= nil then
				add_chat(nil, "can't harvest: " .. tostring(response.reason), C_BAD)
			end
		end)
	end
end

function in_reach(me, cell)
	local dx = cell[1] - me.x
	local dy = cell[2] - me.y
	local dz = cell[3] + 0.5 - me.z
	return dx * dx + dy * dy + dz * dz <= REACH * REACH
end

-- The outline cube around the targeted cell, parked far away when there is
-- none (only transforms sync on the web, so it's moved, never re-made).
function show_cursor(cell)
	if APP.cursor == nil then
		APP.cursor = make("cursor", 0, 0, -1000, 1)
	end
	local c = APP.cursor
	if cell == nil then
		c.z = -1000
	else
		c.x = cell[1]
		c.y = cell[2]
		c.z = cell[3]
	end
end

function edit_block(cell)
	local pos = { cell[1], cell[2], cell[3] }
	local payload = {}
	payload.position = pos
	local event = "dig_action"
	if APP.tool == "build" then
		event = "place_action"
		payload.block_type = PLACEABLE[APP.block_i]
	end
	PHX:push(ACTIONS, event, payload, function(status, response)
		if status ~= "ok" and response ~= nil and response.reason ~= nil then
			add_chat(nil, "can't: " .. tostring(response.reason), C_BAD)
		end
	end)
end

function do_emote(name)
	local me = APP.me
	me:play_emote(name)
	local payload = {}
	payload.emote = name
	PHX:push(LOBBY, "emote", payload)
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

function place_camera(x, y, z)
	local cl = cos(CAM.alt)
	local fx = cos(CAM.az) * cl
	local fy = sin(CAM.az) * cl
	local fz = sin(CAM.alt)
	local focus_z = z + 1.1
	CAM.x = x - fx * CAM.dist
	CAM.y = y - fy * CAM.dist
	CAM.z = focus_z - fz * CAM.dist
	local pos = { CAM.x, CAM.y, CAM.z }
	local rot = { CAM.az, CAM.alt }
	cam({ pos = pos, rot = rot })
end

-- ---------------------------------------------------------------------------
-- HUD

HUD_BTN_W = 72
HUD_BTN_H = 18
HUD_ROWS = 7 -- right-hand column: 4 emotes, face, pose, chat
HINT = "enter: chat  wasd: walk  1-4: tool  z/x: block  f: face  g: pose  5-8: emote  q/e: look"
TOOLS = { "walk", "dig", "build", "plant" }
TOOL_W = 60

-- Where everything on the HUD goes this frame. The gui can be as small as
-- 320x240, so nothing overlaps there: the button column hangs from the top
-- right, the toolbar sits on the bottom edge (the block picker wraps to a row
-- above it when it doesn't fit beside it), and chat stacks above those on the
-- left, clear of the column.
function hud_layout()
	local L = {}
	L.top_h = LH + PAD * 2
	L.col_x = gui.w - HUD_BTN_W - PAD * 2
	L.col_y = L.top_h + PAD * 2
	L.col_h = (HUD_BTN_H + PAD) * HUD_ROWS

	local tools_w = TOOL_W * #TOOLS + PAD * (#TOOLS - 1)
	local pick_w = TOOL_W * #PLACEABLE + PAD * (#PLACEABLE - 1)
	L.tb_y = gui.h - HUD_BTN_H - PAD * 2
	L.tb_x = flr((gui.w - tools_w) / 2)
	L.tb_w = tools_w
	L.pick = APP.tool == "build"
	L.pick_x = 0
	L.pick_y = L.tb_y
	L.pick_w = pick_w
	local bottom = L.tb_y
	if L.pick then
		local both = tools_w + PAD * 3 + pick_w
		if both <= gui.w - PAD * 4 then
			L.tb_x = flr((gui.w - both) / 2)
			L.pick_x = L.tb_x + tools_w + PAD * 3
		else
			L.pick_y = L.tb_y - HUD_BTN_H - PAD * 2
			L.pick_x = flr((gui.w - pick_w) / 2)
			bottom = L.pick_y
		end
	end
	L.hint = UI.text_w(HINT) <= gui.w - PAD * 4
	if L.hint then
		bottom = bottom - LH - PAD
	end
	L.chat_bottom = bottom - PAD
	local w = flr(gui.w * 0.45)
	if w < 160 then
		w = 160
	end
	local room = L.col_x - PAD * 3
	if w > room then
		w = room
	end
	L.chat_w = w
	return L
end

function hud_hit(x, y)
	local L = hud_layout()
	if y < L.top_h then
		return true
	end
	if x >= L.col_x and y >= L.col_y and y < L.col_y + L.col_h then
		return true
	end
	if y >= L.tb_y and x >= L.tb_x and x < L.tb_x + L.tb_w then
		return true
	end
	if L.pick and y >= L.pick_y and y < L.pick_y + HUD_BTN_H and x >= L.pick_x and x < L.pick_x + L.pick_w then
		return true
	end
	if APP.typing and x < PAD + L.chat_w and y >= L.chat_bottom - LH - PAD * 2 and y < L.chat_bottom then
		return true
	end
	return false
end

function draw_hud()
	local L = hud_layout()
	-- world overlays first so panels sit on top of them
	Herd.overlay()
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
	UI.panel(0, 0, gui.w, L.top_h, "0A0E16B0")
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
	if Farm.carrots > 0 then
		local carrots = tostring(Farm.carrots) .. " carrot"
		if Farm.carrots > 1 then
			carrots = carrots .. "s"
		end
		local cx = hx - UI.text_w(carrots) - PAD * 3
		-- only where it clears the status
		if cx > PAD * 2 + 6 * CH + UI.text_w(label) + PAD * 2 then
			UI.text(carrots, cx, PAD + 1, "EE842A")
		end
	end

	draw_chat(L)
	if APP.me ~= nil then
		draw_toolbar(L)
		draw_buttons(L)
		if L.hint and not APP.typing then
			UI.text(HINT, PAD * 2, L.chat_bottom + PAD + 1, "FFFFFF70")
		end
	end
end

-- Tools (1-4) and, while building, the block to place (Z/X).
function draw_toolbar(L)
	local x = L.tb_x
	local y = L.tb_y
	for i = 1, #TOOLS do
		local name = TOOLS[i]
		local label = tostring(i) .. " " .. name
		if APP.tool == name then
			gui:rrect(x - 1, y - 1, TOOL_W + 2, HUD_BTN_H + 2, 3, C_ACCENT)
		end
		if UI.button(label, x, y, TOOL_W, HUD_BTN_H) then
			APP.tool = name
		end
		x = x + TOOL_W + PAD
	end
	if not L.pick then
		return
	end
	x = L.pick_x
	y = L.pick_y
	for i = 1, #PLACEABLE do
		if APP.block_i == i then
			gui:rrect(x - 1, y - 1, TOOL_W + 2, HUD_BTN_H + 2, 3, C_OK)
		end
		local name = PLACEABLE[i]
		if UI.button(name, x, y, TOOL_W, HUD_BTN_H) then
			APP.block_i = i
		end
		x = x + TOOL_W + PAD
	end
end

function draw_buttons(L)
	local me = APP.me
	local x = L.col_x
	local y = L.col_y
	for i = 1, #EMOTES do
		local label = tostring(i + 4) .. " " .. EMOTES[i]
		if UI.button(label, x, y, HUD_BTN_W, HUD_BTN_H) then
			do_emote(EMOTES[i])
		end
		y = y + HUD_BTN_H + PAD
	end
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

function draw_chat(L)
	local w = L.chat_w
	local cols = flr((w - PAD * 2) / CH)
	local bottom = L.chat_bottom
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

	-- never climb into the top strip
	local max_rows = flr((bottom - L.top_h - PAD * 4) / LH)
	while #rows > max_rows and #rows > 0 do
		table.remove(rows)
	end

	if #rows > 0 then
		local h = #rows * LH + PAD * 2
		gui:rrect(PAD, bottom - h, w, h, 3, "0A0E1690")
		for r = 1, #rows do
			UI.text(rows[r].text, PAD * 2, bottom - PAD - r * LH + 1, rows[r].col)
		end
	end

	if APP.typing then
		local y = L.chat_bottom - LH - PAD * 2
		UI.panel(PAD, y, w, LH + PAD * 2, C_PANEL_HI)
		local shown = "> " .. APP.draft.text
		if #shown > cols - 1 then
			shown = shown:sub(#shown - cols + 2)
		end
		if UI.blink < 30 then
			shown = shown .. "_"
		end
		UI.text(shown, PAD * 2, y + PAD + 1, C_TEXT)
	end
end
