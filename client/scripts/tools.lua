-- tools — what the keys and the pointer do in the world.
--
-- The tool decides what a click on the block under the pointer does:
--
--   walk   walk onto it; furniture that holds things, open it (bag.lua);
--          a ship's helm, take it
--   dig    dig it into the bag; furniture breaks (some of what it was made
--          of and all it held come back); scaffolding comes down
--   build  place what's picked from the bag (Z/X, or click it in the bag)
--          on the face it was hit through; furniture that packs into a
--          bag goes down turned (R)
--   plant  plant carrots on grass or dirt, or pick them once ripe
--   carry  lift a pot, a cow or furniture over your head, and put it down
--          on a face; heavy furniture needs a second carrier: another
--          player, or a helper (click one, or press H)
--   craft  lay out a blueprint (Z/X picks it, R turns it), then click its
--          scaffolding to put in the ingredients from the bag
--
-- Airships are blocks like any other: walk aboard, build on them, set
-- furniture down on deck. Every cell a tool aims at is in the world or in a
-- ship's own frame (`on`, its id), and goes to the server that way. At a
-- ship's helm (B) W/S drive it ahead and astern, A/D turn it, space/C climb
-- and sink.

TOOLS = { "walk", "dig", "build", "plant", "carry", "craft" }
EMOTE_KEYS = { "7", "8", "9", "0" }
STEER_HEARTBEAT = 1 -- seconds; restate the wanted velocity this often
CAM_TURN = 1.8 -- radians a second, Q/E

-- WASD / arrows walk relative to the camera (or, at a helm, steer); Q/E
-- turn it; F/G cycle face and pose (G puts down what we carry); 1-6 pick
-- the tool, Z/X what it uses, R turns it; 7-0 emote; I opens the bag; H
-- asks a helper for a hand; B takes the helm we stand at, or lets go;
-- Enter opens chat.
function world_keys(me)
	if key("enter", true) then
		APP.typing = true
		APP.draft.text = ""
		cin() -- swallow anything typed this frame
		return
	end
	for i = 1, #TOOLS do
		local k = tostring(i)
		if key(k, true) then
			APP.tool = TOOLS[i]
		end
	end
	if key("z", true) then
		cycle_pick(-1)
	end
	if key("x", true) then
		cycle_pick(1)
	end
	if key("r", true) then
		APP.rot = (APP.rot + 1) % 4
	end
	if key("i", true) then
		if Bag.open then
			Bag.close()
		else
			Bag.open = true
		end
	end
	if key("escape", true) then
		Bag.close()
	end
	if key("h", true) then
		call_nearest_helper(me)
	end
	if key("b", true) then
		helm_pressed(me)
	end
	for i = 1, #EMOTES do
		if key(EMOTE_KEYS[i], true) then
			do_emote(EMOTES[i])
		end
	end
	if key("f", true) then
		Creator.open()
	end
	if key("g", true) then
		pose_pressed()
	end
	-- on real time, so it turns as fast at any frame rate
	if key("q") then
		CAM.az = CAM.az + CAM_TURN * U.dt
	end
	if key("e") then
		CAM.az = CAM.az - CAM_TURN * U.dt
	end

	-- at the helm, the keys are the ship's (steer_ship)
	if Ships.piloted_by(APP.my_id) ~= nil then
		if me:driven() then
			me:stop()
		end
		return
	end
	local dx, dy = move_keys()
	if dx == 0 and dy == 0 then
		if me:driven() then
			me:stop()
		end
		return
	end
	if me.anim == 1 then
		change_anim(1) -- stand up to walk
	end
	me:drive(dx * AV_SPEED, dy * AV_SPEED)
end

-- The way WASD / the arrows point, relative to the camera: a unit vector,
-- or 0, 0.
function move_keys()
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
		return 0, 0
	end
	local fx = cos(CAM.az)
	local fy = sin(CAM.az)
	local dx = fx * fwd - fy * side
	local dy = fy * fwd + fx * side
	local l = sqrt(dx * dx + dy * dy)
	return dx / l, dy / l
end

-- At the helm: tell the ship how we'd like to go when that changes (and
-- now and then regardless): W/S ahead and astern, A/D turn to port and
-- starboard, space/C climb and sink.
function steer_ship(me)
	local thrust = 0
	local turn = 0
	local lift = 0
	if not APP.typing then
		if key("w") or key("up") then
			thrust = thrust + 1
		end
		if key("s") or key("down") then
			thrust = thrust - 1
		end
		if key("a") or key("left") then
			turn = turn + 1
		end
		if key("d") or key("right") then
			turn = turn - 1
		end
		if key("space") then
			lift = 1
		elseif key("c") then
			lift = -1
		end
	end
	local last = APP.steer
	local changed = last == nil or last[1] ~= thrust or last[2] ~= turn or last[3] ~= lift
	local moving = thrust ~= 0 or turn ~= 0 or lift ~= 0
	if changed or (moving and U.clock - APP.steer_at >= STEER_HEARTBEAT) then
		local helm = { thrust, turn, lift }
		local payload = {}
		payload.helm = helm
		if PHX:push(ACTIONS, "steer", payload) then
			APP.steer = helm
			APP.steer_at = U.clock
		end
	end
end

-- Z/X: the next or previous thing for the tool in hand.
function cycle_pick(d)
	if APP.tool == "craft" then
		local n = #Furn.order
		if n > 0 then
			APP.craft_i = (APP.craft_i - 1 + d) % n + 1
		end
		return
	end
	local items = Bag.placeable()
	if #items == 0 then
		return
	end
	local at = 0
	for i = 1, #items do
		if items[i] == APP.build_item then
			at = i
		end
	end
	if at == 0 then
		at = 1
	else
		at = (at - 1 + d) % #items + 1
	end
	APP.build_item = items[at]
	APP.tool = "build"
end

-- Build with `item` from now on (a click in the bag).
function pick_build_item(item)
	local info = Furn.items[item]
	if info ~= nil and (info.block ~= nil or info.furniture ~= nil) then
		APP.build_item = item
		APP.tool = "build"
	end
end

-- The blueprint the craft tool lays out.
function craft_kind()
	if #Furn.order == 0 then
		return nil
	end
	if APP.craft_i > #Furn.order then
		APP.craft_i = 1
	end
	return Furn.order[APP.craft_i]
end

-- The footprint of something `kind` at `cell`, turned the way R says.
function footprint(kind, cell)
	local k = Furn.kind(kind)
	if k == nil or cell == nil then
		return nil
	end
	return Furn.cells_of(cell, k.size, APP.rot)
end

function all_in_reach(me, cells, on)
	for i = 1, #cells do
		if not in_reach(me, cells[i], on) then
			return false
		end
	end
	return true
end

-- What a click would do, worked out every frame from the tool and what's
-- under the pointer: `cell` gets the cursor, `ghost` the green outline of
-- a footprint. Right-drag orbits; scroll zooms.
function world_pointer(me)
	local m = UI.mouse
	if m.m2 then
		CAM.az = CAM.az - m.dx * 4
		CAM.alt = U.clamp(CAM.alt + m.dy * 2, -1.3, -0.15)
	end
	if m.scroll ~= 0 then
		CAM.dist = U.clamp(CAM.dist - m.scroll * 1.5, 4, 22)
	end

	local tool = APP.tool
	local holding = Carry.of(APP.my_id)
	local hit = nil
	local cow = nil
	local helper = nil
	-- Buttons are drawn after this runs, so hit-test the HUD region directly.
	local over_hud = hud_hit(UI.mx, UI.my)
	if not over_hud then
		hit = Blocks.raycast(CAM.x, CAM.y, CAM.z, m.vx, m.vy, m.vz, 64)
		local d = 64
		if hit ~= nil then
			d = hit.dist
		end
		if tool == "carry" and holding == nil then
			cow = Herd.under_ray(CAM.x, CAM.y, CAM.z, m.vx, m.vy, m.vz, d)
		end
		if tool == "carry" and holding ~= nil and holding.furniture ~= nil then
			helper = Helpers.under_ray(CAM.x, CAM.y, CAM.z, m.vx, m.vy, m.vz, d)
		end
	end

	-- the cell a tool would act on, and any footprint to outline, in the
	-- frame of what was hit (the world's, or a ship's)
	local on = nil
	local cell = nil
	local ghost = nil
	local box = nil
	local helm = false
	if hit ~= nil then
		on = hit.on
		if tool == "walk" then
			local f = Furn.at(on, hit.hit[1], hit.hit[2], hit.hit[3])
			if f ~= nil and #Furn.pieces[f].slots > 0 then
				box = f
				cell = hit.hit
			elseif on ~= nil and hit.id == HELM then
				helm = true
				cell = hit.hit
			end
		elseif tool == "dig" then
			cell = hit.hit
		elseif tool == "build" then
			cell = hit.before
			local info = Furn.items[APP.build_item or ""]
			if info ~= nil and info.furniture ~= nil then
				ghost = footprint(info.furniture, cell)
			end
		elseif tool == "plant" then
			if on == nil then
				cell = plant_cell(hit)
			end
		elseif tool == "carry" then
			if holding ~= nil then
				cell = hit.before
				local f = nil
				if holding.furniture ~= nil then
					f = Furn.pieces[holding.furniture]
				end
				if f ~= nil and f.lifted then
					ghost = footprint(f.kind, cell)
				end
			elseif hit.id == FURNITURE or Carry.can_carry(hit.id) then
				cell = hit.hit
			end
		elseif tool == "craft" then
			if hit.id == SCAFFOLD then
				cell = hit.hit
			else
				cell = hit.before
				local kind = craft_kind()
				ghost = footprint(kind, cell)
			end
		end
	end
	if cow ~= nil then
		local at = { cow.x, cow.y, cow.z }
		cell = at
		on = nil
	end
	if helper ~= nil then
		ghost = nil
		cell = nil
	end
	if cell ~= nil and not in_reach(me, cell, on) then
		cell = nil
		cow = nil
		box = nil
		helm = false
	end
	if ghost ~= nil and not all_in_reach(me, ghost, on) then
		ghost = nil
		cell = nil
	end
	APP.target = cell
	if ghost ~= nil then
		show_cursor(nil)
	else
		show_cursor(cell, on)
	end
	Furn.show_ghost(ghost, on)

	if not UI.clicked or over_hud then
		return
	end
	if helper ~= nil then
		call_helper(helper.id)
		return
	end
	if cow ~= nil then
		pick_up_cow(cow)
		return
	end
	if hit == nil then
		return
	end
	if tool == "walk" then
		if box ~= nil then
			Bag.open_box(box)
			return
		end
		if helm then
			helm_action()
			return
		end
		if Ships.piloted_by(APP.my_id) ~= nil then
			return -- the keys steer; let go of the helm (B) to walk
		end
		local h = hit.hit
		-- hoisted: a call in the first argument miscompiles (SILT-BUGS.md #1)
		local frame = Ships.get(on)
		if Blocks.get_in(frame, h[1], h[2], h[3] + 1) == 0 then
			if me.anim == 1 then
				change_anim(1)
			end
			me:walk_to(h[1], h[2], on)
		end
	elseif cell == nil then
		return
	elseif tool == "plant" then
		farm_action(cell)
	elseif tool == "carry" then
		carry_action(cell, on)
	elseif tool == "craft" then
		craft_action(cell, on, hit.id == SCAFFOLD)
	elseif tool == "build" then
		place_action(cell, on)
	else
		dig_action(cell, on)
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

-- Push `event` and say what went wrong, if anything; a reply carrying the
-- bag updates ours. `then_fn(response)` runs on success.
function act(event, payload, verb, then_fn)
	PHX:push(ACTIONS, event, payload, function(status, response)
		if status == "ok" then
			if response ~= nil and response.bag ~= nil then
				Bag.set(response.bag)
			end
			if then_fn ~= nil then
				then_fn(response)
			end
		elseif response ~= nil and response.reason ~= nil then
			add_chat(nil, "can't " .. verb .. ": " .. say_reason(response.reason), C_BAD)
		end
	end)
end

-- The server's reasons, readable.
REASONS = {
	bag_full = "your bag is full",
	none_left = "you have none left",
	missing_ingredients = "you don't have what it needs",
	out_of_reach = "too far away",
	hands_full = "your hands are full",
	in_use = "someone has hold of it",
	edge_of_the_world = "that's the edge of the world",
	nothing_to_help_with = "pick up one end of something heavy first",
	no_helm_here = "stand at a ship's helm to steer it",
	someone_else_steers = "someone else is at the helm",
	last_block = "a ship needs at least one block",
	cows_stay_ashore = "cows stay ashore",
}

function say_reason(r)
	return REASONS[r] or tostring(r)
end

-- A cell to send: in the world, or on ship `on` (in its frame).
function cell_payload(cell, on)
	local pos = { cell[1], cell[2], cell[3] }
	local payload = {}
	payload.position = pos
	if on ~= nil then
		payload.on = on
	end
	return payload
end

function farm_action(cell)
	local crop = Farm.get(cell[1], cell[2], cell[3])
	local payload = cell_payload(cell)
	if crop == nil then
		act("plant_action", payload, "plant")
	elseif crop.stage < CROP_RIPE then
		add_chat(nil, "not ripe yet", C_DIM)
	else
		act("harvest_action", payload, "harvest", function(r)
			add_chat(nil, "+1 carrot", C_OK)
		end)
	end
end

function dig_action(cell, on)
	local payload = cell_payload(cell, on)
	act("dig_action", payload, "dig")
end

function place_action(cell, on)
	local item = APP.build_item
	if item == nil or Bag.count(item) == 0 then
		add_chat(nil, "nothing to build with: dig, or pick from your bag (I)", C_DIM)
		return
	end
	local payload = cell_payload(cell, on)
	payload.item = item
	payload.rot = APP.rot
	act("place_action", payload, "place that", function(r)
		if Bag.count(item) == 0 then
			APP.build_item = Bag.placeable()[1]
		end
	end)
end

-- Lay out the blueprint at `cell`, or put ingredients into the one there.
function craft_action(cell, on, scaffold)
	local payload = cell_payload(cell, on)
	if scaffold then
		act("deposit_action", payload, "build it", function(r)
			if r.built ~= nil then
				add_chat(nil, "built!", C_OK)
			end
		end)
		return
	end
	local kind = craft_kind()
	if kind == nil then
		return
	end
	payload.kind = kind
	payload.rot = APP.rot
	act("build_action", payload, "lay that out", function(r)
		add_chat(nil, kind .. " laid out: click it to put in " .. Furn.recipe_text(kind), C_DIM)
	end)
end

-- Pick up what's in `cell`, or put down what we hold there (furniture
-- turned as R says). The server's `carry` broadcast is what changes our
-- hands, for us as for everyone.
function carry_action(cell, on)
	local payload = cell_payload(cell, on)
	if Carry.of(APP.my_id) ~= nil then
		payload.rot = APP.rot
		act("put_down_action", payload, "put it down")
		return
	end
	act("pick_up_action", payload, "pick that up", function(r)
		if r.how == "gripped" then
			add_chat(nil, "it's heavy: someone has to take the other end (or press H for a helper)", C_DIM)
		elseif r.how == "pocketed" then
			add_chat(nil, "packed into your bag", C_OK)
		end
	end)
end

function pick_up_cow(cow)
	local payload = {}
	payload.cow = cow.id
	act("pick_up_action", payload, "pick it up")
end

function box_action(event, id, slot)
	local payload = {}
	payload.furniture = id
	payload.slot = slot
	act(event, payload, "move that")
end

-- Take the helm we stand at, or let go of the one we hold.
function helm_action()
	act("helm_action", {}, "take the helm", function(r)
		APP.steer = nil
		if r.ship ~= nil then
			APP.me:stop()
			add_chat(nil, "at the helm: W/S ahead and astern, A/D turn, space/C up and down, B to let go", C_DIM)
		else
			add_chat(nil, "you let go of the helm", C_DIM)
		end
	end)
end

-- B: the helm we hold, or the one we stand at.
function helm_pressed(me)
	if Ships.piloted_by(APP.my_id) == nil and Ships.helm_near(me.x, me.y, me.z) == nil then
		add_chat(nil, say_reason("no_helm_here"), C_DIM)
		return
	end
	helm_action()
end

function call_helper(id)
	local payload = {}
	payload.helper = id
	act("call_helper_action", payload, "call for help", function(r)
		add_chat(nil, "a helper is on the way", C_OK)
	end)
end

-- H: the nearest helper, if we're holding one end of something.
function call_nearest_helper(me)
	if Carry.furniture(APP.my_id) == nil then
		add_chat(nil, say_reason("nothing_to_help_with"), C_DIM)
		return
	end
	local best = nil
	local best_d = 0
	for id, h in pairs(Helpers.list) do
		local dx = h.av.x - me.x
		local dy = h.av.y - me.y
		local d = dx * dx + dy * dy
		if best == nil or d < best_d then
			best = id
			best_d = d
		end
	end
	if best ~= nil then
		call_helper(best)
	end
end

-- Stop carrying: put it down one cell ahead, where we face; on deck, in
-- the ship's frame.
function put_down_ahead()
	local me = APP.me
	local heading = me.heading
	local mx = me.x
	local my = me.y
	local mz = me.z
	local s = Ships.get(me.on)
	if s ~= nil then
		heading = heading - s.h
		local lx, ly, lz = Ships.to_local(s, me.x, me.y, me.z)
		mx = lx
		my = ly
		mz = lz
	end
	local fx = cos(heading)
	local fy = sin(heading)
	local x = Blocks.cell(mx)
	local y = Blocks.cell(my)
	if math.abs(fx) >= math.abs(fy) then
		if fx < 0 then
			x = x - 1
		else
			x = x + 1
		end
	elseif fy < 0 then
		y = y - 1
	else
		y = y + 1
	end
	local z = flr(mz + 0.01)
	local cell = { x, y, z }
	local on = nil
	if s ~= nil then
		on = s.id
	end
	carry_action(cell, on)
end

-- G and the pose button: let go of the helm, put down what we carry, else
-- sit or stand.
function pose_pressed()
	if Ships.piloted_by(APP.my_id) ~= nil then
		helm_action()
	elseif Carry.of(APP.my_id) ~= nil then
		put_down_ahead()
	else
		change_anim(1)
	end
end

-- Is `cell` (of the world, or ship `on`'s) within reach of `me`?
function in_reach(me, cell, on)
	local x, y, z = Ships.frame_pos(on, cell[1], cell[2], cell[3] + 0.5)
	if x == nil then
		return false
	end
	local dx = x - me.x
	local dy = y - me.y
	local dz = z - me.z
	return dx * dx + dy * dy + dz * dz <= REACH * REACH
end

-- The outline cube around the targeted cell (of the world, or ship `on`'s),
-- parked far away when there is none (only transforms sync on the web, so
-- it's moved, never re-made).
function show_cursor(cell, on)
	if APP.cursor == nil then
		APP.cursor = make("cursor", 0, 0, -1000, 1)
	end
	local c = APP.cursor
	if cell == nil then
		c.z = -1000
		return
	end
	local x, y, z, rz = Ships.frame_pos(on, cell[1], cell[2], cell[3])
	if x == nil then
		c.z = -1000
		return
	end
	c.x = x
	c.y = y
	c.z = z
	c.rz = rz
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
		if body:sub(1, 1) == "/" then
			Account.command(body)
		elseif body ~= "" then
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
