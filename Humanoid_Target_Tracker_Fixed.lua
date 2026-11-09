--[[
    HUMANOID TARGET TRACKER - PLAYER / NPC NAME MODES

    LocalScript for Roblox.

    Controls:
      X / Q or R3 : Lock / unlock the selected target
      Tab / L3     : Switch to another matching target
      P            : Player mode
      N            : NPC-by-name mode
      Mouse wheel  : Adjust camera distance while locked

    Modes:
      PLAYER : Searches Players:GetPlayers() for characters in this server.
               Leave the name box blank to choose the best visible player,
               or enter a username / display name to select that player.
      NPC    : Searches workspace for NPC Models with a living Humanoid.
               Enter the NPC Model name. Blank NPC searches are disabled so
               random humanoid props / pets are not acquired accidentally.

    Camera:
      Fixed 60-degree downward pitch, stable yaw, close-range direction
      deadzone, smoothed target position, and collision handling.

    Note: This is a client-side tracker. It can only see players and NPCs
    replicated to this client in the current server.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")

local localPlayer = Players.LocalPlayer
local camera = workspace.CurrentCamera

local CONFIG = {
    MAX_LOCK_DISTANCE = 95,
    BREAK_LOCK_DISTANCE = 115,

    CAMERA_SMOOTH_SPEED = 8,
    CAMERA_YAW_SPEED = math.rad(150),
    CAMERA_PITCH_DEGREES = 60, -- Fixed downward angle from the horizontal
    CAMERA_DISTANCE = 13.5,
    MIN_ZOOM = 7,
    MAX_ZOOM = 22,
    SHOULDER_OFFSET = 1.2,
    MIN_DIRECTION_DISTANCE = 3.5, -- Freeze yaw when player is too close to target

    RETICLE_COLOR_PLAYER = Color3.fromRGB(70, 210, 255),
    RETICLE_COLOR_NPC = Color3.fromRGB(255, 75, 75),
}

local isLocked = false
local currentTarget = nil
local currentZoom = CONFIG.CAMERA_DISTANCE
local targetMode = "PLAYER"

local reticleBillboard = nil
local targetHighlight = nil
local hudGui = nil
local statusBadge = nil
local playerModeButton = nil
local npcModeButton = nil
local targetNameBox = nil
local lockButton = nil

local cameraTypeBeforeLock = nil
local cameraSubjectBeforeLock = nil
local cameraYaw = nil
local smoothedFocus = nil
local smoothedCameraDistance = CONFIG.CAMERA_DISTANCE

local toggleLockOn
local switchTarget
local lockTarget
local unlockTarget
local setTargetMode

-----------------------------------------------------------------------
-- SMALL HELPERS
-----------------------------------------------------------------------
local function trim(value)
    return (tostring(value or ""):gsub("^%s*(.-)%s*$", "%1"))
end

local function lower(value)
    return string.lower(tostring(value or ""))
end

local function wrapAngle(angle)
    return (angle + math.pi) % (2 * math.pi) - math.pi
end

local function getCharacterRoot(model)
    if not model or not model:IsA("Model") then
        return nil
    end

    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        return nil
    end

    local root = humanoid.RootPart
        or model:FindFirstChild("HumanoidRootPart")
        or model.PrimaryPart

    if root and root:IsA("BasePart") and root:IsDescendantOf(model) then
        return root
    end

    return nil
end

local function getHumanoid(model)
    if not model or not model:IsA("Model") then
        return nil
    end
    return model:FindFirstChildOfClass("Humanoid")
end

local function getLocalRoot()
    local character = localPlayer.Character
    if not character then
        return nil
    end
    return getCharacterRoot(character)
end

local function getTargetPlayer(model)
    return Players:GetPlayerFromCharacter(model)
end

local function isInsideLocalCharacter(model)
    local character = localPlayer.Character
    return character ~= nil and (model == character or model:IsDescendantOf(character))
end

-- Exclude NPCs/pets that the game explicitly marks as belonging to this player.
-- Models without ownership metadata are handled by the character/ancestor filters.
local function isOwnedByLocalPlayer(model)
    local userIdKeys = {
        "OwnerUserId", "PlayerUserId", "CreatorUserId",
        "SummonerUserId", "OwnerId", "CreatorId",
    }
    for _, key in ipairs(userIdKeys) do
        local value = model:GetAttribute(key)
        if typeof(value) == "number" and value == localPlayer.UserId then
            return true
        end
    end

    local nameKeys = {
        "Owner", "Player", "Creator", "OwnerName", "CreatorName", "SummonedBy",
    }
    for _, key in ipairs(nameKeys) do
        local value = model:GetAttribute(key)
        if typeof(value) == "string" then
            local normalized = lower(value)
            if normalized == lower(localPlayer.Name) or normalized == lower(localPlayer.DisplayName) then
                return true
            end
        end
    end

    for _, key in ipairs({
        "Owner", "Player", "Creator", "owner", "player", "creator", "Summoner",
    }) do
        local valueObject = model:FindFirstChild(key, true)
        if valueObject then
            if valueObject:IsA("ObjectValue") then
                if valueObject.Value == localPlayer or valueObject.Value == localPlayer.Character then
                    return true
                end
            elseif valueObject:IsA("StringValue") then
                local normalized = lower(valueObject.Value)
                if normalized == lower(localPlayer.Name) or normalized == lower(localPlayer.DisplayName) then
                    return true
                end
            elseif valueObject:IsA("IntValue") or valueObject:IsA("NumberValue") then
                if valueObject.Value == localPlayer.UserId then
                    return true
                end
            end
        end
    end

    -- Some games put summoned NPCs in a Folder named after their owner,
    -- or store the owner id on that Folder instead of the NPC Model.
    local ancestor = model.Parent
    while ancestor and ancestor ~= workspace do
        if ancestor ~= localPlayer.Character then
            local ancestorName = lower(ancestor.Name)
            if ancestorName == lower(localPlayer.Name) or ancestorName == lower(localPlayer.DisplayName) then
                return true
            end
            for _, key in ipairs(userIdKeys) do
                local value = ancestor:GetAttribute(key)
                if typeof(value) == "number" and value == localPlayer.UserId then
                    return true
                end
            end
        end
        ancestor = ancestor.Parent
    end

    return false
end

-- Only the outer character Model is targetable. This avoids locking onto
-- nested humanoid props / sub-models inside another character rig.
local function hasHumanoidModelAncestor(model)
    local ancestor = model.Parent
    while ancestor and ancestor ~= workspace do
        if ancestor:IsA("Model") and ancestor:FindFirstChildOfClass("Humanoid") then
            return true
        end
        ancestor = ancestor.Parent
    end
    return false
end

local function getTargetDistance(model)
    local myRoot = getLocalRoot()
    local targetRoot = getCharacterRoot(model)
    if not myRoot or not targetRoot then
        return math.huge
    end
    return (targetRoot.Position - myRoot.Position).Magnitude
end

local function isValidTarget(model)
    if not model or not model:IsA("Model") then
        return false
    end
    if not model:IsDescendantOf(workspace) then
        return false
    end
    if isInsideLocalCharacter(model) then
        return false
    end
    if getTargetPlayer(model) == localPlayer then
        return false
    end

    local humanoid = getHumanoid(model)
    local root = getCharacterRoot(model)
    if not humanoid or not root or humanoid.Health <= 0 then
        return false
    end

    local myRoot = getLocalRoot()
    if not myRoot then
        return false
    end

    local distance = (root.Position - myRoot.Position).Magnitude
    return distance <= CONFIG.BREAK_LOCK_DISTANCE, distance
end

local function getTargetSearchText()
    return targetNameBox and trim(targetNameBox.Text) or ""
end

local function getNameMatchScore(name, displayName, query)
    if query == "" then
        return 0
    end

    local q = lower(query)
    local n = lower(name)
    local d = lower(displayName)

    if n == q then return 100 end
    if d ~= "" and d == q then return 95 end
    if n:sub(1, #q) == q then return 80 end
    if d ~= "" and d:sub(1, #q) == q then return 75 end
    if string.find(n, q, 1, true) then return 60 end
    if d ~= "" and string.find(d, q, 1, true) then return 55 end
    return nil
end

local function getTargetDisplayName(model)
    local player = getTargetPlayer(model)
    if player then
        if player.DisplayName ~= player.Name then
            return player.DisplayName .. " (@" .. player.Name .. ")"
        end
        return player.Name
    end
    return model and model.Name or "UNKNOWN"
end

-----------------------------------------------------------------------
-- AUDIO FEEDBACK
-----------------------------------------------------------------------
local function playSound(soundId, volume, pitch)
    local sound = Instance.new("Sound")
    sound.SoundId = soundId
    sound.Volume = volume or 0.6
    sound.PlaybackSpeed = pitch or 1
    sound.Parent = SoundService
    sound:Play()
    sound.Ended:Connect(function()
        sound:Destroy()
    end)
end

local function playLockSound()
    playSound("rbxassetid://9114223171", 0.5, 1.2)
end

local function playUnlockSound()
    playSound("rbxassetid://9114223171", 0.35, 0.8)
end

-----------------------------------------------------------------------
-- RETICLE / TARGET VISUALS
-----------------------------------------------------------------------
local function destroyTargetVisuals()
    if reticleBillboard then
        reticleBillboard:Destroy()
        reticleBillboard = nil
    end
    if targetHighlight then
        targetHighlight:Destroy()
        targetHighlight = nil
    end
end

local function createReticle(target, root)
    destroyTargetVisuals()

    local isPlayerTarget = getTargetPlayer(target) ~= nil
    local accent = isPlayerTarget and CONFIG.RETICLE_COLOR_PLAYER or CONFIG.RETICLE_COLOR_NPC

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "HumanoidTrackerReticle"
    billboard.Size = UDim2.fromOffset(110, 90)
    billboard.StudsOffset = Vector3.new(0, 0.15, 0)
    billboard.AlwaysOnTop = true
    billboard.LightInfluence = 0
    billboard.Adornee = root
    billboard.Parent = localPlayer:WaitForChild("PlayerGui")

    local container = Instance.new("Frame")
    container.Name = "Container"
    container.Size = UDim2.fromScale(1, 1)
    container.BackgroundTransparency = 1
    container.Parent = billboard

    local function makeBracket(name, position, anchor, rotation)
        local bracket = Instance.new("Frame")
        bracket.Name = name
        bracket.Size = UDim2.fromOffset(20, 20)
        bracket.Position = position
        bracket.AnchorPoint = anchor
        bracket.BackgroundTransparency = 1
        bracket.Rotation = rotation
        bracket.Parent = container

        local horizontal = Instance.new("Frame")
        horizontal.Size = UDim2.new(1, 0, 0, 3)
        horizontal.BackgroundColor3 = accent
        horizontal.BorderSizePixel = 0
        horizontal.Parent = bracket
        Instance.new("UICorner", horizontal).CornerRadius = UDim.new(0, 1)

        local vertical = Instance.new("Frame")
        vertical.Size = UDim2.new(0, 3, 1, 0)
        vertical.BackgroundColor3 = accent
        vertical.BorderSizePixel = 0
        vertical.Parent = bracket
        Instance.new("UICorner", vertical).CornerRadius = UDim.new(0, 1)
    end

    makeBracket("TopLeft", UDim2.fromScale(0, 0), Vector2.new(0, 0), 0)
    makeBracket("TopRight", UDim2.fromScale(1, 0), Vector2.new(1, 0), 90)
    makeBracket("BottomRight", UDim2.fromScale(1, 1), Vector2.new(1, 1), 180)
    makeBracket("BottomLeft", UDim2.fromScale(0, 1), Vector2.new(0, 1), 270)

    local diamond = Instance.new("Frame")
    diamond.Name = "CenterDiamond"
    diamond.Size = UDim2.fromOffset(10, 10)
    diamond.AnchorPoint = Vector2.new(0.5, 0.5)
    diamond.Position = UDim2.fromScale(0.5, 0.5)
    diamond.BackgroundColor3 = Color3.new(1, 1, 1)
    diamond.Rotation = 45
    diamond.BorderSizePixel = 0
    diamond.Parent = container

    local diamondStroke = Instance.new("UIStroke")
    diamondStroke.Color = accent
    diamondStroke.Thickness = 2
    diamondStroke.Parent = diamond

    local infoLabel = Instance.new("TextLabel")
    infoLabel.Name = "InfoLabel"
    infoLabel.Size = UDim2.new(2.6, 0, 0, 18)
    infoLabel.AnchorPoint = Vector2.new(0.5, 0)
    infoLabel.Position = UDim2.new(0.5, 0, 1, 5)
    infoLabel.BackgroundTransparency = 1
    infoLabel.Font = Enum.Font.GothamBold
    infoLabel.Text = string.upper(getTargetDisplayName(target))
    infoLabel.TextColor3 = Color3.new(1, 1, 1)
    infoLabel.TextSize = 12
    infoLabel.TextStrokeTransparency = 0.25
    infoLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
    infoLabel.TextTruncate = Enum.TextTruncate.AtEnd
    infoLabel.Parent = container

    reticleBillboard = billboard

    -- Visible outline makes the selected NPC easier to locate. Occluded mode
    -- avoids displaying the outline through solid walls.
    local highlight = Instance.new("Highlight")
    highlight.Name = "HumanoidTrackerHighlight"
    highlight.Adornee = target
    highlight.FillColor = accent
    highlight.FillTransparency = 0.88
    highlight.OutlineColor = accent
    highlight.OutlineTransparency = 0.08
    highlight.DepthMode = Enum.HighlightDepthMode.Occluded
    highlight.Parent = target
    targetHighlight = highlight

    container.Size = UDim2.fromScale(1.5, 1.5)
    TweenService:Create(container, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Size = UDim2.fromScale(1, 1)
    }):Play()
end

-----------------------------------------------------------------------
-- HUD
-----------------------------------------------------------------------
local function updateModeButtons()
    if not playerModeButton or not npcModeButton then
        return
    end

    local selectedColor = Color3.fromRGB(55, 105, 155)
    local idleColor = Color3.fromRGB(35, 39, 49)

    playerModeButton.BackgroundColor3 = targetMode == "PLAYER" and selectedColor or idleColor
    npcModeButton.BackgroundColor3 = targetMode == "NPC" and selectedColor or idleColor
end

local function updateHUDState()
    if not statusBadge then
        return
    end

    if isLocked and currentTarget then
        statusBadge.BackgroundColor3 = Color3.fromRGB(35, 105, 75)
        statusBadge.TextColor3 = Color3.fromRGB(255, 255, 255)
        statusBadge.Text = "LOCKED: " .. string.upper(getTargetDisplayName(currentTarget))
        if lockButton then lockButton.Text = "UNLOCK" end
    else
        statusBadge.BackgroundColor3 = Color3.fromRGB(28, 30, 38)
        statusBadge.TextColor3 = Color3.fromRGB(165, 175, 190)
        if targetMode == "NPC" and getTargetSearchText() == "" then
            statusBadge.Text = "NPC MODE: ENTER NPC MODEL NAME"
        elseif getTargetSearchText() ~= "" then
            statusBadge.Text = targetMode .. " MODE: READY TO LOCK"
        else
            statusBadge.Text = "PLAYER MODE: NEAREST PLAYER"
        end
        if lockButton then lockButton.Text = "LOCK" end
    end
end

local function makeModeButton(parent, name, text, position)
    local button = Instance.new("TextButton")
    button.Name = name
    button.Size = UDim2.fromOffset(92, 24)
    button.Position = position
    button.BackgroundColor3 = Color3.fromRGB(35, 39, 49)
    button.BorderSizePixel = 0
    button.Text = text
    button.Font = Enum.Font.GothamBold
    button.TextSize = 11
    button.TextColor3 = Color3.fromRGB(240, 245, 255)
    button.AutoButtonColor = true
    button.Parent = parent
    Instance.new("UICorner", button).CornerRadius = UDim.new(0, 6)
    return button
end

local function createHUD()
    local playerGui = localPlayer:WaitForChild("PlayerGui")
    local existing = playerGui:FindFirstChild("HumanoidTrackerHUD")
    if existing then
        existing:Destroy()
    end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "HumanoidTrackerHUD"
    screenGui.ResetOnSpawn = false
    screenGui.Parent = playerGui

    local panel = Instance.new("Frame")
    panel.Name = "TrackerPanel"
    panel.Size = UDim2.fromOffset(330, 142)
    panel.AnchorPoint = Vector2.new(1, 1)
    panel.Position = UDim2.new(1, -22, 1, -22)
    panel.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
    panel.BackgroundTransparency = 0.12
    panel.BorderSizePixel = 0
    panel.Parent = screenGui
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)

    local panelStroke = Instance.new("UIStroke")
    panelStroke.Color = Color3.fromRGB(60, 68, 82)
    panelStroke.Thickness = 1.3
    panelStroke.Parent = panel

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.Size = UDim2.new(1, -20, 0, 20)
    title.Position = UDim2.fromOffset(10, 7)
    title.BackgroundTransparency = 1
    title.Text = "HUMANOID TARGET TRACKER"
    title.Font = Enum.Font.GothamBlack
    title.TextSize = 13
    title.TextColor3 = Color3.fromRGB(235, 240, 250)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = panel

    playerModeButton = makeModeButton(panel, "PlayerModeButton", "PLAYER  [P]", UDim2.fromOffset(10, 32))
    npcModeButton = makeModeButton(panel, "NPCModeButton", "NPC NAME  [N]", UDim2.fromOffset(110, 32))

    targetNameBox = Instance.new("TextBox")
    targetNameBox.Name = "TargetNameBox"
    targetNameBox.Size = UDim2.new(1, -20, 0, 27)
    targetNameBox.Position = UDim2.fromOffset(10, 62)
    targetNameBox.BackgroundColor3 = Color3.fromRGB(31, 35, 44)
    targetNameBox.BorderSizePixel = 0
    targetNameBox.ClearTextOnFocus = false
    targetNameBox.Font = Enum.Font.Gotham
    targetNameBox.TextSize = 12
    targetNameBox.TextColor3 = Color3.fromRGB(245, 245, 250)
    targetNameBox.PlaceholderColor3 = Color3.fromRGB(135, 145, 160)
    targetNameBox.PlaceholderText = "Player username / NPC model name (NPC mode needs a name)"
    targetNameBox.Text = ""
    targetNameBox.TextXAlignment = Enum.TextXAlignment.Left
    targetNameBox.Parent = panel
    Instance.new("UICorner", targetNameBox).CornerRadius = UDim.new(0, 6)

    statusBadge = Instance.new("TextLabel")
    statusBadge.Name = "StatusBadge"
    statusBadge.Size = UDim2.new(1, -112, 0, 27)
    statusBadge.Position = UDim2.fromOffset(10, 103)
    statusBadge.BackgroundColor3 = Color3.fromRGB(28, 30, 38)
    statusBadge.BorderSizePixel = 0
    statusBadge.Font = Enum.Font.GothamBold
    statusBadge.TextSize = 10
    statusBadge.TextColor3 = Color3.fromRGB(165, 175, 190)
    statusBadge.Text = "PLAYER MODE: NEAREST PLAYER"
    statusBadge.TextTruncate = Enum.TextTruncate.AtEnd
    statusBadge.Parent = panel
    Instance.new("UICorner", statusBadge).CornerRadius = UDim.new(0, 6)

    lockButton = Instance.new("TextButton")
    lockButton.Name = "LockButton"
    lockButton.Size = UDim2.fromOffset(92, 27)
    lockButton.Position = UDim2.new(1, -102, 0, 103)
    lockButton.BackgroundColor3 = Color3.fromRGB(145, 45, 45)
    lockButton.BorderSizePixel = 0
    lockButton.Text = "LOCK"
    lockButton.Font = Enum.Font.GothamBlack
    lockButton.TextSize = 11
    lockButton.TextColor3 = Color3.new(1, 1, 1)
    lockButton.Parent = panel
    Instance.new("UICorner", lockButton).CornerRadius = UDim.new(0, 6)

    playerModeButton.MouseButton1Click:Connect(function()
        setTargetMode("PLAYER")
    end)
    npcModeButton.MouseButton1Click:Connect(function()
        setTargetMode("NPC")
    end)
    lockButton.MouseButton1Click:Connect(function()
        toggleLockOn()
    end)
    targetNameBox.FocusLost:Connect(function(enterPressed)
        updateHUDState()
        if enterPressed then
            if isLocked then
                unlockTarget()
            end
            toggleLockOn()
        end
    end)

    hudGui = screenGui
    updateModeButtons()
    updateHUDState()
end

setTargetMode = function(mode)
    if mode ~= "PLAYER" and mode ~= "NPC" then
        return
    end
    if isLocked and unlockTarget then
        unlockTarget()
    end
    targetMode = mode
    updateModeButtons()
    updateHUDState()
end

-----------------------------------------------------------------------
-- TARGET SEARCH
-----------------------------------------------------------------------
local function findBestTarget(ignoreCurrent)
    local myRoot = getLocalRoot()
    if not myRoot then
        return nil
    end

    local query = getTargetSearchText()
    if targetMode == "NPC" and query == "" then
        return nil
    end

    local camLook = (workspace.CurrentCamera or camera).CFrame.LookVector
    local candidates = {}

    local function considerModel(model, player)
        if not model or model == currentTarget and ignoreCurrent then
            return
        end
        if not isValidTarget(model) then
            return
        end

        local root = getCharacterRoot(model)
        if not root then
            return
        end

        local distanceVector = root.Position - myRoot.Position
        local distance = distanceVector.Magnitude
        if distance > CONFIG.MAX_LOCK_DISTANCE then
            return
        end

        local matchScore = 0
        if query ~= "" then
            if targetMode == "PLAYER" then
                matchScore = getNameMatchScore(player.Name, player.DisplayName, query)
            else
                matchScore = getNameMatchScore(model.Name, "", query)
            end
            if not matchScore then
                return
            end
        end

        local dot = 0
        if distance > 0.05 then
            dot = camLook:Dot(distanceVector.Unit)
        end

        -- Manual name matches are allowed even when the target is behind the camera.
        -- Blank PLAYER mode still prefers targets generally in front of the player.
        if query == "" and dot <= -0.2 then
            return
        end

        local score = (matchScore * 1000) + (dot * 50) - (distance * 0.8)
        table.insert(candidates, {
            model = model,
            score = score,
            distance = distance,
        })
    end

    if targetMode == "PLAYER" then
        -- Only actual Players in this server are considered in Player mode.
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= localPlayer and player.Character then
                considerModel(player.Character, player)
            end
        end
    else
        -- NPC mode: only independent, outermost humanoid Models are considered.
        for _, descendant in ipairs(workspace:GetDescendants()) do
            if descendant:IsA("Model")
                and getTargetPlayer(descendant) == nil
                and not isInsideLocalCharacter(descendant)
                and not hasHumanoidModelAncestor(descendant)
                and not isOwnedByLocalPlayer(descendant) then
                considerModel(descendant, nil)
            end
        end
    end

    if #candidates == 0 then
        return nil
    end

    table.sort(candidates, function(a, b)
        if a.score == b.score then
            return a.distance < b.distance
        end
        return a.score > b.score
    end)

    return candidates[1].model
end

-----------------------------------------------------------------------
-- CAMERA STABILIZATION
-----------------------------------------------------------------------
local function getTargetFocusPoint(target)
    local root = getCharacterRoot(target)
    local humanoid = getHumanoid(target)
    if not root or not humanoid then
        return nil
    end

    local verticalOffset = math.clamp(humanoid.HipHeight * 0.55, 0.8, 2.1)
    return root.Position + Vector3.new(0, verticalOffset, 0)
end

local function initializeCameraTracking(target)
    local myRoot = getLocalRoot()
    local targetRoot = getCharacterRoot(target)
    if not myRoot or not targetRoot then
        return
    end

    local difference = myRoot.Position - targetRoot.Position
    local flat = Vector3.new(difference.X, 0, difference.Z)

    if flat.Magnitude < CONFIG.MIN_DIRECTION_DISTANCE then
        local look = myRoot.CFrame.LookVector
        flat = Vector3.new(-look.X, 0, -look.Z)
    end

    if flat.Magnitude < 0.05 then
        flat = Vector3.new(0, 0, 1)
    end

    flat = flat.Unit
    cameraYaw = math.atan2(flat.X, flat.Z)
    smoothedFocus = getTargetFocusPoint(target)
    smoothedCameraDistance = currentZoom
end

local function updateLockCamera(dt, myRoot, targetRoot)
    local currentCamera = workspace.CurrentCamera
    if not currentCamera then
        return
    end
    camera = currentCamera

    local targetPosition = targetRoot.Position
    local myPosition = myRoot.Position

    -- Update horizontal direction only when there is enough separation.
    -- This prevents the direction vector from flipping around at point-blank range.
    local difference = myPosition - targetPosition
    local flatDifference = Vector3.new(difference.X, 0, difference.Z)
    if flatDifference.Magnitude > CONFIG.MIN_DIRECTION_DISTANCE then
        local desiredYaw = math.atan2(flatDifference.X, flatDifference.Z)
        local yawDelta = wrapAngle(desiredYaw - cameraYaw)
        local maxStep = CONFIG.CAMERA_YAW_SPEED * dt
        cameraYaw = cameraYaw + math.clamp(yawDelta, -maxStep, maxStep)
    end

    local alpha = 1 - math.exp(-CONFIG.CAMERA_SMOOTH_SPEED * dt)
    local targetFocus = getTargetFocusPoint(currentTarget)
    if not targetFocus then
        return
    end
    smoothedFocus = smoothedFocus and smoothedFocus:Lerp(targetFocus, alpha) or targetFocus

    local flatDirection = Vector3.new(math.sin(cameraYaw), 0, math.cos(cameraYaw))
    local rightDirection = Vector3.new(0, 1, 0):Cross(flatDirection)
    if rightDirection.Magnitude > 0.001 then
        rightDirection = rightDirection.Unit
    else
        rightDirection = Vector3.new(1, 0, 0)
    end

    local horizontalOffset = flatDirection * currentZoom + rightDirection * CONFIG.SHOULDER_OFFSET
    local pitchRadians = math.rad(CONFIG.CAMERA_PITCH_DEGREES)
    local verticalOffset = horizontalOffset.Magnitude * math.tan(pitchRadians)
    local offset = Vector3.new(horizontalOffset.X, verticalOffset, horizontalOffset.Z)

    -- Keep the fixed camera angle when avoiding walls by scaling the whole offset.
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    local exclusions = { currentTarget }
    if localPlayer.Character then
        table.insert(exclusions, localPlayer.Character)
    end
    rayParams.FilterDescendantsInstances = exclusions
    rayParams.IgnoreWater = true

    local rayHit = workspace:Raycast(smoothedFocus, offset, rayParams)
    local desiredDistance = currentZoom
    if rayHit then
        local hitFraction = math.clamp((rayHit.Distance - 0.65) / math.max(offset.Magnitude, 0.01), 0.2, 1)
        desiredDistance = currentZoom * hitFraction
    end

    smoothedCameraDistance = smoothedCameraDistance + (desiredDistance - smoothedCameraDistance) * alpha

    horizontalOffset = flatDirection * smoothedCameraDistance + rightDirection * (CONFIG.SHOULDER_OFFSET * (smoothedCameraDistance / currentZoom))
    verticalOffset = horizontalOffset.Magnitude * math.tan(pitchRadians)
    local cameraPosition = smoothedFocus + Vector3.new(horizontalOffset.X, verticalOffset, horizontalOffset.Z)

    -- Fixed pitch plus smoothed focus/yaw prevents 180-degree flips and close-range shake.
    camera.CFrame = CFrame.lookAt(cameraPosition, smoothedFocus, Vector3.new(0, 1, 0))
    camera.Focus = CFrame.new(smoothedFocus)
end

-----------------------------------------------------------------------
-- LOCK / UNLOCK
-----------------------------------------------------------------------
lockTarget = function(target)
    if not isValidTarget(target) then
        return
    end

    local wasLocked = isLocked
    local currentCamera = workspace.CurrentCamera
    if not currentCamera then
        return
    end
    camera = currentCamera

    if not wasLocked then
        cameraTypeBeforeLock = camera.CameraType
        cameraSubjectBeforeLock = camera.CameraSubject
    end

    currentTarget = target
    isLocked = true

    local root = getCharacterRoot(target)
    if not root then
        isLocked = false
        currentTarget = nil
        return
    end

    createReticle(target, root)
    initializeCameraTracking(target)

    -- Keep the existing camera type so a separate shift-lock function can
    -- continue running. This tracker writes its CFrame after the normal
    -- camera update (Camera priority + 1) while the lock is active.
    playLockSound()
    updateHUDState()
end

unlockTarget = function()
    if not isLocked then
        return
    end

    isLocked = false
    currentTarget = nil
    destroyTargetVisuals()

    local currentCamera = workspace.CurrentCamera
    if currentCamera then
        camera = currentCamera
        camera.CameraType = cameraTypeBeforeLock or Enum.CameraType.Custom
        if cameraSubjectBeforeLock and cameraSubjectBeforeLock.Parent then
            camera.CameraSubject = cameraSubjectBeforeLock
        end
    end

    cameraTypeBeforeLock = nil
    cameraSubjectBeforeLock = nil
    cameraYaw = nil
    smoothedFocus = nil
    smoothedCameraDistance = currentZoom

    playUnlockSound()
    updateHUDState()
end

toggleLockOn = function()
    if isLocked then
        unlockTarget()
        return
    end

    local target = findBestTarget(false)
    if target then
        lockTarget(target)
    elseif statusBadge then
        if targetMode == "NPC" and getTargetSearchText() == "" then
            statusBadge.Text = "ENTER AN NPC MODEL NAME FIRST"
        elseif getTargetSearchText() ~= "" then
            statusBadge.Text = "NO MATCHING " .. targetMode .. " FOUND IN RANGE"
        else
            statusBadge.Text = "NO OTHER PLAYER IN RANGE"
        end
        task.delay(1.4, function()
            if not isLocked then
                updateHUDState()
            end
        end)
    end
end

switchTarget = function()
    if not isLocked then
        toggleLockOn()
        return
    end

    local nextTarget = findBestTarget(true)
    if nextTarget and nextTarget ~= currentTarget then
        lockTarget(nextTarget)
    end
end

-----------------------------------------------------------------------
-- RENDER UPDATE
-----------------------------------------------------------------------
RunService:BindToRenderStep(
    "HumanoidTargetTrackerCamera",
    Enum.RenderPriority.Camera.Value + 1,
    function(dt)
        if not isLocked or not currentTarget then
            return
        end

        if not isValidTarget(currentTarget) then
            unlockTarget()
            return
        end

        local myRoot = getLocalRoot()
        local targetRoot = getCharacterRoot(currentTarget)
        if not myRoot or not targetRoot then
            unlockTarget()
            return
        end

        local distance = (targetRoot.Position - myRoot.Position).Magnitude
        if distance > CONFIG.BREAK_LOCK_DISTANCE then
            unlockTarget()
            return
        end

        if reticleBillboard and reticleBillboard:FindFirstChild("Container") then
            local container = reticleBillboard.Container
            local infoLabel = container:FindFirstChild("InfoLabel")
            if infoLabel then
                infoLabel.Text = string.format("%s  [%d STUDS]", string.upper(getTargetDisplayName(currentTarget)), math.floor(distance))
            end

            local diamond = container:FindFirstChild("CenterDiamond")
            if diamond then
                diamond.Rotation = 45 + math.sin(os.clock() * 3) * 5
            end
        end

        updateLockCamera(dt, myRoot, targetRoot)
    end
)

-----------------------------------------------------------------------
-- INPUT
-----------------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then
        return
    end

    if input.KeyCode == Enum.KeyCode.ButtonR3 then
        toggleLockOn()
    elseif input.KeyCode == Enum.KeyCode.ButtonL3 then
        switchTarget()
    elseif input.KeyCode == Enum.KeyCode.X or input.KeyCode == Enum.KeyCode.Q then
        toggleLockOn()
    elseif input.KeyCode == Enum.KeyCode.Tab then
        switchTarget()
    elseif input.KeyCode == Enum.KeyCode.P then
        setTargetMode("PLAYER")
    elseif input.KeyCode == Enum.KeyCode.N then
        setTargetMode("NPC")
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if not isLocked then
        return
    end

    if input.UserInputType == Enum.UserInputType.MouseWheel then
        currentZoom = math.clamp(
            currentZoom - input.Position.Z * 1.5,
            CONFIG.MIN_ZOOM,
            CONFIG.MAX_ZOOM
        )
    end
end)

localPlayer.CharacterAdded:Connect(function()
    if isLocked then
        unlockTarget()
    end
end)

createHUD()
