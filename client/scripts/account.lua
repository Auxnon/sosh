-- account — signing in, the home screen, and the chat beyond the world.
--
-- The socket starts signed out and can only use `auth:lobby` (sign in, sign
-- up with an emailed code, reset a password). Signing in answers a token;
-- the socket is made again with it (`&token=`) and joins our own
-- `user:<id>`, whose join reply is everything: who we are, the servers and
-- our place in each, friends, conversations, the bag and the character
-- catalog. It also tells us when any of that changes.
--
-- Servers are universes. The home screen lists them: enter one we're a
-- member of (the server moves us there, `enter`), or ask to join the rest.
-- In a server's world its chat is `server:<id>`: everyone's messages, from
-- the world or from the Android app, land in the chat log (said in the
-- world they're also a bubble over the speaker; main.lua).
--
-- Chat commands (tools.lua sends anything starting with / here):
--   /dm @name text       a direct message (/w too)
--   /give @name item [n] items for them, in the server chat; only they can
--                        open it (/open <id>), you can take it back (/unsend)
--   /friend @name, /accept @name, /unfriend @name, /friends
--   /home                back to the server list
--
-- The engine keeps nothing between runs, so the game signs in each time.

Account = {}

AUTH_TITLES = {
	login = "sign in",
	register = "make an account",
	confirm = "check your email",
	forgot = "forgot password",
	reset = "new password",
}

function Account.init()
	local a = {}
	a.mode = "login"
	a.email = UI.field("", 64)
	a.password = UI.field("", 64)
	a.handle = UI.field("", 16)
	a.code = UI.field("", 6)
	a.focus = 1
	a.status = ""
	a.status_col = C_DIM
	a.busy = false
	APP.auth = a
	APP.token = nil
	APP.account = nil
	APP.servers = {}
	APP.friends = nil
	APP.server = nil
	APP.friend_field = UI.field("", 16)
	APP.home_focus = false
	APP.home_status = ""
	APP.home_scroll = 0
	USER = nil
	AUTH = nil
	SERVER = nil
end

-- Connect, signed out, and show the sign-in screen.
function Account.start(url)
	APP.url = url
	PHX = Phx.new(url)
	AUTH = PHX:channel("auth:lobby", {})
	PHX:connect()
	APP.screen = "auth"
end

-- Signed in: connect again with the token and join our own channel.
function Account.signed_in(session)
	APP.token = session.token
	APP.account = session.user
	APP.auth.password.text = ""
	APP.auth.code.text = ""
	if PHX ~= nil then
		PHX:disconnect()
	end
	local url = APP.url .. "&token=" .. session.token
	PHX = Phx.new(url)
	USER = PHX:channel("user:" .. tostring(session.user.id), {})
	Account.bind_user(USER)
	PHX:connect()
	APP.screen = "home"
	APP.home_status = "signing in..."
end

function Account.sign_out()
	if USER ~= nil and USER.joined then
		PHX:push(USER, "logout", {})
	end
	if APP.screen == "world" then
		Account.leave_world()
	end
	if PHX ~= nil then
		PHX:disconnect()
	end
	APP.token = nil
	APP.account = nil
	USER = nil
	Account.start(APP.url)
end

function Account.bind_user(ch)
	ch.on_join = function(r)
		APP.account = r.user
		APP.servers = r.servers or {}
		APP.friends = r.friends
		APP.catalog = r.catalog
		APP.convos = r.conversations or {}
		Bag.set(r.bag or {})
		APP.home_status = ""
		if APP.me ~= nil then
			APP.me:set_character(r.user.character)
		end
	end
	ch.on_error = function(r)
		-- a dead token: sign in again
		APP.auth.status = "signed out"
		APP.auth.status_col = C_BAD
		Account.start(APP.url)
	end
	ch.on["servers"] = function(p)
		Account.refresh("servers")
	end
	ch.on["friends"] = function(p)
		Account.refresh("friends")
	end
	ch.on["bag"] = function(p)
		Bag.set(p.bag)
	end
	ch.on["character"] = function(p)
		APP.account.character = p.character
		if APP.me ~= nil then
			APP.me:set_character(p.character)
		end
	end
	ch.on["dm"] = function(p)
		local m = p.message
		local who = "@" .. p.from.handle
		if m ~= nil and m.body ~= "" then
			add_chat("[dm] " .. who, m.body, C_ACCENT)
		end
		if m ~= nil and m.gift ~= nil then
			add_chat(nil, who .. " sent you a gift: /open " .. tostring(m.id), C_ACCENT)
		end
	end
	ch.on["gift"] = function(p)
		if APP.server == nil then
			add_chat(nil, "@" .. p.from.handle .. " sent you a gift: /open " .. tostring(p.message_id), C_ACCENT)
		end
	end
	ch.on["removed"] = function(p)
		if APP.server ~= nil and APP.server.id == p.server_id and APP.screen == "world" then
			Account.leave_world()
			APP.home_status = "you're no longer a member of that server"
		end
		Account.refresh("servers")
	end
end

-- Ask again for a list that changed.
function Account.refresh(what)
	if USER == nil or not USER.joined then
		return
	end
	PHX:push(USER, what, {}, function(status, r)
		if status ~= "ok" then
			return
		end
		if what == "servers" then
			APP.servers = r.servers
		elseif what == "friends" then
			APP.friends = r
		end
	end)
end

-- Do something on our own channel; `done(response)` on success, else the
-- reason in the chat log (or the home screen's status).
function Account.ask(event, payload, done)
	if USER == nil or not USER.joined then
		Account.say("not connected", C_BAD)
		return
	end
	PHX:push(USER, event, payload, function(status, r)
		if status == "ok" then
			if done ~= nil then
				done(r)
			end
		else
			local why = "failed"
			if r ~= nil and r.message ~= nil then
				why = r.message
			elseif r ~= nil and r.reason ~= nil then
				why = r.reason
			end
			Account.say(event .. ": " .. tostring(why), C_BAD)
		end
	end)
end

function Account.say(text, col)
	if APP.screen == "world" then
		add_chat(nil, text, col or C_DIM)
	else
		APP.home_status = text
	end
end

-- ---------------------------------------------------------------------------
-- the sign-in screen

function auth_fields(mode)
	if mode == "login" then
		return { "email", "password" }
	elseif mode == "register" then
		return { "email", "handle", "password" }
	elseif mode == "confirm" then
		return { "email", "code" }
	elseif mode == "forgot" then
		return { "email" }
	end
	return { "email", "code", "password" }
end

FIELD_LABELS = {
	email = "email",
	password = "password (10+ characters)",
	handle = "handle: what everyone sees",
	code = "6-digit code from the email",
}

function auth_screen()
	PHX:update()
	CAM.az = CAM.az + 0.0015
	place_camera(0, 0, GROUND_Z)

	local a = APP.auth
	local fields = auth_fields(a.mode)
	local w = 300
	local h = 70 + #fields * 38 + 40
	local x = flr((gui.w - w) / 2)
	local y = flr((gui.h - h) / 2)
	UI.panel(x, y, w, h)
	UI.text("sosh", x + PAD * 3, y + PAD * 3, C_ACCENT)
	UI.text(AUTH_TITLES[a.mode], x + PAD * 3 + 48, y + PAD * 3, C_TEXT)

	local fx = x + PAD * 3
	local fw = w - PAD * 6
	local fy = y + 26
	if a.focus > #fields then
		a.focus = 1
	end
	for i = 1, #fields do
		local name = fields[i]
		local f = a[name]
		local shown = f
		if name == "password" then
			shown = UI.field(string.rep("*", #f.text), 64)
		end
		if UI.draw_field(FIELD_LABELS[name], shown, fx, fy, fw, a.focus == i) then
			a.focus = i
		end
		fy = fy + 38
	end

	local go_label = "sign in"
	if a.mode == "register" then
		go_label = "sign up"
	elseif a.mode == "confirm" then
		go_label = "confirm"
	elseif a.mode == "forgot" then
		go_label = "send code"
	elseif a.mode == "reset" then
		go_label = "set it"
	end
	local by = y + h - PAD * 3 - 18
	local go = UI.button(go_label, x + w - PAD * 3 - 80, by, 80, 18)

	-- the other modes, as links along the bottom
	local lx = fx
	local links = {}
	if a.mode == "login" then
		links = { "register", "forgot" }
	elseif a.mode == "register" then
		links = { "login", "confirm" }
	elseif a.mode == "confirm" then
		links = { "login", "resend" }
	else
		links = { "login" }
	end
	local link_labels = {
		register = "new here?",
		forgot = "forgot?",
		login = "sign in",
		confirm = "have a code?",
		resend = "send again",
	}
	for i = 1, #links do
		local label = link_labels[links[i]]
		local lw = UI.text_w(label) + 8
		if UI.button(label, lx, by, lw, 18) then
			if links[i] == "resend" then
				auth_push("resend")
			else
				a.mode = links[i]
				a.focus = 1
				a.status = ""
			end
		end
		lx = lx + lw + 4
	end
	if a.status ~= "" then
		UI.text(a.status, fx, y + h - PAD * 3 - 34, a.status_col)
	end

	local field_name = fields[a.focus]
	local res = UI.type_into(a[field_name])
	if key("tab", true) then
		a.focus = a.focus % #fields + 1
	end
	if res == "enter" then
		if a.focus < #fields then
			a.focus = a.focus + 1
		else
			go = true
		end
	end
	if go and not a.busy then
		auth_push(a.mode)
	end
end

function auth_push(mode)
	local a = APP.auth
	if not AUTH.joined then
		a.status = "connecting..."
		a.status_col = C_DIM
		return
	end
	local payload = {}
	payload.email = U.trim(a.email.text)
	if mode == "login" or mode == "register" or mode == "reset" then
		payload.password = a.password.text
	end
	if mode == "register" then
		payload.handle = U.trim(a.handle.text)
	end
	if mode == "confirm" or mode == "reset" then
		payload.code = U.trim(a.code.text)
	end
	a.busy = true
	a.status = "..."
	a.status_col = C_DIM
	PHX:push(AUTH, mode, payload, function(status, r)
		a.busy = false
		if status == "ok" then
			if r.token ~= nil then
				a.status = ""
				Account.signed_in(r)
			elseif mode == "register" or mode == "resend" then
				a.mode = "confirm"
				a.focus = 2
				a.status = "we emailed you a code"
				a.status_col = C_OK
			elseif mode == "forgot" then
				a.mode = "reset"
				a.focus = 2
				a.status = "if that's an account, a code is on its way"
				a.status_col = C_OK
			end
		else
			a.status = auth_error(r)
			a.status_col = C_BAD
			if r ~= nil and r.reason == "unconfirmed" then
				a.mode = "confirm"
				a.focus = 2
			end
		end
	end)
end

AUTH_ERRORS = {
	bad_login = "wrong email or password",
	unconfirmed = "confirm your email first: we sent a new code",
	bad_code = "that code didn't work",
	rate_limited = "too many tries: wait a few minutes",
}

function auth_error(r)
	if r == nil then
		return "failed"
	end
	if r.message ~= nil then
		return r.message
	end
	return AUTH_ERRORS[r.reason] or tostring(r.reason)
end

-- ---------------------------------------------------------------------------
-- the home screen: servers and friends

STATUS_LABELS = {
	member = "enter",
	pending = "asked",
	invited = "accept",
	banned = "banned",
}

function home_screen()
	PHX:update()
	CAM.az = CAM.az + 0.0015
	place_camera(0, 0, GROUND_Z)

	local x = 8
	local y = 6
	local w = gui.w - 16
	local h = gui.h - 12
	UI.panel(x, y, w, h)
	local me = APP.account
	UI.text("sosh", x + PAD * 2, y + PAD * 2, C_ACCENT)
	if me ~= nil then
		UI.text("@" .. me.handle, x + PAD * 2 + 40, y + PAD * 2, C_TEXT)
	end
	if UI.button("look", x + w - 82, y + 4, 38, 14) then
		Creator.open()
	end
	if UI.button("out", x + w - 42, y + 4, 36, 14) then
		Account.sign_out()
		return
	end

	local col_w = flr(w * 0.6)
	local sx = x + PAD * 2
	local top = y + 24
	UI.text("servers", sx, top, C_DIM)
	local rows = APP.servers or {}
	local ry = top + LH + 2
	local name_w = col_w - 44 - 34
	local name_chars = flr(name_w / CH)
	for i = 1, #rows do
		local s = rows[i]
		if ry + 14 > y + h - 14 then
			break
		end
		local label = STATUS_LABELS[s.status or ""] or "join"
		if s.status == nil and s.policy ~= "open" then
			label = "ask"
		end
		local name = s.name
		if #name > name_chars then
			name = name:sub(1, name_chars)
		end
		UI.text(name, sx, ry + 3, C_TEXT)
		local count = tostring(s.members or 0)
		UI.text(count, sx + name_w + 4, ry + 3, C_DIM)
		if UI.button(label, sx + col_w - 48, ry, 44, 13) then
			server_clicked(s)
		end
		ry = ry + 15
	end

	-- friends, on the right
	local fx = sx + col_w + PAD
	local fw = x + w - fx - PAD * 2
	UI.text("friends", fx, top, C_DIM)
	local fy = top + LH + 2
	local f = APP.friends
	if f ~= nil then
		fy = friend_rows(f.incoming or {}, "asks", fx, fy, fw, true)
		fy = friend_rows(f.friends or {}, nil, fx, fy, fw, false)
		fy = friend_rows(f.outgoing or {}, "asked", fx, fy, fw, false)
	end
	local ay = y + h - 50
	if UI.draw_field("add friend", APP.friend_field, fx, ay, fw, APP.home_focus) then
		APP.home_focus = true
	end
	local add = UI.button("add", fx + fw - 30, ay, 30, 11)
	if APP.home_focus then
		local res = UI.type_into(APP.friend_field)
		if res == "enter" then
			add = true
		elseif res == "escape" then
			APP.home_focus = false
		end
	end
	if add then
		local handle = U.trim(APP.friend_field.text)
		handle = handle:gsub("^@", "")
		if handle ~= "" then
			local p = {}
			p.handle = handle
			Account.ask("friend_add", p, function(r)
				APP.home_status = "asked @" .. handle
			end)
			APP.friend_field.text = ""
		end
	end

	if APP.home_status ~= "" then
		local status = APP.home_status
		local fit = flr((w - PAD * 4) / CH)
		if #status > fit then
			status = status:sub(1, fit)
		end
		UI.text(status, sx, y + h - 12, C_DIM)
	end
end

function friend_rows(list, note, x, y, w, incoming)
	for i = 1, #list do
		local u = list[i]
		local label = "@" .. u.handle
		if note ~= nil then
			label = label .. " " .. note
		end
		local fit = flr((w - 34) / CH)
		if incoming and #label > fit then
			label = label:sub(1, fit)
		end
		UI.text(label, x, y + 3, C_TEXT)
		if incoming then
			if UI.button("y", x + w - 30, y, 14, 13) then
				local p = {}
				p.handle = u.handle
				Account.ask("friend_accept", p)
			end
			if UI.button("n", x + w - 14, y, 14, 13) then
				local p = {}
				p.handle = u.handle
				Account.ask("friend_remove", p)
			end
		end
		y = y + 15
	end
	return y
end

function server_clicked(s)
	local p = {}
	p.id = s.id
	if s.status == "member" then
		Account.ask("enter", p, function(r)
			Account.enter(s, r.universe)
		end)
	elseif s.status == "banned" then
		APP.home_status = "you're banned from " .. s.name
	else
		Account.ask("join_server", p, function(r)
			if r.status == "member" then
				APP.home_status = "joined " .. s.name
			else
				APP.home_status = "asked to join " .. s.name .. ": someone there has to let you in"
			end
			Account.refresh("servers")
		end)
	end
end

-- ---------------------------------------------------------------------------
-- a server's world and chat

function Account.enter(s, u)
	APP.server = s
	APP.chat = {}
	APP.screen = "world"
	CAM.az = 0.6
	SERVER = PHX:channel("server:" .. tostring(s.id), {})
	SERVER.on_join = function(r)
		local list = r.messages or {}
		for i = 1, #list do
			chat_message(list[i], true)
		end
		add_chat(nil, "in " .. s.name .. " (universe " .. universe_key(u) .. ")", C_OK)
	end
	SERVER.on["message"] = function(m)
		chat_message(m, false)
	end
	SERVER.on["gift"] = function(m)
		gift_settled(m)
	end
	SERVER.on["removed"] = function(p)
		Account.leave_world()
		APP.home_status = "you're no longer a member of " .. s.name
	end
	PHX:open(SERVER)
	enter_universe(u)
end

function Account.leave_world()
	if LOBBY ~= nil then
		PHX:leave(LOBBY)
		LOBBY = nil
	end
	if ACTIONS ~= nil then
		PHX:leave(ACTIONS)
		ACTIONS = nil
	end
	if SERVER ~= nil then
		PHX:leave(SERVER)
		SERVER = nil
	end
	clear_world()
	if APP.me ~= nil then
		APP.me:remove()
		APP.me = nil
	end
	APP.my_id = nil
	APP.server = nil
	APP.typing = false
	APP.screen = "home"
	Account.refresh("servers")
end

-- A message of the server's chat into the log. From the world it was
-- already a bubble over them; the log is where everyone's goes.
function chat_message(m, old)
	local who = "?"
	if m.author ~= nil then
		who = m.author.handle
	end
	local col = C_TEXT
	if m.author ~= nil then
		col = U.hex_for(who)
	end
	if m.body ~= nil and m.body ~= "" then
		add_chat(who, m.body, col)
	end
	if m.gift ~= nil then
		local to = "someone"
		if m.gift.to ~= nil then
			to = "@" .. m.gift.to.handle
		end
		local line = who .. " left a gift for " .. to
		if m.gift.to ~= nil and APP.account ~= nil and m.gift.to.handle == APP.account.handle and m.gift.state == "sealed" then
			line = line .. ": /open " .. tostring(m.id)
		elseif m.gift.state ~= "sealed" then
			line = line .. " (" .. m.gift.state .. ")"
		end
		add_chat(nil, line, C_ACCENT)
	end
end

function gift_settled(m)
	if m.gift == nil then
		return
	end
	local to = "someone"
	if m.gift.to ~= nil then
		to = "@" .. m.gift.to.handle
	end
	add_chat(nil, "the gift for " .. to .. " was " .. m.gift.state, C_DIM)
end

-- ---------------------------------------------------------------------------
-- chat commands

-- `text` began with /: true if it was one of ours.
function Account.command(text)
	local words = U.words(text)
	local cmd = words[1]
	local who = nil
	if words[2] ~= nil then
		local stripped = words[2]:gsub("^@", "")
		who = stripped
	end

	if cmd == "/home" then
		Account.leave_world()
		return true
	end
	if cmd == "/dm" or cmd == "/w" then
		if who == nil or words[3] == nil then
			add_chat(nil, "/dm @name message", C_DIM)
			return true
		end
		local body = text:match("^%S+%s+%S+%s+(.+)$") or ""
		local p = {}
		p.handle = who
		p.body = body
		Account.ask("dm_post", p, function(r)
			add_chat("[dm] to @" .. who, body, C_DIM)
		end)
		return true
	end
	if cmd == "/give" then
		local item = words[3]
		local n = 1
		if words[4] ~= nil then
			n = flr(tonumber(words[4]) or 1)
		end
		if who == nil or item == nil or SERVER == nil then
			add_chat(nil, "/give @name item [count], in a server", C_DIM)
			return true
		end
		local gift = {}
		gift.item = item
		gift.count = n
		gift.to = who
		local p = {}
		p.body = "@" .. who
		p.gift = gift
		PHX:push(SERVER, "post", p, function(status, r)
			if status ~= "ok" then
				local why = "failed"
				if r ~= nil and r.reason ~= nil then
					why = r.reason
				end
				add_chat(nil, "gift not sent: " .. why, C_BAD)
			else
				add_chat(nil, "sent " .. tostring(n) .. " " .. item .. " to @" .. who .. " (/unsend " .. tostring(r.message.id) .. " to take it back)", C_DIM)
			end
		end)
		return true
	end
	if cmd == "/open" or cmd == "/unsend" then
		local id = flr(tonumber(words[2] or "") or 0)
		local p = {}
		p.id = id
		local event = "claim"
		if cmd == "/unsend" then
			event = "cancel"
		end
		Account.ask(event, p, function(r)
			local g = r.message.gift
			if g ~= nil and g.item ~= nil then
				add_chat(nil, tostring(g.count) .. " " .. g.item .. ": in your bag", C_OK)
			end
		end)
		return true
	end
	if cmd == "/friend" or cmd == "/accept" or cmd == "/unfriend" then
		if who == nil then
			add_chat(nil, cmd .. " @name", C_DIM)
			return true
		end
		local events = {}
		events["/friend"] = "friend_add"
		events["/accept"] = "friend_accept"
		events["/unfriend"] = "friend_remove"
		local p = {}
		p.handle = who
		Account.ask(events[cmd], p, function(r)
			add_chat(nil, "ok", C_OK)
		end)
		return true
	end
	if cmd == "/friends" then
		local f = APP.friends
		if f == nil or #f.friends == 0 then
			add_chat(nil, "no friends yet: /friend @name", C_DIM)
		else
			local names = ""
			for i = 1, #f.friends do
				names = names .. " @" .. f.friends[i].handle
			end
			add_chat(nil, "friends:" .. names, C_DIM)
		end
		return true
	end
	add_chat(nil, "commands: /dm /give /open /unsend /friend /accept /unfriend /friends /home", C_DIM)
	return true
end
