--[[
    ============================================================================
    JJS TARGET LOCK-ON + LIVE SERVER ROSTER (v7 FINAL)
    ============================================================================
    Features:
      1. LIVE SERVER ROSTER & PLAYER PICKER:
         - Clean collapsible UI panel on the screen.
         - Shows all players in the server with avatar thumbnails, names & distance.
         - Also detects workspace NPCs & Training Dummies.
         - Click ANY player/NPC in the list to INSTANTLY lock onto them!
      2. CAMERA LOCK-ON (REAL & ROCK SOLID):
         - Camera actually locks on and orbits smoothly over your shoulder.
         - ZERO 180° FLIPS / ZERO CRAZINESS IN CLOSE MELEE (Tested < 3.5 studs clamp).
      3. CHARACTER AUTO-FACING:
         - Your character automatically faces the enemy when locked.
      4. MULTI-PLATFORM CONTROLS:
         - PC / Studio: Press 'E' to toggle, or click any player in the UI.
         - Console: Press Right Stick (R3).
         - Mobile: On-screen touch lock button + interactive UI roster.

    INSTALLATION:
      Put this LocalScript inside: StarterPlayer -> StarterPlayerScripts
    ============================================================================
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local localPlayer = Players.LocalPlayer
local camera = workspace.CurrentCamera

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------
local CONFIG = {
    -- Camera
    CAMERA_DISTANCE     = 13.0,     -- Distance behind your character
    CAMERA_HEIGHT       = 2.8,      -- Height above your root
    SHOULDER_OFFSET     = 1.8,      -- Over-the-shoulder offset (+ right, - left)
    SMOOTH_SPEED        = 14,       -- Sharp responsive tracking speed
    MIN_STABLE_DISTANCE = 3.5,      -- Clamped angle threshold at close range (fixes the wild spin!)

    -- Auto-Facing
    ENABLE_AUTO_FACE    = true,     -- Turn your character to face the target
    AUTO_FACE_SPEED     = 20,

    -- Visuals
    RETICLE_COLOR       = Color3.fromRGB(255, 60, 60),
    HIGHLIGHT_COLOR     = Color3.fromRGB(255, 70, 70),

    -- Controls
    PC_KEYBIND          = Enum.KeyCode.E,
    GAMEPAD_KEYBIND     = Enum.KeyCode.ButtonR3,
}

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------
local isLocked = false
local currentTargetModel = nil
local currentTargetPlayer = nil
local currentTargetRoot = nil
local currentTargetHum = nil

local currentCamPos = nil
local currentCamLook = nil

local reticleGui = nil
local highlightInstance = nil

-- UI references
local rosterFrame = nil
local rosterList = nil
local lockStatusBtn = nil
local isRosterCollapsed = false

--------------------------------------------------------------------------------
-- CHARACTER UTILITIES
--------------------------------------------------------------------------------
local function getLocalRoot()
    local char = localPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function getLocalHumanoid()
    local char = localPlayer.Character
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function getModelRootAndHum(model)
    if not model or not model:IsA("Model") then return nil, nil end
    local root = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Torso") or model:FindFirstChild("UpperTorso")
    local hum = model:FindFirstChildOfClass("Humanoid")
    return root, hum
end

--------------------------------------------------------------------------------
-- RETICLE & HIGHLIGHT VISUALS
--------------------------------------------------------------------------------
local function removeVisuals()
    if reticleGui then
        reticleGui:Destroy()
        reticleGui = nil
    end
    if highlightInstance then
        highlightInstance:Destroy()
        highlightInstance = nil
    end
end

local function createVisuals(targetModel)
    removeVisuals()
    local root = targetModel:FindFirstChild("HumanoidRootPart") or targetModel:FindFirstChild("Torso")
    if not root then return end

    -- Billboard Reticle over target
    local bb = Instance.new("BillboardGui")
    bb.Name = "JJS_Reticle"
    bb.Adornee = root
    bb.Size = UDim2.new(3.2, 0, 3.2, 0)
    bb.AlwaysOnTop = true
    bb.ResetOnSpawn = false

    local holder = Instance.new("Frame")
    holder.Size = UDim2.new(1, 0, 1, 0)
    holder.BackgroundTransparency = 1
    holder.Parent = bb

    -- Corner brackets
    local function makeBracket(pos, anchor, rot)
        local img = Instance.new("ImageLabel")
        img.Size = UDim2.new(0.4, 0, 0.4, 0)
        img.Position = pos
        img.AnchorPoint = anchor
        img.Rotation = rot
        img.BackgroundTransparency = 1
        img.Image = "rbxassetid://13847525381"
        img.ImageColor3 = CONFIG.RETICLE_COLOR
        img.Parent = holder
    end
    makeBracket(UDim2.new(0, 0, 0, 0), Vector2.new(0, 0), 0)
    makeBracket(UDim2.new(1, 0, 0, 0), Vector2.new(1, 0), 90)
    makeBracket(UDim2.new(1, 0, 1, 0), Vector2.new(1, 1), 180)
    makeBracket(UDim2.new(0, 0, 1, 0), Vector2.new(0, 1), 270)

    -- Center dot
    local dot = Instance.new("Frame")
    dot.Size = UDim2.new(0, 6, 0, 6)
    dot.Position = UDim2.new(0.5, 0, 0.5, 0)
    dot.AnchorPoint = Vector2.new(0.5, 0.5)
    dot.BackgroundColor3 = CONFIG.RETICLE_COLOR
    dot.BorderSizePixel = 0
    dot.Parent = holder
    Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

    -- Pop animation
    holder.Size = UDim2.new(1.8, 0, 1.8, 0)
    holder.Position = UDim2.new(-0.4, 0, -0.4, 0)
    TweenService:Create(holder, TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
        Size = UDim2.new(1, 0, 1, 0),
        Position = UDim2.new(0, 0, 0, 0)
    }):Play()

    bb.Parent = localPlayer:WaitForChild("PlayerGui")
    reticleGui = bb

    -- Subtle Highlight
    local hl = Instance.new("Highlight")
    hl.Name = "JJS_Highlight"
    hl.Adornee = targetModel
    hl.FillColor = CONFIG.HIGHLIGHT_COLOR
    hl.OutlineColor = CONFIG.HIGHLIGHT_COLOR
    hl.FillTransparency = 0.8
    hl.OutlineTransparency = 0.2
    hl.DepthMode = Enum.HighlightDepthMode.Occluded
    hl.Parent = targetModel
    highlightInstance = hl
end

--------------------------------------------------------------------------------
-- LOCK LOGIC
--------------------------------------------------------------------------------
local function updateUIStatus()
    if not lockStatusBtn then return end
    if isLocked and currentTargetModel then
        local targetName = currentTargetPlayer and currentTargetPlayer.DisplayName or currentTargetModel.Name
        lockStatusBtn.Text = "LOCKED: " .. string.upper(targetName) .. " [E to Unlock]"
        lockStatusBtn.BackgroundColor3 = Color3.fromRGB(200, 45, 45)
    else
        lockStatusBtn.Text = "NOT LOCKED [Click player or press E]"
        lockStatusBtn.BackgroundColor3 = Color3.fromRGB(35, 40, 55)
    end
end

local function unlock()
    if not isLocked then return end
    isLocked = false
    currentTargetModel = nil
    currentTargetPlayer = nil
    currentTargetRoot = nil
    currentTargetHum = nil

    removeVisuals()

    camera.CameraType = Enum.CameraType.Custom
    local myHum = getLocalHumanoid()
    if myHum then
        myHum.AutoRotate = true
    end

    updateUIStatus()
end

local function lockOnModel(model, playerObj)
    local root, hum = getModelRootAndHum(model)
    if not root or not hum or hum.Health <= 0 then
        unlock()
        return
    end

    unlock()

    isLocked = true
    currentTargetModel = model
    currentTargetPlayer = playerObj
    currentTargetRoot = root
    currentTargetHum = hum

    createVisuals(model)

    camera.CameraType = Enum.CameraType.Scriptable
    currentCamPos = camera.CFrame.Position
    currentCamLook = root.Position + Vector3.new(0, 1.2, 0)

    hum.Died:Connect(function()
        if currentTargetModel == model then
            unlock()
        end
    end)

    updateUIStatus()
end

local function autoFindNearestTarget()
    local myRoot = getLocalRoot()
    if not myRoot then return nil end
    local myPos = myRoot.Position

    local nearestModel = nil
    local nearestPlayer = nil
    local nearestDist = 80

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and p.Character then
            local r, h = getModelRootAndHum(p.Character)
            if r and h and h.Health > 0 then
                local d = (r.Position - myPos).Magnitude
                if d < nearestDist then
                    nearestDist = d
                    nearestModel = p.Character
                    nearestPlayer = p
                end
            end
        end
    end

    -- If no player, check workspace dummies / NPCs
    if not nearestModel then
        for _, m in ipairs(workspace:GetChildren()) do
            if m:IsA("Model") and m ~= localPlayer.Character and not Players:GetPlayerFromCharacter(m) then
                local r, h = getModelRootAndHum(m)
                if r and h and h.Health > 0 then
                    local d = (r.Position - myPos).Magnitude
                    if d < nearestDist then
                        nearestDist = d
                        nearestModel = m
                        nearestPlayer = nil
                    end
                end
            end
        end
    end

    return nearestModel, nearestPlayer
end

local function toggleLock()
    if isLocked then
        unlock()
    else
        local m, p = autoFindNearestTarget()
        if m then
            lockOnModel(m, p)
        end
    end
end

--------------------------------------------------------------------------------
-- MAIN CAMERA & AUTO-FACE RENDER LOOP
--------------------------------------------------------------------------------
RunService.RenderStepped:Connect(function(dt)
    if not isLocked or not currentTargetModel or not currentTargetRoot or not currentTargetHum then
        return
    end

    local myRoot = getLocalRoot()
    local myHum = getLocalHumanoid()
    if not myRoot or not myHum or myHum.Health <= 0 then
        unlock()
        return
    end

    -- Target health or existence check
    if currentTargetHum.Health <= 0 or not currentTargetModel.Parent then
        -- Respawn tracking for players
        if currentTargetPlayer and currentTargetPlayer.Character and currentTargetPlayer.Character ~= currentTargetModel then
            lockOnModel(currentTargetPlayer.Character, currentTargetPlayer)
            return
        end
        unlock()
        return
    end

    local toEnemy = currentTargetRoot.Position - myRoot.Position

    -- =========================================================================
    -- THE CRUCIAL CLOSE-RANGE FIX:
    -- Rigidly anchor camera behind the PLAYER. Clamp angle when distance < 3.5.
    -- =========================================================================
    local flatToEnemy = Vector3.new(toEnemy.X, 0, toEnemy.Z)
    local lookDir
    if flatToEnemy.Magnitude >= CONFIG.MIN_STABLE_DISTANCE then
        lookDir = flatToEnemy.Unit
    else
        lookDir = myRoot.CFrame.LookVector
    end

    local rightVec = Vector3.new(0, 1, 0):Cross(lookDir).Unit

    -- Camera Position: anchored to YOUR head, offset over shoulder and back
    local playerHead = myRoot.Position + Vector3.new(0, CONFIG.CAMERA_HEIGHT, 0)
    local desiredCamPos = playerHead 
        - (lookDir * CONFIG.CAMERA_DISTANCE) 
        + (rightVec * CONFIG.SHOULDER_OFFSET)

    -- Wall raycast check
    local rayParams = RaycastParams.new()
    rayParams.FilterType = RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = { localPlayer.Character, currentTargetModel, camera }
    local wallHit = workspace:Raycast(playerHead, desiredCamPos - playerHead, rayParams)
    if wallHit then
        desiredCamPos = wallHit.Position + (wallHit.Normal * 0.4)
    end

    -- Camera Focus: Target upper torso/chest
    local targetFocus = currentTargetRoot.Position + Vector3.new(0, 1.2, 0)

    -- Smooth damping
    local alpha = 1 - math.exp(-CONFIG.SMOOTH_SPEED * dt)
    currentCamPos = currentCamPos and currentCamPos:Lerp(desiredCamPos, alpha) or desiredCamPos
    currentCamLook = currentCamLook and currentCamLook:Lerp(targetFocus, alpha) or targetFocus

    camera.CFrame = CFrame.lookAt(currentCamPos, currentCamLook, Vector3.new(0, 1, 0))

    -- Auto-Facing: smoothly rotate character horizontally
    if CONFIG.ENABLE_AUTO_FACE then
        myHum.AutoRotate = false
        local targetYaw = math.atan2(-toEnemy.X, -toEnemy.Z)
        local currentCFrame = myRoot.CFrame
        local targetCFrame = CFrame.new(myRoot.Position) * CFrame.Angles(0, targetYaw + math.pi, 0)
        local faceAlpha = math.clamp(CONFIG.AUTO_FACE_SPEED * dt, 0, 1)
        myRoot.CFrame = currentCFrame:Lerp(targetCFrame, faceAlpha)
    end
end)

--------------------------------------------------------------------------------
-- LIVE SERVER ROSTER UI (PLAYER PICKER)
--------------------------------------------------------------------------------
local function buildServerRosterUI()
    local pg = localPlayer:WaitForChild("PlayerGui")
    if pg:FindFirstChild("JJS_RosterHUD") then
        pg.JJS_RosterHUD:Destroy()
    end

    local sg = Instance.new("ScreenGui")
    sg.Name = "JJS_RosterHUD"
    sg.ResetOnSpawn = false
    sg.DisplayOrder = 15
    sg.Parent = pg

    -- Main Container (Top-Left)
    local main = Instance.new("Frame")
    main.Name = "RosterMain"
    main.Size = UDim2.new(0, 260, 0, 310)
    main.Position = UDim2.new(0, 15, 0, 60)
    main.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
    main.BackgroundTransparency = 0.15
    main.BorderSizePixel = 0
    main.ClipsDescendants = true
    main.Parent = sg
    rosterFrame = main

    Instance.new("UICorner", main).CornerRadius = UDim.new(0, 12)
    local stroke = Instance.new("UIStroke", main)
    stroke.Color = Color3.fromRGB(45, 55, 75)
    stroke.Thickness = 1.2

    -- Title Bar
    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, 36)
    header.BackgroundColor3 = Color3.fromRGB(22, 28, 40)
    header.BorderSizePixel = 0
    header.Parent = main

    local title = Instance.new("TextLabel")
    title.Text = "🎯 JJS LOCK-ON ROSTER"
    title.Font = Enum.Font.GothamBold
    title.TextSize = 12
    title.TextColor3 = Color3.fromRGB(240, 240, 240)
    title.Size = UDim2.new(1, -40, 1, 0)
    title.Position = UDim2.new(0, 12, 0, 0)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.BackgroundTransparency = 1
    title.Parent = header

    -- Minimize Button
    local minBtn = Instance.new("TextButton")
    minBtn.Text = "—"
    minBtn.Font = Enum.Font.GothamBold
    minBtn.TextSize = 14
    minBtn.TextColor3 = Color3.fromRGB(180, 190, 210)
    minBtn.Size = UDim2.new(0, 28, 0, 28)
    minBtn.Position = UDim2.new(1, -32, 0, 4)
    minBtn.BackgroundColor3 = Color3.fromRGB(30, 38, 54)
    minBtn.BorderSizePixel = 0
    minBtn.Parent = header
    Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 6)

    minBtn.Activated:Connect(function()
        isRosterCollapsed = not isRosterCollapsed
        if isRosterCollapsed then
            TweenService:Create(main, TweenInfo.new(0.2), { Size = UDim2.new(0, 260, 0, 36) }):Play()
            minBtn.Text = "+"
        else
            TweenService:Create(main, TweenInfo.new(0.2), { Size = UDim2.new(0, 260, 0, 310) }):Play()
            minBtn.Text = "—"
        end
    end)

    -- Status & Quick Lock Toggle Button
    local statusBtn = Instance.new("TextButton")
    statusBtn.Name = "StatusBtn"
    statusBtn.Size = UDim2.new(1, -16, 0, 32)
    statusBtn.Position = UDim2.new(0, 8, 0, 42)
    statusBtn.BackgroundColor3 = Color3.fromRGB(35, 40, 55)
    statusBtn.Font = Enum.Font.GothamBold
    statusBtn.TextSize = 11
    statusBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    statusBtn.Text = "NOT LOCKED [Click player or press E]"
    statusBtn.BorderSizePixel = 0
    statusBtn.Parent = main
    Instance.new("UICorner", statusBtn).CornerRadius = UDim.new(0, 8)
    lockStatusBtn = statusBtn

    statusBtn.Activated:Connect(function()
        toggleLock()
    end)

    -- Scrollable List
    local scroll = Instance.new("ScrollingFrame")
    scroll.Size = UDim2.new(1, -16, 1, -84)
    scroll.Position = UDim2.new(0, 8, 0, 78)
    scroll.BackgroundTransparency = 1
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 4
    scroll.ScrollBarImageColor3 = Color3.fromRGB(80, 95, 125)
    scroll.Parent = main
    rosterList = scroll

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 5)
    layout.Parent = scroll

    -- Populate List with Server Players & NPCs
    local function refreshRoster()
        for _, child in ipairs(scroll:GetChildren()) do
            if child:IsA("GuiObject") and child ~= layout then
                child:Destroy()
            end
        end

        local myRoot = getLocalRoot()
        local myPos = myRoot and myRoot.Position or Vector3.new()

        -- 1. Server Players
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= localPlayer then
                local char = p.Character
                local root, hum = getModelRootAndHum(char)
                local distText = "Spawned"
                if root then
                    distText = math.floor((root.Position - myPos).Magnitude) .. " studs"
                else
                    distText = "Dead/Respawning"
                end

                local item = Instance.new("TextButton")
                item.Size = UDim2.new(1, -6, 0, 38)
                item.BackgroundColor3 = (currentTargetModel == char) and Color3.fromRGB(50, 75, 120) or Color3.fromRGB(24, 30, 42)
                item.BorderSizePixel = 0
                item.Text = ""
                item.Parent = scroll
                Instance.new("UICorner", item).CornerRadius = UDim.new(0, 6)

                -- Avatar Headshot
                local avatar = Instance.new("ImageLabel")
                avatar.Size = UDim2.new(0, 28, 0, 28)
                avatar.Position = UDim2.new(0, 5, 0.5, -14)
                avatar.BackgroundColor3 = Color3.fromRGB(35, 42, 60)
                avatar.Image = "rbxthumb://type=AvatarHeadShot&id=" .. p.UserId .. "&w=100&h=100"
                avatar.Parent = item
                Instance.new("UICorner", avatar).CornerRadius = UDim.new(1, 0)

                -- Name Label
                local nameLbl = Instance.new("TextLabel")
                nameLbl.Text = p.DisplayName
                nameLbl.Font = Enum.Font.GothamBold
                nameLbl.TextSize = 11
                nameLbl.TextColor3 = Color3.fromRGB(240, 240, 240)
                nameLbl.Position = UDim2.new(0, 40, 0, 4)
                nameLbl.Size = UDim2.new(1, -110, 0, 14)
                nameLbl.TextXAlignment = Enum.TextXAlignment.Left
                nameLbl.BackgroundTransparency = 1
                nameLbl.Parent = item

                -- Username / Distance
                local subLbl = Instance.new("TextLabel")
                subLbl.Text = "@" .. p.Name .. " • " .. distText
                subLbl.Font = Enum.Font.Gotham
                subLbl.TextSize = 9
                subLbl.TextColor3 = Color3.fromRGB(150, 165, 190)
                subLbl.Position = UDim2.new(0, 40, 0, 19)
                subLbl.Size = UDim2.new(1, -45, 0, 14)
                subLbl.TextXAlignment = Enum.TextXAlignment.Left
                subLbl.BackgroundTransparency = 1
                subLbl.Parent = item

                -- Click to Lock!
                item.Activated:Connect(function()
                    if p.Character then
                        lockOnModel(p.Character, p)
                        refreshRoster()
                    end
                end)
            end
        end

        -- 2. Workspace NPCs / Dummies (Crucial for Studio Solo Testing!)
        for _, m in ipairs(workspace:GetChildren()) do
            if m:IsA("Model") and m ~= localPlayer.Character and not Players:GetPlayerFromCharacter(m) then
                local root, hum = getModelRootAndHum(m)
                if root and hum and hum.Health > 0 then
                    local dist = math.floor((root.Position - myPos).Magnitude)
                    local item = Instance.new("TextButton")
                    item.Size = UDim2.new(1, -6, 0, 36)
                    item.BackgroundColor3 = (currentTargetModel == m) and Color3.fromRGB(100, 40, 40) or Color3.fromRGB(32, 24, 28)
                    item.BorderSizePixel = 0
                    item.Text = ""
                    item.Parent = scroll
                    Instance.new("UICorner", item).CornerRadius = UDim.new(0, 6)

                    local npcName = Instance.new("TextLabel")
                    npcName.Text = "🤖 NPC: " .. m.Name
                    npcName.Font = Enum.Font.GothamBold
                    npcName.TextSize = 11
                    npcName.TextColor3 = Color3.fromRGB(255, 180, 180)
                    npcName.Position = UDim2.new(0, 10, 0, 3)
                    npcName.Size = UDim2.new(1, -20, 0, 14)
                    npcName.TextXAlignment = Enum.TextXAlignment.Left
                    npcName.BackgroundTransparency = 1
                    npcName.Parent = item

                    local npcDist = Instance.new("TextLabel")
                    npcDist.Text = dist .. " studs • Health: " .. math.floor(hum.Health)
                    npcDist.Font = Enum.Font.Gotham
                    npcDist.TextSize = 9
                    npcDist.TextColor3 = Color3.fromRGB(180, 150, 150)
                    npcDist.Position = UDim2.new(0, 10, 0, 18)
                    npcDist.Size = UDim2.new(1, -20, 0, 14)
                    npcDist.TextXAlignment = Enum.TextXAlignment.Left
                    npcDist.BackgroundTransparency = 1
                    npcDist.Parent = item

                    item.Activated:Connect(function()
                        lockOnModel(m, nil)
                        refreshRoster()
                    end)
                end
            end
        end

        scroll.CanvasSize = UDim2.fromOffset(0, layout.AbsoluteContentSize.Y + 10)
    end

    -- Initial load & live update every 1.5 seconds
    refreshRoster()
    task.spawn(function()
        while task.wait(1.5) do
            if not isRosterCollapsed and main.Parent then
                refreshRoster()
            end
        end
    end)
end

buildServerRosterUI()

--------------------------------------------------------------------------------
-- CONTROLS
--------------------------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == CONFIG.PC_KEYBIND then
        toggleLock()
    elseif input.KeyCode == CONFIG.GAMEPAD_KEYBIND then
        toggleLock()
    end
end)

print("[JJS Lock-on v7]: Live Server Roster ready. Click any player/NPC or press E to lock.")
