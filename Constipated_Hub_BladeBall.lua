--[[
	Constipated Hub | Blade Ball
	UI: Orion
	Logic: velocity / ETA auto-parry (open BladeBallHub patterns) + spam + ball track
]]

repeat task.wait() until game:IsLoaded()

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local VirtualUser = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local GENV = (typeof(getgenv) == "function" and getgenv()) or _G
GENV.__ConstipatedBladeGen = (GENV.__ConstipatedBladeGen or 0) + 1
local GEN = GENV.__ConstipatedBladeGen

local function alive()
	return GENV.__ConstipatedBladeGen == GEN
end

-- Orion
local OrionLib
do
	local urls = {
		"https://raw.githubusercontent.com/jensonhirst/Orion/main/source",
		"https://raw.githubusercontent.com/shlexware/Orion/main/source",
	}
	for _, u in ipairs(urls) do
		local ok, res = pcall(function()
			return loadstring(game:HttpGet(u))()
		end)
		if ok and res then
			OrionLib = res
			break
		end
	end
end
if not OrionLib then
	warn("[Constipated Hub] Orion failed")
	return
end

-- Config
local CFG = {
	AutoParry = false,
	AutoSpam = false,
	SpamRange = 18,
	ParryDistance = 14,
	ReactionTime = 0.04,
	Prediction = 0.8,
	MinBallSpeed = 8,
	MaxBallDist = 150,
	PingComp = true,
	ParryMethod = "Remote", -- Remote | Click | Both

	BallESP = true,
	BallTrail = false,

	WalkSpeedOn = false,
	WalkSpeed = 20,
	InfJump = false,
	Noclip = false,
	Fullbright = false,
	AntiAFK = true,
}

local lastParry = 0
local currentBall = nil

-- Character helpers
local function getChar()
	return LocalPlayer.Character
end

local function getHRP()
	local c = getChar()
	return c and (c:FindFirstChild("HumanoidRootPart") or c:FindFirstChild("UpperTorso"))
end

local function getHum()
	local c = getChar()
	return c and c:FindFirstChildOfClass("Humanoid")
end

-- Ball resolve
local function resolveBallFolder()
	return Workspace:FindFirstChild("Balls") or Workspace:FindFirstChild("TrainingBalls")
end

local function findRealBall(folder)
	if not folder then
		return nil
	end
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("BasePart") and child:GetAttribute("realBall") == true then
			return child
		end
	end
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("BasePart") then
			local vel = child.AssemblyLinearVelocity.Magnitude
			if child:GetAttribute("target") ~= nil or vel > 5 then
				return child
			end
		end
	end
	return nil
end

local function getBallVelocity(ball)
	if not ball then
		return Vector3.zero
	end
	local zoomies = ball:FindFirstChild("zoomies")
	if zoomies then
		if zoomies:IsA("BodyVelocity") then
			return zoomies.Velocity
		end
		if zoomies:IsA("LinearVelocity") then
			return zoomies.VectorVelocity
		end
	end
	return ball.AssemblyLinearVelocity
end

local function refreshBall()
	local folder = resolveBallFolder()
	currentBall = findRealBall(folder)
	return currentBall
end

-- ETA prediction
local function predictImpact(ballPos, ballVel, playerPos)
	local relative = ballPos - playerPos
	local speed = ballVel.Magnitude
	if speed < 0.01 then
		return relative.Magnitude, false, math.huge
	end
	local approaching = relative:Dot(ballVel) < 0
	local eta = relative.Magnitude / speed
	if approaching then
		local closing = -relative.Unit:Dot(ballVel)
		if closing > 0.5 then
			eta = relative.Magnitude / closing
		end
	end
	return relative.Magnitude, approaching, eta
end

local function estimatedPing()
	if not CFG.PingComp then
		return 0
	end
	local ok, ping = pcall(function()
		return game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue()
	end)
	if ok and type(ping) == "number" then
		return math.clamp(ping / 1000, 0, 0.25)
	end
	return 0.05
end

-- Fire parry
local function fireParry()
	local now = os.clock()
	local cd = CFG.ReactionTime + 0.06
	if now - lastParry < cd then
		return false
	end
	lastParry = now

	local success = false

	if CFG.ParryMethod == "Remote" or CFG.ParryMethod == "Both" then
		pcall(function()
			local remotes = ReplicatedStorage:FindFirstChild("Remotes")
			if remotes then
				local parry = remotes:FindFirstChild("ParryButtonPress")
					or remotes:FindFirstChild("ParryAttempt")
					or remotes:FindFirstChild("Parry")
				if parry and parry:IsA("RemoteEvent") then
					parry:FireServer()
					success = true
				end
			end
			-- deep search fallback
			if not success then
				for _, r in ipairs(ReplicatedStorage:GetDescendants()) do
					if r:IsA("RemoteEvent") and r.Name:lower():find("parry") then
						r:FireServer()
						success = true
						break
					end
				end
			end
		end)
	end

	if (not success and CFG.ParryMethod == "Remote") or CFG.ParryMethod == "Click" or CFG.ParryMethod == "Both" then
		pcall(function()
			VirtualInputManager:SendMouseButtonEvent(0, 0, 0, true, game, 0)
			task.wait(0.015)
			VirtualInputManager:SendMouseButtonEvent(0, 0, 0, false, game, 0)
			success = true
		end)
		-- also try key F / E common binds
		pcall(function()
			if keypress then
				keypress(0x46) -- F
				task.wait(0.02)
				keyrelease(0x46)
			end
		end)
	end

	return success
end

-- Auto parry step
local function autoParryStep()
	if not CFG.AutoParry then
		return
	end
	local root = getHRP()
	if not root then
		return
	end
	if not currentBall or not currentBall.Parent then
		refreshBall()
	end
	local ball = currentBall
	if not ball then
		return
	end

	local vel = getBallVelocity(ball)
	local speed = vel.Magnitude
	if speed < CFG.MinBallSpeed then
		return
	end

	local dist, approaching, eta = predictImpact(ball.Position, vel, root.Position)
	if dist > CFG.MaxBallDist then
		return
	end
	if not approaching and dist > CFG.ParryDistance * 0.55 then
		return
	end

	local ping = estimatedPing()
	local threshold = CFG.ReactionTime + ping + (CFG.ParryDistance / math.max(speed, 1)) * CFG.Prediction

	-- spam mode when very close
	if CFG.AutoSpam and dist <= CFG.SpamRange then
		fireParry()
		return
	end

	if eta <= threshold or dist <= CFG.ParryDistance then
		fireParry()
	end
end

-- Ball ESP
local ballHighlight
local ballBillboard
local function updateBallESP()
	if not CFG.BallESP then
		if ballHighlight then
			ballHighlight:Destroy()
			ballHighlight = nil
		end
		if ballBillboard then
			ballBillboard:Destroy()
			ballBillboard = nil
		end
		return
	end
	local ball = currentBall
	if not ball then
		return
	end
	if not ballHighlight or ballHighlight.Adornee ~= ball then
		if ballHighlight then
			ballHighlight:Destroy()
		end
		local parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
		ballHighlight = Instance.new("Highlight")
		ballHighlight.Adornee = ball
		ballHighlight.FillColor = Color3.fromRGB(255, 80, 80)
		ballHighlight.OutlineColor = Color3.fromRGB(255, 200, 60)
		ballHighlight.FillTransparency = 0.35
		ballHighlight.OutlineTransparency = 0
		ballHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		ballHighlight.Parent = parent
	end
	if not ballBillboard or ballBillboard.Adornee ~= ball then
		if ballBillboard then
			ballBillboard:Destroy()
		end
		local parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
		ballBillboard = Instance.new("BillboardGui")
		ballBillboard.Adornee = ball
		ballBillboard.Size = UDim2.fromOffset(100, 24)
		ballBillboard.StudsOffset = Vector3.new(0, 2.5, 0)
		ballBillboard.AlwaysOnTop = true
		ballBillboard.Parent = parent
		local tl = Instance.new("TextLabel")
		tl.Name = "T"
		tl.BackgroundTransparency = 1
		tl.Size = UDim2.fromScale(1, 1)
		tl.Font = Enum.Font.GothamBold
		tl.TextSize = 14
		tl.TextColor3 = Color3.fromRGB(255, 220, 80)
		tl.TextStrokeTransparency = 0.3
		tl.Text = "BALL"
		tl.Parent = ballBillboard
	end
	local vel = getBallVelocity(ball)
	local label = ballBillboard:FindFirstChild("T")
	if label then
		label.Text = string.format("BALL %.0f", vel.Magnitude)
	end
end

-- Movement
RunService.Stepped:Connect(function()
	if not alive() or not CFG.Noclip then
		return
	end
	local c = getChar()
	if c then
		for _, p in ipairs(c:GetDescendants()) do
			if p:IsA("BasePart") then
				p.CanCollide = false
			end
		end
	end
end)

RunService.Heartbeat:Connect(function()
	if not alive() then
		return
	end
	local hum = getHum()
	if hum and CFG.WalkSpeedOn then
		hum.WalkSpeed = CFG.WalkSpeed
	end
end)

UserInputService.JumpRequest:Connect(function()
	if CFG.InfJump and alive() then
		local hum = getHum()
		if hum then
			hum:ChangeState(Enum.HumanoidStateType.Jumping)
		end
	end
end)

LocalPlayer.Idled:Connect(function()
	if CFG.AntiAFK then
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
	end
end)

-- Main loops
task.spawn(function()
	while alive() do
		refreshBall()
		pcall(autoParryStep)
		pcall(updateBallESP)
		task.wait()
	end
end)

Workspace.ChildAdded:Connect(function(child)
	if child.Name == "Balls" or child.Name == "TrainingBalls" then
		task.wait(0.1)
		refreshBall()
	end
end)

-- UI
local Window = OrionLib:MakeWindow({
	Name = "Constipated Hub | Blade Ball",
	HidePremium = true,
	SaveConfig = false,
	IntroEnabled = false,
})

local TabParry = Window:MakeTab({ Name = "Parry", Icon = "rbxassetid://4483362748", PremiumOnly = false })
local TabVis = Window:MakeTab({ Name = "Visuals", Icon = "rbxassetid://4483345998", PremiumOnly = false })
local TabPlayer = Window:MakeTab({ Name = "Player", Icon = "rbxassetid://4483342657", PremiumOnly = false })
local TabMisc = Window:MakeTab({ Name = "Misc", Icon = "rbxassetid://4483362458", PremiumOnly = false })

TabParry:AddToggle({
	Name = "Auto Parry",
	Default = false,
	Callback = function(v)
		CFG.AutoParry = v
		OrionLib:MakeNotification({
			Name = "Constipated Hub",
			Content = v and "Auto Parry ON" or "Auto Parry OFF",
			Time = 2,
		})
	end,
})

TabParry:AddToggle({
	Name = "Auto Spam (close range)",
	Default = false,
	Callback = function(v)
		CFG.AutoSpam = v
	end,
})

TabParry:AddSlider({
	Name = "Parry Distance",
	Min = 6,
	Max = 30,
	Default = 14,
	Increment = 1,
	Callback = function(v)
		CFG.ParryDistance = v
	end,
})

TabParry:AddSlider({
	Name = "Spam Range",
	Min = 8,
	Max = 35,
	Default = 18,
	Increment = 1,
	Callback = function(v)
		CFG.SpamRange = v
	end,
})

TabParry:AddSlider({
	Name = "Prediction Strength",
	Min = 0.3,
	Max = 1.2,
	Default = 0.8,
	Increment = 0.05,
	Callback = function(v)
		CFG.Prediction = v
	end,
})

TabParry:AddSlider({
	Name = "Reaction Time (s)",
	Min = 0,
	Max = 0.2,
	Default = 0.04,
	Increment = 0.01,
	Callback = function(v)
		CFG.ReactionTime = v
	end,
})

TabParry:AddSlider({
	Name = "Min Ball Speed",
	Min = 0,
	Max = 40,
	Default = 8,
	Increment = 1,
	Callback = function(v)
		CFG.MinBallSpeed = v
	end,
})

TabParry:AddToggle({
	Name = "Ping Compensation",
	Default = true,
	Callback = function(v)
		CFG.PingComp = v
	end,
})

TabParry:AddDropdown({
	Name = "Parry Method",
	Default = "Remote",
	Options = { "Remote", "Click", "Both" },
	Callback = function(v)
		CFG.ParryMethod = v
	end,
})

TabParry:AddButton({
	Name = "Manual Parry Now",
	Callback = function()
		fireParry()
	end,
})

TabVis:AddToggle({
	Name = "Ball ESP",
	Default = true,
	Callback = function(v)
		CFG.BallESP = v
		if not v then
			if ballHighlight then
				ballHighlight:Destroy()
				ballHighlight = nil
			end
			if ballBillboard then
				ballBillboard:Destroy()
				ballBillboard = nil
			end
		end
	end,
})

TabPlayer:AddToggle({
	Name = "WalkSpeed",
	Default = false,
	Callback = function(v)
		CFG.WalkSpeedOn = v
	end,
})

TabPlayer:AddSlider({
	Name = "WalkSpeed Value",
	Min = 16,
	Max = 40,
	Default = 20,
	Increment = 1,
	Callback = function(v)
		CFG.WalkSpeed = v
	end,
})

TabPlayer:AddToggle({
	Name = "Infinite Jump",
	Default = false,
	Callback = function(v)
		CFG.InfJump = v
	end,
})

TabPlayer:AddToggle({
	Name = "Noclip",
	Default = false,
	Callback = function(v)
		CFG.Noclip = v
	end,
})

TabMisc:AddToggle({
	Name = "Fullbright",
	Default = false,
	Callback = function(v)
		CFG.Fullbright = v
		if v then
			Lighting.Brightness = 2
			Lighting.ClockTime = 14
			Lighting.FogEnd = 1e6
			Lighting.GlobalShadows = false
		else
			Lighting.Brightness = 1
			Lighting.GlobalShadows = true
		end
	end,
})

TabMisc:AddToggle({
	Name = "Anti AFK",
	Default = true,
	Callback = function(v)
		CFG.AntiAFK = v
	end,
})

TabMisc:AddButton({
	Name = "Unload Hub",
	Callback = function()
		GENV.__ConstipatedBladeGen = GEN + 1
		if ballHighlight then
			ballHighlight:Destroy()
		end
		if ballBillboard then
			ballBillboard:Destroy()
		end
		pcall(function()
			OrionLib:Destroy()
		end)
	end,
})

TabMisc:AddParagraph(
	"Info",
	"Constipated Hub | Blade Ball\nVelocity ETA auto-parry\nRemote + click fallback · Ball ESP"
)

OrionLib:MakeNotification({
	Name = "Constipated Hub",
	Content = "Blade Ball loaded — enable Auto Parry",
	Time = 4,
})

print("[Constipated Hub] Blade Ball ready")
