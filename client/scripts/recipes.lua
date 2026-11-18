-- recipes — how things are made, from the catalog's `recipes`, and which
-- ones we're partway through (the server's `players.crafting`).
--
-- A step turns its inputs into its output (the best case: a poorer stroke
-- gives less, never less than half and never none), at a station kind or
-- by hand (no station). Each item is made by one step at most, named after
-- it; anything no step makes is a raw material (wood, stone, wool).
--
-- Recipes.plan(item) expands an item into the steps that make it, depth
-- first, so precursors come first, counted against the bag: an ingredient
-- the bag already has enough of is used, not made. Done again whenever the
-- bag changes, so steps drop out as they're done.
--
-- Whether a step can be done right now is the server's say: the bag holds
-- its inputs, and its station kind is in the `stations` the server
-- records for us (pushed on `user:<id>`). The client never claims to be
-- near a station.
--
-- Recipes in progress live on the server (`crafting` / `set_crafting` on
-- `user:<id>`, pushed as `crafting`): {recipe = {step, at}}, `step` the
-- spread of the book it's open at and `at` an ever-growing count, so the
-- latest is the one with the biggest. The server keeps 20.

Recipes = {}

-- deep enough for any recipe; a loop in the catalog stops here
PLAN_DEPTH = 8

function Recipes.init()
	-- step id -> {id, inputs, outputs, station, gesture, stroke, to_bag}
	Recipes.steps = {}
	-- step ids, in the catalog's order
	Recipes.order = {}
	-- item -> the step that makes it
	Recipes.making = {}
	-- station kind -> true
	Recipes.kinds = {}
	-- recipe -> {step, at}, as the server has it
	Recipes.crafting = {}
	-- station kind -> true: the ones the server has us in range of
	Recipes.near = {}
	Recipes.have_catalog = false
	Recipes.loaded = false
end

-- The catalog (the actions join reply's): its recipe steps and stations.
function Recipes.set_catalog(c)
	if c == nil or c.recipes == nil then
		return
	end
	Recipes.steps = {}
	Recipes.order = {}
	Recipes.making = {}
	local list = c.recipes
	for i = 1, #list do
		local st = list[i]
		Recipes.steps[st.id] = st
		table.insert(Recipes.order, st.id)
		local out = st.outputs[1]
		if out ~= nil then
			Recipes.making[out[1]] = st
		end
	end
	Recipes.kinds = {}
	local kinds = c.stations or {}
	for i = 1, #kinds do
		Recipes.kinds[kinds[i]] = true
	end
	Recipes.have_catalog = true
	Book.changed()
end

function Recipes.is_station(kind)
	return kind ~= nil and Recipes.kinds[kind] == true
end

-- What step `st` makes, and how many at best.
function Recipes.output(st)
	local out = st.outputs[1]
	if out == nil then
		return st.id, 1
	end
	return out[1], out[2]
end

-- The step's station kind, or nil for a hand step (the wire's nil may
-- simply be missing).
function Recipes.station_of(st)
	if st.station == nil or st.station == "" then
		return nil
	end
	return st.station
end

-- "spinning_wheel" -> "spinning wheel"
function Recipes.pretty(name)
	if name == nil then
		return ""
	end
	local s = name:gsub("_", " ")
	return s
end

-- How many of each thing the bag holds: item -> count.
function Recipes.bag_counts()
	local out = {}
	local slots = Bag.slots or {}
	for i = 1, #slots do
		local s = slots[i]
		if s[1] ~= nil then
			out[s[1]] = (out[s[1]] or 0) + s[2]
		end
	end
	return out
end

-- The steps that make one `item`, precursors first, against what the bag
-- holds now: {item, steps = {{step, item, need, runs, out_n}}, short =
-- {raw item -> how many more}, short_order}. The last step is always the
-- item itself, even if the bag has some.
function Recipes.plan(item)
	local avail = Recipes.bag_counts()
	avail[item] = 0
	local plan = {}
	plan.item = item
	plan.steps = {}
	plan.short = {}
	plan.short_order = {}
	Recipes.need(plan, item, 1, avail, 0)
	return plan
end

-- `n` of `item` for `plan`: from what's left in `avail` if it can, else
-- the steps that make the rest, theirs first.
function Recipes.need(plan, item, n, avail, depth)
	local have = avail[item] or 0
	local use = n
	if have < use then
		use = have
	end
	avail[item] = have - use
	local missing = n - use
	if missing <= 0 then
		return
	end
	local st = Recipes.making[item]
	if st == nil or depth > PLAN_DEPTH then
		if plan.short[item] == nil then
			plan.short[item] = 0
			table.insert(plan.short_order, item)
		end
		plan.short[item] = plan.short[item] + missing
		return
	end
	local _, out_n = Recipes.output(st)
	if out_n < 1 then
		out_n = 1
	end
	-- whole goes of the step, each making out_n at best
	local runs = 0
	local made = 0
	while made < missing do
		runs = runs + 1
		made = made + out_n
	end
	local inputs = st.inputs
	for i = 1, #inputs do
		local inp = inputs[i]
		local k = inp[2] * runs
		Recipes.need(plan, inp[1], k, avail, depth + 1)
	end
	local e = {}
	e.step = st
	e.item = item
	e.need = missing
	e.runs = runs
	e.out_n = out_n
	table.insert(plan.steps, e)
	-- what's made beyond what's needed is there for later steps
	avail[item] = (avail[item] or 0) + made - missing
end

-- Whether step `st` can be done now: true, or false and why ("missing",
-- the item short) or ("station", the kind we're not near).
function Recipes.ready(st)
	local inputs = st.inputs
	for i = 1, #inputs do
		local inp = inputs[i]
		local have = Bag.count(inp[1])
		if have < inp[2] then
			return false, "missing", inp[1]
		end
	end
	local kind = Recipes.station_of(st)
	if kind ~= nil and Recipes.near[kind] ~= true then
		return false, "station", kind
	end
	return true, nil, nil
end

-- The things that can be made, in the catalog's order, whose name has
-- `q` in it (spaces for underscores, any case).
function Recipes.index(q)
	local out = {}
	local trimmed = U.trim(q or "")
	local want = trimmed:lower()
	for i = 1, #Recipes.order do
		local st = Recipes.steps[Recipes.order[i]]
		local item = Recipes.output(st)
		local name = Recipes.pretty(item)
		if want == "" or U.has(name, want) or U.has(item, want) then
			table.insert(out, item)
		end
	end
	return out
end

-- -- the server's record: recipes in progress and stations near

-- Ask for both (on joining our channel).
function Recipes.fetch()
	if USER == nil or not USER.joined then
		return
	end
	PHX:push(USER, "crafting", {}, Recipes.fetched)
	-- outside a world nothing else brings the catalog (the book on its own)
	if not Recipes.have_catalog then
		PHX:push(USER, "catalog", {}, Recipes.fetched_catalog)
	end
end

function Recipes.fetched_catalog(status, r)
	if status ~= "ok" or r == nil or Recipes.have_catalog then
		return
	end
	Recipes.set_catalog(r.catalog)
end

function Recipes.fetched(status, r)
	if status ~= "ok" or r == nil then
		return
	end
	Recipes.got_crafting(r.crafting)
	Recipes.got_stations(r.stations)
end

-- `crafting`, from the server: the recipes in progress.
function Recipes.got_crafting(map)
	if map == nil then
		return
	end
	Recipes.crafting = map
	Recipes.loaded = true
	Book.changed()
end

-- `stations`, from the server: the kinds we're in range of.
function Recipes.got_stations(list)
	if list == nil then
		return
	end
	Recipes.near = {}
	for i = 1, #list do
		Recipes.near[list[i]] = true
	end
	Book.changed()
end

-- The recipe last worked on, and its step, or nil.
function Recipes.latest()
	local best = nil
	local best_at = nil
	local step = 0
	for name, v in pairs(Recipes.crafting) do
		if best_at == nil or v.at > best_at then
			best = name
			best_at = v.at
			step = v.step
		end
	end
	return best, step
end

-- The recipes in progress, the latest first: {{recipe, step, at}}.
function Recipes.history()
	local out = {}
	for name, v in pairs(Recipes.crafting) do
		local e = {}
		e.recipe = name
		e.step = v.step
		e.at = v.at
		table.insert(out, e)
	end
	for i = 2, #out do
		local e = out[i]
		local j = i - 1
		while j >= 1 and out[j].at < e.at do
			out[j + 1] = out[j]
			j = j - 1
		end
		out[j + 1] = e
	end
	return out
end

-- Where `recipe` was left (its spread), or nil.
function Recipes.step_of(recipe)
	local v = Recipes.crafting[recipe]
	if v == nil then
		return nil
	end
	return v.step
end

-- We're on spread `step` of `recipe`: it becomes the latest, saved.
function Recipes.remember(recipe, step)
	if recipe == nil then
		return
	end
	local top = 0
	local latest = nil
	for name, v in pairs(Recipes.crafting) do
		if v.at > top then
			top = v.at
			latest = name
		end
	end
	local cur = Recipes.crafting[recipe]
	if cur ~= nil and latest == recipe and cur.step == step then
		return
	end
	local at = top
	if latest ~= recipe then
		at = top + 1
	end
	local v = {}
	v.step = step
	v.at = at
	Recipes.crafting[recipe] = v
	Recipes.save()
end

-- `recipe` is made, or given up: off the list.
function Recipes.forget(recipe)
	if Recipes.crafting[recipe] == nil then
		return
	end
	local rest = {}
	for name, v in pairs(Recipes.crafting) do
		if name ~= recipe then
			rest[name] = v
		end
	end
	Recipes.crafting = rest
	Recipes.save()
end

function Recipes.save()
	if USER == nil or not USER.joined then
		return
	end
	local p = {}
	p.crafting = Recipes.crafting
	PHX:push(USER, "set_crafting", p, Recipes.saved)
end

-- The server's cleaned copy is the record.
function Recipes.saved(status, r)
	if status == "ok" and r ~= nil and r.crafting ~= nil then
		Recipes.crafting = r.crafting
	end
end
