-- ChatRoom Server for OpenComputers
-- 兼容原版 OpenOS，无需 PixelOS
-- 需要网卡组件（有线/无线/高级网卡均可）
-- 用法: lua server.lua

local component = require("component")
local event = require("event")
local term = require("term")
local computer = require("computer")
local filesystem = require("filesystem")
local serialization = require("serialization")

-- 检查网卡
if not component.isAvailable("modem") then
	io.write("错误: 需要网卡组件（有线/无线/高级网卡）!\n")
	return
end

local modem = component.modem

-- ===== 配置 =====
local dataPath = "/etc/chatroom/"
local configPath = dataPath .. "config.cfg"
local usersPath = dataPath .. "users.dat"

local config = {
	port = 1488,
	password = "",
	serverName = "ChatRoom Server",
	maxConnections = 50,
	blacklist = {},
}

-- ===== 状态 =====
local users = {}        -- [username] = {password=..., created=...}
local connections = {}  -- [address] = {address=..., username=..., loggedIn=false, connectTime=...}
local chatLog = {}      -- {username=..., text=..., timestamp=...}
local running = true

-- ===== 工具函数 =====
local function ensureDataDir()
	if not filesystem.exists(dataPath) then
		filesystem.makeDirectory(dataPath)
	end
end

local function loadConfig()
	local f = io.open(configPath, "r")
	if f then
		local data = f:read("*a")
		f:close()
		local loaded = serialization.unserialize(data)
		if loaded then
			for k, v in pairs(loaded) do
				config[k] = v
			end
		end
	end
end

local function saveConfig()
	ensureDataDir()
	local f = io.open(configPath, "w")
	if f then
		f:write(serialization.serialize(config))
		f:close()
	end
end

local function loadUsers()
	local f = io.open(usersPath, "r")
	if f then
		local data = f:read("*a")
		f:close()
		users = serialization.unserialize(data) or {}
	end
end

local function saveUsers()
	ensureDataDir()
	local f = io.open(usersPath, "w")
	if f then
		f:write(serialization.serialize(users))
		f:close()
	end
end

local function sendToClient(address, ...)
	modem.send(address, config.port, ...)
end

local function isBlacklisted(address)
	for _, addr in ipairs(config.blacklist) do
		if addr == address then
			return true
		end
	end
	return false
end

local function getConnectedCount()
	local count = 0
	for _ in pairs(connections) do
		count = count + 1
	end
	return count
end

local function getLoggedInCount()
	local count = 0
	for _, conn in pairs(connections) do
		if conn.loggedIn then
			count = count + 1
		end
	end
	return count
end

local function formatTime(timestamp)
	local hours = math.floor(timestamp / 3600) % 24
	local minutes = math.floor(timestamp / 60) % 60
	return string.format("%02d:%02d", hours, minutes)
end

local function broadcastChat(username, text)
	local timestamp = computer.uptime()
	local entry = {
		username = username,
		text = text,
		timestamp = timestamp,
	}
	table.insert(chatLog, entry)
	if #chatLog > 500 then
		table.remove(chatLog, 1)
	end
	for addr, conn in pairs(connections) do
		if conn.loggedIn then
			sendToClient(addr, "chat", username, text, timestamp)
		end
	end
end

local function broadcastSystem(text)
	local entry = {
		username = "[System]",
		text = text,
		timestamp = computer.uptime(),
	}
	table.insert(chatLog, entry)
	if #chatLog > 500 then
		table.remove(chatLog, 1)
	end
	for addr, conn in pairs(connections) do
		if conn.loggedIn then
			sendToClient(addr, "sys", text)
		end
	end
end

-- ===== 网络消息处理 =====
local function handleMessage(eventName, localAddr, remoteAddr, port, distance, msgType, ...)
	if port ~= config.port then return end

	-- 服务器发现请求
	if msgType == "discover" then
		sendToClient(remoteAddr, "discovered", config.serverName, localAddr)
		return
	end

	-- 黑名单检查
	if isBlacklisted(remoteAddr) then
		return
	end

	if msgType == "connect" then
		local password = ...
		if getConnectedCount() >= config.maxConnections then
			sendToClient(remoteAddr, "rejected", "服务器已满")
			return
		end
		if config.password ~= "" and password ~= config.password then
			sendToClient(remoteAddr, "rejected", "服务器密码错误")
			return
		end
		connections[remoteAddr] = {
			address = remoteAddr,
			username = nil,
			loggedIn = false,
			connectTime = computer.uptime(),
		}
		sendToClient(remoteAddr, "connected", config.serverName)

	elseif msgType == "disconnect" then
		if connections[remoteAddr] then
			if connections[remoteAddr].loggedIn then
				broadcastSystem(connections[remoteAddr].username .. " 离开了聊天室")
			end
			connections[remoteAddr] = nil
		end

	elseif msgType == "register" then
		local username, password = ...
		if not connections[remoteAddr] then
			sendToClient(remoteAddr, "error", "未连接")
			return
		end
		if not username or #username < 1 or #username > 20 then
			sendToClient(remoteAddr, "reg_fail", "用户名长度需为1-20个字符")
			return
		end
		if users[username] then
			sendToClient(remoteAddr, "reg_fail", "用户名已存在")
			return
		end
		users[username] = {
			password = password or "",
			created = computer.uptime(),
		}
		saveUsers()
		-- 注册后自动登录
		connections[remoteAddr].username = username
		connections[remoteAddr].loggedIn = true
		sendToClient(remoteAddr, "login_ok", username)
		broadcastSystem(username .. " 加入了聊天室")

	elseif msgType == "login" then
		local username, password = ...
		if not connections[remoteAddr] then
			sendToClient(remoteAddr, "error", "未连接")
			return
		end
		if not users[username] then
			sendToClient(remoteAddr, "login_fail", "用户不存在")
			return
		end
		if users[username].password ~= password then
			sendToClient(remoteAddr, "login_fail", "密码错误")
			return
		end
		-- 踢掉已在其他地方登录的同一账号
		for addr, conn in pairs(connections) do
			if conn.loggedIn and conn.username == username then
				conn.loggedIn = false
				conn.username = nil
				sendToClient(addr, "sys", "账号在其他地方登录")
			end
		end
		connections[remoteAddr].username = username
		connections[remoteAddr].loggedIn = true
		sendToClient(remoteAddr, "login_ok", username)
		broadcastSystem(username .. " 加入了聊天室")

	elseif msgType == "logout" then
		if connections[remoteAddr] and connections[remoteAddr].loggedIn then
			broadcastSystem(connections[remoteAddr].username .. " 退出了登录")
			connections[remoteAddr].loggedIn = false
			connections[remoteAddr].username = nil
			sendToClient(remoteAddr, "sys", "已退出登录")
		end

	elseif msgType == "msg" then
		local text = ...
		if not connections[remoteAddr] or not connections[remoteAddr].loggedIn then
			sendToClient(remoteAddr, "error", "未登录")
			return
		end
		if text and #text > 0 and #text <= 500 then
			broadcastChat(connections[remoteAddr].username, text)
		end
	end
end

-- ===== 终端UI =====
local function clearScreen()
	term.clear()
	term.setCursor(1, 1)
end

local function drawHeader()
	clearScreen()
	print("========================================")
	print("       ChatRoom Server v1.0             ")
	print("========================================")
	print(" 地址:   " .. modem.address:sub(1, 16) .. "...")
	print(" 端口:   " .. tostring(config.port))
	print(" 名称:   " .. config.serverName)
	print(" 密码:   " .. (config.password == "" and "(无)" or "已设置"))
	print(" 连接:   " .. getConnectedCount() .. "/" .. config.maxConnections)
	print(" 在线:   " .. getLoggedInCount() .. " 人已登录")
	print(" 消息:   " .. #chatLog .. " 条")
	print("========================================")
	print("")
end

local function drawMainMenu()
	drawHeader()
	print(" [1] 配置管理")
	print(" [2] 连接列表")
	print(" [3] 聊天记录")
	print(" [4] 用户管理")
	print(" [5] 关机")
	print(" [6] 重启")
	print("")
	io.write(" > ")
end

local function drawConfigMenu()
	drawHeader()
	print(" === 配置管理 ===")
	print("")
	print(" [1] 修改服务器名称")
	print(" [2] 设置连接密码")
	print(" [3] 修改端口")
	print(" [4] 设置最大连接数")
	print(" [5] 管理黑名单")
	print(" [6] 返回")
	print("")
	io.write(" > ")
end

local function drawBlacklistMenu()
	drawHeader()
	print(" === 黑名单管理 ===")
	print("")
	if #config.blacklist == 0 then
		print(" (空)")
	else
		for i, addr in ipairs(config.blacklist) do
			print(" " .. i .. ". " .. addr:sub(1, 16) .. "...")
		end
	end
	print("")
	print(" [1] 添加地址")
	print(" [2] 移除地址")
	print(" [3] 返回")
	print("")
	io.write(" > ")
end

local function handleConfigMenu()
	while true do
		drawConfigMenu()
		local input = io.read()
		if not input then break end

		if input == "1" then
			io.write(" 新服务器名称: ")
			local name = io.read()
			if name and #name > 0 then
				config.serverName = name
				saveConfig()
				print(" 已保存!")
				os.sleep(1)
			end
		elseif input == "2" then
			io.write(" 新密码 (留空则无密码): ")
			local pass = io.read()
			config.password = pass or ""
			saveConfig()
			print(" 已保存!")
			os.sleep(1)
		elseif input == "3" then
			io.write(" 新端口 (1-65535): ")
			local port = tonumber(io.read())
			if port and port > 0 and port < 65536 then
				modem.close(config.port)
				config.port = math.floor(port)
				modem.open(config.port)
				saveConfig()
				print(" 已保存!")
			else
				print(" 无效端口!")
			end
			os.sleep(1)
		elseif input == "4" then
			io.write(" 最大连接数: ")
			local max = tonumber(io.read())
			if max and max > 0 then
				config.maxConnections = math.floor(max)
				saveConfig()
				print(" 已保存!")
			else
				print(" 无效数值!")
			end
			os.sleep(1)
		elseif input == "5" then
			while true do
				drawBlacklistMenu()
				local blInput = io.read()
				if not blInput then break end
				if blInput == "1" then
					io.write(" 要拉黑的地址: ")
					local addr = io.read()
					if addr and #addr > 0 then
						table.insert(config.blacklist, addr)
						saveConfig()
						print(" 已添加!")
						os.sleep(1)
					end
				elseif blInput == "2" then
					io.write(" 要移除的编号: ")
					local num = tonumber(io.read())
					if num and config.blacklist[num] then
						table.remove(config.blacklist, num)
						saveConfig()
						print(" 已移除!")
					else
						print(" 无效编号!")
					end
					os.sleep(1)
				elseif blInput == "3" then
					break
				end
			end
		elseif input == "6" then
			break
		end
	end
end

local function handleConnectionList()
	drawHeader()
	print(" === 连接列表 ===")
	print("")
	local count = 0
	for addr, conn in pairs(connections) do
		count = count + 1
		local status = conn.loggedIn and ("已登录: " .. conn.username) or "未登录"
		local timeStr = formatTime(computer.uptime() - conn.connectTime)
		print(" " .. count .. ". " .. addr:sub(1, 12) .. "... | " .. status .. " | 在线: " .. timeStr)
	end
	if count == 0 then
		print(" (无连接)")
	end
	print("")
	print(" 按回车键返回")
	io.read()
end

local function handleChatLog()
	local scroll = 0
	local pageSize = 18

	while true do
		drawHeader()
		print(" === 聊天记录 (最近 " .. pageSize .. " 条) ===")
		print("")

		local total = #chatLog
		local startIdx = math.max(1, total - pageSize + 1 - scroll)
		local endIdx = math.max(1, total - scroll)

		for i = startIdx, endIdx do
			if chatLog[i] then
				local msg = chatLog[i]
				local timeStr = formatTime(msg.timestamp)
				local line = "[" .. timeStr .. "] " .. msg.username .. ": " .. msg.text
				if #line > 38 then
					line = line:sub(1, 35) .. "..."
				end
				print(" " .. line)
			end
		end

		print("")
		print(" [↑/↓] 滚动 | [Q] 返回")

		local eventData = {event.pull()}
		local eventType = eventData[1]

		if eventType == "key_down" then
			local char = eventData[3]
			local code = eventData[4]
			if char == 113 or char == 81 then
				return
			end
			if code == 200 then
				scroll = math.min(total - pageSize, scroll + 1)
			elseif code == 208 then
				scroll = math.max(0, scroll - 1)
			end
		end
	end
end

local function handleUserManagement()
	drawHeader()
	print(" === 用户管理 ===")
	print("")
	print(" 已注册用户:")
	local count = 0
	local userList = {}
	for username, data in pairs(users) do
		count = count + 1
		table.insert(userList, username)
		print(" " .. count .. ". " .. username .. " (注册时间: " .. formatTime(data.created) .. ")")
	end
	if count == 0 then
		print(" (无注册用户)")
	end
	print("")
	print(" [1] 删除用户")
	print(" [2] 清空所有用户")
	print(" [3] 返回")
	print("")
	io.write(" > ")

	local input = io.read()
	if input == "1" then
		io.write(" 要删除的用户名: ")
		local username = io.read()
		if username and users[username] then
			users[username] = nil
			saveUsers()
			print(" 已删除!")
		else
			print(" 用户不存在!")
		end
		os.sleep(1)
	elseif input == "2" then
		io.write(" 确认清空所有用户? (yes/no): ")
		local confirm = io.read()
		if confirm == "yes" then
			users = {}
			saveUsers()
			print(" 已清空!")
		end
		os.sleep(1)
	end
end

-- ===== 初始化与主循环 =====
local function init()
	ensureDataDir()
	loadConfig()
	loadUsers()
	modem.open(config.port)
	event.listen("modem_message", handleMessage)
end

local function main()
	init()

	while running do
		drawMainMenu()
		local input = io.read()
		if not input then break end

		if input == "1" then
			handleConfigMenu()
		elseif input == "2" then
			handleConnectionList()
		elseif input == "3" then
			handleChatLog()
		elseif input == "4" then
			handleUserManagement()
		elseif input == "5" then
			io.write(" 确认关机? (yes/no): ")
			local confirm = io.read()
			if confirm == "yes" then
				broadcastSystem("服务器即将关闭")
				os.sleep(0.5)
				running = false
			end
		elseif input == "6" then
			io.write(" 确认重启? (yes/no): ")
			local confirm = io.read()
			if confirm == "yes" then
				broadcastSystem("服务器即将重启")
				saveConfig()
				saveUsers()
				os.sleep(0.5)
				computer.shutdown(true)
			end
		end
	end

	-- 清理
	event.ignore("modem_message", handleMessage)
	modem.close(config.port)
	clearScreen()
	print("ChatRoom Server 已停止。")
end

main()
