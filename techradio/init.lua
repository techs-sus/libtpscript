-- 12/17/22 10:28 PM
-- I am done for today. Time to commit.

local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")
---@module ecc
local ecc = loadstring(
	HttpService:GetAsync(
		"https://gist.githubusercontent.com/techs-sus/2f9170b21a42596e4f518ed838afc12e/raw/6e4167b994f0e632ea677affebc2498082391cbc/stuff.lua"
	)
)()

type Message = {
	encrypted: boolean,
	author: string,
	message: string,
	type: string,
	extra: any,
}

warn("key-generation will be slow. task.desynchronize throws off math")

local keys = {}
local actualKeys = {}
local sharedSecrets = {}
local privateKey, publicKey
local fromHex = ecc.utils.fromHex

local function generateKeys()
	privateKey, publicKey = ecc.keypair(ecc.random.random())
end

generateKeys()
print([[
prefix: >
>exchange <author> (exchanges keys with an author)
>say <message> (signed, unencrypted)
>esay <author> <message> (encrypted, but tedious)
>regen (regenerates your keypair)
]])

local function verify(x, t)
	return x == nil or typeof(x) ~= t
end

do
	local A_Z = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	local characters = A_Z .. string.lower(A_Z) .. "1234567890-=+_~/,.<> !@#$%^&*()	"
	local characters_array: { string } = {}
	for character in string.gmatch(characters, ".") do
		table.insert(characters_array, character)
	end
	function buildCache(key)
		local cache = {}
		local now = os.clock()
		task.desynchronize()
		-- We are in a new thread!!!
		for _, character in characters_array do
			cache[character] = ecc.encrypt(character, key)
		end
		print(string.format("built cache of %i, in %2.1f seconds", #characters_array, os.clock() - now))
		task.synchronize()
		return cache
	end
end

local function receive(p)
	local alive, data: Message = pcall(HttpService.JSONDecode, HttpService, p.Data)
	if
		not alive
		or verify(data.encrypted, "boolean")
		or verify(data.author, "string")
		or verify(data.type, "string")
	then
		return
	end
	local author = data.author
	if data.type == "text" then
		if data.encrypted then
			return decryptMessage(data)
		end
		local key = actualKeys[author]
		if not key or not data.extra or typeof(data.extra) ~= "table" then
			return warn(string.format("%s didn't attach a signature.", author))
		end
		local valid = ecc.verify(key, data.message, data.extra)
		if valid then
			print(string.format("(signed) %s: %s", author, data.message))
		else
			warn(string.format("(invalid) %s sent an invalid signature.", author))
		end
	elseif data.type == "keys-share" then
		local key = data.message
		if keys[author] ~= nil then
			actualKeys[author] = key
			keys[author] = key
			return
		end
		print(string.format("(import) %s is using %s", author, fromHex(key)))
		keys[author] = key
		actualKeys[author] = key
	elseif data.type == "keys-update" then
		local key = data.message
		keys[author] = key
		actualKeys[author] = key
		print(string.format("(update) %s is using %s", author, fromHex(key)))
	elseif data.type == "heartbeat" then
		if not keys[author] then
			keys[author] = data.message
		end
		actualKeys[author] = data.message
	elseif data.type == "exchange" then
		print(string.format("(exchange) Exchanging with %s...", author))
		local key = data.message
		local shared = ecc.exchange(privateKey, key)
		sharedSecrets[author] = { key = shared, cache = buildCache(shared) }
		print(string.format("(exchange) Exchanged with %s!", author))
	end
end

function decryptMessage(data: Message)
	local info = sharedSecrets[data.author]
	local key = info and info.key
	local message = {}
	local store = MemoryStoreService:GetQueue("techradio-private-" .. data.author)
	-- in this case data.message is the length
	local items, id = store:ReadAsync(tonumber(data.message), false, 0)
	task.desynchronize()
	local cache = info.cache
	for index, v in pairs(items) do
		task.spawn(function()
			if not cache[v] then
				cache[v] = tostring(ecc.decrypt(HttpService:JSONDecode(v), key))
			end
			message[index] = cache[v]
		end)
	end
	repeat
		task.wait()
	until #message == #items
	task.synchronize()
	store:RemoveAsync(id)
	print(string.format("[encrypted] %s -> you: %s", data.author, table.concat(message, "")))
end

task.spawn(function()
	while task.wait(10) do
		table.clear(actualKeys)
	end
end)

task.spawn(function()
	while task.wait(20) do
		for index in actualKeys do
			if not keys[index] then
				actualKeys[index] = nil
				keys[index] = nil
				print("(gc) removing", index)
			end
		end
	end
end)

-- begin generic code!!!
local channel = "general"
local gc = {}

local function send(message: Message)
	MessagingService:PublishAsync("techradio:" .. channel, HttpService:JSONEncode(message))
end

local user = "tech"

local function connect(name: string)
	if gc.channel ~= nil then
		gc.channel:Disconnect()
		gc.channel = nil
	end
	if gc.thread ~= nil then
		task.cancel(gc.thread)
		gc.thread = nil
	end
	channel = name
	gc.channel = MessagingService:SubscribeAsync("techradio:" .. channel, receive)
	send({
		message = publicKey,
		author = user,
		encrypted = false,
		extra = "",
		type = "keys-share",
	})
	gc.thread = task.defer(function()
		while task.wait(10) do
			send({
				message = publicKey,
				author = user,
				encrypted = false,
				extra = "",
				type = "heartbeat",
			})
		end
	end)
end

connect(channel)

local commands = {
	say = function(split: { string })
		local message = table.concat(split, " ", 2)
		send({
			message = message,
			author = user,
			encrypted = false,
			extra = ecc.sign(privateKey, message),
			type = "text",
		})
	end,
	regen = function()
		generateKeys()
		send({
			message = publicKey,
			author = user,
			encrypted = false,
			extra = false,
			type = "keys-update",
		})
	end,
	exchange = function(split: { string })
		local author = split[2]
		local key = ecc.exchange(privateKey, keys[author])
		sharedSecrets[author] = { key = key, cache = buildCache(key) }
		send({
			message = publicKey,
			author = user,
			encrypted = false,
			extra = author,
			type = "exchange",
		})
		print(string.format("(exchange) Exchanged with %s!", author))
	end,
	encrypted_say = function(split: { string })
		local author = split[2]
		local key = sharedSecrets[author].key
		local message = table.concat(split, " ", 3)
		local store = MemoryStoreService:GetQueue("techradio-private-" .. user)
		local done = {}
		local alreadyDone = 0
		local cache = sharedSecrets[author].cache
		task.desynchronize()
		local i = 0
		for v in string.gmatch(message, ".") do
			i += 1
			task.spawn(function()
				if not cache[v] then
					cache[v] = ecc.encrypt(v, key)
				end
				done[i] = cache[v]
			end)
		end
		repeat
			task.wait()
		until #done == #message
		task.synchronize()
		local lengthOfDone = #done
		for index, encryptedCharacter in done do
			task.spawn(function()
				store:AddAsync(HttpService:JSONEncode(encryptedCharacter), 30 + lengthOfDone, lengthOfDone - index)
			end)
		end
		repeat
			task.wait()
		until alreadyDone == lengthOfDone
		send({
			message = tostring(#done),
			author = user,
			encrypted = true,
			extra = "",
			type = "text",
		})
		print(string.format("(encrypt) you -> %s: %s", author, message))
	end,
}

local USE_CHATTED = true

if USE_CHATTED then
	print("(commands) initalizing chatted handler")
	getfenv().owner.Chatted:Connect(function(message)
		local split = string.split(message, " ")
		if string.sub(split[1], 1, 1) == ">" then
			local command = string.sub(split[1], 2)
			if commands[command] then
				commands[command](split)
			end
		end
	end)
end
