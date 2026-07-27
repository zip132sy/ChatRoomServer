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
	broadcastShutdown = true,
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

local function broadcastUserList()
	local userList = {}
	for _, conn in pairs(connections) do
		if conn.loggedIn and conn.username then
			table.insert(userList, conn.username)
		end
	end
	for addr, conn in pairs(connections) do
		if conn.loggedIn then
			sendToClient(addr, "userlist", table.unpack(userList))
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
		if connections[remoteAddr] then
			sendToClient(remoteAddr, "rejected", "该地址已连接")
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
			broadcastUserList()
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
		broadcastUserList()

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
		broadcastUserList()

	elseif msgType == "logout" then
		if connections[remoteAddr] and connections[remoteAddr].loggedIn then
			broadcastSystem(connections[remoteAddr].username .. " 退出了登录")
			connections[remoteAddr].loggedIn = false
			connections[remoteAddr].username = nil
			sendToClient(remoteAddr, "sys", "已退出登录")
			broadcastUserList()
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
	print(" [5] 退出服务器")
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
	print(" [6] 关机重启广播: " .. (config.broadcastShutdown and "开启" or "关闭"))
	print(" [7] 返回")
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
			config.broadcastShutdown = not config.broadcastShutdown
			saveConfig()
			print(" 关机重启广播已" .. (config.broadcastShutdown and "开启" or "关闭") .. "!")
			os.sleep(1)
		elseif input == "7" then
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

-- ===== 安装向导 =====
local function runInstaller()
	clearScreen()
	print("========================================")
	print("   ChatRoom Server 安装向导")
	print("========================================")
	print("")
	print(" 欢迎使用 ChatRoom 聊天室服务器!")
	print(" 接下来将引导您完成初始配置。")
	print("")
	print("========================================")
	print("")
	io.write(" 按回车键继续...")
	io.read()

	clearScreen()
	print("========================================")
	print("   步骤 1/4: 服务器名称")
	print("========================================")
	print("")
	print(" 给你的服务器起个名字吧。")
	print(" 这个名字会显示在客户端的服务器列表中。")
	print("")
	io.write(" 服务器名称 [ChatRoom Server]: ")
	local name = io.read()
	if not name or #name == 0 then
		name = "ChatRoom Server"
	end
	config.serverName = name
	print("")
	print(" ✓ 已设置: " .. name)
	os.sleep(0.5)

	clearScreen()
	print("========================================")
	print("   步骤 2/4: 端口设置")
	print("========================================")
	print("")
	print(" 设置服务器监听的端口号。")
	print(" 客户端连接时需要使用相同的端口。")
	print("")
	io.write(" 端口号 [1488]: ")
	local portInput = tonumber(io.read())
	if portInput and portInput > 0 and portInput < 65536 then
		config.port = math.floor(portInput)
	else
		config.port = 1488
	end
	print("")
	print(" ✓ 已设置端口: " .. config.port)
	os.sleep(0.5)

	clearScreen()
	print("========================================")
	print("   步骤 3/4: 连接密码")
	print("========================================")
	print("")
	print(" 设置连接密码，客户端需要输入正确密码")
	print(" 才能连接到服务器。")
	print(" 留空表示不需要密码。")
	print("")
	io.write(" 连接密码 [无]: ")
	local pass = io.read()
	config.password = pass or ""
	print("")
	if #config.password > 0 then
		print(" ✓ 已设置密码")
	else
		print(" ✓ 无密码 (任何人都可连接)")
	end
	os.sleep(0.5)

	clearScreen()
	print("========================================")
	print("   步骤 4/4: 开机自启")
	print("========================================")
	print("")
	print(" 是否设置开机自动启动服务器?")
	print(" [1] 不设置 (手动运行)")
	print(" [2] 使用 rc 服务自启 (推荐)")
	print("     不影响 OpenOS 正常使用")
	print(" [3] 写入 EEPROM (高级, 需 EEPROM 组件)")
	print("     ✓  服务器 + OpenOS 共存")
	print("     ✓  开机先跑服务器，退出后自动引导系统")
	print("     ⚠  会覆盖当前 BIOS")
	print("")
	io.write(" 请选择 [1]: ")
	local bootChoice = io.read()

	if bootChoice == "2" then
		local ok, rc = pcall(require, "rc")
		if ok and rc then
			-- 获取脚本路径
			local scriptDir = filesystem.path(os.getenv("_") or "server.lua") or ""
			if scriptDir == "" then
				scriptDir = filesystem.get(".") and "" or ""
			end
			local fullPath = scriptDir .. "server.lua"
			-- 尝试获取绝对路径
			if not fullPath:match("^/") then
				local curDir = os.getenv("PWD") or ""
				if curDir ~= "" then
					fullPath = curDir .. "/" .. fullPath
				end
			end

			if not filesystem.exists("/etc/rc.d") then
				filesystem.makeDirectory("/etc/rc.d")
			end
			local rcScript = "/etc/rc.d/chatroom"
			local rf = io.open(rcScript, "w")
			if rf then
				rf:write(fullPath .. "\n")
				rf:close()
			end
			pcall(function() rc.enable("chatroom") end)
			config.autoStart = "rc"
			print("")
			print(" ✓ 已设置 rc 服务自启")
		else
			print("")
			print(" ✗ 无法设置 rc 服务 (rc 库不可用)")
		end
		os.sleep(1)
	elseif bootChoice == "3" then
		if component.isAvailable("eeprom") then
			clearScreen()
			print("========================================")
			print("   写入 EEPROM - 共存模式")
			print("========================================")
			print("")
			print(" 将写入精简版引导程序到 EEPROM：")
			print("")
			print(" 1. 开机自动启动聊天室服务器")
			print(" 2. 退出服务器后自动引导 OpenOS")
			print(" 3. 服务器出错也不会影响系统启动")
			print("")
			print(" 注意: 这将覆盖当前 BIOS!")
			print("")
			io.write(" 确认写入? (yes/no): ")
			local confirm = io.read()
			if confirm == "yes" then
				local eeprom = component.eeprom
				-- 获取脚本路径
				local scriptDir = filesystem.path(os.getenv("_") or "server.lua") or ""
				local fullPath = scriptDir .. "server.lua"
				if not fullPath:match("^/") then
					local curDir = os.getenv("PWD") or ""
					if curDir ~= "" then
						fullPath = curDir .. "/" .. fullPath
					end
				end
				-- 精简版 BIOS：先跑服务器，退出后引导磁盘系统
				-- 服务器出错也不会影响系统引导
				local function rf(fs, path)
					local h = fs.open(path, "r")
					if h then
						local c = ""
						for _ = 1, 9999 do
							local d = fs.read(h, 4096)
							if not d or #d == 0 then break end
							c = c .. d
						end
						fs.close(h)
						return c
					end
				end
				local biosCode = "local C=computer local a=C.getBootAddress() " ..
					"if a then local f=component.proxy(a) if f then " ..
					"local function rp(p) local h=f.open(p,'r') if h then " ..
					"local c=''for _=1,9999 do local d=f.read(h,4096) " ..
					"if not d or#d==0 then break end c=c..d end " ..
					"f.close(h) return c end end " ..
					"local s=rp('" .. fullPath .. "') " ..
					"if s then local e=load(s,'srv','t',_G) " ..
					"if e then pcall(e) end end end end " ..
					"-- boot os -- " ..
					"if a then local f=component.proxy(a) if f then " ..
					"local function rp(p) local h=f.open(p,'r') if h then " ..
					"local c=''for _=1,9999 do local d=f.read(h,4096) " ..
					"if not d or#d==0 then break end c=c..d end " ..
					"f.close(h) return c end end " ..
					"local k=rp('/init.lua')or rp('/boot/kernel.lua')or rp('/OS.lua') " ..
					"if k then local e=load(k,'init','t',_G) " ..
					"if e then e()end end end end"
				eeprom.set(biosCode)
				eeprom.setLabel("ChatRoom BIOS")
				config.autoStart = "eeprom"
				print("")
				print(" ✓ 已写入 EEPROM!")
				print(" (" .. #biosCode .. " 字节 / 4096 可用)")
			else
				print("")
				print(" 已取消")
			end
		else
			print("")
			print(" ✗ 未找到 EEPROM 组件")
		end
		os.sleep(1)
	else
		config.autoStart = "none"
		print("")
		print(" ✓ 未设置自启")
		os.sleep(0.5)
	end

	saveConfig()

	clearScreen()
	print("========================================")
	print("   安装完成!")
	print("========================================")
	print("")
	print(" 服务器名称: " .. config.serverName)
	print(" 端口:       " .. config.port)
	print(" 密码:       " .. (#config.password > 0 and "已设置" or "无"))
	print(" 自启方式:   " .. (config.autoStart or "none"))
	print("")
	print("----------------------------------------")
	print(" 服务器地址 (给客户端连接用):")
	print(" " .. modem.address)
	print(" 端口: " .. config.port)
	print("----------------------------------------")
	print("")
	print(" 提示: 客户端可以使用搜索功能")
	print(" 自动找到此服务器，无需手动输入地址。")
	print("")
	io.write(" 按回车键启动服务器...")
	io.read()
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
	ensureDataDir()

	-- 检测是否首次运行
	local firstRun = not filesystem.exists(configPath)
	if firstRun then
		runInstaller()
	end

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
			io.write(" 确认退出服务器? (yes/no): ")
			local confirm = io.read()
			if confirm == "yes" then
				if config.broadcastShutdown then
					broadcastSystem("服务器已关闭")
				end
				os.sleep(0.5)
				running = false
			end
		elseif input == "6" then
			io.write(" 确认重启? (yes/no): ")
			local confirm = io.read()
			if confirm == "yes" then
				if config.broadcastShutdown then
					broadcastSystem("服务器即将重启")
				end
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
