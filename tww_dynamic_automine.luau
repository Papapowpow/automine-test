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

local Global = require(game:GetService("ReplicatedStorage").SharedModules.Global)
getgenv().Global = Global

local DEPOSIT_ROOT = workspace.WORKSPACE_Interactables.Mining.OreDeposits

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
	stats = { mined = 0, swings = 0, paths = 0 },
	settings = {
		speed = 16,
		sprint = true,
		autoEquip = true,
		loop = true,
		arrive = CFG.WaypointRadius,
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
	local best
	for _, group in ipairs(DEPOSIT_ROOT:GetChildren()) do
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
	notify(("Playing %s (%d points)"):format(name, #path.points))

	task.spawn(function()
		ensureHook()
		while not S.stop and alive() do
			local ok = playOnce(path)
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
local selectedPath = paths[1]

local pathDropdown
pathDropdown = AutomineTab:Dropdown({
	Title = "Path",
	Desc = "Recorded routes",
	Values = paths,
	Value = selectedPath,
	Callback = function(value)
		selectedPath = value
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

return S
