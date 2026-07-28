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

-- ===== 自动启动管理 =====

-- 检测系统类型和版本
local systemInfo = nil
local function getSystemInfo()
	if systemInfo then return systemInfo end
	systemInfo = { name = "Unknown", version = "", method = "autorun" }

	-- 1. 先检测 rc 库（OpenOS 特有，最可靠）
	local hasRC = false
	local ok, rc = pcall(require, "rc")
	if ok and rc and rc.enable then
		hasRC = true
		systemInfo.method = "rc"
	end

	-- 2. 读取 /etc/os-release（OpenOS 和 Plan9k 都可能有）
	local f = io.open("/etc/os-release", "r")
	if f then
		local content = f:read("*a")
		f:close()
		local name = content:match("NAME%s*=%s*\"?([^\n\"]+)\"?")
		local version = content:match("VERSION%s*=%s*\"?([^\n\"]+)\"?")
		if name then systemInfo.name = name end
		if version then systemInfo.version = version end
	end

	-- 3. 如果还没识别出来，用更可靠的标识判断
	if systemInfo.name == "Unknown" then
		if hasRC then
			-- 有 rc 库一定是 OpenOS
			systemInfo.name = "OpenOS"
		elseif filesystem.exists("/bin/oppm") or filesystem.exists("/usr/bin/oppm") then
			-- oppm 是 Plan9k 特有的包管理器
			systemInfo.name = "Plan9k"
		elseif filesystem.exists("/init.lua") then
			-- OpenOS 的启动文件
			systemInfo.name = "OpenOS"
		end
	end

	-- 4. 获取版本信息
	if #systemInfo.version == 0 then
		-- OpenOS: 读 /etc/release
		local vf = io.open("/etc/release", "r")
		if vf then
			systemInfo.version = (vf:read("*l") or ""):match("[%d.]+") or ""
			vf:close()
		end
		-- 如果还是空，用 _OSVERSION 或 os.version
		if #systemInfo.version == 0 then
			local ver = _OSVERSION or (os and os.version)
			if type(ver) == "string" then
				systemInfo.version = ver:match("[%d.]+") or ver
			end
		end
	end

	return systemInfo
end

-- 自动检测系统类型，返回最佳自启动方式
local function detectAutoStartMethod()
	return getSystemInfo().method
end

-- 获取 server.lua 的完整路径
local function getScriptPath()
	local scriptDir = filesystem.path(os.getenv("_") or "server.lua") or ""
	local fullPath = scriptDir .. "server.lua"
	if not fullPath:match("^/") then
		local curDir = os.getenv("PWD") or ""
		if curDir ~= "" then
			fullPath = curDir .. "/" .. fullPath
		end
	end
	return fullPath, scriptDir
end

-- 设置 rc 自启
-- 按官方文档：/etc/rc.d/chatroom.lua，定义全局 start 函数
-- 用 loadfile 直接在当前进程中运行，避免 os.execute 创建新进程导致终端冲突
local function setupRC(fullPath, scriptDir)
	local ok, rc = pcall(require, "rc")
	if not ok or not rc then return false end
	if not filesystem.exists("/etc/rc.d") then
		filesystem.makeDirectory("/etc/rc.d")
	end
	-- 文件名必须有 .lua 后缀
	local rcPath = "/etc/rc.d/chatroom.lua"
	local rf = io.open(rcPath, "w")
	if rf then
		-- 全局函数，不用 local，不返回表
		rf:write("-- ChatRoom server rc script\n")
		rf:write("local cfgPath = \"/etc/chatroom/config.cfg\"\n")
		rf:write("local srvPath = \"" .. fullPath .. "\"\n")
		rf:write("\n")
		rf:write("function start()\n")
		rf:write("  local f = io.open(cfgPath, \"r\")\n")
		rf:write("  if not f then return end\n")
		rf:write("  local c = f:read(\"*a\")\n")
		rf:write("  f:close()\n")
		rf:write("  local ok, cfg = pcall(function() return load(\"return \"..c)() end)\n")
		rf:write("  if not ok or not cfg then return end\n")
		rf:write("  if cfg.autoStart == \"rc\" or cfg.autoStart == true then\n")
		-- 用 loadfile 而非 os.execute，直接在当前进程运行
		-- 避免 shell 进程和 server.lua 争抢终端
		rf:write("    local srv, err = loadfile(srvPath)\n")
		rf:write("    if srv then\n")
		rf:write("      pcall(srv)\n")
		rf:write("    end\n")
		rf:write("  end\n")
		rf:write("end\n")
		rf:write("\n")
		rf:write("function stop()\n")
		rf:write("end\n")
		rf:close()
	end
	-- 删除旧的无后缀文件
	if filesystem.exists("/etc/rc.d/chatroom") then
		filesystem.remove("/etc/rc.d/chatroom")
	end
	pcall(function() rc.enable("chatroom") end)
	return true
end

-- 设置 autorun 自启（通用方案，Plan9k 等）
local function setupAutorun(fullPath, scriptDir)
	-- 写启动脚本到单独文件
	local scriptPath = "/etc/chatroom_autostart.lua"
	local sf = io.open(scriptPath, "w")
	if sf then
		-- 配置文件固定在 /etc/chatroom/config.cfg
		sf:write("-- ChatRoom server autostart\n")
		sf:write("local cfgPath = \"/etc/chatroom/config.cfg\"\n")
		sf:write("local srvPath = \"" .. fullPath .. "\"\n")
		sf:write("local f = io.open(cfgPath, \"r\")\n")
		sf:write("if f then\n")
		sf:write("  local c = f:read(\"*a\")\n")
		sf:write("  f:close()\n")
		sf:write("  local ok, cfg = pcall(function() return load(\"return \"..c)() end)\n")
		sf:write("  if ok and cfg and (cfg.autoStart == \"autorun\" or cfg.autoStart == true) then\n")
		-- 用 thread 避免阻塞系统启动
		sf:write("    local okt, thread = pcall(require, \"thread\")\n")
		sf:write("    if okt and thread then\n")
		sf:write("      thread.create(function() os.execute(srvPath) end):detach()\n")
		sf:write("    else\n")
		sf:write("      os.execute(srvPath)\n")
		sf:write("    end\n")
		sf:write("  end\n")
		sf:write("end\n")
		sf:close()
	end
	-- 在 /autorun.lua 中添加引用（不覆盖已有内容）
	local autorunPath = "/autorun.lua"
	local existing = ""
	local af = io.open(autorunPath, "r")
	if af then
		existing = af:read("*a")
		af:close()
	end
	-- 检查是否已包含引用
	if not existing:find("chatroom_autostart", 1, true) then
		af = io.open(autorunPath, "a")
		if af then
			if #existing > 0 and not existing:sub(-1):match("[\r\n]") then
				af:write("\n")
			end
			af:write("pcall(dofile, \"/etc/chatroom_autostart.lua\")\n")
			af:close()
		end
	end
	return true
end

-- 关闭 rc 自启
local function disableRC()
	local ok, rc = pcall(require, "rc")
	if ok and rc then
		pcall(function() rc.disable("chatroom") end)
	end
end

-- 关闭 autorun 自启（从 /autorun.lua 中移除引用）
local function disableAutorun()
	local autorunPath = "/autorun.lua"
	local af = io.open(autorunPath, "r")
	if not af then return end
	local content = af:read("*a")
	af:close()
	-- 移除包含 chatroom_autostart 的行
	local lines = {}
	for line in content:gmatch("[^\r\n]+") do
		if not line:find("chatroom_autostart", 1, true) then
			table.insert(lines, line)
		end
	end
	local newContent = table.concat(lines, "\n")
	af = io.open(autorunPath, "w")
	if af then
		if #newContent > 0 then
			af:write(newContent .. "\n")
		else
			af:write("")
		end
		af:close()
	end
end

-- 统一设置自启（自动检测系统类型）
local function enableAutoStart()
	local method = detectAutoStartMethod()
	local fullPath, scriptDir = getScriptPath()
	if method == "rc" then
		setupRC(fullPath, scriptDir)
		config.autoStart = "rc"
	else
		setupAutorun(fullPath, scriptDir)
		config.autoStart = "autorun"
	end
	return method
end

-- 统一关闭自启
local function disableAutoStart()
	if config.autoStart == "rc" then
		disableRC()
	elseif config.autoStart == "autorun" then
		disableAutorun()
	end
	config.autoStart = "none"
end

-- ===== 终端UI =====
local function clearScreen()
	term.clear()
	term.setCursor(1, 1)
end

local function drawHeader()
	local sys = getSystemInfo()
	local sysDisplay = sys.name
	if sys.version and #sys.version > 0 then
		sysDisplay = sysDisplay .. " " .. sys.version
	end
	clearScreen()
	print("========================================")
	print("       ChatRoom Server v1.0             ")
	print("========================================")
	print(" 系统:   " .. sysDisplay)
	print(" 地址:")
	print("  " .. modem.address)
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
	print(" [7] 开机自启: " .. (config.autoStart == "rc" and "开启 (rc)" or (config.autoStart == "autorun" and "开启 (autorun)" or "关闭")))
	print(" [8] 返回")
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
			if config.autoStart == "rc" or config.autoStart == "autorun" or config.autoStart == true then
				-- 关闭自启
				disableAutoStart()
				saveConfig()
				print(" 开机自启已关闭!")
			else
				-- 开启自启（自动检测系统类型）
				local method = enableAutoStart()
				saveConfig()
				if method == "rc" then
					print(" 开机自启已开启! (rc 服务 / OpenOS)")
				else
					print(" 开机自启已开启! (autorun / 通用)")
				end
			end
			os.sleep(1.5)
		elseif input == "8" then
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
	-- 自动检测系统类型
	local sys = getSystemInfo()
	local sysDisplay = sys.name
	if sys.version and #sys.version > 0 then
		sysDisplay = sysDisplay .. " " .. sys.version
	end
	local methodDisplay = sys.method == "rc" and "rc 服务 (OpenOS)" or "autorun (通用)"
	print(" 检测到系统: " .. sysDisplay)
	print(" 自启方式:   " .. methodDisplay)
	print("")
	print(" 是否设置开机自动启动服务器?")
	print(" [1] 不设置 (手动运行)")
	print(" [2] 自动设置自启 (推荐)")
	print("     ✓  不修改 BIOS，完全安全")
	print("     ✓  主菜单中可随时开关自启")
	print("     ✓  不影响系统正常启动")
	print("")
	io.write(" 请选择 [2]: ")
	local bootChoice = io.read()
	if bootChoice == "" or bootChoice == "2" then
		bootChoice = "2"
	end

	if bootChoice == "2" then
		local usedMethod = enableAutoStart()
		saveConfig()
		print("")
		if usedMethod == "rc" then
			print(" ✓ 已设置 rc 服务自启 (OpenOS)")
		else
			print(" ✓ 已设置 autorun 自启 (通用)")
		end
		print(" (可在主菜单→配置中随时开关)")
		os.sleep(1.5)
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
	local sys = getSystemInfo()
	local sysDisplay = sys.name
	if sys.version and #sys.version > 0 then
		sysDisplay = sysDisplay .. " " .. sys.version
	end
	print(" 系统:       " .. sysDisplay)
	print(" 服务器名称: " .. config.serverName)
	print(" 端口:       " .. config.port)
	print(" 密码:       " .. (#config.password > 0 and "已设置" or "无"))
	local autoStartDisplay = "无"
	if config.autoStart == "rc" then
		autoStartDisplay = "rc 服务 (OpenOS)"
	elseif config.autoStart == "autorun" then
		autoStartDisplay = "autorun (通用)"
	end
	print(" 自启方式:   " .. autoStartDisplay)
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
