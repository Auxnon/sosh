-- book — the blueprints book: a 3D book over the world (or, in book mode,
-- alone), whose pages show what can be made and how, step by step.
--
-- The model (assets/book.glb, from tools/gen_assets.py) is skinned: its
-- right half (`cover_r`) folds over the left to shut it, and one leaf
-- (`leaf`) turns from the right page to the left. Its one texture,
-- "book", holds four pages side by side (left, right, and the two faces
-- of the leaf) and the leather; each page is drawn with nimg and the lot
-- uploaded with tex("book", ...) only when something on them changes.
--
-- Spreads: the index (recipe nil), searchable, with what's in progress;
-- then, for a chosen thing, an overview (spread 0) and one spread per
-- step of its plan (Recipes.plan: precursors first, skipping what the bag
-- has). Each step is ready or waiting by the bag and the server's
-- `stations`; "do it" opens its station (stations.lua), which closes
-- itself on success, and the book moves on.
--
-- Turning forward, the leaf shows the old right page on its front and the
-- new left page on its back; the new right page is already under it.
-- Backward, the other way round.
--
-- Hooks: a host (the apps) calls the global hook(key, value): `open`,
-- `close`, `search` (the index filtered by the text), `show` (an item's
-- recipe) and `mode` (`book`: a screen with only the book). We tell it
-- `book` "open" / "closed" and `step` "<recipe>/<spread>" ("" on the
-- index) through host.hook, when the engine has it. `/hook key value` in
-- chat feeds the same handler.

Book = {}

-- the texture's layout: keep in step with BOOK_* in tools/gen_assets.py
BOOK_TEX_W = 768
BOOK_TEX_H = 240
BOOK_PW = 176
BOOK_PH = 220
BOOK_LEATHER = { 704, 0, 32, 32 }
BOOK_EDGE = { 736, 0, 32, 32 }
-- the model's measures, in tiles: a page's width and half height, the
-- pages' top over the spine, and the whole thing open
BOOK_W = 1.5
BOOK_HH = 0.9375
BOOK_T = 0.1875
BOOK_SPAN_W = 3.125
BOOK_SPAN_H = 2
-- how much of the world's view it takes at most, across and up
BOOK_FILL_W = 0.86
BOOK_FILL_H = 0.8
-- tipped back from facing the camera, as if lying on a lectern
BOOK_LEAN = 0.42
BOOK_OPEN_TIME = 0.45 -- seconds to open or shut
BOOK_TURN_TIME = 0.5 -- seconds a page takes to turn
BOOK_ROW = 10 -- a line of the index
BOOK_QUERY_MAX = 24

-- ink on the pages
P_PAPER = "FFF4D6"
P_RULE = "E6D6B0"
P_INK = "4A3B2A"
P_DIM = "8A7458"
P_GOOD = "3E8A2E"
P_BAD = "C04838"
P_MARK = "F7A531"

GESTURE_TEXT = {
	saw = "draw one straight line square across the plank",
	veneer = "one long straight stroke along the block, end to end",
	spin = "circle the wheel once, evenly",
	weave = "swipe across the loom and back, four times",
	assemble = "put the parts together",
}

RAW_HINTS = {
	wool = "shear a sheep",
	wood = "dig a tree",
	stone = "dig stone",
}

function Book.init()
	Book.up = false
	Book.ent = nil
	Book.cover = 0
	Book.turn = nil
	local v = {}
	v.recipe = nil
	v.spread = 0
	Book.view = v
	Book.plan = nil
	Book.dirty = true
	Book.query = UI.field("", BOOK_QUERY_MAX)
	Book.hot = {}
	Book.made = nil
	Book.for_station = false
	Book.sent_step = nil
	Book.note = nil
	Book.note_t = 0
	Book.pages = nil
end

-- Something the pages show changed (the bag, the catalog, the stations).
function Book.changed()
	Book.dirty = true
end

-- Whether the book has the screen (and the keys and the pointer).
function Book.is_up()
	return Book.up
end

-- -- opening, closing, and the hooks

function Book.open_book()
	if Book.up then
		return
	end
	Book.up = true
	Book.for_station = false
	-- back where we left off: the latest recipe in progress
	if Book.view.recipe == nil then
		local latest, step = Recipes.latest()
		if latest ~= nil then
			local v = {}
			v.recipe = latest
			v.spread = step
			Book.view = v
		end
	end
	Book.dirty = true
	cin() -- nothing typed before it opened
	Book.hook_out("book", "open")
end

function Book.close()
	if not Book.up then
		return
	end
	Book.up = false
	Book.hook_out("book", "closed")
end

function Book.toggle()
	if Book.up then
		Book.close()
	else
		Book.open_book()
	end
end

-- Tell the host something, if the engine lets us (host.hook is new).
function Book.hook_out(key, value)
	if host == nil or host.hook == nil then
		return
	end
	host.hook(key, value or "")
end

-- From the host (or `/hook` in chat).
function Book.on_hook(key, value)
	if APP == nil or key == nil then
		return
	end
	local v = value or ""
	if key == "open" then
		Book.open_book()
	elseif key == "close" then
		Book.close()
	elseif key == "search" then
		Book.search(v)
	elseif key == "show" then
		Book.open_book()
		Book.show(v)
	elseif key == "mode" then
		if v == "book" then
			Book.enter_mode()
		elseif v == "world" then
			Book.leave_mode()
		end
	end
end

-- The index, filtered by `text`.
function Book.search(text)
	local t = text:sub(1, BOOK_QUERY_MAX)
	Book.query.text = t
	Book.open_book()
	if Book.view.recipe ~= nil then
		Book.to_index()
	else
		Book.dirty = true
	end
end

-- -- moving about

-- To `view` ({recipe, spread}), turning the page `dir` (1 on, -1 back).
function Book.go(view, dir)
	if Book.turn ~= nil then
		Book.end_turn()
	end
	local old = Book.view
	Book.view = view
	Book.made = nil
	if view.recipe ~= nil then
		Recipes.remember(view.recipe, view.spread)
	end
	if Book.ent == nil or Book.cover < 1 or Book.pages == nil then
		Book.dirty = true
		return
	end
	Book.start_turn(old, view, dir)
end

function Book.to_index()
	local v = {}
	v.recipe = nil
	v.spread = 0
	Book.go(v, -1)
end

-- An item's recipe, where it was left (or at `spread`).
function Book.show(item)
	if item == nil or item == "" then
		return
	end
	if Recipes.have_catalog and Recipes.making[item] == nil then
		Book.say("nothing makes " .. item)
		return
	end
	local v = {}
	v.recipe = item
	v.spread = Recipes.step_of(item) or 0
	Book.go(v, 1)
end

function Book.go_spread(k)
	local cur = Book.view
	if cur.recipe == nil or k == cur.spread then
		return
	end
	local dir = 1
	if k < cur.spread then
		dir = -1
	end
	local v = {}
	v.recipe = cur.recipe
	v.spread = k
	Book.go(v, dir)
end

-- How many spreads the recipe open has past the overview.
function Book.last_spread()
	if Book.plan == nil then
		return 0
	end
	return #Book.plan.steps
end

function Book.next()
	local cur = Book.view
	if cur.recipe == nil then
		return
	end
	local last = Book.last_spread()
	if cur.spread < last then
		Book.go_spread(cur.spread + 1)
	end
end

function Book.prev()
	local cur = Book.view
	if cur.recipe == nil then
		return
	end
	if cur.spread > 0 then
		Book.go_spread(cur.spread - 1)
	else
		Book.to_index()
	end
end

-- A word on the page's edge for a moment (in the overlay).
function Book.say(text)
	Book.note = text
	Book.note_t = U.clock
end

-- -- doing a step

-- The step on spread `k`: off to its station, or done here by hand.
function Book.do_step(k)
	local plan = Book.plan
	if plan == nil then
		return
	end
	local e = plan.steps[k]
	if e == nil then
		return
	end
	local st = e.step
	local ok, why, what = Recipes.ready(st)
	if not ok then
		local wt = Book.waiting_text(why, what)
		Book.say(wt)
		return
	end
	local from = {}
	from.recipe = Book.view.recipe
	from.spread = k
	local kind = Recipes.station_of(st)
	local in_world = not APP.book_mode and ACTIONS ~= nil and ACTIONS.joined
	if not in_world then
		if kind ~= nil then
			Book.say("that's done at a station, in a world")
			return
		end
		if not st.to_bag then
			Book.say("that's finished in a world: it's too big for a bag")
			return
		end
		Station.craft_by_hand(st, from)
		return
	end
	if kind == nil and not st.stroke then
		Station.send(st, nil, from)
		return
	end
	-- the station takes over; the book comes back when it's done
	Book.up = false
	Book.for_station = true
	Book.hook_out("book", "closed")
	Station.open(kind, nil, st, from)
end

-- A step from the book was done (Station.reply): on to the next, or the
-- whole thing's made.
function Book.step_done(from, made)
	if from == nil then
		return
	end
	if made ~= nil and made.step == from.recipe then
		Recipes.forget(from.recipe)
		local v = {}
		v.recipe = from.recipe
		v.spread = 0
		Book.view = v
		Book.made = from.recipe
	else
		local v = {}
		v.recipe = from.recipe
		v.spread = from.spread
		Book.view = v
		Recipes.remember(from.recipe, from.spread)
	end
	Book.dirty = true
	Book.reopen()
end

-- The station opened from the book was closed (done or not): the book
-- again.
function Book.reopen()
	if Book.for_station then
		Book.for_station = false
		Book.up = true
		Book.hook_out("book", "open")
	end
end

-- Why a step waits, for a page or a note.
function Book.waiting_text(why, what)
	if why == "missing" then
		local name = Recipes.pretty(what)
		return "waiting: short of " .. name
	end
	if why == "station" then
		local name = Recipes.pretty(what)
		if APP.book_mode or APP.screen ~= "world" then
			return "waiting: needs a " .. name .. ", in a world"
		end
		return "waiting: no " .. name .. " near"
	end
	return "waiting"
end

-- -- every frame

-- Open, shut, turn and place the book, and act on the pointer. After the
-- camera is placed.
function Book.frame()
	if not Book.up and Book.ent == nil then
		return
	end
	Book.ensure()
	local want = 0
	if Book.up then
		want = 1
	end
	local step = U.dt / BOOK_OPEN_TIME
	if Book.cover < want then
		Book.cover = U.clamp(Book.cover + step, 0, 1)
	elseif Book.cover > want then
		Book.cover = U.clamp(Book.cover - step, 0, 1)
	end
	local e = Book.ent
	if Book.cover <= 0 and not Book.up then
		e.z = -1000
		return
	end
	if Book.turn ~= nil then
		Book.turn.t = Book.turn.t + U.dt / BOOK_TURN_TIME
		if Book.turn.t >= 1 then
			Book.end_turn()
		end
	end
	if Book.dirty and Book.turn == nil then
		Book.repaint()
	end
	Book.place()
	Book.pose()
	if Book.up and Book.cover >= 1 and Book.turn == nil then
		Book.pointer()
	end
end

-- The keys, while it's up: typing searches, arrows turn, Esc shuts it.
function Book.keys()
	local before = Book.query.text
	local res = UI.type_into(Book.query)
	if res == "escape" then
		Book.close()
		return
	end
	if Book.query.text ~= before then
		if Book.view.recipe ~= nil then
			Book.to_index()
		else
			Book.dirty = true
		end
		Book.hook_out("search", Book.query.text)
	end
	if key("right", true) then
		Book.next()
	end
	if key("left", true) then
		Book.prev()
	end
end

function Book.ensure()
	if Book.ent ~= nil then
		return
	end
	local e = make("book", 0, 0, -1000, 1)
	e.zyx = true
	e.unlit = true
	Book.ent = e
	local pages = {}
	pages.l = nimg(BOOK_PW, BOOK_PH)
	pages.r = nimg(BOOK_PW, BOOK_PH)
	pages.f = nimg(BOOK_PW, BOOK_PH)
	pages.b = nimg(BOOK_PW, BOOK_PH)
	Book.pages = pages
	local atlas = nimg(BOOK_TEX_W, BOOK_TEX_H)
	atlas:fill("000000")
	-- the leather and the page edges, once
	local l = BOOK_LEATHER
	atlas:rect(l[1], l[2], l[3], l[4], "7A3E2A")
	for i = 0, 7 do
		local lx = l[1] + i * 4
		atlas:rect(lx, l[2] + i * 3, 2, 1, "602E20")
	end
	local g = BOOK_EDGE
	atlas:rect(g[1], g[2], g[3], g[4], "F6ECD2")
	for i = 0, 10 do
		local gy = g[2] + i * 3
		atlas:rect(g[1], gy, g[3], 1, "E2D4B4")
	end
	Book.atlas = atlas
	Book.dirty = true
end

-- In front of the camera, in the middle of the world's view, sized to fit.
function Book.place()
	local e = Book.ent
	-- a first guess at how far ahead it goes; Book.fit corrects it from
	-- where its corners actually land
	if Book.dist == nil then
		local th = 0.41421356
		local aspect = gui.w / gui.h
		local dw = BOOK_SPAN_W / (BOOK_FILL_W * 2 * th * aspect)
		local dh = BOOK_SPAN_H / (BOOK_FILL_H * 2 * th)
		local d0 = dw
		if dh > d0 then
			d0 = dh
		end
		Book.dist = d0
		Book.lift = 0
	end
	local d = Book.dist
	local sx = flr(VIEW_W / 2)
	local sy = flr(gui.h * 0.5) + Book.lift
	local x, y, z = UI.unproject(sx, sy, d)
	local rx = math.pi / 2 + CAM.alt - BOOK_LEAN
	local rz = CAM.az - math.pi / 2
	e.x = x
	e.y = y
	e.z = z
	e.rx = rx
	e.ry = 0
	e.rz = rz
	-- its axes, for finding where on a page the pointer is: the entity's
	-- rotation with rx first, then rz (zyx)
	local B = {}
	B.ox = x
	B.oy = y
	B.oz = z
	local cr = cos(rz)
	local sr = sin(rz)
	local cx = cos(rx)
	local sx2 = sin(rx)
	local bx = { cr, sr, 0 }
	local nyx = -cx * sr
	local nyy = cx * cr
	local by = { nyx, nyy, sx2 }
	local nzx = sx2 * sr
	local nzy = -sx2 * cr
	local bz = { nzx, nzy, cx }
	B.ex = bx
	B.ey = by
	B.ez = bz
	Book.basis = B
	Book.fit(B)
end

-- Where the open spread's corners land on the screen, and the distance
-- and height that make it fill BOOK_FILL of the view, centred: closer to
-- right each frame (size goes as one over distance).
function Book.fit(B)
	local minx = 100000
	local maxx = -100000
	local miny = 100000
	local maxy = -100000
	local hw = BOOK_SPAN_W / 2
	for i = 0, 3 do
		local u = -hw
		if i % 2 == 1 then
			u = hw
		end
		local v = -BOOK_HH
		if i >= 2 then
			v = BOOK_HH
		end
		local px = B.ox + B.ex[1] * u + B.ey[1] * v + B.ez[1] * BOOK_T
		local py = B.oy + B.ex[2] * u + B.ey[2] * v + B.ez[2] * BOOK_T
		local pz = B.oz + B.ex[3] * u + B.ey[3] * v + B.ez[3] * BOOK_T
		local p = UI.project(px, py, pz)
		if p == nil then
			-- behind us: back off
			Book.dist = Book.dist * 1.5
			return
		end
		minx = math.min(minx, p[1])
		maxx = math.max(maxx, p[1])
		miny = math.min(miny, p[2])
		maxy = math.max(maxy, p[2])
	end
	local w = maxx - minx
	local h = maxy - miny
	if w < 1 or h < 1 then
		return
	end
	local rw = w / (VIEW_W * BOOK_FILL_W)
	local rh = h / (gui.h * BOOK_FILL_H)
	local r = math.max(rw, rh)
	r = U.clamp(r, 0.5, 2)
	Book.dist = U.clamp(Book.dist * r, 1, 40)
	local mid = (miny + maxy) / 2
	local want = gui.h * 0.52
	Book.lift = U.clamp(Book.lift + (want - mid) * 0.5, -gui.h * 0.4, gui.h * 0.4)
end

-- Smooth in and out, 0..1.
function Book.ease(t)
	local c = U.clamp(t, 0, 1)
	return c * c * (3 - 2 * c)
end

-- The covers and the leaf.
function Book.pose()
	local e = Book.ent
	local open = Book.ease(Book.cover)
	local shut = -math.pi * (1 - open)
	local cr = { 0, shut, 0 }
	e:bone("cover_r", cr)
	local leaf = shut
	local t = Book.turn
	if t ~= nil then
		local k = Book.ease(t.t)
		if t.dir > 0 then
			leaf = -math.pi * k
		else
			leaf = -math.pi * (1 - k)
		end
	end
	local lr = { 0, leaf, 0 }
	e:bone("leaf", lr)
end

-- Where the pointer's ray meets the pages: "l" or "r", and the pixel on
-- that page; nil off them.
function Book.hit_page()
	local B = Book.basis
	if B == nil then
		return nil
	end
	local m = UI.mouse
	local ez = B.ez
	-- the pages' plane: T over the spine, along ez
	local px = B.ox + ez[1] * BOOK_T
	local py = B.oy + ez[2] * BOOK_T
	local pz = B.oz + ez[3] * BOOK_T
	local dn = m.vx * ez[1] + m.vy * ez[2] + m.vz * ez[3]
	if math.abs(dn) < 0.0001 then
		return nil
	end
	local t = ((px - CAM.x) * ez[1] + (py - CAM.y) * ez[2] + (pz - CAM.z) * ez[3]) / dn
	if t <= 0 then
		return nil
	end
	local hx = CAM.x + m.vx * t - px
	local hy = CAM.y + m.vy * t - py
	local hz = CAM.z + m.vz * t - pz
	local ex = B.ex
	local ey = B.ey
	local lx = hx * ex[1] + hy * ex[2] + hz * ex[3]
	local ly = hx * ey[1] + hy * ey[2] + hz * ey[3]
	if ly < -BOOK_HH or ly > BOOK_HH or lx < -BOOK_W or lx > BOOK_W then
		return nil
	end
	local fy = (BOOK_HH - ly) / (BOOK_HH * 2) * BOOK_PH
	if lx < 0 then
		local fx = (lx + BOOK_W) / BOOK_W * BOOK_PW
		return "l", flr(fx), flr(fy)
	end
	local fx = lx / BOOK_W * BOOK_PW
	return "r", flr(fx), flr(fy)
end

-- The pointer on the pages: what's under it takes a tap.
function Book.pointer()
	local side, px, py = Book.hit_page()
	if side == nil then
		return
	end
	local h = nil
	for i = 1, #Book.hot do
		local r = Book.hot[i]
		if r.side == side and px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h then
			h = r
		end
	end
	if h == nil then
		return
	end
	UI.hot = true
	if UI.tapped then
		Book.act(h)
	end
end

function Book.act(h)
	if h.act == "show" then
		Book.show(h.arg)
	elseif h.act == "index" then
		Book.to_index()
	elseif h.act == "spread" then
		Book.go_spread(h.arg)
	elseif h.act == "next" then
		Book.next()
	elseif h.act == "prev" then
		Book.prev()
	elseif h.act == "do" then
		Book.do_step(h.arg)
	end
end

-- -- painting

-- The plan for the recipe of `view`, or nil on the index.
function Book.plan_for(view)
	if view.recipe == nil or not Recipes.have_catalog then
		return nil
	end
	local p = Recipes.plan(view.recipe)
	return p
end

-- Draw the spread on show, both pages, and the leaf as the right page.
function Book.repaint()
	local v = Book.view
	Book.plan = Book.plan_for(v)
	if v.recipe ~= nil then
		local last = Book.last_spread()
		if v.spread > last then
			v.spread = last
		end
		if v.spread < 0 then
			v.spread = 0
		end
	end
	Book.hot = {}
	local P = Book.pages
	Book.paint(P.l, v, Book.plan, "l", true)
	Book.paint(P.r, v, Book.plan, "r", true)
	Book.paint(P.f, v, Book.plan, "r", false)
	Book.compose()
	Book.dirty = false
	-- where we are, for the host
	local where = ""
	if v.recipe ~= nil then
		where = v.recipe .. "/" .. tostring(v.spread)
	end
	if where ~= Book.sent_step then
		Book.sent_step = where
		Book.hook_out("step", where)
	end
end

function Book.compose()
	local a = Book.atlas
	local P = Book.pages
	a:img(P.l, 0, 0)
	a:img(P.r, BOOK_PW, 0)
	a:img(P.f, BOOK_PW * 2, 0)
	a:img(P.b, BOOK_PW * 3, 0)
	tex("book", a)
end

-- Turning from `old` to `new`: the pages under the leaf and its two faces.
function Book.start_turn(old, new, dir)
	local P = Book.pages
	local old_plan = Book.plan
	local new_plan = Book.plan_for(new)
	if dir > 0 then
		Book.paint(P.l, old, old_plan, "l", false)
		Book.paint(P.f, old, old_plan, "r", false)
		Book.paint(P.b, new, new_plan, "l", false)
		Book.paint(P.r, new, new_plan, "r", false)
	else
		Book.paint(P.b, old, old_plan, "l", false)
		Book.paint(P.r, old, old_plan, "r", false)
		Book.paint(P.l, new, new_plan, "l", false)
		Book.paint(P.f, new, new_plan, "r", false)
	end
	Book.compose()
	Book.hot = {}
	local t = {}
	t.dir = dir
	t.t = 0
	Book.turn = t
end

function Book.end_turn()
	Book.turn = nil
	Book.repaint()
end

-- A clickable patch of a page, kept only for the spread on show.
function Book.hotspot(rec, side, x, y, w, h, act, arg)
	if not rec then
		return
	end
	local r = {}
	r.side = side
	r.x = x
	r.y = y
	r.w = w
	r.h = h
	r.act = act
	r.arg = arg
	table.insert(Book.hot, r)
end

-- Text on a page, at whole pixels.
function Book.text(im, s, x, y, col)
	local px = flr(x)
	local py = flr(y)
	im:text(s, px, py, col)
end

-- Text centred on a page.
function Book.centre(im, s, y, col)
	local w = #s * CH
	local x = flr((BOOK_PW - w) / 2)
	Book.text(im, s, x, y, col)
end

-- `s` cut to `n` characters.
function Book.cut(s, n)
	if #s <= n then
		return s
	end
	local short = s:sub(1, n - 1)
	return short .. "."
end

-- One page (`side` "l" or "r") of `view`.
function Book.paint(im, view, plan, side, rec)
	im:fill(P_PAPER)
	im:rect(0, 0, BOOK_PW, 1, P_RULE)
	im:rect(0, BOOK_PH - 1, BOOK_PW, 1, P_RULE)
	-- the gutter's shade, by the spine
	if side == "l" then
		im:rect(BOOK_PW - 3, 0, 3, BOOK_PH, P_RULE)
	else
		im:rect(0, 0, 3, BOOK_PH, P_RULE)
	end
	if not Recipes.have_catalog then
		Book.paint_empty(im, side)
		return
	end
	if view.recipe == nil then
		if side == "l" then
			Book.paint_index_left(im, rec)
		else
			Book.paint_index_right(im, rec)
		end
		return
	end
	if plan == nil then
		return
	end
	if view.spread == 0 then
		if side == "l" then
			Book.paint_overview_left(im, view, plan, rec)
		else
			Book.paint_overview_right(im, view, plan, rec)
		end
		return
	end
	local e = plan.steps[view.spread]
	if e == nil then
		return
	end
	if side == "l" then
		Book.paint_step_left(im, view, plan, e, rec)
	else
		Book.paint_step_right(im, view, plan, e, rec)
	end
end

-- No catalog yet: it comes with a world (the actions channel's join).
function Book.paint_empty(im, side)
	if side == "l" then
		Book.centre(im, "blueprints", 12, P_INK)
		return
	end
	local lines = U.wrap("the blueprints come with a world: step into one and they'll be here", 19)
	for i = 1, #lines do
		local y = 40 + (i - 1) * 12
		Book.text(im, lines[i], 12, y, P_DIM)
	end
end

-- Lines of wrapped text from (x, y); returns the y after them.
function Book.para(im, text, x, y, cols, col)
	local lines = U.wrap(text, cols)
	for i = 1, #lines do
		local ly = y + (i - 1) * 11
		Book.text(im, lines[i], x, ly, col)
	end
	return y + #lines * 11
end

-- The index's left page: the title, what's typed, and what's in progress.
function Book.paint_index_left(im, rec)
	Book.centre(im, "blueprints", 10, P_INK)
	im:rect(40, 21, BOOK_PW - 80, 1, P_RULE)
	-- the search
	im:rrect(10, 28, BOOK_PW - 20, 16, 3, P_RULE)
	local q = Book.query.text
	local shown = "find: " .. q .. "_"
	local col = P_INK
	if q == "" then
		shown = "find: type a name"
		col = P_DIM
	end
	local cut = Book.cut(shown, 19)
	Book.text(im, cut, 14, 32, col)
	-- recipes in progress, the latest first
	local hist = Recipes.history()
	local y = 54
	if #hist == 0 then
		Book.para(im, "nothing started yet: pick something to make", 12, y, 19, P_DIM)
		return
	end
	Book.text(im, "in progress", 12, y, P_DIM)
	y = y + 14
	for i = 1, #hist do
		if y > BOOK_PH - 24 then
			return
		end
		local h = hist[i]
		Icons.draw(im, h.recipe, 12, y, 1)
		local name = Recipes.pretty(h.recipe)
		local label = Book.cut(name, 12)
		Book.text(im, label, 24, y, P_INK)
		local st = "step " .. tostring(h.step)
		if h.step == 0 then
			st = "begun"
		end
		Book.text(im, st, 124, y, P_DIM)
		Book.hotspot(rec, "l", 8, y - 2, BOOK_PW - 16, BOOK_ROW + 2, "show", h.recipe)
		y = y + BOOK_ROW + 4
	end
end

-- The index's right page: everything that can be made, as filtered.
function Book.paint_index_right(im, rec)
	Book.centre(im, "make", 10, P_INK)
	im:rect(40, 21, BOOK_PW - 80, 1, P_RULE)
	local list = Recipes.index(Book.query.text)
	if #list == 0 then
		local q = Book.query.text
		Book.para(im, "nothing called \"" .. q .. "\"", 12, 34, 19, P_DIM)
		return
	end
	local rows = flr((BOOK_PH - 40) / BOOK_ROW)
	local y = 28
	for i = 1, #list do
		if i > rows then
			local more = "+" .. tostring(#list - rows) .. " more: search"
			Book.text(im, more, 12, y, P_DIM)
			return
		end
		local item = list[i]
		Icons.draw(im, item, 12, y, 1)
		local name = Recipes.pretty(item)
		local label = Book.cut(name, 15)
		Book.text(im, label, 24, y, P_INK)
		-- a dot when its own step could be done right now
		local st = Recipes.making[item]
		if st ~= nil then
			local ok = Recipes.ready(st)
			if ok then
				im:rrect(BOOK_PW - 18, y + 1, 6, 6, 3, P_GOOD)
			end
		end
		Book.hotspot(rec, "r", 8, y - 1, BOOK_PW - 16, BOOK_ROW, "show", item)
		y = y + BOOK_ROW
	end
end

-- "< blueprints", top left of a recipe's left page.
function Book.back_link(im, rec)
	Book.text(im, "< blueprints", 8, 6, P_DIM)
	Book.hotspot(rec, "l", 4, 2, 104, 14, "index", nil)
end

-- Page numbers at the foot.
function Book.folio(im, view, side)
	local n = view.spread * 2 + 1
	if side == "r" then
		n = n + 1
	end
	local s = tostring(n)
	Book.centre(im, s, BOOK_PH - 12, P_DIM)
end

-- A recipe's overview, left: what it is, what it takes, what's short.
function Book.paint_overview_left(im, view, plan, rec)
	Book.back_link(im, rec)
	local item = plan.item
	local ix = flr((BOOK_PW - 32) / 2)
	Icons.draw(im, item, ix, 22, 4)
	local name = Recipes.pretty(item)
	Book.centre(im, name, 60, P_INK)
	local y = 74
	if Book.made == item then
		im:rrect(30, y - 2, BOOK_PW - 60, 13, 3, P_GOOD)
		Book.centre(im, "made it!", y, P_PAPER)
		y = y + 16
	end
	local st = Recipes.making[item]
	if st ~= nil then
		Book.text(im, "takes", 12, y, P_DIM)
		y = y + 12
		local inputs = st.inputs
		for i = 1, #inputs do
			local inp = inputs[i]
			Icons.draw(im, inp[1], 14, y, 1)
			local pname = Recipes.pretty(inp[1])
			local line = tostring(inp[2]) .. " " .. pname
			Book.text(im, line, 26, y, P_INK)
			local have = Bag.count(inp[1])
			local hs = "(" .. tostring(have) .. ")"
			local hcol = P_DIM
			if have >= inp[2] then
				hcol = P_GOOD
			end
			Book.text(im, hs, 128, y, hcol)
			y = y + 11
		end
	end
	if #plan.short_order > 0 then
		y = y + 4
		Book.text(im, "still to find", 12, y, P_BAD)
		y = y + 12
		for i = 1, #plan.short_order do
			if y > BOOK_PH - 30 then
				break
			end
			local raw = plan.short_order[i]
			Icons.draw(im, raw, 14, y, 1)
			local rname = Recipes.pretty(raw)
			local line = tostring(plan.short[raw]) .. " " .. rname
			Book.text(im, line, 26, y, P_INK)
			y = y + 11
			local hint = RAW_HINTS[raw]
			if hint ~= nil then
				Book.text(im, hint, 26, y, P_DIM)
				y = y + 11
			end
		end
	end
	Book.folio(im, view, "l")
end

-- A recipe's overview, right: its steps, each ready or waiting.
function Book.paint_overview_right(im, view, plan, rec)
	Book.centre(im, "steps", 10, P_INK)
	im:rect(40, 21, BOOK_PW - 80, 1, P_RULE)
	local y = 28
	local steps = plan.steps
	for i = 1, #steps do
		if y > BOOK_PH - 40 then
			break
		end
		local e = steps[i]
		local st = e.step
		local num = tostring(i) .. "."
		Book.text(im, num, 8, y, P_DIM)
		Icons.draw(im, e.item, 26, y, 1)
		local iname = Recipes.pretty(e.item)
		local what = "make " .. tostring(e.need) .. " " .. iname
		local cut = Book.cut(what, 16)
		Book.text(im, cut, 38, y, P_INK)
		local where = Book.where_text(st)
		local ok = Recipes.ready(st)
		local mark = "waiting"
		local mcol = P_DIM
		if ok then
			mark = "ready"
			mcol = P_GOOD
		end
		local wcut = Book.cut(where, 11)
		Book.text(im, wcut, 38, y + 10, P_DIM)
		Book.text(im, mark, BOOK_PW - 64, y + 10, mcol)
		Book.hotspot(rec, "r", 4, y - 2, BOOK_PW - 8, 22, "spread", i)
		y = y + 24
	end
	Book.text(im, "begin >", BOOK_PW - 68, BOOK_PH - 24, P_MARK)
	Book.hotspot(rec, "r", BOOK_PW - 76, BOOK_PH - 30, 72, 18, "next", nil)
	Book.folio(im, view, "r")
end

-- "bench", "by hand"
function Book.where_text(st)
	local kind = Recipes.station_of(st)
	if kind == nil then
		return "by hand"
	end
	local s = Recipes.pretty(kind)
	return s
end

-- A step, left: what it makes and what goes in.
function Book.paint_step_left(im, view, plan, e, rec)
	Book.back_link(im, rec)
	local st = e.step
	local of = tostring(view.spread) .. "/" .. tostring(#plan.steps)
	local ow = #of * 8
	Book.text(im, of, BOOK_PW - ow - 8, 6, P_DIM)
	local iname = Recipes.pretty(e.item)
	local what = "make " .. tostring(e.need) .. " " .. iname
	local y = Book.para(im, what, 12, 26, 19, P_INK)
	if e.runs > 1 then
		local goes = tostring(e.runs) .. " goes, up to " .. tostring(e.out_n) .. " a go"
		y = Book.para(im, goes, 12, y, 19, P_DIM)
	end
	y = y + 8
	Book.text(im, "put in", 12, y, P_DIM)
	y = y + 14
	local inputs = st.inputs
	for i = 1, #inputs do
		local inp = inputs[i]
		Icons.draw(im, inp[1], 14, y, 2)
		local pname = Recipes.pretty(inp[1])
		local line = tostring(inp[2]) .. " " .. pname
		local cut = Book.cut(line, 12)
		Book.text(im, cut, 36, y + 4, P_INK)
		local have = Bag.count(inp[1])
		local hs = "have " .. tostring(have)
		local hcol = P_GOOD
		if have < inp[2] then
			hcol = P_BAD
		end
		Book.text(im, hs, 36, y + 14, hcol)
		y = y + 28
	end
	Book.text(im, "< back", 8, BOOK_PH - 24, P_MARK)
	Book.hotspot(rec, "l", 4, BOOK_PH - 30, 64, 18, "prev", nil)
	Book.folio(im, view, "l")
end

-- A step, right: where, the gesture, what comes out, ready or waiting.
function Book.paint_step_right(im, view, plan, e, rec)
	local st = e.step
	local kind = Recipes.station_of(st)
	local where = "by hand"
	if kind ~= nil then
		local kname = Recipes.pretty(kind)
		where = "at the " .. kname
	end
	Book.centre(im, where, 8, P_INK)
	-- the gesture, drawn as at the station
	local g = st.gesture or "assemble"
	local size = 72
	local gx = flr((BOOK_PW - size) / 2)
	im:rect(gx - 1, 21, size + 2, size + 2, P_RULE)
	Piece.draw(im, g, gx, 22, size, true, st)
	local gtext = GESTURE_TEXT[g] or g
	local y = Book.para(im, gtext, 12, 100, 19, P_DIM)
	-- what comes out
	y = y + 4
	local out_item, out_n = Recipes.output(st)
	Icons.draw(im, out_item, 14, y, 2)
	local oname = Recipes.pretty(out_item)
	local out = tostring(out_n) .. " " .. oname
	if out_n > 1 then
		out = "up to " .. out
	end
	Book.text(im, out, 36, y + 4, P_INK)
	y = y + 24
	-- ready, or what it waits for
	local ok, why, what = Recipes.ready(st)
	if ok then
		local doable = true
		if APP.book_mode or APP.screen ~= "world" then
			doable = kind == nil and st.to_bag
		end
		if doable then
			im:rrect(36, y, BOOK_PW - 72, 18, 4, P_MARK)
			Book.centre(im, "do it", y + 5, P_INK)
			Book.hotspot(rec, "r", 36, y, BOOK_PW - 72, 18, "do", view.spread)
		else
			Book.para(im, "ready: finish it in a world", 12, y, 19, P_GOOD)
		end
	else
		local wt = Book.waiting_text(why, what)
		Book.para(im, wt, 12, y, 19, P_BAD)
	end
	if view.spread < #plan.steps then
		Book.text(im, "next >", BOOK_PW - 60, BOOK_PH - 24, P_MARK)
		Book.hotspot(rec, "r", BOOK_PW - 68, BOOK_PH - 30, 64, 18, "next", nil)
	end
	Book.folio(im, view, "r")
end

-- -- over it, on the gui

-- What to press, and a word now and then. After the HUD.
function Book.draw_overlay()
	if not Book.up then
		return
	end
	local y = gui.h - LH - PAD * 2
	local hint = "type to search   left/right: turn   esc: close"
	if APP.book_mode then
		hint = "type to search   left/right: turn"
	end
	local hw = UI.text_w(hint)
	if hw <= VIEW_W - PAD * 4 then
		local hx = flr((VIEW_W - hw) / 2)
		UI.text(hint, hx, y, "FFFFFFA0")
	end
	if not APP.book_mode then
		local bx = VIEW_W - PAD * 2 - 60
		local by = LH + PAD * 4
		if UI.button("close", bx, by, 60, HUD_BTN_H) then
			Book.close()
		end
	end
	if Book.note ~= nil and U.clock - Book.note_t < 3 then
		local nw = UI.text_w(Book.note) + PAD * 2
		local nx = flr((VIEW_W - nw) / 2)
		local ny = y - LH - PAD * 3
		gui:rrect(nx, ny, nw, LH + PAD, 3, C_GLASS)
		UI.text(Book.note, nx + PAD, ny + 2, C_ACCENT)
	end
end

-- -- book mode: a screen with only the book (the apps' book page)

function Book.enter_mode()
	if APP.screen == "world" then
		Account.leave_world()
	end
	APP.book_mode = true
	APP.enter_id = nil
	Bag.close()
	Station.close()
	Book.open_book()
end

function Book.leave_mode()
	if not APP.book_mode then
		return
	end
	APP.book_mode = false
	Book.close()
	if USER ~= nil then
		APP.screen = "home"
	end
end

-- The screen in book mode: signed in as the app's session (hosted.lua),
-- never in a universe, with the bag, the catalog (if we have one), the
-- recipes in progress and the stations over our own channel.
function book_screen()
	if PHX ~= nil then
		PHX:update()
	end
	VIEW_W = gui.w
	CAM.az = 0.6
	CAM.alt = -0.55
	place_camera(0, 0, GROUND_Z)
	Book.keys()
	Book.frame()
	Fly.update(U.dt)
	Book.draw_overlay()
	local status = ""
	if USER == nil then
		status = "not signed in"
	elseif not USER.joined then
		status = "signing in..."
	end
	if status ~= "" then
		UI.text(status, PAD * 2, PAD * 2, C_DIM)
	end
	Fly.draw_labels()
end

-- The host's events, one at a time, before loop() (Petrichor64's hook API).
function hook(key, value)
	Book.on_hook(key, value)
end
