--[[
	TWW Dynamic Automine — record/replay build

	A recreation of the feature set advertised by "Dynamic TWW Automine"
	(Amulet, ScriptBlox 2026-02-24): Record Paths, Play Automine Path,
	Auto Equip Next Pickaxe, Speed Customization.

	The original ships as a keyed, obfuscated module behind a loader whose
	payload was removed from Pastebin; only its feature list survived, so this
	is a rebuild of the behaviour, not of its source.

	Record: walk your route, mine as you go. Mining marks are added for you
	        when an ore lands in your bag. F7 drops a sell mark at your feet.
	Play:   replays the waypoints through the game's own control path and
	        mines / sells at the recorded marks.

	UI: WindUI (Footagesus). Toggle key to hide the window is configurable
	    from the library's own settings.
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local LP = Players.LocalPlayer

local function waitForPath(root, path, seconds)
	local deadline = os.clock() + (seconds or 90)
	repeat
		local node = root
		for part in string.gmatch(path, "[^%.]+") do
			node = node and node:FindFirstChild(part)
		end
		if node then
			return node
		end
		task.wait(0.25)
	until os.clock() > deadline
	return nil
end

-- A client that arrived from a server hop starts before the game's modules have
-- replicated, and requiring then kills the load before anything is built - the
-- next server is left with nobody mining.
local globalNode = waitForPath(game:GetService("ReplicatedStorage"), "SharedModules.Global", 120)
if not globalNode then
	return
end

local Global = require(globalNode)
getgenv().Global = Global

local function depositRoot()
	local interactables = workspace:FindFirstChild("WORKSPACE_Interactables")
	local mining = interactables and interactables:FindFirstChild("Mining")
	return mining and mining:FindFirstChild("OreDeposits")
end

local CFG = {
	PathFolder = "TWW_DynamicAutomine/Paths",

	-- movement
	WaypointRadius = 2.5,     -- studs, horizontal
	WaypointTimeout = 25,     -- seconds per point before we give up on it
	SampleSpacing = 1.5,      -- studs between recorded points
	SampleInterval = 0.1,

	-- mining
	MineSearchRadius = 45,    -- studs from a mine mark to look for ore
	MineReach = 9,            -- studs from the ore box before swinging
	SwingInterval = 0.6,
	SwingAttempts = 22,       -- per deposit

	-- keys
	MarkSellKey = Enum.KeyCode.F7,
}

--------------------------------------------------------------------------------
-- State (survives reloads badly on purpose: we kill the previous copy)
--------------------------------------------------------------------------------

local S = {
	running = false,
	stop = false,
	mode = nil,               -- "record" | "play"
	status = "idle",
	pickaxe = nil,
	rec = nil,
	rounds = 0,
	stats = { mined = 0, swings = 0, paths = 0 },
	settings = {
		speed = 16,
		sprint = true,
		autoEquip = true,
		loop = true,
		arrive = CFG.WaypointRadius,
		-- farm / hop
		respawnTown = "Don't respawn",
		respawnAfterDeath = false,
		respawnOnStart = false,
		hopAfter = false,
		hopOnDeath = false,
		roundsPerServer = 1,
		autoResume = true,
	},
}

local ALL = getgenv().__TWW_DA_ALL
if type(ALL) ~= "table" then
	ALL = {}
	getgenv().__TWW_DA_ALL = ALL
end
for _, other in ipairs(ALL) do
	other.stop = true
end
table.insert(ALL, S)
getgenv().TWW_DYNAMIC_AUTOMINE = S

-- a live-reload only kills the top thread, so every run takes a token and an
-- older copy notices it lost ownership on its next tick
local TOKEN = {}
getgenv().__TWW_DA_TOKEN = TOKEN

local function alive()
	return getgenv().__TWW_DA_TOKEN == TOKEN
end

local function notify(text)
	S.status = text
	print(("[DA] %s"):format(text))
	local ui = getgenv().__DA_UI
	if ui and ui.UpdateStatus then
		pcall(ui.UpdateStatus, text)
	end
end

--------------------------------------------------------------------------------
-- Small JSON files (config + the note the next server reads)
--------------------------------------------------------------------------------

local function saveJson(path, data)
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(data)
	end)
	if not ok then
		return false
	end
	local dir = path:match("^(.*)/[^/]+$")
	if dir then
		pcall(function()
			makefolder(dir)
		end)
	end
	return (pcall(function()
		writefile(path, encoded)
	end))
end

local function readJson(path)
	local ok, raw = pcall(function()
		return readfile(path)
	end)
	if not ok then
		return nil
	end
	local ok2, data = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not ok2 then
		return nil
	end
	return data
end

--------------------------------------------------------------------------------
-- Character
--------------------------------------------------------------------------------

local function getPC()
	local pc = Global.PlayerCharacter
	if not pc or pc.IsDead then
		return nil
	end
	local root = pc.RootPart
	local hum = pc.Human
	if not root or not root.Parent or not hum or hum.Health <= 0 then
		return nil
	end
	return pc, root, hum
end

local function setSprint(on)
	local pc = Global.PlayerCharacter
	if pc then
		pc.IsSprintButtonDown = on and true or false
	end
end

local function applySpeed()
	local _, _, hum = getPC()
	if hum then
		pcall(function()
			hum.WalkSpeed = S.settings.speed
		end)
	end
end

--------------------------------------------------------------------------------
-- Movement injection
--------------------------------------------------------------------------------

local MOVE = getgenv().__TWW_DA_MOVE
if type(MOVE) ~= "table" then
	MOVE = { want = Vector3.zero, active = false, orig = nil, controls = nil }
	MOVE.wrapper = function(player, moveVector, cameraRelative)
		if player == LP and MOVE.active then
			local v = MOVE.want
			if cameraRelative then
				v = workspace.CurrentCamera.CFrame:VectorToObjectSpace(v)
			end
			return MOVE.orig(player, v, cameraRelative)
		end
		return MOVE.orig(player, moveVector, cameraRelative)
	end
	getgenv().__TWW_DA_MOVE = MOVE
end

local function getControls()
	local ok, pm = pcall(require, LP.PlayerScripts:WaitForChild("PlayerModule"))
	if not ok or not pm then
		return nil
	end
	local ok2, controls = pcall(function()
		return pm:GetControls()
	end)
	if not ok2 then
		return nil
	end
	return controls
end

local function ensureHook()
	local controls = getControls()
	if not controls then
		return nil
	end
	if controls.moveFunction == MOVE.wrapper then
		return controls
	end
	MOVE.orig = controls.moveFunction
	MOVE.controls = controls
	controls.moveFunction = MOVE.wrapper
	return controls
end

local function setMove(dir)
	if dir and dir.Magnitude > 0.05 then
		local flat = Vector3.new(dir.X, 0, dir.Z)
		MOVE.want = flat.Magnitude > 1e-3 and flat.Unit or Vector3.zero
		MOVE.active = MOVE.want.Magnitude > 0
	else
		MOVE.want = Vector3.zero
		MOVE.active = false
	end
end

local function releaseMovement()
	setMove(nil)
	setSprint(false)
end

local function unhook()
	releaseMovement()
	local controls = MOVE.controls
	if controls and controls.moveFunction == MOVE.wrapper then
		controls.moveFunction = MOVE.orig
	end
end

ensureHook()

-- walk to a point, return ok, reason
local function walkTo(target, tol, timeout)
	tol = tol or S.settings.arrive
	timeout = timeout or CFG.WaypointTimeout

	local deadline = os.clock() + timeout
	local last = nil
	local stuck = 0

	while os.clock() < deadline do
		if S.stop or not alive() then
			releaseMovement()
			return false, "stopped"
		end
		local _, root, hum = getPC()
		if not root then
			releaseMovement()
			return false, "nochar"
		end

		local flat = Vector3.new(target.X - root.Position.X, 0, target.Z - root.Position.Z)
		if flat.Magnitude <= tol then
			setMove(nil)
			return true
		end

		setMove(flat)
		if S.settings.sprint then
			setSprint(true)
		end

		if last and (root.Position - last).Magnitude < 0.15 then
			stuck += 0.06
			if stuck > 0.5 then
				hum.Jump = true
			end
			if stuck > 2.0 then
				releaseMovement()
				return false, "stuck"
			end
		else
			stuck = 0
		end
		last = root.Position

		task.wait(0.06)
	end

	releaseMovement()
	return false, "timeout"
end

--------------------------------------------------------------------------------
-- Geometry / ore
--------------------------------------------------------------------------------

local function boxDistance(pos, part)
	local lp = part.CFrame:PointToObjectSpace(pos)
	local h = part.Size * 0.5
	local c = Vector3.new(
		math.clamp(lp.X, -h.X, h.X),
		math.clamp(lp.Y, -h.Y, h.Y),
		math.clamp(lp.Z, -h.Z, h.Z)
	)
	return (lp - c).Magnitude
end

local function closestPoint(pos, part)
	local lp = part.CFrame:PointToObjectSpace(pos)
	local h = part.Size * 0.5
	local c = Vector3.new(
		math.clamp(lp.X, -h.X, h.X),
		math.clamp(lp.Y, -h.Y, h.Y),
		math.clamp(lp.Z, -h.Z, h.Z)
	)
	return part.CFrame:PointToWorldSpace(c)
end

local function nearestOre(pos, radius)
	local root = depositRoot()
	if not root then
		return nil
	end
	local best
	for _, group in ipairs(root:GetChildren()) do
		for _, dep in ipairs(group:GetChildren()) do
			local info = dep:FindFirstChild("DepositInfo")
			local remaining = info and info:FindFirstChild("OreRemaining")
			local part = dep.PrimaryPart or dep:FindFirstChildWhichIsA("BasePart")
			if remaining and part and remaining.Value > 0 then
				local d = boxDistance(pos, part)
				if d <= radius and (not best or d < best.dist) then
					best = {
						model = dep,
						part = part,
						remaining = remaining,
						progress = info:FindFirstChild("Progress"),
						name = group.Name,
						dist = d,
					}
				end
			end
		end
	end
	return best
end

--------------------------------------------------------------------------------
-- Pickaxe
--------------------------------------------------------------------------------

local function pickaxeRank(itemType)
	if itemType == "BasicPickaxe" then
		return 0
	end
	local n = tonumber(tostring(itemType):match("^Tier(%d+)Pickaxe$"))
	return n or -1
end

local function equipBestPickaxe()
	local pc = Global.PlayerCharacter
	if not pc then
		return nil
	end

	local bestType, bestRecord, bestRank = nil, nil, -1
	for _, item in pairs(Global.PlayerData.InventoryContainer.Items) do
		if type(item) == "table" and type(item.Type) == "string" then
			local rank = pickaxeRank(item.Type)
			if rank > bestRank then
				bestRank, bestType, bestRecord = rank, item.Type, item
			end
		end
	end
	if not bestType then
		return nil
	end

	if pc:GetEquippedItemType() ~= bestType then
		pcall(function()
			pc:EquipItem(bestRecord)
		end)
		local deadline = os.clock() + 4
		while os.clock() < deadline and pc:GetEquippedItemType() ~= bestType do
			task.wait(0.1)
		end
	end
	if pc:GetEquippedItemType() ~= bestType then
		return nil
	end

	local ok, item = pcall(function()
		return pc:GetItem(bestType)
	end)
	S.pickaxe = bestType
	return ok and item or nil
end

local function currentPickaxe()
	local pc = Global.PlayerCharacter
	if not pc or not S.pickaxe then
		return nil
	end
	if pc:GetEquippedItemType() ~= S.pickaxe then
		return nil
	end
	local ok, item = pcall(function()
		return pc:GetItem(S.pickaxe)
	end)
	return ok and item or nil
end

--------------------------------------------------------------------------------
-- Inventory
--------------------------------------------------------------------------------

local function inventoryCount()
	local n = 0
	for _ in pairs(Global.PlayerData.InventoryContainer.Items) do
		n += 1
	end
	return n
end

local function inventorySize()
	return Global.PlayerData.InventoryContainer.Size or 40
end

local function sellOres()
	local ic = Global.PlayerData.InventoryContainer
	local list = {}
	for _, item in pairs(ic.Items) do
		if type(item) == "table" and type(item.Type) == "string" and item.Type:match("Ore$") then
			table.insert(list, item)
		end
	end

	local sold = 0
	for _, item in ipairs(list) do
		if S.stop or not alive() then
			break
		end
		local before = inventoryCount()
		pcall(function()
			Global.PlayerData:SellInventoryItem(item)
		end)
		task.wait(0.3)
		if inventoryCount() < before then
			sold += 1
		end
	end
	return sold
end

--------------------------------------------------------------------------------
-- Mining
--------------------------------------------------------------------------------

local function mineAt(radius)
	local pc, root = getPC()
	if not root then
		return false, "nochar"
	end

	local ore = nearestOre(root.Position, radius or CFG.MineSearchRadius)
	if not ore then
		return false, "noore"
	end

	local item
	if S.settings.autoEquip then
		item = equipBestPickaxe()
	else
		item = currentPickaxe() or equipBestPickaxe()
	end
	if not item then
		return false, "nopickaxe"
	end
	notify(("Mining %s"):format(ore.name))

	-- get into reach first
	local approach = closestPoint(root.Position, ore.part)
	local ok = walkTo(approach, CFG.MineReach, 12)
	if not ok then
		-- already close enough? fall through and try swinging anyway
	end

	local swings = 0
	while swings < CFG.SwingAttempts do
		if S.stop or not alive() then
			releaseMovement()
			return false, "stopped"
		end

		local _, root2, hum = getPC()
		if not root2 then
			releaseMovement()
			return false, "nochar"
		end
		if not ore.model:IsDescendantOf(workspace) or ore.remaining.Value <= 0 then
			releaseMovement()
			return true
		end

		local dist = boxDistance(root2.Position, ore.part)
		if dist > CFG.MineReach + 2 then
			local ok2 = walkTo(closestPoint(root2.Position, ore.part), CFG.MineReach, 6)
			if not ok2 then
				hum.Jump = true
			end
		end

		pcall(function()
			item:Swing()
		end)
		swings += 1
		S.stats.swings += 1

		task.wait(CFG.SwingInterval)
	end

	releaseMovement()
	return false, "swings"
end

--------------------------------------------------------------------------------
-- Path storage
--------------------------------------------------------------------------------

local function ensureFolder()
	pcall(function()
		makefolder("TWW_DynamicAutomine")
		makefolder(CFG.PathFolder)
	end)
end

local function pathFile(name)
	return CFG.PathFolder .. "/" .. name .. ".json"
end

local function listPaths()
	ensureFolder()
	local out = {}
	local ok, files = pcall(function()
		return listfiles(CFG.PathFolder)
	end)
	if ok and type(files) == "table" then
		for _, f in ipairs(files) do
			local name = f:match("([^/\\]+)%.json$")
			if name then
				table.insert(out, name)
			end
		end
	end
	table.sort(out)
	return out
end

local function savePath(name, data)
	ensureFolder()
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(data)
	end)
	if not ok then
		return false, "encode"
	end
	local ok2 = pcall(function()
		writefile(pathFile(name), encoded)
	end)
	if not ok2 then
		return false, "write"
	end
	return true
end

local function loadPath(name)
	local ok, raw = pcall(function()
		return readfile(pathFile(name))
	end)
	if not ok then
		return nil
	end
	local ok2, data = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not ok2 or type(data) ~= "table" or type(data.points) ~= "table" then
		return nil
	end
	return data
end

--------------------------------------------------------------------------------
-- Respawn (driven through the game's own spawn menu)
--------------------------------------------------------------------------------

local function spawnTowns()
	local out = { "Don't respawn" }
	local ok, names = pcall(function()
		local list = {}
		for name in pairs(Global.UI.Spawn.SpawnButtons) do
			table.insert(list, name)
		end
		table.sort(list)
		return list
	end)
	if ok and type(names) == "table" then
		for _, name in ipairs(names) do
			table.insert(out, name)
		end
	end
	return out
end

local function respawnUi()
	local pg = LP:FindFirstChild("PlayerGui")
	return pg and pg:FindFirstChild("NewSpawnUI")
end

local function isDead()
	local pc = Global.PlayerCharacter
	if pc and pc.IsDead == true then
		return true
	end
	local state = Global.ReplicatedState and Global.ReplicatedState.State
	if state and state.RespawnMenuOpen == true then
		return true
	end
	local ui = respawnUi()
	return ui ~= nil and ui.Enabled == true
end

-- firesignal does nothing in this executor, so the handler is taken off the
-- signal and called directly: the same Lua closure a real click would run.
local function press(button)
	if not button then
		return false
	end
	for _, name in ipairs({ "Activated", "MouseButton1Click", "MouseButton1Up" }) do
		local signal = button[name]
		if signal then
			local ok, conns = pcall(getconnections, signal)
			if ok and type(conns) == "table" then
				for _, conn in ipairs(conns) do
					if type(conn.Function) == "function" then
						if pcall(conn.Function) then
							return true
						end
					end
				end
			end
		end
	end
	return false
end

local function townButton(ui, town)
	local screen = ui:FindFirstChild("Screen")
	if not screen then
		return nil
	end
	local sidebar = screen:FindFirstChild("SideBar")
	local body = sidebar and sidebar:FindFirstChild("Body")
	local root = body or screen
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("GuiButton") and d.Name == town then
			return d
		end
	end
	return nil
end

--- Reset the character through the game's spawn menu and take `town` out of it.
local function respawnAt(town)
	local ui = respawnUi()

	if not (ui and ui.Enabled) then
		notify("Resetting character")
		pcall(function()
			Global.Network:FireServer("RespawnTriggered")
		end)
		local deadline = os.clock() + 25
		while os.clock() < deadline do
			ui = ui or respawnUi()
			if ui and ui.Enabled then
				break
			end
			task.wait(0.2)
		end
	end

	if not (ui and ui.Enabled) then
		notify("Spawn menu did not open")
		return false
	end

	task.wait(0.8)

	local screen = ui:FindFirstChild("Screen")
	local accept = screen and screen:FindFirstChild("AcceptButton")
	if not accept then
		notify("No accept button")
		return false
	end

	if type(town) == "string" and town ~= "" and town ~= "Don't respawn" then
		local button = townButton(ui, town)
		if button then
			notify("Spawning at " .. town)
			press(button)
		else
			notify(town .. " is not offered here")
		end
	end

	local deadline = os.clock() + 60
	while os.clock() < deadline and ui.Enabled do
		press(accept)
		local slice = os.clock() + 1.5
		while os.clock() < slice and ui.Enabled do
			task.wait(0.2)
		end
	end

	local rigDeadline = os.clock() + 20
	while os.clock() < rigDeadline and not getPC() do
		task.wait(0.25)
	end
	if getPC() then
		task.wait(0.4)
	end
	return getPC() ~= nil
end

--------------------------------------------------------------------------------
-- Server hop
--------------------------------------------------------------------------------

local TeleportService = game:GetService("TeleportService")

local HOP_NOTE = "TWW_DynamicAutomine/hop.json"
local HOP_COPY = "tww_dynamic_automine.luau"
local HOP_MIN_GAP = 30

local function saveSettings()
	saveJson("TWW_DynamicAutomine/config.json", {
		settings = S.settings,
		path = S.selectedPath,
	})
end

--- The place's public servers, or nil (the endpoint rate limits hard, so it is
--- treated as a hint and never as a requirement).
local function serverList()
	local ok, res = pcall(function()
		return request({
			Url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100"):format(game.PlaceId),
			Method = "GET",
		})
	end)
	if not ok or type(res) ~= "table" then
		return nil
	end
	local body = res.Body or res.body
	if type(body) ~= "string" then
		return nil
	end
	local ok2, decoded = pcall(function()
		return HttpService:JSONDecode(body)
	end)
	if not ok2 or type(decoded) ~= "table" or type(decoded.data) ~= "table" then
		return nil
	end
	return decoded.data
end

--- The quietest server that is not this one.
local function pickServer(list)
	local best, bestN
	for _, server in ipairs(list) do
		local id = server.id
		local playing = tonumber(server.playing)
		local max = tonumber(server.maxPlayers)
		if type(id) == "string" and id ~= game.JobId
			and playing and (not max or playing < max)
			and (not bestN or playing < bestN) then
			best, bestN = id, playing
		end
	end
	return best
end

local function hopServer()
	-- The server list is a hint, never a requirement: the endpoint rate limits
	-- and this executor can stall on it, so the lookup is given 3 seconds and
	-- the teleport goes ahead without a named instance if it has not answered.
	local list, done = nil, false
	task.spawn(function()
		local ok, res = pcall(serverList)
		if ok then
			list = res
		end
		done = true
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < 3 do
		task.wait(0.1)
	end

	local target = list and pickServer(list) or nil
	if target then
		if pcall(function()
			TeleportService:TeleportToPlaceInstance(game.PlaceId, target, LP)
		end) then
			return true
		end
	end
	if type(TeleportService.TeleportAsync) == "function" then
		if pcall(function()
			TeleportService:TeleportAsync(game.PlaceId, { LP })
		end) then
			return true
		end
	end
	return (pcall(function()
		TeleportService:Teleport(game.PlaceId, LP)
	end))
end

--- Queue a loader rather than the source: the running chunk has no copy of its
--- own text, and the copy already sits in the executor workspace.
local function queueResume()
	if not S.settings.autoResume then
		return true
	end
	local loader = table.concat({
		"task.spawn(function()",
		"    local t0 = os.clock()",
		"    while not game:IsLoaded() and os.clock() - t0 < 90 do task.wait(1) end",
		"    local ok, src = pcall(readfile, " .. string.format("%q", HOP_COPY) .. ")",
		"    if not (ok and type(src) == \"string\" and #src > 1000) then",
		"        warn(\"[DA] hop copy missing from the executor workspace\")",
		"        return",
		"    end",
		"    local fn, err = loadstring(src)",
		"    if not fn then warn(\"[DA] hop copy did not compile: \" .. tostring(err)) return end",
		"    local ran, why = pcall(fn)",
		"    if not ran then warn(\"[DA] hop copy failed: \" .. tostring(why)) end",
		"end)",
	}, "\n")
	return (pcall(queue_on_teleport, loader))
end

--- Leave for another server, with the town and the path written down first.
local function hopNow(reason)
	if os.clock() - (S.hopLast or 0) < HOP_MIN_GAP then
		notify("Hop skipped (one just happened)")
		return false
	end
	S.hopLast = os.clock()

	local note = {
		pending = true,
		spawn = S.settings.respawnTown,
		path = S.selectedPath,
		autostart = S.settings.autoResume,
		reason = tostring(reason or "round"),
		at = os.time(),
	}

	saveSettings()
	saveJson(HOP_NOTE, note)
	notify("Server hopping")

	if not queueResume() then
		note.pending = false
		saveJson(HOP_NOTE, note)
		notify("Could not queue the next server")
		return false
	end

	task.wait(2)

	if not hopServer() then
		note.pending = false
		saveJson(HOP_NOTE, note)
		pcall(function()
			clear_teleport_queue()
		end)
		notify("Hop refused - staying put")
		return false
	end

	S.stop = true
	return true
end

-- exposed so the console (and a test) can drive the same code the menu does
getgenv().__DA_RESPAWN = respawnAt
getgenv().__DA_HOP = hopNow

--------------------------------------------------------------------------------
-- Recorder
--------------------------------------------------------------------------------

local function stopRecording()
	if not S.rec then
		return
	end
	local rec = S.rec
	rec.active = false
	S.rec = nil
	S.mode = nil
	releaseMovement()

	if #rec.points < 2 then
		notify("Recording discarded (too short)")
		return
	end

	local data = {
		name = rec.name,
		created = os.time(),
		points = rec.points,
		marks = rec.marks,
	}
	local ok = savePath(rec.name, data)
	if ok then
		S.stats.paths += 1
		notify(("Saved %s (%d points, %d marks)"):format(rec.name, #rec.points, #rec.marks))
		local ui = getgenv().__DA_UI
		if ui and ui.RefreshPaths then
			pcall(ui.RefreshPaths)
		end
	else
		notify("Could not save path")
	end
end

local function startRecording(name)
	if S.running then
		notify("Stop the current run first")
		return
	end
	if not getPC() then
		notify("No character")
		return
	end

	local rec = {
		name = name,
		active = true,
		points = {},
		marks = {},
		lastInv = inventoryCount(),
	}
	S.rec = rec
	S.mode = "record"
	S.stop = false
	S.running = true
	ensureHook()
	notify("Recording - walk the route, mine as you go (F7 marks a sell spot)")

	task.spawn(function()
		local last = nil

		while rec.active and alive() do
			local _, root = getPC()
			if root then
				local p = root.Position
				local far = not last
					or Vector3.new(p.X - last.X, 0, p.Z - last.Z).Magnitude >= CFG.SampleSpacing
					or math.abs(p.Y - last.Y) >= 2
				if far then
					table.insert(rec.points, { x = math.floor(p.X * 10) / 10, y = math.floor(p.Y * 10) / 10, z = math.floor(p.Z * 10) / 10 })
					last = p
				end
			end

			-- an ore landed in the bag: that spot is a mine mark
			local inv = inventoryCount()
			if inv > rec.lastInv and #rec.points > 0 then
				table.insert(rec.marks, { type = "mine", index = #rec.points })
				notify(("Mine mark at point %d"):format(#rec.points))
			end
			rec.lastInv = inv

			if S.stop or not alive() then
				rec.active = false
				break
			end
			task.wait(CFG.SampleInterval)
		end

		if not alive() then
			return
		end
		S.running = false
		if S.rec == rec then
			stopRecording()
		end
	end)
end

local function markSell()
	local rec = S.rec
	if not rec or not rec.active then
		notify("Not recording")
		return
	end
	table.insert(rec.marks, { type = "sell", index = #rec.points })
	notify(("Sell mark at point %d"):format(#rec.points))
end

--------------------------------------------------------------------------------
-- Player
--------------------------------------------------------------------------------

local function marksAt(path, index)
	local out = {}
	for _, m in ipairs(path.marks or {}) do
		if m.index == index then
			table.insert(out, m)
		end
	end
	return out
end

local function playOnce(path)
	local points = path.points
	for i = 1, #points do
		if S.stop or not alive() then
			return false
		end
		local p = points[i]
		local target = Vector3.new(p.x, p.y, p.z)

		local ok, reason = walkTo(target, S.settings.arrive, CFG.WaypointTimeout)
		if not ok and reason ~= "stuck" then
			notify(("Path aborted at point %d (%s)"):format(i, tostring(reason)))
			return false
		end

		for _, mark in ipairs(marksAt(path, i)) do
			if S.stop or not alive() then
				return false
			end
			if mark.type == "mine" then
				local before = inventoryCount()
				mineAt()
				if inventoryCount() > before then
					S.stats.mined += inventoryCount() - before
				end
			elseif mark.type == "sell" then
				local sold = sellOres()
				notify(("Sold %d"):format(sold))
			end
		end
	end
	return true
end

local function startPlayback(name)
	if S.running then
		notify("Already running")
		return
	end
	local path = loadPath(name)
	if not path then
		notify("Path not found: " .. tostring(name))
		return
	end
	if not getPC() then
		notify("No character")
		return
	end

	S.stop = false
	S.running = true
	S.mode = "play"
	S.playPath = name
	notify(("Playing %s (%d points)"):format(name, #path.points))

	task.spawn(function()
		ensureHook()
		if S.settings.respawnOnStart and S.settings.respawnTown ~= "Don't respawn" then
			notify("Spawning at " .. S.settings.respawnTown)
			respawnAt(S.settings.respawnTown)
		end
		while not S.stop and alive() do
			local ok = playOnce(path)
			if ok then
				S.rounds += 1
				if S.settings.hopAfter and S.rounds >= S.settings.roundsPerServer then
					S.rounds = 0
					if hopNow("round") then
						return
					end
				end
			end
			if not ok or not S.settings.loop or S.stop then
				break
			end
			task.wait(0.5)
		end

		releaseMovement()
		S.running = false
		S.mode = nil
		notify(("Stopped (%d ore)"):format(S.stats.mined))
	end)
end

local function stopAll()
	S.stop = true
	releaseMovement()
	if S.rec then
		stopRecording()
	end
end

getgenv().__DA_PLAY = startPlayback
getgenv().__DA_STOP = stopAll

--------------------------------------------------------------------------------
-- Death watch: respawn at the chosen town, or hand the round to a new server
--------------------------------------------------------------------------------

task.spawn(function()
	local lastAction = 0
	while alive() do
		task.wait(0.5)
		pcall(function()
			if getPC() then
				return
			end
			if not isDead() then
				return
			end
			if os.clock() - lastAction < 8 then
				return
			end
			if not (S.settings.respawnAfterDeath or (S.settings.hopOnDeath and S.running)) then
				return
			end
			lastAction = os.clock()

			if S.settings.hopOnDeath and S.running then
				notify("Died - hopping")
				S.running = false
				hopNow("death")
				return
			end

			local wasRunning = S.running and S.mode == "play"
			notify("Died - respawning")
			releaseMovement()
			respawnAt(S.settings.respawnTown)

			local name = S.playPath
			if wasRunning and name then
				S.running = false
				S.stop = false
				task.wait(0.5)
				startPlayback(name)
			end
		end)
	end
end)

-- F7 drops a sell mark while recording
local KEYENV = "__DA_KEYS"
local previousKeys = getgenv()[KEYENV]
if previousKeys then
	pcall(function()
		previousKeys:Disconnect()
	end)
end

getgenv()[KEYENV] = UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == CFG.MarkSellKey then
		markSell()
	end
end)

--------------------------------------------------------------------------------
-- Saved settings
--------------------------------------------------------------------------------

do
	local saved = readJson("TWW_DynamicAutomine/config.json")
	if type(saved) == "table" then
		if type(saved.settings) == "table" then
			for k, v in pairs(saved.settings) do
				if S.settings[k] ~= nil and type(v) == type(S.settings[k]) then
					S.settings[k] = v
				end
			end
		end
		if type(saved.path) == "string" then
			S.selectedPath = saved.path
		end
	end
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

local okLib, WindUI = pcall(function()
	return loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua", true))()
end)

if not okLib or type(WindUI) ~= "table" then
	warn("[DA] WindUI failed to load: " .. tostring(WindUI))
	return
end

local Window = WindUI:CreateWindow({
	Title = "Dynamic Automine",
	Author = "record / replay",
	Icon = "play",
	Folder = "DynamicAutomine",
	Size = UDim2.fromOffset(560, 430),
	Theme = "Dark",
	HideSearchBar = true,
	ToggleKey = Enum.KeyCode.RightShift,
})

-- keep a handle so the window can be re-shown from the console if it is ever
-- minimised into nothing
getgenv().__DA_WINDOW = Window

local statusLabel = "idle"
local statusParagraph

local function updateStatus(text)
	statusLabel = text
	if statusParagraph then
		pcall(function()
			statusParagraph:SetTitle(text)
		end)
	end
end

getgenv().__DA_UI = { UpdateStatus = updateStatus }

-- Record tab -------------------------------------------------------------
local RecordTab = Window:Tab({ Title = "Record", Icon = "circle" })

local pathName = "path"

RecordTab:Input({
	Title = "Path name",
	Desc = "Saved under the executor workspace",
	Value = pathName,
	Placeholder = "path",
	Callback = function(value)
		if type(value) == "string" and value ~= "" then
			pathName = value
		end
	end,
})

RecordTab:Space()

RecordTab:Button({
	Title = "Start recording",
	Desc = "Walk the route and mine; marks are added as ore lands",
	Color = Color3.fromHex("#305dff"),
	Callback = function()
		startRecording(pathName)
	end,
})

RecordTab:Button({
	Title = "Stop and save",
	Desc = "Writes points and marks to disk",
	Color = Color3.fromHex("#10c550"),
	Callback = function()
		stopAll()
	end,
})

RecordTab:Space()

RecordTab:Button({
	Title = "Mark sell spot here",
	Desc = "F7 also does this while recording",
	Icon = "coins",
	Callback = function()
		markSell()
	end,
})

RecordTab:Space()

statusParagraph = RecordTab:Paragraph({
	Title = statusLabel,
	Desc = "Status",
})

-- Automine tab -----------------------------------------------------------
local AutomineTab = Window:Tab({ Title = "Automine", Icon = "play" })

local paths = listPaths()
local selectedPath = S.selectedPath
if not selectedPath or not table.find(paths, selectedPath) then
	selectedPath = paths[1]
	S.selectedPath = selectedPath
end

local pathDropdown
pathDropdown = AutomineTab:Dropdown({
	Title = "Path",
	Desc = "Recorded routes",
	Values = paths,
	Value = selectedPath,
	Callback = function(value)
		selectedPath = value
		S.selectedPath = value
		saveSettings()
	end,
})

AutomineTab:Space()

AutomineTab:Button({
	Title = "Start automine",
	Desc = "Replays the selected path",
	Color = Color3.fromHex("#10c550"),
	Icon = "play",
	Callback = function()
		if selectedPath then
			startPlayback(selectedPath)
		else
			notify("No path selected")
		end
	end,
})

AutomineTab:Button({
	Title = "Stop",
	Color = Color3.fromHex("#ef4f1d"),
	Icon = "square",
	Callback = function()
		stopAll()
	end,
})

AutomineTab:Toggle({
	Title = "Loop path",
	Desc = "Keep replaying until stopped",
	Value = true,
	Callback = function(v)
		S.settings.loop = v
	end,
})

AutomineTab:Toggle({
	Title = "Auto equip next pickaxe",
	Desc = "Always swing the best pickaxe in the bag",
	Value = true,
	Callback = function(v)
		S.settings.autoEquip = v
	end,
})

AutomineTab:Space()

AutomineTab:Button({
	Title = "Refresh paths",
	Icon = "refresh-cw",
	Callback = function()
		local list = listPaths()
		pcall(function()
			pathDropdown:Refresh(list)
		end)
		if list[1] then
			pcall(function()
				pathDropdown:Select(list[1])
			end)
		end
		selectedPath = list[1]
		notify(("%d path(s) found"):format(#list))
	end,
})

getgenv().__DA_UI.RefreshPaths = function()
	local list = listPaths()
	pcall(function()
		pathDropdown:Refresh(list)
	end)
end

-- Farm tab ---------------------------------------------------------------
local FarmTab = Window:Tab({ Title = "Farm", Icon = "repeat" })

local towns = spawnTowns()
local selectedTown = S.settings.respawnTown
if not table.find(towns, selectedTown) then
	selectedTown = "Don't respawn"
	S.settings.respawnTown = selectedTown
end

FarmTab:Dropdown({
	Title = "Respawn town",
	Desc = "Where a respawn or a server hop drops you",
	Values = towns,
	Value = selectedTown,
	Callback = function(value)
		S.settings.respawnTown = value
		saveSettings()
	end,
})

FarmTab:Space()

FarmTab:Toggle({
	Title = "Respawn after death",
	Desc = "Takes the chosen town out of the spawn menu",
	Value = S.settings.respawnAfterDeath,
	Callback = function(v)
		S.settings.respawnAfterDeath = v
		saveSettings()
	end,
})

FarmTab:Toggle({
	Title = "Respawn when a run starts",
	Desc = "Resets at the chosen town before playing the path",
	Value = S.settings.respawnOnStart,
	Callback = function(v)
		S.settings.respawnOnStart = v
		saveSettings()
	end,
})

FarmTab:Toggle({
	Title = "Server hop after each round",
	Desc = "Leaves for a quieter server when the path completes",
	Value = S.settings.hopAfter,
	Callback = function(v)
		S.settings.hopAfter = v
		saveSettings()
	end,
})

FarmTab:Toggle({
	Title = "Server hop on death",
	Desc = "Hands the round to a new server instead of respawning",
	Value = S.settings.hopOnDeath,
	Callback = function(v)
		S.settings.hopOnDeath = v
		saveSettings()
	end,
})

FarmTab:Slider({
	Title = "Rounds per server",
	Desc = "Completed path passes before leaving",
	Step = 1,
	Value = { Min = 1, Max = 20, Default = S.settings.roundsPerServer },
	Callback = function(value)
		S.settings.roundsPerServer = math.floor(value)
		saveSettings()
	end,
})

FarmTab:Toggle({
	Title = "Resume after hop",
	Desc = "Queues this script into the teleport so the farm keeps running",
	Value = S.settings.autoResume,
	Callback = function(v)
		S.settings.autoResume = v
		saveSettings()
	end,
})

FarmTab:Space()

FarmTab:Button({
	Title = "Respawn now",
	Icon = "user",
	Callback = function()
		task.spawn(function()
			respawnAt(S.settings.respawnTown)
		end)
	end,
})

FarmTab:Button({
	Title = "Hop now",
	Desc = "Leave this server immediately",
	Color = Color3.fromHex("#ef4f1d"),
	Icon = "arrow-right",
	Callback = function()
		task.spawn(function()
			hopNow("manual")
		end)
	end,
})

-- Settings tab -----------------------------------------------------------
local SettingsTab = Window:Tab({ Title = "Settings", Icon = "settings" })

SettingsTab:Slider({
	Title = "Speed",
	Desc = "Walk speed target",
	Step = 1,
	Value = { Min = 8, Max = 40, Default = 16 },
	Callback = function(value)
		S.settings.speed = value
		applySpeed()
	end,
})

SettingsTab:Slider({
	Title = "Waypoint radius",
	Desc = "How close counts as arrived",
	Step = 0.5,
	Value = { Min = 1, Max = 8, Default = CFG.WaypointRadius },
	Callback = function(value)
		S.settings.arrive = value
	end,
})

SettingsTab:Toggle({
	Title = "Sprint",
	Value = true,
	Callback = function(v)
		S.settings.sprint = v
		if not v then
			setSprint(false)
		end
	end,
})

WindUI:Notify({
	Title = "Dynamic Automine",
	Content = "Record a route, then play it back.",
	Duration = 5,
})

notify("Ready")

--------------------------------------------------------------------------------
-- Arriving from a hop
--------------------------------------------------------------------------------

local function resumeAfterHop()
	local note = readJson(HOP_NOTE)
	if type(note) ~= "table" or not note.pending then
		return
	end
	note.pending = false
	saveJson(HOP_NOTE, note)

	task.spawn(function()
		notify("Arrived from a server hop")
		local t0 = os.clock()
		while os.clock() - t0 < 120 and not game:IsLoaded() do
			task.wait(1)
		end
		task.wait(4)

		local town = type(note.spawn) == "string" and note.spawn or ""
		if town ~= "" and town ~= "Don't respawn" then
			respawnAt(town)
		end

		if note.autostart and type(note.path) == "string" and note.path ~= "" then
			S.selectedPath = note.path
			S.running = false
			S.stop = false
			startPlayback(note.path)
		end
	end)
end

resumeAfterHop()

return S
