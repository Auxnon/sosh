-- Run by an app that hosts the engine (the desktop app, desktop/): the app
-- signs in, has the chat and the way home, and tells us over the engine's
-- host channel (`host.recv`) who we are and where to be. Lines of words:
--
--   session <socket url> <token> <user id> <server id>
--     sign in as that session (the app's own) and go into that server
--   enter <server id>
--     go into that server instead (the app opened another)
--
-- `host` is nil where nothing hosts us (chor, the web), and quiet when the
-- host never writes: the game runs as ever.

Hosted = {}

function Hosted.update()
	if host == nil then
		return
	end
	while true do
		local m = host.recv()
		if m == nil then
			return
		end
		local w = U.words(m)
		if w[1] == "session" and #w >= 5 then
			Hosted.session(w[2], w[3], tonumber(w[4]), tonumber(w[5]))
		elseif w[1] == "enter" and #w >= 2 then
			Hosted.enter(tonumber(w[2]))
		end
	end
end

function Hosted.session(url, token, user_id, server_id)
	if APP.screen == "world" then
		Account.leave_world()
	end
	-- like the Android app's world: no chat, creator or home of our own
	APP.embedded = true
	APP.url = url
	APP.enter_id = server_id
	Account.signed_in({ token = token, user = { id = user_id } })
end

function Hosted.enter(id)
	if id == nil then
		return
	end
	if APP.server ~= nil and APP.server.id == id then
		return
	end
	if APP.screen == "world" then
		Account.leave_world()
	end
	for i = 1, #APP.servers do
		if APP.servers[i].id == id then
			server_clicked(APP.servers[i])
			return
		end
	end
	-- not signed in yet: once our channel has the servers (bind_user)
	APP.enter_id = id
end
