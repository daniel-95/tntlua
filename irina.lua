--
-- irina.lua
--

--
-- Space 0: Remote IMAP Collector Accounts (Instant and Usual)
--   Tuple: { email (STR), user_id (NUM), is_instant (NUM), is_expirable (NUM), inst_from (NUM), shard_id (NUM) }
--   Index 0: HASH { email }
--   Index 1: TREE { is_instant, shard_id }
--
-- Space 1: Remote IMAP Collector Listeners
--   Tuple: { shard_id (NUM), addr (STR) }
--   Index 0: TREE { shard_id }
--

local function get_collector_address(shardid)
	local v = box.space[1].index[0]:iterator(box.index.GT, shardid)()
	if v == nil then return nil end

	local addr = v[1]
	local ind = addr:find(":")
	if ind == nil then return nil end

	return addr:sub(0, ind - 1), tonumber(addr:sub(ind + 1))
end

--
-- Send signal to Instant Remote IMAP Collector daemon
--
local function send_instant_changes(email, userid, shardid, enabled, expirable)
	local host, port = get_collector_address(shardid)
	if host == nil then return end

	local s = box.socket.tcp()
	if s == nil then
		print("can not create imaplistener socket")
		return
	end

	if not s:connect(host, port, 0.1) then
		local _, errstr = s:error()
		print("can not connect to imaplistener[" .. host .. ":" .. port .. "]: " .. errstr)
		s:close()
		return
	end

	local data = email .. " " .. userid .. " " .. enabled .. " " .. expirable
	local bytes_sent, status, errno, errstr = s:send(data, 0.1)
	if bytes_sent ~= #data then
		local _, errstr = s:error()
		print("can not send data to imaplistener[" .. host .. ":" .. port .. "]: " .. errstr)
		s:close()
		return
	end

	s:close()
end

local function update_record(email, set_instant, set_expirable)
	box.update(0, email, "=p=p=p", 2, set_instant, 3, set_expirable, 4, box.time())
end

function irina_add_user(email, userid, is_instant, shardid)
	userid = box.unpack('i', userid)
	is_instant = box.unpack('i', is_instant)
	shardid = box.unpack('i', shardid)

	local need_send = false
	local tuple = box.select(0, 0, email)
	if tuple == nil then
		box.insert(0, email, userid, is_instant, 0, box.time(), shardid)
		need_send = (is_instant == 1)
	elseif is_instant == 1 then
		local is_old_instant, is_old_expirable = box.unpack('i', tuple[2]), box.unpack('i', tuple[3])
		if (is_old_instant == 0 or is_old_expirable == 1) then
			need_send = true
			update_record(email, is_instant, 0)
		end
	end

	if need_send then send_instant_changes(email, userid, shardid, 1, 0) end
end

function irina_del_user(email)
	local tuple = box.delete(0, email)
	if tuple == nil then return end

	local userid = box.unpack('i', tuple[1])
	local is_old_instant = box.unpack('i', tuple[2])
	local shardid = box.unpack('i', tuple[5])
	if is_old_instant == 1 then send_instant_changes(email, userid, shardid, 0, 0) end
end

local function set_flags_impl(tuple, cond, set_instant, set_expirable)
	local email = tuple[0]
	local userid = box.unpack('i', tuple[1])
	local is_instant = box.unpack('i', tuple[2])
	local is_expirable = box.unpack('i', tuple[3])
	local shardid = box.unpack('i', tuple[5])

	if not cond(is_instant, is_expirable) then return end
	update_record(email, set_instant, set_expirable)

	if is_instant ~= set_instant or is_expirable ~= set_expirable then
		send_instant_changes(email, userid, shardid, set_instant, set_expirable)
	end
end

local function set_flags(email, cond, set_instant, set_expirable)
	local tuple = box.select(0, 0, email)
	if tuple == nil then return end
	set_flags_impl(tuple, cond, set_instant, set_expirable)
end

function irina_set_instant(email)
	set_flags(email,
		function(i, e) return i == 0 or e == 1 end,
		1, 0)
end

function irina_del_instant(email)
	set_flags(email,
		function(i, e) return i == 1 and e == 0 end,
		0, 0)
end

function irina_set_online(email)
	set_flags(email,
		function(i, e) return i == 0 or e == 1 end,
		1, 1)
end

local function get_users_impl(shardid, is_instant)
	local result = {}
	local tuples = { box.select(0, 1, is_instant, shardid) }
	for _, tuple in pairs(tuples) do table.insert(result, { tuple[0], box.unpack('i', tuple[1]) }) end
	return result
end

function irina_get_instant_users(shardid) -- deprecated
	shardid = box.unpack('i', shardid)
	local result = get_users_impl(shardid, 1)
	return unpack(result)
end

function irina_get_instant_users_ex(shardid)
	shardid = box.unpack('i', shardid)

	local result = {}
	local tuples = { box.select(0, 1, 1, shardid) }
	for _, tuple in pairs(tuples) do table.insert(result, { tuple[0], box.unpack('i', tuple[1]), box.unpack('i', tuple[3]) }) end

	return unpack(result)
end

function irina_get_usual_users(shardid)
	shardid = box.unpack('i', shardid)
	local result = get_users_impl(shardid, 0)
	return unpack(result)
end

local function is_expired(args, tuple)
	if tuple == nil or #tuple <= args.fieldno then return nil end
	local is_expirable = box.unpack('i', tuple[3])
	if is_expirable == 0 then return false end

	local field = box.unpack('i', tuple[args.fieldno])
	return box.time() >= field + args.expiration_time
end

local function clean_expired(spaceno, args, tuple)
	set_flags_impl(tuple,
		function (i, e) return i == 1 and e == 1 end,
		0, 0)
end

dofile('expirationd.lua')

expirationd.run_task('expire_instant', 0, is_expired, clean_expired, {fieldno = 4, expiration_time = 5*60})
