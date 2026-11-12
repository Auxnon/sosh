-- web — what the game asks of the web page around it (client/web/bridge.js).
--
-- Lua can only reach out through `conn`, so on the web a `conn` to
-- /sosh-bridge leads to the page instead of the network (the engine's worker
-- imports client/web/bridge-worker.js, which makes that socket). Whenever
-- it changes, the game sends what it wants as `sosh;play=...;ticket=...;
-- pick=n`:
--
--   * a shared cart running (`play`): the page puts the cart's own page,
--     fenced off from sosh, in a frame over the box the chat leaves for it
--     (Web.box, drawn by chatpane.lua or hud.lua)
--   * the open chat's share ticket (`ticket`): pictures dropped on the page,
--     pasted or picked are posted there (Sosh.Media.ticket: good for that
--     chat, an hour, pictures only; the page never sees our session)
--   * `pick`: counts up each time the attach button is pressed, and the page
--     opens its file picker
--
-- On the desktop there's no page: a cart says where to play it instead.

Web = {}

WEB_TICKET_SECS = 50 * 60 -- asked for again before the server's hour runs out
WEB_BOX_TITLE = 14

Web.cart = nil -- the shared cart running: its media
Web.box = nil -- {x, y, w, h} in gui pixels: where it shows, set when drawn
Web.ticket = nil
Web.ticket_for = nil
Web.ticket_at = -1000000
Web.picks = 0
Web.sent = nil

-- Run a shared cart, in the chat on the web; elsewhere, say where.
function Web.open(m)
	if m == nil or m.kind ~= "cart" then
		return
	end
	if APP.web then
		Web.cart = m
		return
	end
	local where = U.trim(APP.server_field.text)
	local secure = where:gsub("^wss://", "https://")
	local site = secure:gsub("^ws://", "http://")
	local page = m.url:gsub("^/media/", "/play/")
	add_chat(nil, "games from chat run on the web and in the app: " .. site .. page, C_ACCENT)
end

function Web.close()
	Web.cart = nil
	Web.box = nil
	Web.last_box = nil
end

-- Is gui pixel (x, y) on the running cart's box (so not the world's)?
function Web.hit(x, y)
	local b = Web.last_box
	if Web.cart == nil or b == nil then
		return false
	end
	return x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h
end

-- The attach button: the page's file picker (web only).
function Web.pick()
	if APP.web and Web.ticket ~= nil then
		Web.picks = Web.picks + 1
	end
end

function Web.can_share()
	return APP.web and Web.ticket ~= nil
end

-- The chat we're in, as the server names places, or nil.
function Web.place()
	if APP.server ~= nil and APP.screen == "world" then
		return "server:" .. tostring(APP.server.id)
	end
	return nil
end

-- Once a frame, after everything's drawn (so Web.box is this frame's).
function Web.update()
	-- in the app its own screens share pictures and play games
	if not APP.web or APP.embedded then
		return
	end
	local place = Web.place()
	if place == nil then
		Web.ticket = nil
		Web.ticket_for = nil
		Web.cart = nil
		Web.box = nil
	elseif USER ~= nil and (Web.ticket_for ~= place or U.clock - Web.ticket_at > WEB_TICKET_SECS) then
		Web.ticket_for = place
		Web.ticket_at = U.clock
		local p = {}
		p.place = place
		Account.ask("media_ticket", p, function(r)
			if Web.ticket_for == place then
				Web.ticket = r.ticket
			end
		end)
	end

	local s = "sosh"
	if Web.cart ~= nil and Web.box ~= nil then
		local b = Web.box
		s = s .. ";play=" .. Web.cart.key .. "," .. Web.frac(b.x, gui.w) .. "," .. Web.frac(b.y, gui.h) .. "," .. Web.frac(b.w, gui.w) .. "," .. Web.frac(b.h, gui.h)
	end
	if Web.ticket ~= nil then
		s = s .. ";ticket=" .. Web.ticket
	end
	s = s .. ";pick=" .. tostring(Web.picks)
	if Web.sock == nil then
		local ok, sock = pcall(conn, "/sosh-bridge")
		if ok then
			Web.sock = sock
		end
		Web.sent = nil
	end
	if Web.sock ~= nil and s ~= Web.sent then
		Web.sent = s
		Web.sock:send(s)
	end
	-- drawn again next frame if it's still wanted
	Web.box = nil
end

function Web.frac(v, of)
	local f = flr(v / of * 10000) / 10000
	return tostring(f)
end

-- The running cart's box at (x, y), `w` wide: a plastic title bar with its
-- name and a close button, and the space the page's frame covers. Returns
-- its height.
function Web.draw_box(x, y, w)
	local m = Web.cart
	local inner_w = w - 4
	local inner_h = flr(inner_w * 3 / 4)
	local h = WEB_BOX_TITLE + inner_h + 4
	local whole = {}
	whole.x = x
	whole.y = y
	whole.w = w
	whole.h = h
	Web.last_box = whole
	UI.plastic(x, y, w, h, 5)
	if UI.inside(x, y, w, h) then
		UI.hot = true
	end
	local name = Media.label(m)
	local fit = flr((w - 24) / CH)
	if #name > fit then
		name = name:sub(1, fit)
	end
	Media.glyph(x + PAD, y + 3, m, U.clock)
	UI.text(name, x + PAD + MEDIA_W + MEDIA_GAP, y + 4, C_TEXT)
	if UI.button("x", x + w - 16, y + 1, 14, 11) then
		Web.close()
		return h
	end
	gui:rect(x + 2, y + WEB_BOX_TITLE, inner_w, inner_h, C_GROUND)
	UI.text("starting...", x + PAD * 2, y + WEB_BOX_TITLE + PAD * 2, C_DIM)
	local b = {}
	b.x = x + 2
	b.y = y + WEB_BOX_TITLE
	b.w = inner_w
	b.h = inner_h
	Web.box = b
	return h
end
