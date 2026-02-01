-- ============================================
-- AUTO FISH SCRIPT — LinoriaLib UI Integration
-- Every pcall has console output. Example script.
-- ============================================

-- ============================================
-- CONFIG
-- ============================================
local CONFIG = {
	Enabled = false,
	BaitPriority = { "Legendary Fish Bait", "Rare Fish Bait", "Common Fish Bait" },
	CastDistance = 25,
	Terminated = false,
	AutoBuyBait = true,
	BaitBuyThreshold = 10,
	BaitBuyAmount = 50,
	WebhookURL = "",
	WebhookEnabled = false,
	SilentMode = true,
	SpecialItems = {
		"Dragon", "Mochi", "Ope", "Tori", "Soul", "Buddha",
		"Pika", "Venom", "Pteranodon", "Goro", "Magu", "Hie", "Gura",
	},
}

-- Safe print function
local function safePrint(...)
	if not CONFIG.SilentMode then
		local args = {...}
		pcall(function()
			print("[AutoFish]", unpack(args))
		end)
	end
end

-- Killaura debug print (always shows)
local function debugPrint(...)
	local args = {...}
	pcall(function()
		print("[KILLAURA]", unpack(args))
	end)
end

-- Clone references for anti-detection
local safeClone = cloneref or function(obj) return obj end

-- ============================================
-- LINORIA LIB LOAD
-- ============================================
local Library, ThemeManager, SaveManager

local libLoaded, libErr = pcall(function()
	local repo = "https://raw.githubusercontent.com/liquit4/uilibrary/main/"
	Library = loadstring(game:HttpGet(repo .. "Library.lua"))()
	ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
	SaveManager = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()
end)
if not libLoaded then safePrint("Failed to load LinoriaLib:", libErr) end

-- ============================================
-- SERVICES
-- ============================================
local Players = safeClone(game:GetService("Players"))
local UserInputService = safeClone(game:GetService("UserInputService"))
local RunService = safeClone(game:GetService("RunService"))
local ReplicatedStorage = safeClone(game:GetService("ReplicatedStorage"))
local HttpService = safeClone(game:GetService("HttpService"))

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()

-- ============================================
-- STATE
-- ============================================
local forcedWaterPosition = nil
local spoofEnabled = false
local isFishing = false
local currentBobble = nil
local selectedBait = nil
local blockRotation = false
local previousInventory = {}
local inventoryConnection = nil
local lastWebhookTime = {}
local lastBuyTime = 0
local allConnections = {}
local autoFishConnection = nil
local minigameConnection = nil

-- Killaura state
local killauraConnection = nil
local killauraEnabled = false
local killauraRange = 20
local killauraDelay = 0.1
local lastKillauraAttack = 0
local targetNPC = nil
local killauraDebug = true -- Always print killaura debug info
local killauraPaused = false
local lastToolChange = 0
local lastEquippedTool = nil

-- ============================================
-- REMOTE LOADING
-- ============================================
local FishingRemote = nil
pcall(function()
	local fishing = ReplicatedStorage:WaitForChild("Fishing", 10)
	if fishing then
		local remotes = fishing:WaitForChild("Remotes", 10)
		if remotes then
			FishingRemote = safeClone(remotes:WaitForChild("Action", 10))
		end
	end
end)

local ShopRemote = nil
pcall(function()
	local events = ReplicatedStorage:WaitForChild("Events", 10)
	if events then
		ShopRemote = safeClone(events:WaitForChild("Shop", 10))
	end
end)

-- ============================================
-- HOOK: BLOCK ROTATION
-- ============================================
pcall(function()
	if hookmetamethod then
		local oldNewindex
		oldNewindex = hookmetamethod(game, "__newindex", function(self, key, value)
			if blockRotation and key == "CFrame" and self.Name == "HumanoidRootPart" then
				local char = LocalPlayer.Character
				if char and self.Parent == char then
					return
				end
			end
			return oldNewindex(self, key, value)
		end)
	end
end)

-- ============================================
-- HOOK: NAMECALL (INTERCEPT InvokeServer)
-- ============================================
local Mouse = LocalPlayer:GetMouse()

local function setForcedMousePosition(pos)
	forcedWaterPosition = pos
	spoofEnabled = true
end

local function disableMouseSpoof()
	spoofEnabled = false
end

local oldNamecall = nil
pcall(function()
	if hookmetamethod and getnamecallmethod then
		oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
			local method = getnamecallmethod()
			local args = { ... }

			-- Check if this is a Fishing Remote InvokeServer call
			if method == "InvokeServer" and tostring(self):find("Fishing") then
				if args[1] and type(args[1]) == "table" then
					-- Hook the Throw action
					if args[1].Action == "Throw" and spoofEnabled and forcedWaterPosition then
						args[1].Goal = forcedWaterPosition
						return oldNamecall(self, unpack(args))
					end
				end
			end

			return oldNamecall(self, ...)
		end)
	end
end)

-- Fallback: hookfunction on InvokeServer directly
pcall(function()
	if not oldNamecall and hookfunction and FishingRemote then
		local oldInvoke = FishingRemote.InvokeServer

		local newInvoke = function(self, data, ...)
			if type(data) == "table" and data.Action == "Throw" then
				if spoofEnabled and forcedWaterPosition then
					data.Goal = forcedWaterPosition
				end
			end
			return oldInvoke(self, data, ...)
		end

		hookfunction(FishingRemote.InvokeServer, newInvoke)
	end
end)

-- RenderStepped spoof
local spoofConnection = RunService.RenderStepped:Connect(function()
	if spoofEnabled and forcedWaterPosition then
		rawset(_G, "MouseCF", CFrame.new(forcedWaterPosition))
	end
end)

-- ============================================
-- JSON FUNCTIONS
-- ============================================
local function decodeJSON(jsonString)
	local result = {}
	if not jsonString or jsonString == "" then return result end

	local content = jsonString:match("^%s*{(.*)}")
	if not content then return result end

	for key, value in content:gmatch('"([^"]+)"%s*:%s*([^,}]+)') do
		value = value:match("^%s*(.-)%s*$")
		local numValue = tonumber(value)
		if numValue then
			result[key] = numValue
		else
			result[key] = value:match('"(.-)"') or value
		end
	end

	return result
end

local function encodeJSON(tbl)
	local function encode(val)
		if type(val) == "string" then
			local escaped = val:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
			return '"' .. escaped .. '"'
		elseif type(val) == "number" then
			return tostring(val)
		elseif type(val) == "boolean" then
			return val and "true" or "false"
		elseif type(val) == "table" then
			local maxIndex = 0
			local count = 0
			for k, _ in pairs(val) do
				count = count + 1
				if type(k) == "number" and k > maxIndex then
					maxIndex = k
				end
			end
			local isArray = maxIndex == count and count > 0

			if isArray then
				local parts = {}
				for i, v in ipairs(val) do
					table.insert(parts, encode(v))
				end
				return "[" .. table.concat(parts, ",") .. "]"
			else
				local parts = {}
				for k, v in pairs(val) do
					table.insert(parts, '"' .. tostring(k) .. '":' .. encode(v))
				end
				return "{" .. table.concat(parts, ",") .. "}"
			end
		elseif val == nil then
			return "null"
		end
		return '"' .. tostring(val) .. '"'
	end
	return encode(tbl)
end

-- ============================================
-- WEBHOOK
-- ============================================
local function sendWebhook(itemName, newCount)
	local whLoaded, whErr = pcall(function()
		if not CONFIG.WebhookEnabled then
			print("[AutoFish] Webhook: disabled in config")
			return
		end
		if not CONFIG.WebhookURL or CONFIG.WebhookURL == "" then
			print("[AutoFish] Webhook: no URL set")
			return
		end

		local httpRequest = request or http_request or (syn and syn.request) or (http and http.request) or (fluxus and fluxus.request)

		if not httpRequest then
			print("[AutoFish] Webhook: no http request function available")
			return
		end

		local playerThumb = "https://www.roblox.com/headshot-thumbnail/image?userId=" .. LocalPlayer.UserId .. "&width=420&height=420&format=png"

		local data = {
			embeds = {{
				author = {
					name = "Sulfur • Notification",
					icon_url = "https://cdn-icons-png.flaticon.com/512/2979/2979679.png"
				},
				title = " Caught an item ",
				description = "**" .. LocalPlayer.Name .. "** has caught an item.",
				color = tonumber(0x8332b3),
				thumbnail = { url = playerThumb },
				fields = {
					{ name = " Item Name ", value = "**" .. itemName .. "**", inline = true },
					{ name = " Total Inventory ", value = "`" .. tostring(newCount) .. "`", inline = true }
				},
				footer = { text = "AutoFish | " .. os.date("%Y-%m-%d") },
				timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
			}}
		}

		local jsonData = encodeJSON(data)

		httpRequest({
			Url = CONFIG.WebhookURL,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = jsonData
		})

end)
end

-- ============================================
-- INVENTORY HELPERS
-- ============================================
local function isSpecialItem(itemName)
	for _, special in ipairs(CONFIG.SpecialItems) do
		if itemName == special then
			return true
		end
	end
	return false
end

local function parseInventory(jsonString)
	local success, result = pcall(function()
		if not jsonString or jsonString == "" then return {} end
		return decodeJSON(jsonString)
	end)
	if success then return result end
	return {}
end

local function getBaitCount(baitName)
	local success, result = pcall(function()
		local statsFolder = ReplicatedStorage:FindFirstChild("Stats" .. LocalPlayer.Name)
		if not statsFolder then
			print("[AutoFish] getBaitCount: Stats folder not found")
			return 0
		end

		local inventoryFolder = statsFolder:FindFirstChild("Inventory")
		if not inventoryFolder then
			print("[AutoFish] getBaitCount: Inventory folder not found")
			return 0
		end

		local inventoryValue = inventoryFolder:FindFirstChild("Inventory")
		if not inventoryValue or not inventoryValue:IsA("StringValue") then
			print("[AutoFish] getBaitCount: Inventory StringValue not found")
			return 0
		end

		local jsonString = inventoryValue.Value
		if not jsonString or jsonString == "" then
			print("[AutoFish] getBaitCount: Inventory is empty")
			return 0
		end

		local inventoryData = decodeJSON(jsonString)
		local count = tonumber(inventoryData[baitName]) or 0
		print(string.format("[AutoFish] getBaitCount(%s) = %d", baitName, count))
		return count
	end)

	print("[AutoFish] getBaitCount finished:", success, result or 0)
	if success and result then
		return tonumber(result) or 0
	end
	return 0
end

-- ============================================
-- BUY BAIT
-- ============================================
local function buyBait(baitName, amount)
	pcall(function()
		local player = game.Players.LocalPlayer

		local function getShopWithFrame()
			local playerGui = player:WaitForChild("PlayerGui")
			for _, gui in pairs(playerGui:GetChildren()) do
				if gui.Name == "Shop" then
					if gui:FindFirstChild("Frame") then
						return gui
					end
				end
			end
			return nil
		end

		local function getClosestCommonBaitPrompt()
			local character = player.Character or player.CharacterAdded:Wait()
			local humanoidRootPart = character:WaitForChild("HumanoidRootPart")
			local buyablefolder = game.Workspace:WaitForChild("BuyableItems")

			local closestPrompt = nil
			local closestDistance = math.huge

			for _, item in pairs(buyablefolder:GetChildren()) do
				if string.find(item.Name:lower(), "common fish bait") then
					for _, descendant in pairs(item:GetDescendants()) do
						if descendant:IsA("ProximityPrompt") then
							local promptParent = descendant.Parent
							if promptParent:IsA("BasePart") then
								local distance = (humanoidRootPart.Position - promptParent.Position).Magnitude
								if distance < closestDistance then
									closestDistance = distance
									closestPrompt = descendant
								end
							end
						end
					end
				end
			end

			return closestPrompt, closestDistance
		end

		local closestPrompt, distance = getClosestCommonBaitPrompt()

		if closestPrompt then
			firesignal(closestPrompt.Triggered)
			task.wait(1)

			local yesbtn = player.PlayerGui:WaitForChild("NPCCHAT").Frame.go
			firesignal(yesbtn.MouseButton1Click)
			task.wait(1)

			local shopGui = getShopWithFrame()
			local exit = player.PlayerGui:WaitForChild("NPCCHAT"):WaitForChild("Frame"):WaitForChild("endChat")

			if shopGui then
				local count = shopGui.Frame.count
				local buybtn = shopGui.Frame.buy
				count.Text = tostring(amount)
				task.wait(0.5)
				firesignal(buybtn.MouseButton1Click)
				task.wait(0.5)
				firesignal(exit.MouseButton1Click)
			end
		end
	end)
end

local function checkAndBuyBait()
	pcall(function()
		if not CONFIG.AutoBuyBait then return end
		if tick() - lastBuyTime < 5 then return end

		local commonBaitCount = tonumber(getBaitCount("Common Fish Bait")) or 0
		local threshold = tonumber(CONFIG.BaitBuyThreshold) or 10

		if commonBaitCount <= threshold then
			buyBait("Common Fish Bait", CONFIG.BaitBuyAmount)
			lastBuyTime = tick()
		end
	end)
end

-- ============================================
-- INVENTORY MONITOR
-- ============================================
local function setupInventoryMonitor()
	pcall(function()
		local statsFolder = ReplicatedStorage:FindFirstChild("Stats" .. LocalPlayer.Name)
		if not statsFolder then
			statsFolder = ReplicatedStorage:WaitForChild("Stats" .. LocalPlayer.Name, 30)
		end
		if not statsFolder then return end

		local inventoryFolder = statsFolder:FindFirstChild("Inventory")
		if not inventoryFolder then
			inventoryFolder = statsFolder:WaitForChild("Inventory", 10)
		end
		if not inventoryFolder then return end

		local inventoryValue = inventoryFolder:FindFirstChild("Inventory")
		if not inventoryValue then
			inventoryValue = inventoryFolder:WaitForChild("Inventory", 10)
		end
		if not inventoryValue then return end

		previousInventory = parseInventory(inventoryValue.Value)

		inventoryConnection = inventoryValue.Changed:Connect(function(newValue)
			local changeLoaded, changeErr = pcall(function()
				local newInventory = parseInventory(newValue)

				for itemName, newCount in pairs(newInventory) do
					local oldCount = previousInventory[itemName] or 0

					if newCount > oldCount then
						local gained = newCount - oldCount
						print(string.format("[AutoFish] Inventory change: +%d %s (total: %d)", gained, itemName, newCount))

						if isSpecialItem(itemName) then
							local now = tick()
							if not lastWebhookTime[itemName] or (now - lastWebhookTime[itemName]) > 3 then
								lastWebhookTime[itemName] = now
								print("[AutoFish] ⭐ SPECIAL ITEM CAUGHT:", itemName)
								sendWebhook(itemName, newCount)
							end
						end
					end
				end

				pcall(function() checkAndBuyBait() end)
				previousInventory = newInventory
			end)
		end)

		table.insert(allConnections, inventoryConnection)
	end)
end

-- ============================================
-- BOBBLE VELOCITY OVERRIDE (ARC)
-- ============================================
local function setupBobbleVelocityOverride()
	pcall(function()
		local effects = workspace:FindFirstChild("Effects")
		if not effects then
			effects = workspace:WaitForChild("Effects", 10)
		end
		if not effects then return end

		local hookName = string.format("%s's hook", LocalPlayer.Name)

		effects.ChildAdded:Connect(function(child)
			pcall(function()
				if child.Name ~= hookName then return end
				if not spoofEnabled or not forcedWaterPosition then return end

				local char = LocalPlayer.Character
				if not char then return end

				local hrp = char:FindFirstChild("HumanoidRootPart")
				if not hrp then return end

				local spawnPos = hrp.Position + hrp.CFrame.LookVector * 3 + Vector3.new(0, 2, 0)
				local targetPos = forcedWaterPosition

				local horizontalDiff = Vector3.new(targetPos.X - spawnPos.X, 0, targetPos.Z - spawnPos.Z)
				local horizontalDist = horizontalDiff.Magnitude
				local horizontalDir = horizontalDist > 0 and horizontalDiff.Unit or hrp.CFrame.LookVector

				local heightDiff = targetPos.Y - spawnPos.Y
				local gravity = 196.2
				local launchAngle = math.rad(50)
				local cosAngle = math.cos(launchAngle)
				local tanAngle = math.tan(launchAngle)

				local denominator = 2 * cosAngle * cosAngle * (horizontalDist * tanAngle - heightDiff)
				local speed

				if denominator > 0 then
					speed = math.sqrt((gravity * horizontalDist * horizontalDist) / denominator)
					speed = math.clamp(speed, 50, 200)
				else
					speed = 120
				end

				local horizontalSpeed = speed * math.cos(launchAngle)
				local verticalSpeed = speed * math.sin(launchAngle)
				local velocity = horizontalDir * horizontalSpeed + Vector3.new(0, verticalSpeed, 0)

				task.wait()
				pcall(function()
					if child and child.Parent then
						child.AssemblyLinearVelocity = velocity
						print("[AutoFish] AssemblyLinearVelocity applied")
					end
				end)
			end)
		end)
	end)
end

-- ============================================
-- SELECT BAIT
-- ============================================
local function selectBait()
	local success, result = pcall(function()
		local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
		if not playerGui then return nil end

		local fishingBaitGui = playerGui:FindFirstChild("FishingBaitGui")
		if not fishingBaitGui then return nil end

		local list = fishingBaitGui:FindFirstChild("List")
		if not list then
			local main = fishingBaitGui:FindFirstChild("Main")
			if main then list = main:FindFirstChild("List") end
		end

		if not list then return nil end

		for _, baitName in ipairs(CONFIG.BaitPriority) do
			local baitButton = list:FindFirstChild(baitName)
			if baitButton then
				local btn = baitButton
				if not baitButton:IsA("GuiButton") then
					btn = baitButton:FindFirstChildOfClass("TextButton") or baitButton:FindFirstChildOfClass("ImageButton") or baitButton
				end

				if btn then
					pcall(function()
						if btn.MouseButton1Click then btn.MouseButton1Click:Fire() end
					end)
					pcall(function()
						if btn.Activated then btn.Activated:Fire() end
					end)
					pcall(function()
						if fireclickdetector then fireclickdetector(btn) end
					end)
					pcall(function()
						if firesignal then firesignal(btn.MouseButton1Click) end
					end)

					return baitName
				end
			end
		end

		return nil
	end)
	if success then return result end
	return nil
end

-- ============================================
-- GET WATER POSITION
-- ============================================
local function getWaterPosition()
	local success, result = pcall(function()
		local character = LocalPlayer.Character
		if not character then return nil end

		local hrp = character:FindFirstChild("HumanoidRootPart")
		if not hrp then return nil end

		local lookVector = hrp.CFrame.LookVector
		local waterY = hrp.Position.Y - 5

		pcall(function()
			local waterPart = workspace:FindFirstChild("Water")
				or workspace:FindFirstChild("Ocean")
				or (workspace:FindFirstChild("Env") and workspace.Env:FindFirstChild("Water"))

			if waterPart and waterPart:IsA("BasePart") then
				waterY = waterPart.Position.Y
				print("[AutoFish] getWaterPosition: Found waterPart ->", waterY)
			end

			if workspace:FindFirstChild("Env") and workspace.Env:FindFirstChild("WaterStuff") then
				local waterStuff = workspace.Env.WaterStuff
				for _, child in pairs(waterStuff:GetChildren()) do
					if child:IsA("BasePart") then
						waterY = child.Position.Y
						print("[AutoFish] getWaterPosition: Found WaterStuff child ->", waterY)
						break
					end
				end
			end
		end)

		local targetPos = hrp.Position + (lookVector * CONFIG.CastDistance)
		targetPos = Vector3.new(targetPos.X, waterY, targetPos.Z)

		return targetPos
	end)
	if success then return result end
	return nil
end

-- ============================================
-- GET / EQUIP FISHING TOOL
-- ============================================
local function getFishingTool()
	local success, result = pcall(function()
		local character = LocalPlayer.Character
		if not character then return nil end

		for _, item in pairs(character:GetChildren()) do
			if item:IsA("Tool") then
				print("[AutoFish] getFishingTool: Equipped tool ->", item.Name)
				if item.Name:lower():find("rod") or item.Name:lower():find("fishing") then
					print("[AutoFish] getFishingTool: Match! ->", item.Name)
					return item
				end
			end
		end

		local backpack = LocalPlayer:FindFirstChild("Backpack")
		if backpack then
			for _, item in pairs(backpack:GetChildren()) do
				if item:IsA("Tool") then
					print("[AutoFish] getFishingTool: Backpack tool ->", item.Name)
					if item.Name:lower():find("rod") or item.Name:lower():find("fishing") then
						print("[AutoFish] getFishingTool: Match in backpack! ->", item.Name)
						return item
					end
				end
			end
		end

		return nil
	end)
	if success then return result end
	return nil
end

local function equipFishingRod()
	pcall(function()
		local tool = getFishingTool()
		if not tool then
			print("[AutoFish] equipFishingRod: No tool to equip")
			return
		end

		if tool.Parent == LocalPlayer.Backpack then
			print("[AutoFish] equipFishingRod: Tool in backpack, equipping...")
			local humanoid = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid")
			if humanoid then
				humanoid:EquipTool(tool)
				task.wait(0.5)
				print("[AutoFish] equipFishingRod: Tool equipped!")
			else
				print("[AutoFish] equipFishingRod: No humanoid found!")
			end
		end
	end)
	return getFishingTool()
end

-- ============================================
-- CAST LINE
-- ============================================
local function castLine()
	local castLoaded, castResult = pcall(function()
		local waterPos = getWaterPosition()
		if not waterPos then
			print("[AutoFish] castLine: Could not get water position")
			return false
		end

		pcall(function()
			_G.MouseCF = CFrame.new(waterPos)
		end)

		local success, result = pcall(function()
			return FishingRemote:InvokeServer({
				Action = "Throw",
				Goal = waterPos,
				Bait = CONFIG.BaitName
			})
		end)
		print("[AutoFish] castLine: InvokeServer result:", success, result)
		return success and result
	end)
	print("[AutoFish] castLine finished:", castLoaded, castResult or "failed")
	return castLoaded and castResult
end

-- ============================================
-- AUTO MINIGAME
-- ============================================
local function autoMinigame()
	local success, result = pcall(function()
		local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
		if not playerGui then return nil end

		local fishingUI = playerGui:FindFirstChild("FishingUIBill")
		if not fishingUI then return nil end

		local frame = fishingUI:FindFirstChild("Frame")
		if not frame then return nil end

		local playerBar = frame:FindFirstChild("Player")
		local goalBar = frame:FindFirstChild("Goal")

		if not playerBar or not goalBar then return nil end

		local playerY = playerBar.Position.Y.Scale
		local goalY = goalBar.Position.Y.Scale

		return playerY > goalY
	end)
	if success then return result end
	return nil
end

-- ============================================
-- MONITOR BOBBLE
-- ============================================
local function monitorBobble()
	local success, result = pcall(function()
		local effects = workspace:FindFirstChild("Effects")
		if not effects then return nil end

		local hookName = string.format("%s's hook", LocalPlayer.Name)
		local hook = effects:FindFirstChild(hookName)
		
		-- Validate that the hook exists and has necessary parts
		if hook and hook:IsA("Model") and hook.PrimaryPart then
			return hook
		end
		
		return nil
	end)
	-- Don't spam console with bobble checks
	if success then return result end
	return nil
end

-- Wait for bobble with timeout
local function waitForBobble(timeout)
	local startTime = tick()
	timeout = timeout or 5
	
	while tick() - startTime < timeout do
		local bobble = monitorBobble()
		if bobble then
			safePrint("Bobble spawned:", bobble.Name)
			return bobble
		end
		task.wait(0.1)
	end
	
	return nil
end

-- ============================================
-- HIDE IDENTITY
-- ============================================
local function hideIdentity()
	pcall(function()
		local Player = game:GetService("Players").LocalPlayer
		local PlayerGui = Player:WaitForChild("PlayerGui")

		local HealthBarGui = PlayerGui:FindFirstChild("HealthBars")
		local healthbill = HealthBarGui:FindFirstChild(Player.Name)
		local PlayerList = PlayerGui:FindFirstChild("Playerlist")
		local displaygui = PlayerGui:FindFirstChild("Display")

		for _, v in pairs(PlayerList:GetDescendants()) do
			if v.Name == Player.Name then
				v:Destroy()
			end
		end

		for _, v in pairs(displaygui:GetDescendants()) do
			if v.Name == "Region" or v.Name == "Verson" or v.Name == "ServerAge" then
				v:Destroy()
			end
		end

		healthbill.NameT.Text = "Sulfur"

		-- Rainbow gradient animation
		local gradient = healthbill.NameT:FindFirstChild("UIGradient")
		if not gradient then
			gradient = Instance.new("UIGradient")
			gradient.Name = "LegendaryGradient"
			gradient.Parent = healthbill.NameT
		end

		RunService.RenderStepped:Connect(function()
			if not healthbill.NameT or not healthbill.NameT.Parent then return end

			local timeVal = os.clock() % 1
			local keypoints = table.create(8)

			for i = 1, 8 do
				local position = (i - 1) / 7
				local hue = timeVal - position
				if hue < 0 then hue = hue + 1 end
				keypoints[i] = ColorSequenceKeypoint.new(position, Color3.fromHSV(hue, 1, 1))
			end

			gradient.Color = ColorSequence.new(keypoints)
		end)
	end)
end

-- ============================================
-- ANTI-AFK
-- ============================================
local function setupAntiAFK()
	pcall(function()
		if getconnections then
			for _, connection in pairs(getconnections(LocalPlayer.Idled)) do
				if connection.Disable then
					connection:Disable()
				elseif connection.Disconnect then
					connection:Disconnect()
				end
			end
		end
	end)
end

-- ============================================
-- KILLAURA SYSTEM
-- ============================================

-- Load InputCallbacks module (like the game does)
local InputCallbacks = nil
pcall(function()
	local backpack = LocalPlayer:WaitForChild("Backpack", 10)
	if backpack then
		local inputModule = backpack:FindFirstChild("InputCallbacks")
		if inputModule then
			InputCallbacks = require(inputModule)
			debugPrint("✓ InputCallbacks module loaded successfully")
		else
			debugPrint("❌ InputCallbacks module not found in Backpack")
		end
	end
end)

local function getNearestNPC(maxDistance)
	local success, result = pcall(function()
		local char = LocalPlayer.Character
		if not char then return nil end
		
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not hrp then return nil end
		
		local npcsFolder = workspace:FindFirstChild("NPCs")
		if not npcsFolder then
			if tick() % 5 < 0.1 then debugPrint("⚠️ workspace.NPCs not found!") end
			return nil 
		end
		
		local children = npcsFolder:GetChildren()
		if #children == 0 and (tick() % 5 < 0.1) then
			debugPrint("⚠️ workspace.NPCs is empty!")
			return nil
		end

		-- Debug: Print structure of first item to verify assumptions
		if killauraDebug and tick() % 10 < 0.1 then
			local first = children[1]
			debugPrint("🔍 NPC Debug - First Item:", first.Name, "| Class:", first.ClassName, "| HasHum:", first:FindFirstChild("Humanoid") ~= nil)
		end
		
		local closestNPC = nil
		local closestDistance = maxDistance or killauraRange
		
		for _, npc in pairs(children) do
			if npc:IsA("Model") and npc:FindFirstChild("Humanoid") and npc:FindFirstChild("HumanoidRootPart") then
				local npcHum = npc.Humanoid
				local npcHRP = npc.HumanoidRootPart
				
				if npcHum.Health > 0 then
					local distance = (hrp.Position - npcHRP.Position).Magnitude
					if distance < closestDistance then
						closestDistance = distance
						closestNPC = npc
					end
				end
			end
		end
		
		return closestNPC, closestDistance
	end)
	
	if success then return result end
	return nil
end

local function attackNPC(npc)
	debugPrint("━━━ attackNPC START ━━━")
	
	-- Verify InputCallbacks is loaded
	if not InputCallbacks then
		debugPrint("❌ InputCallbacks module not loaded")
		return
	end
	
	if not InputCallbacks.Callbacks or not InputCallbacks.Callbacks.Attack then
		debugPrint("❌ InputCallbacks.Callbacks.Attack not available")
		return
	end
	
	local char = LocalPlayer.Character
	if not char then 
		debugPrint("❌ No character")
		return 
	end
	
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then 
		debugPrint("❌ No HumanoidRootPart")
		return 
	end
	
	local tool = char:FindFirstChildOfClass("Tool")
	if not tool then
		debugPrint("❌ No tool equipped")
		return
	end
	
	-- Check if it's a valid melee tool (like the game does)
	if not InputCallbacks.Utils or not InputCallbacks.Utils.holdingValidMelee then
		debugPrint("❌ InputCallbacks.Utils.holdingValidMelee not available")
		return
	end
	
	if not InputCallbacks.Utils.holdingValidMelee() then
		debugPrint("❌ Not holding valid melee weapon")
		return
	end
	
	local npcHRP = npc:FindFirstChild("HumanoidRootPart")
	local npcHum = npc:FindFirstChild("Humanoid")
	if not npcHRP or not npcHum or npcHum.Health <= 0 then
		debugPrint("❌ NPC invalid")
		return
	end

	-- Face NPC (aim at target)
	local lookAt = Vector3.new(npcHRP.Position.X, hrp.Position.Y, npcHRP.Position.Z)
	hrp.CFrame = CFrame.new(hrp.Position, lookAt)
	debugPrint("✓ Facing NPC:", npc.Name)
	
	-- CRITICAL: Call PC_Activate EXACTLY like the game does in MeleeScript.client.lua line 70
	-- This is the proper way to trigger an attack - not manually sending packets!
	pcall(function()
		debugPrint("⚡ Calling InputCallbacks.Callbacks.Attack:PC_Activate()...")
		InputCallbacks.Callbacks.Attack:PC_Activate()
		debugPrint("✓ PC_Activate called successfully")
	end)
	
	debugPrint("━━━ attackNPC END ━━━")
end

local function startKillaura()
	if killauraConnection then return end
	
	debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	debugPrint("✓ Killaura STARTED")
	debugPrint("Range:", killauraRange, "studs")
	debugPrint("Delay:", killauraDelay, "seconds")
	debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	
	-- Monitor for manual tool equips to pause killaura
	local char = LocalPlayer.Character
	if char then
		char.ChildAdded:Connect(function(child)
			if child:IsA("Tool") and child ~= lastEquippedTool then
				debugPrint("⏸ Pausing killaura - player equipping tool:", child.Name)
				killauraPaused = true
				lastToolChange = tick()
				lastEquippedTool = child
				-- Reset _G flags to default
				_G.canuse = nil
				_G.canM1 = nil
				_G.blocking = nil
				_G.HoldingM1 = nil
				task.delay(2, function()
					killauraPaused = false
					debugPrint("▶ Killaura resumed")
				end)
			end
		end)
	end
	
	local loopCount = 0
	killauraConnection = RunService.Heartbeat:Connect(function()
		pcall(function()
			if not killauraEnabled then return end
			
			-- Pause if player is manually equipping tools
			if killauraPaused or (tick() - lastToolChange < 2) then 
				if loopCount % 60 == 0 then
					debugPrint("⏸ Killaura paused for manual tool equip")
				end
				return 
			end
			
			loopCount = loopCount + 1
			local now = tick()
			
			-- Debug delay check
			local timeSinceLastAttack = now - lastKillauraAttack
			if timeSinceLastAttack < killauraDelay then 
				-- Only print every 30 loops to avoid spam
				if loopCount % 30 == 0 then
					debugPrint("⏳ Waiting for delay:", string.format("%.2f", killauraDelay - timeSinceLastAttack), "seconds remaining")
				end
				return 
			end
			
			local char = LocalPlayer.Character
			if not char then 
				debugPrint("❌ No character in Heartbeat")
				return 
			end
			
			local humanoid = char:FindFirstChild("Humanoid")
			if not humanoid or humanoid.Health <= 0 then 
				debugPrint("❌ Character dead or no humanoid")
				return 
			end
			
			-- Get nearest NPC
			local npc, distance = getNearestNPC(killauraRange)
			
			debugPrint("🔍 NPC Search Result:", npc and npc.Name or "nil", "Distance:", distance and math.floor(distance) or "N/A")
			
			if npc then
				targetNPC = npc
				debugPrint("🎯 ATTACKING:", npc.Name, "at", math.floor(distance), "studs")
				debugPrint("━━━━━━ STARTING ATTACK ━━━━━━")
				attackNPC(npc)
				debugPrint("━━━━━━ ATTACK COMPLETE ━━━━━━")
				lastKillauraAttack = now
			else
				if targetNPC then
					debugPrint("⚠ No NPCs in range (lost target)")
				end
				targetNPC = nil
			end
		end)
	end)
end

local function stopKillaura()
	pcall(function()
		if killauraConnection then
			killauraConnection:Disconnect()
			killauraConnection = nil
		end
		targetNPC = nil
		killauraPaused = false
		
		-- Reset _G flags to nil
		_G.canuse = nil
		_G.canM1 = nil
		_G.blocking = nil
		_G.HoldingM1 = nil
		
		debugPrint("✓ Killaura stopped and _G flags cleaned up")
	end)
end

-- ============================================
-- START / STOP AUTO FISHING
-- ============================================
local function startAutoFishing()
	if autoFishConnection then return end

	safePrint("Auto-fishing started")

	autoFishConnection = RunService.Heartbeat:Connect(function()
		local loopLoaded, loopErr = pcall(function()
			if not CONFIG.Enabled then return end

			local character = LocalPlayer.Character
			if not character then return end

			local humanoid = character:FindFirstChild("Humanoid")
			if not humanoid or humanoid.Health <= 0 then return end

			local bobble = monitorBobble()

			if bobble then
				-- Bobble exists, check if we caught something
				local caughtSuccess, caught = pcall(function() return bobble:GetAttribute("Caught") end)

				if caughtSuccess and caught then
					-- Fish caught! Auto-complete minigame
					local shouldClick = autoMinigame()

					local tool = getFishingTool()
					if tool and tool.Parent == character then
						if shouldClick then
							pcall(function() tool:Activate() end)
						else
							pcall(function() tool:Deactivate() end)
						end
					end
				end
				
				-- Reset fishing flag since bobble exists
				isFishing = false
			else
				-- No bobble detected, start casting
				if not isFishing then
					isFishing = true
					print("[AutoFish] ━━━━━━━━━━ Starting Cast ━━━━━━━━━━")

					task.spawn(function()
						local castSeqLoaded, castSeqErr = pcall(function()
							-- Step 1: Check/buy bait
							pcall(function() checkAndBuyBait() end)

							-- Step 2: Equip rod
							local tool = equipFishingRod()
							local char = LocalPlayer.Character

							if not tool or not char then
								print("[AutoFish] ✗ No tool or character")
								isFishing = false
								return
							end

							if tool.Parent ~= char then
								print("[AutoFish] ✗ Tool not equipped")
								isFishing = false
								return
							end

							task.wait(0.3)
							
							-- Step 3: Select bait
							selectedBait = selectBait()
							print("[AutoFish] Bait:", selectedBait or "None")
							task.wait(0.3)

							if not CONFIG.Enabled then
								isFishing = false
								return
							end

							-- Step 4: Get water position
							local waterPos = getWaterPosition()
							if not waterPos then
								print("[AutoFish] ✗ Can't find water position")
								isFishing = false
								return
							end
							print("[AutoFish] Water pos:", waterPos)

							-- Step 5: Set up hook & cast
							forcedWaterPosition = waterPos
							spoofEnabled = true
							_G.MouseCF = CFrame.new(waterPos)

							print("[AutoFish] ⚡ Casting...")
							tool:Activate()

							-- Hold charge while keeping position spoofed
							local chargeStart = tick()
							while tick() - chargeStart < 1.5 do
								_G.MouseCF = CFrame.new(waterPos)
								task.wait()
							end

							-- Release
							tool:Deactivate()
							print("[AutoFish] ✓ Cast released!")

							-- Wait for bobble to spawn
							task.wait(0.5)
							local spawnedBobble = waitForBobble(3)
							
							if spawnedBobble then
								print("[AutoFish] ✓ Bobble detected! Waiting for fish...")
							else
								print("[AutoFish] ⚠ Bobble not detected, retrying...")
							end
							
							spoofEnabled = false
							isFishing = false
							print("[AutoFish] ━━━━━━━━━━ Cast Complete ━━━━━━━━━━")
						end)
						
						if not castSeqLoaded then
							print("[AutoFish] ✗ Cast error:", castSeqErr)
							isFishing = false
						end
					end)
				end
			end
		end)
	end)

	print("[AutoFish] Auto-fishing Heartbeat loop connected!")
end

local function stopAutoFishing()
	pcall(function()
		if autoFishConnection then
			autoFishConnection:Disconnect()
			autoFishConnection = nil
		end

		if minigameConnection then
			minigameConnection:Disconnect()
			minigameConnection = nil
		end

		isFishing = false
		print("[AutoFish] stopAutoFishing: Stopped")
	end)
	print("[AutoFish] stopAutoFishing finished:", stopLoaded, stopErr or "OK")
end

-- ============================================
-- MINIGAME HOOK (auto-solve)
-- ============================================
local function setupMinigameHook()
	pcall(function()
		local CONFIG_MINIGAME = {
			Enabled = true,
			RotationDelay = 2
		}

		local activeConnection = nil

		local function findGameClientTable()
			for _, v in pairs(getgc(true)) do
				if type(v) == "table" then
					local success, isMatch = pcall(function()
						return rawget(v, "BarPosition") ~= nil
							and rawget(v, "Bobble") ~= nil
							and rawget(v, "Velocity") ~= nil
					end)

					if success and isMatch then
						print("[AutoFish] findGameClientTable: Found client table!")
						return v
					end
				end
			end
			print("[AutoFish] findGameClientTable: Not found in GC")
			return nil
		end

		local function onMinigameDetected(uiObject)
			if not CONFIG_MINIGAME.Enabled then
				print("[AutoFish] onMinigameDetected: Minigame hook disabled in config")
				return
			end

			print("[AutoFish] onMinigameDetected: Minigame UI found — engaging lock!")
			blockRotation = true

			local clientTable = nil
			local frame = nil
			local goalBar = nil

			if activeConnection then activeConnection:Disconnect() end

			activeConnection = RunService.RenderStepped:Connect(function()
				local rsLoaded, rsErr = pcall(function()
					if not uiObject or not uiObject.Parent then
						if activeConnection then activeConnection:Disconnect() end
						print("[AutoFish] onMinigameDetected: UI removed, disconnecting")

						task.delay(CONFIG_MINIGAME.RotationDelay, function()
							blockRotation = false
							print("[AutoFish] onMinigameDetected: Rotation unblocked after delay")
						end)
						return
					end

					if not frame then frame = uiObject:FindFirstChild("Frame") end
					if frame and not goalBar then goalBar = frame:FindFirstChild("Goal") end

					if not clientTable then
						clientTable = findGameClientTable()
						return
					end

					if clientTable and goalBar then
						local fishY = goalBar.Position.Y.Scale
						local maxVal = clientTable.Max or 2

						clientTable.Velocity = 0
						clientTable.BarPosition = fishY * maxVal
					end
				end)
				-- Uncomment for per-frame minigame logging (very spammy):
				-- print("[AutoFish] Minigame RenderStepped:", rsLoaded, rsErr or "OK")
			end)
		end

		local success, playerGui = pcall(function()
			return LocalPlayer:WaitForChild("PlayerGui", 10)
		end)
		print("[AutoFish] setupMinigameHook: PlayerGui found:", success)

		if success and playerGui then
			playerGui.ChildAdded:Connect(function(child)
				if child.Name == "FishingUIBill" then
					print("[AutoFish] setupMinigameHook: FishingUIBill added!")
					onMinigameDetected(child)
				end
			end)

			local existingUI = playerGui:FindFirstChild("FishingUIBill")
			if existingUI then
				print("[AutoFish] setupMinigameHook: FishingUIBill already exists")
				onMinigameDetected(existingUI)
			end
		end
	end)
end

-- ============================================
-- LINORIA UI SETUP
-- ============================================
local function setupUI()
	local uiLoaded, uiErr = pcall(function()
		if not Library then
			print("[AutoFish] setupUI: LinoriaLib not loaded!")
			return
		end

		-- ─── Window ───
		local Window = Library:CreateWindow({
			Title = "Sulfur",
			Center = true,
			AutoShow = true,
			TabPadding = 8,
			MenuFadeTime = 0.2
		})
		print("[AutoFish] setupUI: Window created")

		-- ─── Tabs ───
		local Tabs = {
			Main = Window:AddTab("Main"),
			Misc = Window:AddTab("Misc"),
			["UI Settings"] = Window:AddTab("UI Settings"),
		}
		print("[AutoFish] setupUI: Tabs created")

		-- ═══════════════════════════════════════════
		-- TAB: Main — Left: "Fishing"
		-- ═══════════════════════════════════════════
		local MainLeft = Tabs.Main:AddLeftGroupbox("Fishing")

		-- Toggle: Enable AutoFish
		MainLeft:AddToggle("EnableFishing", {
			Text = "Enable Auto Fishing",
			Default = false,
			Tooltip = "Starts and stops the auto-fishing loop",
		})
		Toggles.EnableFishing:OnChanged(function()
			local val = Toggles.EnableFishing.Value
			print("[AutoFish] UI: EnableFishing toggled ->", val)
			CONFIG.Enabled = val
			if val then
				startAutoFishing()
			else
				stopAutoFishing()
			end
		end)

		-- Toggle: Auto Buy Bait
		MainLeft:AddToggle("AutoBuyBait", {
			Text = "Auto Buy Bait",
			Default = CONFIG.AutoBuyBait,
			Tooltip = "Automatically buys bait when running low",
		})
		Toggles.AutoBuyBait:OnChanged(function()
			CONFIG.AutoBuyBait = Toggles.AutoBuyBait.Value
			print("[AutoFish] UI: AutoBuyBait ->", CONFIG.AutoBuyBait)
		end)

		MainLeft:AddDivider()

		-- Slider: Cast Distance
		MainLeft:AddSlider("CastDistance", {
			Text = "Cast Distance",
			Default = CONFIG.CastDistance,
			Min = 5,
			Max = 60,
			Rounding = 1,
			Suffix = " studs",
			Tooltip = "How far the bobble is thrown from you",
		})
		Options.CastDistance:OnChanged(function()
			CONFIG.CastDistance = Options.CastDistance.Value
			print("[AutoFish] UI: CastDistance ->", CONFIG.CastDistance)
		end)

		MainLeft:AddDivider()

		-- Slider: Bait Buy Threshold
		MainLeft:AddSlider("BaitBuyThreshold", {
			Text = "Buy Threshold",
			Default = CONFIG.BaitBuyThreshold,
			Min = 0,
			Max = 100,
			Rounding = 0,
			Suffix = " count",
			Tooltip = "When bait drops to this amount, auto-buy triggers",
		})
		Options.BaitBuyThreshold:OnChanged(function()
			CONFIG.BaitBuyThreshold = Options.BaitBuyThreshold.Value
			print("[AutoFish] UI: BaitBuyThreshold ->", CONFIG.BaitBuyThreshold)
		end)

		-- Slider: Bait Buy Amount
		MainLeft:AddSlider("BaitBuyAmount", {
			Text = "Buy Amount",
			Default = CONFIG.BaitBuyAmount,
			Min = 1,
			Max = 200,
			Rounding = 0,
			Suffix = " bait",
			Tooltip = "How many bait to purchase each time",
		})
		Options.BaitBuyAmount:OnChanged(function()
			CONFIG.BaitBuyAmount = Options.BaitBuyAmount.Value
			print("[AutoFish] UI: BaitBuyAmount ->", CONFIG.BaitBuyAmount)
		end)

		-- Dropdown: Bait Priority
		local baitOptions = { "Legendary Fish Bait", "Rare Fish Bait", "Common Fish Bait" }
		MainLeft:AddDropdown("BaitPriority", {
			Text = "Bait Priority (First Pick)",
			Values = baitOptions,
			Default = 3,
			Multi = false,
			Tooltip = "Which bait the script tries to select first",
		})
		Options.BaitPriority:OnChanged(function()
			local val = Options.BaitPriority.Value
			print("[AutoFish] UI: BaitPriority ->", val)
			local newPriority = { val }
			for _, b in ipairs(baitOptions) do
				if b ~= val then
					table.insert(newPriority, b)
				end
			end
			CONFIG.BaitPriority = newPriority
			print("[AutoFish] UI: New BaitPriority order ->", table.concat(CONFIG.BaitPriority, ", "))
		end)

		MainLeft:AddDivider()

		-- Toggle: Webhook Enabled
		MainLeft:AddToggle("WebhookEnabled", {
			Text = "Enable Webhook",
			Default = false,
			Tooltip = "Sends a Discord notification when a special item is caught",
		})
		Toggles.WebhookEnabled:OnChanged(function()
			CONFIG.WebhookEnabled = Toggles.WebhookEnabled.Value
			print("[AutoFish] UI: WebhookEnabled ->", CONFIG.WebhookEnabled)
		end)

		-- Input: Webhook URL
		MainLeft:AddInput("WebhookURL", {
			Text = "Webhook URL",
			Default = CONFIG.WebhookURL,
			Placeholder = "https://discord.com/api/webhooks/...",
			Finished = true,
			Tooltip = "Paste your Discord webhook URL here",

			Callback = function(Value)
				CONFIG.WebhookURL = Value
				print("[AutoFish] UI: WebhookURL ->", Value)
			end
		})

		MainLeft:AddLabel("Special items: " .. table.concat(CONFIG.SpecialItems, ", "), true)

		MainLeft:AddDivider()

		MainLeft:AddButton({
			Text = "Manual Cast",
			Func = function()
				print("[AutoFish] UI: Manual cast triggered")
				local waterPos = getWaterPosition()
				if waterPos then
					local tool = equipFishingRod()
					if tool then
						forcedWaterPosition = waterPos
						spoofEnabled = true
						rawset(_G, "MouseCF", CFrame.new(waterPos))
						tool:Activate()

						local chargeStart = tick()
						task.spawn(function()
							while tick() - chargeStart < 1.6 do
								rawset(_G, "MouseCF", CFrame.new(waterPos))
								task.wait()
							end
							tool:Deactivate()
							spoofEnabled = false
							print("[AutoFish] UI: Manual cast complete")
						end)
					else
						print("[AutoFish] UI: Manual cast — no rod equipped!")
					end
				else
					print("[AutoFish] UI: Manual cast — no water position!")
				end
			end,
			Tooltip = "Fires a single cast right now",
		})

		MainLeft:AddButton({
			Text = "Force Buy Bait",
			Func = function()
				print("[AutoFish] UI: Force buy bait triggered")
				buyBait("Common Fish Bait", CONFIG.BaitBuyAmount)
			end,
			Tooltip = "Forces a bait purchase immediately",
		})

		MainLeft:AddButton({
			Text = "Test Webhook",
			Func = function()
				print("[AutoFish] UI: Testing webhook...")
				local oldState = CONFIG.WebhookEnabled
				CONFIG.WebhookEnabled = true
				sendWebhook("TEST_ITEM", 1)
				CONFIG.WebhookEnabled = oldState
			end,
			Tooltip = "Sends a test webhook notification to verify your URL",
		})

		MainLeft:AddDivider()
		MainLeft:AddLabel("Anti-AFK is always active", true)

		-- ═══════════════════════════════════════════
		-- TAB: Main — Right: "Killaura"
		-- ═══════════════════════════════════════════
		local MainRight = Tabs.Main:AddRightGroupbox("Killaura")

		-- Toggle: Enable Killaura
		MainRight:AddToggle("EnableKillaura", {
			Text = "Enable Killaura",
			Default = false,
			Tooltip = "Automatically attacks nearby NPCs",
		})
		Toggles.EnableKillaura:OnChanged(function()
			killauraEnabled = Toggles.EnableKillaura.Value
			print("[AutoFish] UI: Killaura toggled ->", killauraEnabled)
			if killauraEnabled then
				startKillaura()
			else
				stopKillaura()
			end
		end)

		MainRight:AddDivider()

		-- Slider: Killaura Range
		MainRight:AddSlider("KillauraRange", {
			Text = "Attack Range",
			Default = killauraRange,
			Min = 5,
			Max = 50,
			Rounding = 1,
			Suffix = " studs",
			Tooltip = "Maximum distance to attack NPCs",
		})
		Options.KillauraRange:OnChanged(function()
			killauraRange = Options.KillauraRange.Value
			print("[AutoFish] UI: KillauraRange ->", killauraRange)
		end)

		-- Slider: Killaura Delay
		MainRight:AddSlider("KillauraDelay", {
			Text = "Attack Delay",
			Default = killauraDelay,
			Min = 0.05,
			Max = 1,
			Rounding = 2,
			Suffix = "s",
			Tooltip = "Time between attacks",
		})
		Options.KillauraDelay:OnChanged(function()
			killauraDelay = Options.KillauraDelay.Value
			print("[AutoFish] UI: KillauraDelay ->", killauraDelay)
		end)

		MainRight:AddDivider()

		-- Label: Current Target
		local targetLabel = MainRight:AddLabel("Target: None", true)
		
		-- Update target label in real-time
		RunService.Heartbeat:Connect(function()
			pcall(function()
				if targetNPC and targetNPC.Parent then
					targetLabel:SetText("Target: " .. targetNPC.Name)
				else
					targetLabel:SetText("Target: None")
				end
			end)
		end)

		-- ═══════════════════════════════════════════
		-- TAB: Misc
		-- ═══════════════════════════════════════════
		local MiscLeft = Tabs.Misc:AddLeftGroupbox("Identity")

		MiscLeft:AddToggle("HideIdentity", {
			Text = "Hide Identity",
			Default = false,
			Tooltip = "Hides your name and sets it to Sulfur with rainbow text",
		})
		Toggles.HideIdentity:OnChanged(function()
			if Toggles.HideIdentity.Value then
				print("[AutoFish] UI: Hiding identity...")
				hideIdentity()
			else
				print("[AutoFish] UI: HideIdentity toggled off (re-login to revert)")
			end
		end)

		-- ═══════════════════════════════════════════
		-- TAB: UI Settings
		-- ═══════════════════════════════════════════
		local MenuGroup = Tabs["UI Settings"]:AddLeftGroupbox("Menu")

		MenuGroup:AddButton("Unload", function()
			print("[AutoFish] UI: Unloading script...")
			stopAutoFishing()
			Library:Unload()
		end)

		MenuGroup:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", {
			Default = "End",
			NoUI = true,
			Text = "Menu keybind",
		})
		Library.ToggleKeybind = Options.MenuKeybind
		print("[AutoFish] setupUI: Menu keybind set to End")

		-- ─── Addons: ThemeManager + SaveManager ───
		ThemeManager:SetLibrary(Library)
		SaveManager:SetLibrary(Library)
		print("[AutoFish] setupUI: ThemeManager & SaveManager bound")

		SaveManager:IgnoreThemeSettings()
		SaveManager:SetIgnoreIndexes({ "MenuKeybind" })

		ThemeManager:SetFolder("AutoFish")
		SaveManager:SetFolder("AutoFish/config")
		print("[AutoFish] setupUI: Folders set to AutoFish/")

		SaveManager:BuildConfigSection(Tabs["UI Settings"])
		ThemeManager:ApplyToTab(Tabs["UI Settings"])
		print("[AutoFish] setupUI: Config & Theme sections built")

		-- Unload handler
		Library:OnUnload(function()
			print("[AutoFish] UI: Library unloaded callback fired")
			stopAutoFishing()
			stopKillaura()
			if spoofConnection then spoofConnection:Disconnect() end
			for _, conn in ipairs(allConnections) do
				pcall(function() conn:Disconnect() end)
			end
			print("[AutoFish] UI: All connections cleaned up")
		end)

		-- Try to load auto-config
		local acLoaded, acErr = pcall(function()
			SaveManager:LoadAutoloadConfig()
		end)
		print("[AutoFish] setupUI: LoadAutoloadConfig:", acLoaded, acErr or "OK")

		print("[AutoFish] setupUI: UI fully built!")
	end)
	print("[AutoFish] setupUI finished:", uiLoaded, uiErr or "OK")
end

-- ============================================
-- INIT
-- ============================================
pcall(setupAntiAFK)
pcall(setupMinigameHook)
pcall(setupInventoryMonitor)
pcall(setupBobbleVelocityOverride)
pcall(setupUI)

return CONFIG
