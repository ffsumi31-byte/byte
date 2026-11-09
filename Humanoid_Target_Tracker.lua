--[[
    ===================================================================
    JJS CONSOLE-STYLE PLAYER TRACKER (Lock-On Target System)
    Inspired by Jujutsu Shenanigans (JJS) Console Combat Mechanics
    
    Controls:
      - Console Gamepad:
          * R3 (Right Thumbstick Press): Toggle Lock-On / Tracker
          * L3 (Left Thumbstick Press): Switch Target
      - Keyboard / Mouse:
          * X or Q: Toggle Lock-On / Tracker
          * Tab: Switch Target
      - On-Screen UI:
          * Clickable HUD Toggle Button on Bottom-Right / Touch support
          
    Key Rules:
      - Targets HumanoidRootPart directly (NO HEAD tracking to prevent jitter)
      - Smooth 3rd-person combat camera tracking
      - Sleek JJS-inspired targeting reticle with real-time distance
      - Auto-unlock on target death or distance exceed (> 110 studs)
    ===================================================================
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")

local localPlayer = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- Configuration
local CONFIG = {
    MAX_LOCK_DISTANCE = 95,          -- Max distance to acquire target
    BREAK_LOCK_DISTANCE = 115,       -- Max distance before lock breaks
    FOV_WEIGHT = 0.55,               -- Prioritize targets centered on screen
    CAMERA_SMOOTH_SPEED = 12,        -- Interpolation speed for camera tracking
    CAMERA_HEIGHT = 3.0,             -- Vertical camera offset relative to player
    CAMERA_DISTANCE = 13.5,          -- Default camera distance
    MIN_ZOOM = 7,
    MAX_ZOOM = 22,
    SHOULDER_OFFSET = 1.2,           -- Slight combat over-the-shoulder offset
}

-- State variables
local isLocked = false
local currentTarget = nil
local currentZoom = CONFIG.CAMERA_DISTANCE
local reticleGui = nil
local reticleBillboard = nil

-----------------------------------------------------------------------
-- AUDIO FEEDBACK
-----------------------------------------------------------------------
local function playSound(soundId, volume, pitch)
    local sound = Instance.new("Sound")
    sound.SoundId = soundId
    sound.Volume = volume or 0.6
    sound.PlaybackSpeed = pitch or 1.0
    sound.Parent = SoundService
    sound:Play()
    sound.Ended:Connect(function()
        sound:Destroy()
    end)
end

local function playLockSound()
    -- Crisp electronic lock-on beep
    playSound("rbxassetid://9114223171", 0.5, 1.2)
end

local function playUnlockSound()
    -- Low subtle disengage beep
    playSound("rbxassetid://9114223171", 0.35, 0.8)
end

-----------------------------------------------------------------------
-- JJS RETICLE UI (Bracket & Diamond targeting overlay)
-----------------------------------------------------------------------
local function createReticle()
    if reticleBillboard then
        reticleBillboard:Destroy()
        reticleBillboard = nil
    end

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "JJSTargetReticle"
    billboard.Size = UDim2.new(0, 90, 0, 90)
    billboard.StudsOffset = Vector3.new(0, 0, 0) -- Centered on HumanoidRootPart (NO HEAD)
    billboard.AlwaysOnTop = true
    billboard.Active = false

    local container = Instance.new("Frame")
    container.Name = "Container"
    container.Size = UDim2.new(1, 0, 1, 0)
    container.BackgroundTransparency = 1
    container.Parent = billboard

    -- Corner bracket builder
    local function makeBracket(name, pos, anchor, rot)
        local frame = Instance.new("Frame")
        frame.Name = name
        frame.Size = UDim2.new(0, 20, 0, 20)
        frame.Position = pos
        frame.AnchorPoint = anchor
        frame.BackgroundTransparency = 1
        frame.Rotation = rot
        frame.Parent = container

        -- Horizontal line
        local hLine = Instance.new("Frame")
        hLine.Size = UDim2.new(1, 0, 0, 3)
        hLine.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
        hLine.BorderSizePixel = 0
        hLine.Parent = frame
        local corner1 = Instance.new("UICorner")
        corner1.CornerRadius = UDim.new(0, 1)
        corner1.Parent = hLine

        -- Vertical line
        local vLine = Instance.new("Frame")
        vLine.Size = UDim2.new(0, 3, 1, 0)
        vLine.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
        vLine.BorderSizePixel = 0
        vLine.Parent = frame
        local corner2 = Instance.new("UICorner")
        corner2.CornerRadius = UDim.new(0, 1)
        corner2.Parent = vLine
        
        return frame
    end

    makeBracket("TopLeft", UDim2.new(0, 0, 0, 0), Vector2.new(0, 0), 0)
    makeBracket("TopRight", UDim2.new(1, 0, 0, 0), Vector2.new(1, 0), 90)
    makeBracket("BottomRight", UDim2.new(1, 0, 1, 0), Vector2.new(1, 1), 180)
    makeBracket("BottomLeft", UDim2.new(0, 0, 1, 0), Vector2.new(0, 1), 270)

    -- Center Diamond Crosshair
    local centerDot = Instance.new("Frame")
    centerDot.Name = "CenterDiamond"
    centerDot.Size = UDim2.new(0, 10, 0, 10)
    centerDot.AnchorPoint = Vector2.new(0.5, 0.5)
    centerDot.Position = UDim2.new(0.5, 0, 0.5, 0)
    centerDot.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    centerDot.Rotation = 45
    centerDot.BorderSizePixel = 0
    centerDot.Parent = container

    local diamondGlow = Instance.new("UIStroke")
    diamondGlow.Color = Color3.fromRGB(255, 50, 50)
    diamondGlow.Thickness = 2
    diamondGlow.Parent = centerDot

    -- Distance & Target Name Label
    local infoLabel = Instance.new("TextLabel")
    infoLabel.Name = "InfoLabel"
    infoLabel.Size = UDim2.new(2, 0, 0, 18)
    infoLabel.AnchorPoint = Vector2.new(0.5, 0)
    infoLabel.Position = UDim2.new(0.5, 0, 1, 6)
    infoLabel.BackgroundTransparency = 1
    infoLabel.Font = Enum.Font.GothamBold
    infoLabel.Text = "LOCKED"
    infoLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    infoLabel.TextSize = 12
    infoLabel.TextStrokeTransparency = 0.4
    infoLabel.TextStrokeColor3 = Color3.fromRGB(15, 15, 15)
    infoLabel.Parent = container

    reticleBillboard = billboard
    return billboard
end

-----------------------------------------------------------------------
-- SCREEN HUD DISPLAY (Shows Tracker status and Controller Button)
-----------------------------------------------------------------------
local hudGui = nil
local statusBadge = nil
local targetBadge = nil

local function createHUD()
    local playerGui = localPlayer:WaitForChild("PlayerGui")
    
    local existing = playerGui:FindFirstChild("JJSTrackerHUD")
    if existing then existing:Destroy() end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "JJSTrackerHUD"
    screenGui.ResetOnSpawn = false
    screenGui.Parent = playerGui

    -- Main HUD Frame (Bottom-Right, non-intrusive)
    local mainFrame = Instance.new("Frame")
    mainFrame.Name = "TrackerPanel"
    mainFrame.Size = UDim2.new(0, 220, 0, 68)
    mainFrame.AnchorPoint = Vector2.new(1, 1)
    mainFrame.Position = UDim2.new(1, -25, 1, -25)
    mainFrame.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
    mainFrame.BackgroundTransparency = 0.25
    mainFrame.BorderSizePixel = 0
    mainFrame.Parent = screenGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = mainFrame

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(50, 55, 70)
    stroke.Thickness = 1.5
    stroke.Parent = mainFrame

    -- Interactive Toggle Button
    local toggleBtn = Instance.new("TextButton")
    toggleBtn.Name = "ToggleButton"
    toggleBtn.Size = UDim2.new(1, 0, 1, 0)
    toggleBtn.BackgroundTransparency = 1
    toggleBtn.Text = ""
    toggleBtn.Parent = mainFrame

    -- Keybind hint banner (R3 / X)
    local keyHint = Instance.new("TextLabel")
    keyHint.Size = UDim2.new(0, 56, 0, 24)
    keyHint.Position = UDim2.new(0, 10, 0, 10)
    keyHint.BackgroundColor3 = Color3.fromRGB(35, 38, 48)
    keyHint.Text = "R3 / X"
    keyHint.Font = Enum.Font.GothamBold
    keyHint.TextColor3 = Color3.fromRGB(255, 215, 0)
    keyHint.TextSize = 11
    keyHint.Parent = mainFrame
    local keyCorner = Instance.new("UICorner")
    keyCorner.CornerRadius = UDim.new(0, 6)
    keyCorner.Parent = keyHint

    -- Title Label
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(0, 140, 0, 20)
    title.Position = UDim2.new(0, 74, 0, 12)
    title.BackgroundTransparency = 1
    title.Text = "TARGET TRACKER"
    title.Font = Enum.Font.GothamBlack
    title.TextColor3 = Color3.fromRGB(230, 235, 245)
    title.TextSize = 13
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = mainFrame

    -- Status Pill
    statusBadge = Instance.new("TextLabel")
    statusBadge.Size = UDim2.new(1, -20, 0, 22)
    statusBadge.Position = UDim2.new(0, 10, 0, 38)
    statusBadge.BackgroundColor3 = Color3.fromRGB(28, 30, 38)
    statusBadge.Text = "STANDBY  [TAP TO LOCK]"
    statusBadge.Font = Enum.Font.GothamBold
    statusBadge.TextColor3 = Color3.fromRGB(150, 155, 170)
    statusBadge.TextSize = 11
    statusBadge.Parent = mainFrame
    local badgeCorner = Instance.new("UICorner")
    badgeCorner.CornerRadius = UDim.new(0, 6)
    badgeCorner.Parent = statusBadge

    -- Click event for testing without controller
    toggleBtn.MouseButton1Click:Connect(function()
        toggleLockOn()
    end)

    hudGui = screenGui
end

local function updateHUDState()
    if not statusBadge then return end
    if isLocked and currentTarget then
        statusBadge.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
        statusBadge.TextColor3 = Color3.fromRGB(255, 255, 255)
        statusBadge.Text = string.format("LOCKED: %s", string.upper(currentTarget.Name))
    else
        statusBadge.BackgroundColor3 = Color3.fromRGB(28, 30, 38)
        statusBadge.TextColor3 = Color3.fromRGB(150, 155, 170)
        statusBadge.Text = "STANDBY  [R3 / X TO LOCK]"
    end
end

-----------------------------------------------------------------------
-- TARGET SCANNING & VALIDATION
-----------------------------------------------------------------------
-- Supports standard HumanoidRootPart rigs, and Humanoids whose root is
-- exposed through Humanoid.RootPart or the Model.PrimaryPart.
local function getHumanoidRootPart(model)
    if not model or not model:IsA("Model") then return nil end

    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if not humanoid then return nil end

    local rootPart = humanoid.RootPart
        or model:FindFirstChild("HumanoidRootPart", true)
        or model.PrimaryPart

    if rootPart and rootPart:IsA("BasePart") then
        return rootPart
    end

    return nil
end

local function isValidTarget(character)
    if not character or not character:IsA("Model") then return false end
    if character == localPlayer.Character then return false end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local rootPart = getHumanoidRootPart(character)

    if not humanoid or not rootPart or humanoid.Health <= 0 then
        return false
    end

    local myChar = localPlayer.Character
    if not myChar then return false end
    local myRoot = getHumanoidRootPart(myChar)
    if not myRoot then return false end

    local dist = (rootPart.Position - myRoot.Position).Magnitude
    if dist > CONFIG.BREAK_LOCK_DISTANCE then return false end

    return true
end

-- Find the best target (closest to screen center + within range)
local function findBestTarget(ignoreCurrent)
    local myChar = localPlayer.Character
    if not myChar then return nil end
    local myRoot = getHumanoidRootPart(myChar)
    if not myRoot then return nil end

    local camCFrame = camera.CFrame
    local camLook = camCFrame.LookVector

    local candidates = {}

    -- Scan Workspace for valid humanoid character models
    local function checkModel(model)
        if model:IsA("Model") and model ~= myChar and (not ignoreCurrent or model ~= currentTarget) then
            if isValidTarget(model) then
                local rootPart = getHumanoidRootPart(model)
                if not rootPart then return end

                local toTarget = (rootPart.Position - myRoot.Position)
                local dist = toTarget.Magnitude
                
                if dist <= CONFIG.MAX_LOCK_DISTANCE then
                    local dir = toTarget.Unit
                    local dot = camLook:Dot(dir) -- 1.0 = dead center, -1.0 = behind
                    
                    -- Check if target is not completely behind camera
                    if dot > -0.2 then
                        -- Score formula: combines center-alignment and proximity
                        local score = (dot * 50) - (dist * 0.8)
                        table.insert(candidates, {model = model, score = score, dist = dist})
                    end
                end
            end
        end
    end

    -- Scan every descendant Model in Workspace, not just top-level children.
    -- This catches player characters, NPCs, and humanoid rigs inside Folders
    -- or other container Models. Non-Humanoid Models are ignored by checkModel.
    for _, descendant in ipairs(workspace:GetDescendants()) do
        if descendant:IsA("Model") then
            checkModel(descendant)
        end
    end

    if #candidates == 0 then return nil end

    -- Sort by best score
    table.sort(candidates, function(a, b)
        return a.score > b.score
    end)

    return candidates[1].model
end

-----------------------------------------------------------------------
-- LOCK-ON TOGGLE & DISENGAGE
-----------------------------------------------------------------------
function toggleLockOn()
    if isLocked then
        unlockTarget()
    else
        local target = findBestTarget(false)
        if target then
            lockTarget(target)
        else
            -- No target found: subtle feedback
            if statusBadge then
                statusBadge.Text = "NO TARGET IN RANGE"
                task.delay(1, function()
                    if not isLocked then updateHUDState() end
                end)
            end
        end
    end
end

function switchTarget()
    if not isLocked then
        toggleLockOn()
        return
    end
    
    local nextTarget = findBestTarget(true)
    if nextTarget and nextTarget ~= currentTarget then
        lockTarget(nextTarget)
    end
end

function lockTarget(target)
    if not isValidTarget(target) then return end
    
    currentTarget = target
    isLocked = true
    
    -- Setup reticle billboard on HumanoidRootPart (torso center, NO HEAD!)
    local targetRoot = getHumanoidRootPart(target)
    if targetRoot then
        local reticle = createReticle()
        reticle.Adornee = targetRoot
        reticle.Parent = targetRoot
        
        -- Lock-in animation: scale effect
        local container = reticle:FindFirstChild("Container")
        if container then
            container.Size = UDim2.new(1.8, 0, 1.8, 0)
            TweenService:Create(container, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
                Size = UDim2.new(1, 0, 1, 0)
            }):Play()
        end
    end
    
    -- Switch camera to Scriptable to ensure smooth JJS tracker control
    camera.CameraType = Enum.CameraType.Scriptable
    playLockSound()
    updateHUDState()
end

function unlockTarget()
    isLocked = false
    currentTarget = nil
    
    if reticleBillboard then
        reticleBillboard:Destroy()
        reticleBillboard = nil
    end
    
    -- Restore default camera behavior
    camera.CameraType = Enum.CameraType.Custom
    playUnlockSound()
    updateHUDState()
end

-----------------------------------------------------------------------
-- RENDER STEPPED: SMOOTH COMBAT CAMERA & TRACKER UPDATE
-----------------------------------------------------------------------
RunService.RenderStepped:Connect(function(dt)
    if not isLocked or not currentTarget then return end

    -- Verify target is still valid
    if not isValidTarget(currentTarget) then
        unlockTarget()
        return
    end

    local myChar = localPlayer.Character
    if not myChar then
        unlockTarget()
        return
    end

    local myRoot = getHumanoidRootPart(myChar)
    local targetRoot = getHumanoidRootPart(currentTarget)

    if not myRoot or not targetRoot then
        unlockTarget()
        return
    end

    local myPos = myRoot.Position
    local targetPos = targetRoot.Position

    -- Real-time distance check
    local dist = (targetPos - myPos).Magnitude
    if dist > CONFIG.BREAK_LOCK_DISTANCE then
        unlockTarget()
        return
    end

    -- Update Reticle Info & Pulse (Centering on HumanoidRootPart)
    if reticleBillboard and reticleBillboard:FindFirstChild("Container") then
        local container = reticleBillboard.Container
        local infoLabel = container:FindFirstChild("InfoLabel")
        if infoLabel then
            infoLabel.Text = string.format("%s  [%d STUDS]", string.upper(currentTarget.Name), math.floor(dist))
        end

        -- Subtle high-intensity JJS pulse on diamond
        local centerDiamond = container:FindFirstChild("CenterDiamond")
        if centerDiamond then
            centerDiamond.Rotation = 45 + (math.sin(tick() * 6) * 12)
        end
    end

    -- COMPUTE JJS CAMERA TRACKING
    -- 1. Direction vector from target to local player
    local diff = (myPos - targetPos)
    local flatDiff = Vector3.new(diff.X, 0, diff.Z)
    local flatDist = flatDiff.Magnitude
    local flatDir = flatDist > 0.1 and (flatDiff / flatDist) or -myRoot.CFrame.LookVector

    -- 2. Calculate smooth third-person camera placement behind local player
    local camDist = currentZoom
    local camHeight = CONFIG.CAMERA_HEIGHT
    
    -- Subtle lateral shoulder offset for combat framing
    local rightVec = flatDir:Cross(Vector3.new(0, 1, 0)).Unit
    local shoulderOffset = rightVec * CONFIG.SHOULDER_OFFSET

    local targetCamPos = myPos + (flatDir * camDist) + Vector3.new(0, camHeight, 0) + shoulderOffset

    -- 3. Obstacle Collision Raycast (prevent clipping into terrain/walls)
    local rayParams = RaycastParams.new()
    rayParams.FilterDescendantsInstances = {myChar, currentTarget}
    rayParams.FilterType = Enum.RaycastFilterType.Exclude

    local headPos = myPos + Vector3.new(0, camHeight * 0.7, 0)
    local rayDir = (targetCamPos - headPos)
    local hit = workspace:Raycast(headPos, rayDir, rayParams)
    if hit then
        targetCamPos = hit.Position + (hit.Normal * 0.6)
    end

    -- 4. Target tracking point: HumanoidRootPart torso center (NO HEAD!)
    local targetFocusPoint = targetPos + Vector3.new(0, 0.4, 0)

    -- 5. Build desired CFrame looking directly at target
    local desiredCFrame = CFrame.lookAt(targetCamPos, targetFocusPoint)

    -- 6. Smooth Lerp
    local lerpAlpha = math.clamp(CONFIG.CAMERA_SMOOTH_SPEED * dt, 0, 1)
    camera.CFrame = camera.CFrame:Lerp(desiredCFrame, lerpAlpha)
end)

-----------------------------------------------------------------------
-- CONTROLLER & KEYBOARD INPUT HANDLING
-----------------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end

    -- Gamepad (Console) Controls
    if input.KeyCode == Enum.KeyCode.ButtonR3 then
        -- R3 (Right Thumbstick Press): JJS Lock-on toggle
        toggleLockOn()
    elseif input.KeyCode == Enum.KeyCode.ButtonL3 then
        -- L3 (Left Thumbstick Press): Switch target
        switchTarget()
    
    -- Keyboard Controls (Studio Testing without Console)
    elseif input.KeyCode == Enum.KeyCode.X or input.KeyCode == Enum.KeyCode.Q then
        toggleLockOn()
    elseif input.KeyCode == Enum.KeyCode.Tab then
        switchTarget()
    end
end)

-- Mouse Wheel / Zoom support during lock-on
UserInputService.InputChanged:Connect(function(input, gameProcessed)
    if not isLocked then return end
    if input.UserInputType == Enum.UserInputType.MouseWheel then
        currentZoom = math.clamp(currentZoom - (input.Position.Z * 1.5), CONFIG.MIN_ZOOM, CONFIG.MAX_ZOOM)
    end
end)

-- Character respawn cleanup
localPlayer.CharacterAdded:Connect(function()
    if isLocked then
        unlockTarget()
    end
end)

-- Initialize HUD
createHUD()
