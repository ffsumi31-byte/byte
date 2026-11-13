--[[
    ============================================================================
    JJS TARGET LOCK-ON SYSTEM (v6 - BATTLEGROUNDS EDITION)
    ============================================================================
    Engineered for: PC / Studio, Console (Gamepad R3), and Mobile (Touch HUD).
    
    KEY FIXES & ADVANTAGES:
      1. ZERO CAMERA CRAZINESS AT CLOSE RANGE:
         Camera is rigidly anchored to YOUR character (over-the-shoulder),
         NOT the enemy. When you collide, dash through, or fight in close melee,
         the camera never spins or flips 180 degrees.
      2. MULTI-PLATFORM INPUT:
         - PC / Studio: Press 'E' (or Middle Mouse Click) to test directly.
         - Console: Press Right Stick (R3 / ButtonR3).
         - Mobile: Sleek circular Touch Button automatically created.
      3. SMOOTH JJS AUTO-FACING:
         Your character smoothly faces the target on the horizontal plane.
      4. TARGET ACQUISITION:
         Picks the enemy closest to your screen center within line-of-sight.
      5. VISUAL RETICLE & HIGHLIGHT:
         Animated brackets reticle and subtle outline highlight.

    PLACEMENT:
      Put this LocalScript inside: StarterPlayer -> StarterPlayerScripts
    ============================================================================
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")

local localPlayer = Players.LocalPlayer
local camera = workspace.CurrentCamera

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------
local CONFIG = {
    -- Target Detection
    MAX_LOCK_DISTANCE       = 75,       -- Max distance to acquire a target (studs)
    BREAK_LOCK_DISTANCE     = 105,      -- Distance at which lock automatically breaks
    VIEW_ANGLE_WEIGHT       = 0.65,     -- Prioritizes enemies you are actually looking at

    -- Camera Framing (Over-The-Shoulder, Anchored to YOU)
    CAMERA_DISTANCE         = 12.5,     -- Distance behind player
    CAMERA_HEIGHT           = 2.8,      -- Height above player root
    SHOULDER_OFFSET         = 1.8,      -- Right-shoulder offset (+ right, - left)
    SMOOTH_SPEED            = 14,       -- Exponential camera follow speed
    MIN_STABLE_DISTANCE     = 3.5,      -- Below this distance, look angle is clamped to prevent jitter

    -- Character Auto-Facing
    ENABLE_AUTO_FACE        = true,     -- Turn player character towards target
    AUTO_FACE_SPEED         = 18,       -- Turn speed

    -- Visuals
    RETICLE_COLOR           = Color3.fromRGB(255, 65, 65),     -- Vibrant JJS Red/Orange
    HIGHLIGHT_OUTLINE       = Color3.fromRGB(255, 80, 80),
    HIGHLIGHT_FILL          = Color3.fromRGB(255, 50, 50),
    FILL_TRANSPARENCY       = 0.85,
    OUTLINE_TRANSPARENCY    = 0.25,

    -- PC Keybinds
    PC_KEYBIND              = Enum.KeyCode.E,
    PC_ALT_KEYBIND          = Enum.UserInputType.MouseButton3, -- Middle click
    GAMEPAD_KEYBIND         = Enum.KeyCode.ButtonR3,           -- Right Stick click
}

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------
local isLocked = false
local currentTarget = nil            -- Target Model
local currentTargetRoot = nil        -- Target HumanoidRootPart
local currentTargetHum = nil         -- Target Humanoid
local targetDiedConn = nil

local currentCamPos = nil
local currentCamLook = nil

--------------------------------------------------------------------------------
-- UTILITY FUNCTIONS
--------------------------------------------------------------------------------
local function getLocalRoot()
    local char = localPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function getLocalHumanoid()
    local char = localPlayer.Character
    return char and char:FindFirstChildOfClass("Humanoid")
end

-- Line-of-sight check ignoring player and target models
local function hasLineOfSight(fromPos, toPos, targetModel)
    local char = localPlayer.Character
    local params = RaycastParams.new()
    params.FilterType = RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { char, targetModel, camera }
    params.IgnoreWater = true

    local dir = toPos - fromPos
    local result = workspace:Raycast(fromPos, dir, params)
    return result == nil
end

-- Wall collision raycast for camera so it never clips through terrain/walls
local function getCameraOcclusionPosition(headPos, desiredCamPos)
    local char = localPlayer.Character
    local params = RaycastParams.new()
    params.FilterType = RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { char, currentTarget, camera }
    params.IgnoreWater = true

    local dir = desiredCamPos - headPos
    local result = workspace:Raycast(headPos, dir, params)
    if result then
        return result.Position + (result.Normal * 0.4)
    end
    return desiredCamPos
end

--------------------------------------------------------------------------------
-- TARGET ACQUISITION (Smart Conical Range)
--------------------------------------------------------------------------------
local function findBestTarget()
    local myRoot = getLocalRoot()
    if not myRoot then return nil end

    local myPos = myRoot.Position
    local camCFrame = camera.CFrame
    local camForward = camCFrame.LookVector

    local bestTarget = nil
    local bestScore = math.huge

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= localPlayer and player.Character then
            local char = player.Character
            local hum = char:FindFirstChildOfClass("Humanoid")
            local root = char:FindFirstChild("HumanoidRootPart")

            if hum and root and hum.Health > 0 then
                local toTarget = root.Position - myPos
                local dist = toTarget.Magnitude

                if dist <= CONFIG.MAX_LOCK_DISTANCE then
                    -- Angle from where the camera is facing (0 = directly centered)
                    local dirToTarget = toTarget.Unit
                    local dot = camForward:Dot(dirToTarget)
                    local angle = math.deg(math.acos(math.clamp(dot, -1, 1)))

                    -- Only acquire if within ~80 degree forward cone
                    if angle <= 80 then
                        if hasLineOfSight(myPos + Vector3.new(0, 2, 0), root.Position, char) then
                            -- Score combines distance and angle from center screen
                            local score = (dist * (1 - CONFIG.VIEW_ANGLE_WEIGHT)) + (angle * CONFIG.VIEW_ANGLE_WEIGHT * 0.8)
                            if score < bestScore then
                                bestScore = score
                                bestTarget = char
                            end
                        end
                    end
                end
            end
        end
    end

    -- Also check NPCs in workspace (optional: models with Humanoids)
    for _, model in ipairs(workspace:GetChildren()) do
        if model:IsA("Model") and model ~= localPlayer.Character and not Players:GetPlayerFromCharacter(model) then
            local hum = model:FindFirstChildOfClass("Humanoid")
            local root = model:FindFirstChild("HumanoidRootPart")
            if hum and root and hum.Health > 0 then
                local toTarget = root.Position - myPos
                local dist = toTarget.Magnitude
                if dist <= CONFIG.MAX_LOCK_DISTANCE then
                    local dirToTarget = toTarget.Unit
                    local dot = camForward:Dot(dirToTarget)
                    local angle = math.deg(math.acos(math.clamp(dot, -1, 1)))
                    if angle <= 80 and hasLineOfSight(myPos + Vector3.new(0, 2, 0), root.Position, model) then
                        local score = (dist * (1 - CONFIG.VIEW_ANGLE_WEIGHT)) + (angle * CONFIG.VIEW_ANGLE_WEIGHT * 0.8)
                        if score < bestScore then
                            bestScore = score
                            bestTarget = model
                        end
                    end
                end
            end
        end
    end

    return bestTarget
end

--------------------------------------------------------------------------------
-- VISUALS: RETICLE & HIGHLIGHT
--------------------------------------------------------------------------------
local reticleGui = nil
local highlightInstance = nil

local function createReticle(targetChar)
    local root = targetChar:FindFirstChild("HumanoidRootPart")
    if not root then return end

    local bb = Instance.new("BillboardGui")
    bb.Name = "JJS_LockReticle"
    bb.Adornee = root
    bb.Size = UDim2.new(2.8, 0, 2.8, 0)
    bb.StudsOffset = Vector3.new(0, 0.4, 0)
    bb.AlwaysOnTop = true
    bb.ResetOnSpawn = false

    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(1, 0, 1, 0)
    frame.BackgroundTransparency = 1
    frame.Parent = bb

    -- Modern Bracket corners (JJS style)
    local function makeBracket(pos, anchor, rot)
        local img = Instance.new("ImageLabel")
        img.Size = UDim2.new(0.42, 0, 0.42, 0)
        img.Position = pos
        img.AnchorPoint = anchor
        img.Rotation = rot
        img.BackgroundTransparency = 1
        img.Image = "rbxassetid://13847525381" -- Clean corner bracket asset
        img.ImageColor3 = CONFIG.RETICLE_COLOR
        img.Parent = frame
        return img
    end

    makeBracket(UDim2.new(0, 0, 0, 0), Vector2.new(0, 0), 0)
    makeBracket(UDim2.new(1, 0, 0, 0), Vector2.new(1, 0), 90)
    makeBracket(UDim2.new(1, 0, 1, 0), Vector2.new(1, 1), 180)
    makeBracket(UDim2.new(0, 0, 1, 0), Vector2.new(0, 1), 270)

    -- Center subtle pip
    local dot = Instance.new("Frame")
    dot.Size = UDim2.new(0, 6, 0, 6)
    dot.Position = UDim2.new(0.5, 0, 0.5, 0)
    dot.AnchorPoint = Vector2.new(0.5, 0.5)
    dot.BackgroundColor3 = CONFIG.RETICLE_COLOR
    dot.BorderSizePixel = 0
    dot.Parent = frame
    Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

    -- Opening pulse animation
    frame.Size = UDim2.new(1.8, 0, 1.8, 0)
    frame.Position = UDim2.new(-0.4, 0, -0.4, 0)
    TweenService:Create(frame, TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
        Size = UDim2.new(1, 0, 1, 0),
        Position = UDim2.new(0, 0, 0, 0)
    }):Play()

    bb.Parent = localPlayer:WaitForChild("PlayerGui")
    reticleGui = bb

    -- Highlight Outline
    local hl = Instance.new("Highlight")
    hl.Name = "JJS_LockHighlight"
    hl.Adornee = targetChar
    hl.FillColor = CONFIG.HIGHLIGHT_FILL
    hl.OutlineColor = CONFIG.HIGHLIGHT_OUTLINE
    hl.FillTransparency = CONFIG.FILL_TRANSPARENCY
    hl.OutlineTransparency = CONFIG.OUTLINE_TRANSPARENCY
    hl.DepthMode = Enum.HighlightDepthMode.Occluded
    hl.Parent = targetChar
    highlightInstance = hl
end

local function removeReticle()
    if reticleGui then
        reticleGui:Destroy()
        reticleGui = nil
    end
    if highlightInstance then
        highlightInstance:Destroy()
        highlightInstance = nil
    end
end

--------------------------------------------------------------------------------
-- LOCK / UNLOCK CONTROLLER
--------------------------------------------------------------------------------
local function unlock()
    if not isLocked then return end
    isLocked = false
    currentTarget = nil
    currentTargetRoot = nil
    currentTargetHum = nil

    if targetDiedConn then
        targetDiedConn:Disconnect()
        targetDiedConn = nil
    end

    removeReticle()

    -- Restore normal default camera control
    camera.CameraType = Enum.CameraType.Custom
    local myHum = getLocalHumanoid()
    if myHum then
        myHum.AutoRotate = true
    end
end

local function lock(targetModel)
    if not targetModel then return end
    local root = targetModel:FindFirstChild("HumanoidRootPart")
    local hum = targetModel:FindFirstChildOfClass("Humanoid")
    if not root or not hum or hum.Health <= 0 then return end

    unlock()

    isLocked = true
    currentTarget = targetModel
    currentTargetRoot = root
    currentTargetHum = hum

    -- Listen for target death
    targetDiedConn = hum.Died:Connect(function()
        unlock()
    end)

    createReticle(targetModel)

    -- Take manual control of camera during lock
    camera.CameraType = Enum.CameraType.Scriptable
    currentCamPos = camera.CFrame.Position
    currentCamLook = root.Position + Vector3.new(0, 1.2, 0)
end

local function toggleLock()
    if isLocked then
        unlock()
    else
        local target = findBestTarget()
        if target then
            lock(target)
        end
    end
end

--------------------------------------------------------------------------------
-- MAIN CAMERA & AUTO-FACE LOOP (RUNS EVERY FRAME)
--------------------------------------------------------------------------------
RunService.RenderStepped:Connect(function(dt)
    if not isLocked or not currentTarget or not currentTargetRoot or not currentTargetHum then
        return
    end

    local myRoot = getLocalRoot()
    local myHum = getLocalHumanoid()
    if not myRoot or not myHum or myHum.Health <= 0 then
        unlock()
        return
    end

    -- Distance check: break if enemy fled beyond max range
    local toEnemy = currentTargetRoot.Position - myRoot.Position
    local dist = toEnemy.Magnitude
    if dist > CONFIG.BREAK_LOCK_DISTANCE then
        unlock()
        return
    end

    -- =========================================================================
    -- THE CRUCIAL STABILITY FIX:
    -- Direction is calculated horizontally. If distance is tiny (< 3.5 studs),
    -- clamp direction to avoid 180-degree wild spin flips!
    -- =========================================================================
    local flatToEnemy = Vector3.new(toEnemy.X, 0, toEnemy.Z)
    local lookDir
    if flatToEnemy.Magnitude >= CONFIG.MIN_STABLE_DISTANCE then
        lookDir = flatToEnemy.Unit
    else
        -- At ultra-close range / overlapping, maintain player's facing direction
        lookDir = myRoot.CFrame.LookVector
    end

    -- Right-hand vector relative to look direction (for shoulder offset)
    local rightVec = Vector3.new(0, 1, 0):Cross(lookDir).Unit

    -- 1. DESIRED CAMERA POSITION: Rigidly placed behind the PLAYER'S shoulder
    local playerHead = myRoot.Position + Vector3.new(0, CONFIG.CAMERA_HEIGHT, 0)
    local desiredCamPos = playerHead 
        - (lookDir * CONFIG.CAMERA_DISTANCE) 
        + (rightVec * CONFIG.SHOULDER_OFFSET)

    -- Prevent camera from clipping through terrain or obstacles
    local safeCamPos = getCameraOcclusionPosition(playerHead, desiredCamPos)

    -- 2. DESIRED CAMERA FOCUS: Target's chest/upper torso
    local targetFocus = currentTargetRoot.Position + Vector3.new(0, 1.2, 0)

    -- 3. EXPONENTIAL SMOOTH DAMPING (JJS feel: sharp yet organic)
    local alpha = 1 - math.exp(-CONFIG.SMOOTH_SPEED * dt)
    currentCamPos = currentCamPos and currentCamPos:Lerp(safeCamPos, alpha) or safeCamPos
    currentCamLook = currentCamLook and currentCamLook:Lerp(targetFocus, alpha) or targetFocus

    -- Update camera CFrame cleanly
    camera.CFrame = CFrame.lookAt(currentCamPos, currentCamLook, Vector3.new(0, 1, 0))

    -- =========================================================================
    -- CHARACTER AUTO-FACING:
    -- Smoothly turns your character to face the enemy horizontally
    -- =========================================================================
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
-- MULTI-PLATFORM INPUT HANDLING (PC, Console, Mobile)
--------------------------------------------------------------------------------

-- PC Keyboard & Mouse
UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == CONFIG.PC_KEYBIND or input.UserInputType == CONFIG.PC_ALT_KEYBIND then
        toggleLock()
    elseif input.KeyCode == CONFIG.GAMEPAD_KEYBIND then
        toggleLock()
    end
end)

-- Mobile On-Screen Touch Button
local function setupMobileHUD()
    -- Only create if touch is enabled and no mouse/keyboard primary
    if not UserInputService.TouchEnabled then return end

    local pg = localPlayer:WaitForChild("PlayerGui")
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "JJS_MobileLockHUD"
    screenGui.ResetOnSpawn = false
    screenGui.DisplayOrder = 10

    local btn = Instance.new("ImageButton")
    btn.Name = "LockBtn"
    btn.Size = UDim2.new(0, 60, 0, 60)
    btn.Position = UDim2.new(1, -90, 0.5, 40) -- Clean ergonomic thumb position
    btn.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    btn.BackgroundTransparency = 0.35
    btn.Image = "rbxassetid://13847525381"
    btn.ImageColor3 = Color3.fromRGB(240, 240, 240)
    btn.Parent = screenGui

    local corner = Instance.new("UICorner", btn)
    corner.CornerRadius = UDim.new(1, 0)

    local stroke = Instance.new("UIStroke", btn)
    stroke.Color = Color3.fromRGB(255, 255, 255)
    stroke.Transparency = 0.5
    stroke.Thickness = 1.5

    btn.Activated:Connect(function()
        toggleLock()
        if isLocked then
            btn.ImageColor3 = CONFIG.RETICLE_COLOR
            stroke.Color = CONFIG.RETICLE_COLOR
            stroke.Transparency = 0.1
        else
            btn.ImageColor3 = Color3.fromRGB(240, 240, 240)
            stroke.Color = Color3.fromRGB(255, 255, 255)
            stroke.Transparency = 0.5
        end
    end)

    screenGui.Parent = pg
end

setupMobileHUD()

print("[JJS Lock-on v6]: Initialized successfully. Press E or R3 to Lock.")
