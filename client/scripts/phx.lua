-- phx — a Phoenix Channels client over the engine's websocket `conn`.
--
-- Speaks the V2 JSON serializer: every frame is
--   [join_ref, ref, topic, event, payload]
-- `connection:send(table)` encodes it and `recv(true)` decodes it. Frames are
-- built with no nils so they encode as arrays; the one frame that needs a
-- null (the heartbeat's join_ref) is sent as a literal string.
--
-- Everything is polled from loop(): call `phx:update()` once a frame.
--
--   phx = Phx.new("ws://localhost:4000/socket/websocket?vsn=2.0.0")
--   lobby = phx:channel("room:lobby", { name = "me" })
--   lobby.on["new_msg"] = function(p) ... end
--   lobby.on_join = function(reply) ... end
--   phx:connect()
--   phx:push(lobby, "new_msg", { body = "hi" })
--   phx:push(actions, "get_chunks", payload, function(status, response) ... end)

Phx = {}
Phx.__index = Phx

-- In frames (~60/s). Literals, not FPS: script load order isn't guaranteed.
PHX_HEARTBEAT = 1500 -- 25s; Phoenix drops a socket after 60s of silence
PHX_BACKOFF = { 60, 120, 300, 600 }
PHX_MAX_PER_FRAME = 256

function Phx.new(url)
	local p = setmetatable({}, Phx)
	p.url = url
	p.sock = nil
	p.ref = 0
	-- "idle" (never connected), "connecting", "open", "waiting" (to retry)
	p.state = "idle"
	p.error = nil
	p.channels = {}
	p.topics = {}
	-- reply callbacks by ref, for pushes that asked for one
	p.replies = {}
	p.beat = 0
	p.retry_in = 0
	p.retries = 0
	return p
end

function Phx:next_ref()
	self.ref = self.ref + 1
	return tostring(self.ref)
end

function Phx:channel(topic, params)
	local ch = {}
	ch.topic = topic
	ch.params = params
	ch.join_ref = nil
	ch.joined = false
	ch.on = {}
	ch.on_join = nil
	ch.on_error = nil
	self.channels[topic] = ch
	table.insert(self.topics, topic)
	return ch
end

function Phx:connect()
	local ok, sock = pcall(conn, self.url)
	if ok and sock ~= nil then
		self.sock = sock
		self.state = "connecting"
		self.error = nil
		self.beat = 0
		for i = 1, #self.topics do
			self:join(self.channels[self.topics[i]])
		end
	else
		self.error = tostring(sock)
		self:retry()
	end
end

function Phx:disconnect()
	if self.sock ~= nil then
		self.sock:kill()
	end
	self.sock = nil
	self.state = "idle"
	for i = 1, #self.topics do
		self.channels[self.topics[i]].joined = false
	end
end

-- The socket died; schedule a reconnect with backoff.
function Phx:retry()
	if self.sock ~= nil then
		self.sock:kill()
		self.sock = nil
	end
	for i = 1, #self.topics do
		self.channels[self.topics[i]].joined = false
	end
	-- replies to a dead socket never come
	self.replies = {}
	self.retries = self.retries + 1
	local idx = self.retries
	if idx > #PHX_BACKOFF then
		idx = #PHX_BACKOFF
	end
	self.retry_in = PHX_BACKOFF[idx]
	self.state = "waiting"
end

function Phx:join(ch)
	ch.join_ref = self:next_ref()
	ch.joined = false
	local frame = { ch.join_ref, ch.join_ref, ch.topic, "phx_join", ch.params }
	self.sock:send(frame)
end

-- Returns false if the channel isn't joined (the push is dropped).
-- `on_reply(status, response)` is called with the server's reply, if given.
function Phx:push(ch, event, payload, on_reply)
	if self.sock == nil or not ch.joined then
		return false
	end
	-- hoisted: a call inside a table constructor miscompiles in silt
	local ref = self:next_ref()
	local frame = { ch.join_ref, ref, ch.topic, event, payload }
	if on_reply ~= nil then
		self.replies[ref] = on_reply
	end
	self.sock:send(frame)
	return true
end

function Phx:update()
	if self.sock == nil then
		if self.state == "waiting" then
			self.retry_in = self.retry_in - 1
			if self.retry_in <= 0 then
				self:connect()
			end
		end
		return
	end

	local err = self.sock:test()
	if err ~= nil then
		self.error = err
		self:retry()
		return
	end

	self.beat = self.beat + 1
	if self.beat >= PHX_HEARTBEAT then
		self.beat = 0
		self.sock:send('[null,"' .. self:next_ref() .. '","phoenix","heartbeat",{}]')
	end

	local n = 0
	local msg = self.sock:recv(true)
	while msg ~= nil do
		self:dispatch(msg)
		n = n + 1
		if n >= PHX_MAX_PER_FRAME or self.sock == nil then
			return
		end
		msg = self.sock:recv(true)
	end
end

function Phx:dispatch(msg)
	if type(msg) ~= "table" then
		return
	end
	-- Anything arriving means the socket is up.
	self.state = "open"
	self.retries = 0

	local topic = msg[3]
	local event = msg[4]
	local payload = msg[5]
	local ch = self.channels[topic]
	if ch == nil then
		return
	end

	if event == "phx_reply" then
		local cb = self.replies[msg[2]]
		if cb ~= nil then
			self.replies[msg[2]] = nil
			cb(payload.status, payload.response)
			return
		end
		if msg[2] == ch.join_ref then
			if payload.status == "ok" then
				ch.joined = true
				if ch.on_join ~= nil then
					ch.on_join(payload.response)
				end
			else
				ch.joined = false
				if ch.on_error ~= nil then
					ch.on_error(payload.response)
				end
			end
		end
		return
	end

	if event == "phx_error" or event == "phx_close" then
		-- The channel process died server side: rejoin on the same socket.
		if msg[1] == ch.join_ref and self.sock ~= nil then
			self:join(ch)
		end
		return
	end

	local handler = ch.on[event]
	if handler ~= nil then
		handler(payload)
	end
end
