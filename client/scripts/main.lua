-- sosh — floating islands in a grid of universes, to hang out on together.
-- Petrichor64 client for the Phoenix server.
--
-- A universe is one cell of the grid: islands floating over the sea or
-- over wild land, with airships to fly between them and, off the edge of
-- the universe, into the next one. We're in one at a time, joined to its
-- two channels (`room:gx,gy` for people, `actions:gx,gy` for everything
-- else); flying into another, or being told we're elsewhere when joining,
-- swaps them for that universe's (enter_universe).
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
-- `move` goes out when our velocity changes by this much (tiles a second;
-- walking is 4.2, so about a 14 degree turn), at most every MOVE_MIN_GAP
-- seconds, and every MOVE_HEARTBEAT seconds while moving to correct drift
MOVE_TOLERANCE = 1
MOVE_MIN_GAP = 0.07
MOVE_HEARTBEAT = 1

-- camera: orbits the local avatar
CAM = { x = 0, y = 0, z = 0, az = 0, alt = -0.55, dist = 9 }

function main()
	attr({ title = "sosh", modernize = true })
	UI.init()
	world_build()

	APP = {}
	APP.screen = "connect"
	APP.focus = 1
	APP.server_field = UI.field(DEFAULT_SERVER, 64)
	APP.status = ""
	APP.web = detect_web()
	APP.players = {}
	APP.order = {}
	APP.me = nil
	APP.my_id = nil
	APP.chat = {}
	APP.typing = false
	APP.draft = UI.field("", CHAT_MAX)
	-- the motion we last told everyone about (send_move), and when
	APP.sent_at = 0
	APP.sent_vx = 0
	APP.sent_vy = 0
	APP.sent_to = nil
	-- whether the press now down began on the world (not the HUD)
	APP.press_world = false
	-- "walk", "dig", "build", "plant", "carry" or "craft"
	APP.tool = "walk"
	-- what the build tool places (an item in the bag), and the blueprint
	-- the craft tool lays out (an index into Furn.order)
	APP.build_item = nil
	APP.craft_i = 1
	-- quarter turns for furniture and blueprints (R)
	APP.rot = 0
	APP.cursor = nil
	APP.target = nil
	APP.fetch_tick = 0
	APP.universe = { 0, 0 }
	APP.kind = "sea"
	-- which sides have a neighbour: east, west, north, south
	APP.open = {}
	-- what we last asked our ship for, and when
	APP.steer = nil
	APP.steer_at = 0
	Blocks.init()
	Farm.init()
	Herd.init()
	Carry.init()
	Furn.init()
	Ships.init()
	Helpers.init()
	Bag.init()
	world_below("sea")
	Account.init()
	-- on the web the page's own server is ours: straight to signing in
	if APP.web then
		Account.start(SOCKET_PATH)
	end

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
	U.tick()
	UI.begin()
	if APP.screen == "connect" then
		connect_screen()
	elseif APP.screen == "auth" then
		auth_screen()
	elseif APP.screen == "home" then
		home_screen()
	elseif APP.screen == "creator" then
		creator_screen()
	else
		world_frame()
	end
end

function draw() end

-- ---------------------------------------------------------------------------
-- connect screen

-- Desktop only: which server. The web build's server is the page's.
function connect_screen()
	-- slow orbit of the empty plaza
	CAM.az = CAM.az + 0.0015
	place_camera(0, 0, GROUND_Z)

	local w = 260
	local h = 112
	local x = flr((gui.w - w) / 2)
	local y = flr((gui.h - h) / 2)
	UI.panel(x, y, w, h)
	UI.text("sosh", x + PAD * 3, y + PAD * 3, C_ACCENT)
	UI.text("islands in the sky to hang out on", x + PAD * 3, y + PAD * 3 + LH + 2, C_DIM)

	local fx = x + PAD * 3
	local fw = w - PAD * 6
	local fy = y + 40
	UI.draw_field("server", APP.server_field, fx, fy, fw, true)
	local go = UI.button("connect", x + w - PAD * 3 - 64, y + h - PAD * 3 - 18, 64, 18)
	if APP.status ~= "" then
		UI.text(APP.status, fx, y + h - PAD * 3 - 13, C_BAD)
	end
	local res = UI.type_into(APP.server_field)
	if res == "enter" then
		go = true
	end
	if go then
		local server = U.trim(APP.server_field.text)
		if server:sub(#server) == "/" then
			server = server:sub(1, #server - 1)
		end
		if server:sub(1, 5) ~= "ws://" and server:sub(1, 6) ~= "wss://" then
			server = "ws://" .. server
		end
		APP.status = ""
		Account.start(server .. SOCKET_PATH)
	end
end

-- ---------------------------------------------------------------------------
-- network

function universe_key(u)
	return tostring(u[1]) .. "," .. tostring(u[2])
end

-- Join universe `u`'s channels, leaving the ones we were in, with nothing
-- of the last universe left in view.
function enter_universe(u)
	if LOBBY ~= nil then
		PHX:leave(LOBBY)
	end
	if ACTIONS ~= nil then
		PHX:leave(ACTIONS)
	end
	clear_world()
	APP.universe = u
	local key = universe_key(u)
	APP.my_name = APP.account.handle
	local params = {}
	params.face = 0
	params.animation = 0
	if APP.me ~= nil then
		params.face = APP.me.face
		params.animation = APP.me.anim
	end
	LOBBY = PHX:channel("room:" .. key, params)
	bind_lobby(LOBBY)
	local ap = {}
	ACTIONS = PHX:channel("actions:" .. key, ap)
	bind_actions(ACTIONS)
	PHX:open(LOBBY)
	PHX:open(ACTIONS)
end

function clear_world()
	Blocks.clear()
	Farm.init()
	Herd.init()
	Carry.init()
	Furn.init()
	Ships.init()
	Helpers.init()
	Bag.box = nil
	while #APP.order > 0 do
		remove_player(APP.order[1])
	end
	APP.fetch_tick = 0
end

function bind_lobby(ch)
	ch.on_join = function(reply)
		APP.my_id = reply.user_id
		-- where the server says we stand: where we left off, aboard the
		-- ship we flew in on, or on the home island
		local at = reply.at
		if at == nil then
			at = { 0, 0, GROUND_Z }
		end
		if APP.me == nil then
			local look = APP.account.character
			APP.me = Avatar.new(reply.user_id, APP.my_name, at[1], at[2], at[3], 0, 0, look)
		else
			-- rejoined (a drop, another universe): new id, same body
			APP.me.id = reply.user_id
			APP.me:teleport(at[1], at[2], at[3])
		end
		local on = Furn.frame(reply.on)
		if on ~= nil and reply["local"] ~= nil then
			-- on deck, once we know where the ship is
			APP.me.on = on
			APP.me.wait = reply["local"]
		end
		APP.sent_on = nil
		APP.sent_at = 0
		if APP.server == nil then
			add_chat(nil, "in universe " .. universe_key(APP.universe), C_OK)
		end
	end
	ch.on_error = function(reply)
		if reply ~= nil and reply.reason == "elsewhere" and reply.universe ~= nil then
			-- we're in another universe: go there
			enter_universe(reply.universe)
			return
		end
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
		if av == nil or p.at == nil then
			return
		end
		local on = Furn.frame(p.on)
		if on ~= nil and p["local"] ~= nil then
			av:follow(p["local"], p.v, p.to, on)
		else
			av:follow(p.at, p.v, p.to, nil)
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
		-- in a server's universe the log has it already (account.lua)
		if APP.server == nil then
			local hex = C_TEXT
			if p.user_id ~= nil then
				hex = U.hex_for(p.user_id)
			end
			add_chat(name, p.body, hex)
		end
	end
	ch.on["character"] = function(p)
		local av = avatar_of(p.user_id)
		if av ~= nil then
			av:set_character(p.character)
		end
	end
end

-- Everything that happens in the universe (SoshWeb.ActionChannel).
function bind_actions(ch)
	ch.on_join = function(reply)
		-- (re)joined: anything we hold may be stale, so fetch it all again
		Blocks.have = {}
		Blocks.wanted = {}
		APP.fetch_tick = 0
		APP.kind = reply.kind or "sea"
		world_below(APP.kind)
		APP.open = reply.open or {}
		-- what there is, and what's in our bag
		Furn.set_catalog(reply.catalog)
		Bag.set(reply.bag)
		if APP.build_item == nil or Bag.count(APP.build_item) == 0 then
			APP.build_item = Bag.placeable()[1]
		end
		-- the reply is Sosh.Sim's snapshot: crops and cows, furniture and
		-- blueprints, ships and helpers
		Farm.sync(reply.crops or {})
		Herd.sync(reply.cows or {})
		Furn.sync(reply.furniture or {}, reply.sites or {})
		Ships.sync(reply.ships or {})
		Helpers.sync(reply.helpers or {})
		-- and who carries what, and what the universe lets anyone carry
		Carry.set_carryable(reply.carryable or {})
		Carry.sync(reply.held or {})
	end
	ch.on["block_changed"] = function(p)
		local pos = p.position
		Blocks.set(pos[1], pos[2], pos[3], p.block)
	end
	ch.on["crop"] = function(p)
		Farm.set(p.position, p.stage)
	end
	ch.on["cows"] = function(p)
		local rows = p.rows
		for i = 1, #rows do
			Herd.put(rows[i])
		end
	end
	ch.on["moo"] = function(p)
		Herd.moo(p.ids)
	end
	ch.on["carry"] = function(p)
		Carry.set(p)
	end
	ch.on["furniture"] = function(p)
		Furn.set(p)
	end
	ch.on["furniture_gone"] = function(p)
		Furn.gone(p.id)
	end
	ch.on["site"] = function(p)
		Furn.set_site(p)
	end
	ch.on["site_gone"] = function(p)
		Furn.site_gone(p.id)
	end
	ch.on["ships"] = function(p)
		local rows = p.rows
		for i = 1, #rows do
			Ships.put(rows[i])
		end
	end
	ch.on["ship"] = function(p)
		Ships.set(p)
	end
	ch.on["ship_block"] = function(p)
		Ships.block(p)
	end
	ch.on["helpers"] = function(p)
		local rows = p.rows
		for i = 1, #rows do
			Helpers.put(rows[i])
		end
	end
	-- a ship flew off the edge into the next universe; if we're aboard,
	-- so do we
	-- the ship flew into a server we aren't in: we stay, on the home island
	ch.on["stranded"] = function(p)
		if p.user_id == APP.my_id and APP.me ~= nil then
			APP.me:teleport(p.at[1], p.at[2], p.at[3])
			add_chat(nil, "you're not a member there: set down on the home island", C_BAD)
		end
	end
	ch.on["travel"] = function(p)
		Ships.remove(p.ship)
		local users = p.users
		for i = 1, #users do
			if users[i] == APP.my_id then
				add_chat(nil, "flying on into universe " .. universe_key(p.to) .. "...", C_ACCENT)
				enter_universe(p.to)
				return
			end
		end
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
		local look = p.character
		av = Avatar.new(p.user_id, p.name or "guest", x, y, z, p.face or 0, p.animation or 0, look)
		APP.players[p.user_id] = av
		table.insert(APP.order, p.user_id)
	else
		av:set_face(p.face or 0)
		av:set_anim(p.animation or 0)
	end
	-- `vec` is where the server reckons they are now (on a ship, `local`
	-- where on it); carry on from there
	local on = Furn.frame(p.on)
	if snap and on ~= nil and p["local"] ~= nil then
		av:follow(p["local"], p.v, p.to, on)
	elseif snap and p.vec ~= nil then
		av:follow(p.vec, p.v, p.to, nil)
	end
end

-- The avatar of a user id, ours included, or nil.
function avatar_of(id)
	if id ~= nil and id == APP.my_id then
		return APP.me
	end
	return APP.players[id]
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

-- Tell everyone how we're moving: where we are, our velocity in tiles a
-- second and where we're walking to, if anywhere. Everyone (the server too)
-- carries us along that until the next one, so this only goes out when the
-- motion changes, plus a heartbeat to correct drift (see world_frame).
-- Standing on a ship, all three are in its frame (`local`, with `on` its
-- id): it carries us, so only our own walking is news.
function send_move()
	local me = APP.me
	APP.sent_at = U.clock
	APP.sent_vx = me.vx
	APP.sent_vy = me.vy
	APP.sent_to = nil
	APP.sent_on = me.on
	local vx = me.vx
	local vy = me.vy
	local ax = U.round(me.x, 1000)
	local ay = U.round(me.y, 1000)
	local az = U.round(me.z, 1000)
	local at = { ax, ay, az }
	local payload = {}
	payload.at = at
	local s = Ships.get(me.on)
	if s ~= nil then
		local lx, ly, lz = Ships.to_local(s, me.x, me.y, me.z)
		local rx = U.round(lx, 1000)
		local ry = U.round(ly, 1000)
		local rz = U.round(lz, 1000)
		local here = { rx, ry, rz }
		payload.on = s.id
		payload["local"] = here
		local c = cos(s.h)
		local n = sin(s.h)
		local lvx = vx * c + vy * n
		vy = -vx * n + vy * c
		vx = lvx
	end
	local rvx = U.round(vx, 1000)
	local rvy = U.round(vy, 1000)
	local v = { rvx, rvy }
	payload.v = v
	if me.tx ~= nil and me.ton == me.on then
		local to = { me.tx, me.ty }
		payload.to = to
		APP.sent_to = to
	end
	-- a reconnect rejoins with these params
	LOBBY.params.vec = at
	PHX:push(LOBBY, "move", payload)
end

-- Whether our motion has drifted from what we last sent: a start, a stop,
-- a turn, a new destination, or a wall in the way.
function motion_changed(me)
	if me.on ~= APP.sent_on then
		return true -- stepped aboard or ashore
	end
	local to = APP.sent_to
	if me.tx ~= nil then
		-- walking to a point: everyone walks us there, so only a new point
		-- is news (giving up on it clears tx, and that is news below)
		return to == nil or to[1] ~= me.tx or to[2] ~= me.ty
	end
	if to ~= nil then
		return true
	end
	local dvx = me.vx - APP.sent_vx
	local dvy = me.vy - APP.sent_vy
	return dvx * dvx + dvy * dvy > MOVE_TOLERANCE * MOVE_TOLERANCE
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
		if APP.typing then
			chat_typing()
			if me:driven() then
				me:stop() -- the keys are for typing now
			end
		else
			world_keys(me)
		end
		world_pointer(me)
	end
	-- ships first: whoever's on deck is carried by them
	Ships.update(U.dt)
	if me ~= nil then
		me:update(U.dt)
		if Ships.piloted_by(APP.my_id) ~= nil then
			steer_ship(me)
		end
		if LOBBY.joined then
			local since = U.clock - APP.sent_at
			local moving = me.vx ~= 0 or me.vy ~= 0
			if motion_changed(me) and since >= MOVE_MIN_GAP then
				send_move()
			elseif moving and since >= MOVE_HEARTBEAT then
				send_move()
			end
		end
		-- walked away from what we had open
		if Bag.box ~= nil then
			local f = Furn.pieces[Bag.box]
			if f == nil or f.lifted or not in_reach(me, f.origin, f.on) then
				Bag.box = nil
			end
		end
	end

	for i = 1, #APP.order do
		APP.players[APP.order[i]]:update(U.dt)
	end
	Helpers.update(U.dt)
	Herd.update(me)
	Carry.update()
	Furn.update()

	if me ~= nil then
		place_camera(me.x, me.y, me.z)
	else
		CAM.az = CAM.az + 0.0015
		place_camera(0, 0, GROUND_Z)
	end

	draw_hud()
end


-- On a ship the camera stands well back, clear of the balloon.
SHIP_CAM_DIST = 14

function place_camera(x, y, z)
	local cl = cos(CAM.alt)
	local fx = cos(CAM.az) * cl
	local fy = sin(CAM.az) * cl
	local fz = sin(CAM.alt)
	local focus_z = z + 1.1
	local dist = CAM.dist
	if APP ~= nil and APP.me ~= nil and APP.me.on ~= nil and dist < SHIP_CAM_DIST then
		dist = SHIP_CAM_DIST
	end
	CAM.x = x - fx * dist
	CAM.y = y - fy * dist
	CAM.z = focus_z - fz * dist
	local pos = { CAM.x, CAM.y, CAM.z }
	local rot = { CAM.az, CAM.alt }
	cam({ pos = pos, rot = rot })
end
