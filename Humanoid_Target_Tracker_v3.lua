--[[
    HUMANOID TARGET TRACKER v3 - SERVER PLAYER PICKER + NPC NAME TRACKING

    LocalScript for Roblox.

    PLAYER MODE:
      - Open the player picker and choose a player currently in this server.
      - Tracks that Player by UserId, so it can follow their new character after respawn.
      - Does not automatically unlock just because the player moves far away.

    NPC MODE:
      - Enter an NPC Model name (exact or partial) and lock it.
      - Searches Workspace descendants while excluding your own character,
        nested humanoid models, and NPCs marked as owned by you.

    CAMERA:
      - Normal range: fixed 30-degree downward camera pitch (shallower than 60).
      - Close range: smoothly blends to the original player-relative camera framing.
      - Keeps yaw stable when characters overlap to prevent 180-degree flips/shake.
      - Does not change CameraType, so a separate Shift Lock LocalScript can still run.

    CONTROLS:
      - X / Q or R3 : Lock / unlock
      - Tab / L3     : Select next player / next matching NPC
      - P            : Player mode
      - N            : NPC-name mode
      - Mouse wheel  : Camera distance

    NOTE:
      - This is client-side. It can track players/NPCs replicated to this client
        in the current server. It cannot access characters in other servers.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")

local localPlayer = Players.LocalPlayer
local camera = workspace.CurrentCamera

local CONFIG = {
    -- NPC acquisition range only. A manually selected server player is not
    -- rejected just for being farther away (subject to client streaming).
    MAX_NPC_ACQUIRE_DISTANCE = 500,

    CAMERA_SMOOTH_SPEED = 9,
    CAMERA_YAW_SPEED = math.rad(115),
    CAMERA_PITCH_DEGREES = 30, -- fixed downward pitch during normal-range tracking
    CAMERA_HEIGHT = 3.0,       -- used by the original close-range camera framing
    CAMERA_DISTANCE = 13.5,
    MIN_ZOOM = 7,
    MAX_ZOOM = 22,
    SHOULDER_OFFSET = 1.0,
    MIN_DIRECTION_DISTANCE = 4.5,

    -- The original player-relative camera is blended in only at close range.
    CLOSE_RANGE_FULL_OLD_CAMERA = 5,
    CLOSE_RANGE_NO_OLD_CAMERA = 14,

    RETICLE_COLOR_PLAYER = Color3.fromRGB(70, 210, 255),
    RETICLE_COLOR_NPC = Color3.fromRGB(255, 75, 75),
}

local isLocked = false
local currentTarget = nil
local currentTargetPlayer = nil
local currentTargetMode = nil
local currentZoom = CONFIG.CAMERA_DISTANCE
local targetMode = "PLAYER"
local selectedPlayerUserId = nil
local waitingForPlayerCharacter = false

local reticleBillboard = nil
local targetHighlight = nil
local hudGui = nil
local statusBadge = nil
local playerModeButton = nil
local npcModeButton = nil
local playerPickerButton = nil
local playerListFrame = nil
local targetNameBox = nil
local lockButton = nil

local cameraTypeBeforeLock = nil
local cameraSubjectBeforeLock = nil
local cameraYaw = nil
local smoothedFocus = nil
local smoothedCameraCFrame = nil
local smoothedCameraDistance = currentZoom

local toggleLockOn
local switchTarget
local lockTarget
local unlockTarget
local setTargetMode
local refreshPlayerList

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

local function smoothStep01(value)
    local x = math.clamp(value, 0, 1)
    return x * x * (3 - 2 * x)
end

local function getHumanoid(model)
    if not model or not model:IsA("Model") then
        return nil
    end
    return model:FindFirstChildOfClass("Humanoid")
end

local function getCharacterRoot(model)
    if not model or not model:IsA("Model") then
        return nil
    end

    local humanoid = getHumanoid(model)
    local root = (humanoid and humanoid.RootPart)
        or model:FindFirstChild("HumanoidRootPart")
        or model.PrimaryPart

    if root and root:IsA("BasePart") and root:IsDescendantOf(model) then
        return root
    end
    return nil
end

local function getLocalRoot()
    local character = localPlayer.Character
    if not character then
        return nil
    end
    return getCharacterRoot(character)
end

local function getTargetPlayer(model)
    if not model then
        return nil
    end
    return Players:GetPlayerFromCharacter(model)
end

local function getSelectedPlayer()
    if not selectedPlayerUserId then
        return nil
    end
    return Players:GetPlayerByUserId(selectedPlayerUserId)
end

local function isInsideLocalCharacter(model)
    local character = localPlayer.Character
    return character ~= nil and (model == character or model:IsDescendantOf(character))
end

-- Exclude NPCs/pets that the game explicitly marks as belonging to this player.
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

-- Only the outer humanoid Model is targetable, not humanoid sub-models
-- embedded inside another character/NPC.
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
    if not humanoid or humanoid.Health <= 0 or not root then
        return false
    end

    return getLocalRoot() ~= nil
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

    local highlight = Instance.new("Highlight")
    highlight.Name = "HumanoidTrackerHighlight"
    highlight.Adornee = target
    highlight.FillColor = accent
    highlight.FillTransparency = 0.9
    highlight.OutlineColor = accent
    highlight.OutlineTransparency = 0.08
    highlight.DepthMode = Enum.HighlightDepthMode.Occluded
    highlight.Parent = target
    targetHighlight = highlight

    container.Size = UDim2.fromScale(1.35, 1.35)
    TweenService:Create(container, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Size = UDim2.fromScale(1, 1)
    }):Play()
end

-----------------------------------------------------------------------
-- HUD + LIVE SERVER PLAYER PICKER
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

local function updatePlayerPickerText()
    if not playerPickerButton then
        return
    end

    local selected = getSelectedPlayer()
    if selected then
        playerPickerButton.Text = "TARGET PLAYER: " .. selected.DisplayName .. "  (@" .. selected.Name .. ")  ▼"
    else
        playerPickerButton.Text = "SELECT A PLAYER IN THIS SERVER  ▼"
    end
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
        if targetMode == "NPC" then
            statusBadge.Text = getTargetSearchText() == "" and "ENTER NPC MODEL NAME" or "NPC MODE: READY TO LOCK"
        elseif not getSelectedPlayer() then
            statusBadge.Text = "SELECT A SERVER PLAYER FIRST"
        else
            statusBadge.Text = "PLAYER SELECTED: READY TO LOCK"
        end
        if lockButton then lockButton.Text = "LOCK" end
    end
end

local function makeModeButton(parent, name, text, position, width)
    local button = Instance.new("TextButton")
    button.Name = name
    button.Size = UDim2.fromOffset(width or 150, 25)
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

local function setSelectedPlayer(player)
    if not player or player == localPlayer then
        return
    end

    selectedPlayerUserId = player.UserId
    updatePlayerPickerText()

    if playerListFrame then
        playerListFrame.Visible = false
    end

    if isLocked and currentTargetMode == "PLAYER" then
        if player.Character and isValidTarget(player.Character) then
            lockTarget(player.Character)
        else
            unlockTarget()
        end
    end

    updateHUDState()
end

refreshPlayerList = function()
    if not playerListFrame then
        return
    end

    for _, child in ipairs(playerListFrame:GetChildren()) do
        if child:IsA("GuiButton") or child:IsA("TextLabel") then
            child:Destroy()
        end
    end

    local serverPlayers = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= localPlayer then
            table.insert(serverPlayers, player)
        end
    end
    table.sort(serverPlayers, function(a, b)
        return string.lower(a.Name) < string.lower(b.Name)
    end)

    local rowHeight = 28
    if #serverPlayers == 0 then
        local empty = Instance.new("TextLabel")
        empty.Size = UDim2.new(1, -8, 0, rowHeight)
        empty.BackgroundTransparency = 1
        empty.Text = "No other players are currently in this server"
        empty.TextColor3 = Color3.fromRGB(170, 180, 195)
        empty.Font = Enum.Font.Gotham
        empty.TextSize = 11
        empty.Parent = playerListFrame
    else
        for index, player in ipairs(serverPlayers) do
            local button = Instance.new("TextButton")
            button.Name = "PlayerChoice_" .. tostring(player.UserId)
            button.Size = UDim2.new(1, -8, 0, rowHeight)
            button.Position = UDim2.fromOffset(4, (index - 1) * (rowHeight + 3))
            button.BackgroundColor3 = player.UserId == selectedPlayerUserId
                and Color3.fromRGB(48, 85, 115)
                or Color3.fromRGB(37, 42, 52)
            button.BorderSizePixel = 0
            button.Text = player.DisplayName .. "   (@" .. player.Name .. ")"
            button.TextColor3 = Color3.fromRGB(240, 245, 255)
            button.TextSize = 11
            button.Font = Enum.Font.GothamBold
            button.TextXAlignment = Enum.TextXAlignment.Left
            button.AutoButtonColor = true
            button.Parent = playerListFrame
            Instance.new("UICorner", button).CornerRadius = UDim.new(0, 5)

            button.MouseButton1Click:Connect(function()
                setSelectedPlayer(player)
            end)
        end
    end

    playerListFrame.CanvasSize = UDim2.fromOffset(0, math.max(86, #serverPlayers * (rowHeight + 3)))
    updatePlayerPickerText()
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
    panel.Size = UDim2.fromOffset(365, 222)
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

    playerModeButton = makeModeButton(panel, "PlayerModeButton", "PLAYER  [P]", UDim2.fromOffset(10, 32), 165)
    npcModeButton = makeModeButton(panel, "NPCModeButton", "NPC NAME  [N]", UDim2.fromOffset(185, 32), 170)

    playerPickerButton = Instance.new("TextButton")
    playerPickerButton.Name = "PlayerPickerButton"
    playerPickerButton.Size = UDim2.new(1, -20, 0, 27)
    playerPickerButton.Position = UDim2.fromOffset(10, 63)
    playerPickerButton.BackgroundColor3 = Color3.fromRGB(31, 42, 55)
    playerPickerButton.BorderSizePixel = 0
    playerPickerButton.Text = "SELECT A PLAYER IN THIS SERVER  ▼"
    playerPickerButton.TextColor3 = Color3.fromRGB(245, 245, 250)
    playerPickerButton.TextSize = 11
    playerPickerButton.Font = Enum.Font.GothamBold
    playerPickerButton.TextTruncate = Enum.TextTruncate.AtEnd
    playerPickerButton.Parent = panel
    Instance.new("UICorner", playerPickerButton).CornerRadius = UDim.new(0, 6)

    targetNameBox = Instance.new("TextBox")
    targetNameBox.Name = "NPCNameBox"
    targetNameBox.Size = UDim2.new(1, -20, 0, 27)
    targetNameBox.Position = UDim2.fromOffset(10, 63)
    targetNameBox.BackgroundColor3 = Color3.fromRGB(31, 35, 44)
    targetNameBox.BorderSizePixel = 0
    targetNameBox.ClearTextOnFocus = false
    targetNameBox.Font = Enum.Font.Gotham
    targetNameBox.TextSize = 12
    targetNameBox.TextColor3 = Color3.fromRGB(245, 245, 250)
    targetNameBox.PlaceholderColor3 = Color3.fromRGB(135, 145, 160)
    targetNameBox.PlaceholderText = "Enter NPC Model name (exact or partial)"
    targetNameBox.Text = ""
    targetNameBox.TextXAlignment = Enum.TextXAlignment.Left
    targetNameBox.Visible = false
    targetNameBox.Parent = panel
    Instance.new("UICorner", targetNameBox).CornerRadius = UDim.new(0, 6)

    playerListFrame = Instance.new("ScrollingFrame")
    playerListFrame.Name = "PlayerList"
    playerListFrame.Size = UDim2.new(1, -20, 0, 84)
    playerListFrame.Position = UDim2.fromOffset(10, 94)
    playerListFrame.BackgroundColor3 = Color3.fromRGB(24, 28, 36)
    playerListFrame.BorderSizePixel = 0
    playerListFrame.ScrollBarThickness = 5
    playerListFrame.CanvasSize = UDim2.fromOffset(0, 86)
    playerListFrame.Visible = false
    playerListFrame.ZIndex = 5
    playerListFrame.Parent = panel
    Instance.new("UICorner", playerListFrame).CornerRadius = UDim.new(0, 6)

    statusBadge = Instance.new("TextLabel")
    statusBadge.Name = "StatusBadge"
    statusBadge.Size = UDim2.new(1, -112, 0, 27)
    statusBadge.Position = UDim2.fromOffset(10, 185)
    statusBadge.BackgroundColor3 = Color3.fromRGB(28, 30, 38)
    statusBadge.BorderSizePixel = 0
    statusBadge.Font = Enum.Font.GothamBold
    statusBadge.TextSize = 10
    statusBadge.TextColor3 = Color3.fromRGB(165, 175, 190)
    statusBadge.Text = "SELECT A SERVER PLAYER FIRST"
    statusBadge.TextTruncate = Enum.TextTruncate.AtEnd
    statusBadge.Parent = panel
    Instance.new("UICorner", statusBadge).CornerRadius = UDim.new(0, 6)

    lockButton = Instance.new("TextButton")
    lockButton.Name = "LockButton"
    lockButton.Size = UDim2.fromOffset(92, 27)
    lockButton.Position = UDim2.new(1, -102, 0, 185)
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
    playerPickerButton.MouseButton1Click:Connect(function()
        if targetMode ~= "PLAYER" then
            setTargetMode("PLAYER")
        end
        playerListFrame.Visible = not playerListFrame.Visible
        if playerListFrame.Visible then
            refreshPlayerList()
        end
    end)
    lockButton.MouseButton1Click:Connect(function()
        toggleLockOn()
    end)
    targetNameBox.FocusLost:Connect(function(enterPressed)
        updateHUDState()
        if enterPressed and targetMode == "NPC" then
            if isLocked then
                unlockTarget()
            end
            toggleLockOn()
        end
    end)

    hudGui = screenGui
    refreshPlayerList()
    updateModeButtons()
    updateHUDState()
end

setTargetMode = function(mode)
    if mode ~= "PLAYER" and mode ~= "NPC" then
        return
    end
    if isLocked then
        unlockTarget()
    end

    targetMode = mode
    if playerPickerButton then
        playerPickerButton.Visible = mode == "PLAYER"
    end
    if targetNameBox then
        targetNameBox.Visible = mode == "NPC"
    end
    if playerListFrame then
        playerListFrame.Visible = false
    end

    updateModeButtons()
    updateHUDState()
end

-----------------------------------------------------------------------
-- TARGET SEARCH
-----------------------------------------------------------------------
local function findBestTarget(ignoreCurrent)
    if targetMode == "PLAYER" then
        local selected = getSelectedPlayer()
        if not selected or selected == localPlayer then
            return nil
        end
        local character = selected.Character
        if character and (not ignoreCurrent or character ~= currentTarget) and isValidTarget(character) then
            return character
        end
        return nil
    end

    local query = getTargetSearchText()
    if query == "" then
        return nil
    end

    local myRoot = getLocalRoot()
    if not myRoot then
        return nil
    end

    local candidates = {}
    for _, descendant in ipairs(workspace:GetDescendants()) do
        if descendant:IsA("Model")
            and getTargetPlayer(descendant) == nil
            and not isInsideLocalCharacter(descendant)
            and not hasHumanoidModelAncestor(descendant)
            and not isOwnedByLocalPlayer(descendant)
            and (not ignoreCurrent or descendant ~= currentTarget)
            and isValidTarget(descendant) then

            local matchScore = getNameMatchScore(descendant.Name, "", query)
            if matchScore then
                local root = getCharacterRoot(descendant)
                local distance = (root.Position - myRoot.Position).Magnitude
                if distance <= CONFIG.MAX_NPC_ACQUIRE_DISTANCE then
                    table.insert(candidates, {
                        model = descendant,
                        score = matchScore * 1000 - distance,
                        distance = distance,
                    })
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        if a.score == b.score then
            return a.distance < b.distance
        end
        return a.score > b.score
    end)

    return candidates[1] and candidates[1].model or nil
end

local function getOtherServerPlayers()
    local result = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= localPlayer then
            table.insert(result, player)
        end
    end
    table.sort(result, function(a, b)
        return string.lower(a.Name) < string.lower(b.Name)
    end)
    return result
end

local function cycleSelectedPlayer()
    local list = getOtherServerPlayers()
    if #list == 0 then
        return nil
    end

    local currentIndex = 0
    for index, player in ipairs(list) do
        if player.UserId == selectedPlayerUserId then
            currentIndex = index
            break
        end
    end

    local nextIndex = (currentIndex % #list) + 1
    setSelectedPlayer(list[nextIndex])
    return list[nextIndex]
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

    -- Stable torso-level point; avoid tracking animated head/limb positions.
    local verticalOffset = math.clamp(humanoid.HipHeight * 0.45, 0.8, 1.6)
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
    smoothedCameraCFrame = nil
    smoothedCameraDistance = currentZoom
end

local function applyCameraCollision(origin, desiredPosition, excludedModels)
    local direction = desiredPosition - origin
    if direction.Magnitude < 0.05 then
        return desiredPosition
    end

    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = excludedModels
    rayParams.IgnoreWater = true

    local hit = workspace:Raycast(origin, direction, rayParams)
    if hit then
        return hit.Position + hit.Normal * 0.55
    end
    return desiredPosition
end

local function updateLockCamera(dt, myRoot, targetRoot)
    local currentCamera = workspace.CurrentCamera
    if not currentCamera then
        return
    end
    camera = currentCamera

    local myPosition = myRoot.Position
    local targetPosition = targetRoot.Position
    local toPlayer = myPosition - targetPosition
    local flatDifference = Vector3.new(toPlayer.X, 0, toPlayer.Z)

    -- Freeze camera yaw when characters overlap. This avoids the direction
    -- vector rapidly flipping around during close combat / special moves.
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

    local excluded = { currentTarget }
    if localPlayer.Character then
        table.insert(excluded, localPlayer.Character)
    end

    -- NORMAL RANGE: camera orbits around the target with a constant, shallower
    -- downward angle. Target/player height does not alter this pitch.
    local normalHorizontal = flatDirection * currentZoom + rightDirection * CONFIG.SHOULDER_OFFSET
    local pitchRadians = math.rad(CONFIG.CAMERA_PITCH_DEGREES)
    local normalVertical = normalHorizontal.Magnitude * math.tan(pitchRadians)
    local normalPosition = smoothedFocus + Vector3.new(
        normalHorizontal.X,
        normalVertical,
        normalHorizontal.Z
    )
    normalPosition = applyCameraCollision(smoothedFocus, normalPosition, excluded)
    local normalCFrame = CFrame.lookAt(normalPosition, smoothedFocus, Vector3.new(0, 1, 0))

    -- CLOSE RANGE: blend in the original player-relative camera system only
    -- while the target is nearby. It is blended smoothly to avoid a camera snap.
    local oldCameraPosition = myPosition
        + flatDirection * currentZoom
        + Vector3.new(0, CONFIG.CAMERA_HEIGHT, 0)
        + rightDirection * CONFIG.SHOULDER_OFFSET
    local oldCameraOrigin = myPosition + Vector3.new(0, CONFIG.CAMERA_HEIGHT * 0.65, 0)
    oldCameraPosition = applyCameraCollision(oldCameraOrigin, oldCameraPosition, excluded)
    local closeCFrame = CFrame.lookAt(oldCameraPosition, smoothedFocus, Vector3.new(0, 1, 0))

    local distance = (targetPosition - myPosition).Magnitude
    local closeT = 1 - (
        (distance - CONFIG.CLOSE_RANGE_FULL_OLD_CAMERA)
        / (CONFIG.CLOSE_RANGE_NO_OLD_CAMERA - CONFIG.CLOSE_RANGE_FULL_OLD_CAMERA)
    )
    local closeBlend = smoothStep01(closeT)
    local desiredCFrame = normalCFrame:Lerp(closeCFrame, closeBlend)

    -- Smooth the final CFrame as well as the focus point, reducing shaking from
    -- root motion and animation updates.
    smoothedCameraCFrame = smoothedCameraCFrame
        and smoothedCameraCFrame:Lerp(desiredCFrame, alpha)
        or desiredCFrame

    camera.CFrame = smoothedCameraCFrame
    camera.Focus = CFrame.new(smoothedFocus)
end

-----------------------------------------------------------------------
-- LOCK / UNLOCK
-----------------------------------------------------------------------
lockTarget = function(target)
    if not isValidTarget(target) then
        return
    end

    local currentCamera = workspace.CurrentCamera
    if not currentCamera then
        return
    end
    camera = currentCamera

    if not isLocked then
        cameraTypeBeforeLock = camera.CameraType
        cameraSubjectBeforeLock = camera.CameraSubject
    end

    currentTarget = target
    currentTargetPlayer = getTargetPlayer(target)
    currentTargetMode = currentTargetPlayer and "PLAYER" or "NPC"
    waitingForPlayerCharacter = false
    isLocked = true

    local root = getCharacterRoot(target)
    if not root then
        isLocked = false
        currentTarget = nil
        currentTargetPlayer = nil
        currentTargetMode = nil
        return
    end

    createReticle(target, root)
    initializeCameraTracking(target)
    playLockSound()
    updateHUDState()
end

unlockTarget = function()
    if not isLocked then
        return
    end

    isLocked = false
    currentTarget = nil
    currentTargetPlayer = nil
    currentTargetMode = nil
    waitingForPlayerCharacter = false
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
    smoothedCameraCFrame = nil
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
        elseif targetMode == "PLAYER" and not getSelectedPlayer() then
            statusBadge.Text = "PICK A PLAYER FROM THE LIST"
        elseif targetMode == "PLAYER" then
            statusBadge.Text = "PLAYER CHARACTER NOT LOADED YET"
        else
            statusBadge.Text = "NO MATCHING NPC FOUND"
        end
        task.delay(1.5, function()
            if not isLocked then
                updateHUDState()
            end
        end)
    end
end

switchTarget = function()
    if targetMode == "PLAYER" then
        local wasLocked = isLocked
        local nextPlayer = cycleSelectedPlayer()
        -- setSelectedPlayer already retargets an active player lock. When
        -- currently unlocked, acquire the newly selected player once.
        if nextPlayer and not wasLocked then
            toggleLockOn()
        end
        return
    end

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
local renderBindingName = "HumanoidTargetTrackerCamera_" .. tostring(localPlayer.UserId)
pcall(function()
    RunService:UnbindFromRenderStep(renderBindingName)
end)

RunService:BindToRenderStep(
    renderBindingName,
    Enum.RenderPriority.Camera.Value + 1,
    function(dt)
        if not isLocked then
            return
        end

        -- PLAYER LOCKS ARE HELD BY PLAYER INSTANCE / USERID, NOT BY ONE
        -- CHARACTER MODEL. This survives target death/respawn and brief streaming.
        if currentTargetMode == "PLAYER" then
            if not currentTargetPlayer or currentTargetPlayer.Parent ~= Players then
                unlockTarget()
                return
            end

            local latestCharacter = currentTargetPlayer.Character
            if not latestCharacter or not isValidTarget(latestCharacter) then
                if not waitingForPlayerCharacter then
                    destroyTargetVisuals()
                    waitingForPlayerCharacter = true
                    if statusBadge then
                        statusBadge.Text = "WAITING FOR PLAYER CHARACTER..."
                    end
                end
                return
            end

            if latestCharacter ~= currentTarget then
                currentTarget = latestCharacter
                waitingForPlayerCharacter = false
                local newRoot = getCharacterRoot(latestCharacter)
                createReticle(latestCharacter, newRoot)
                initializeCameraTracking(latestCharacter)
                updateHUDState()
            elseif waitingForPlayerCharacter then
                waitingForPlayerCharacter = false
                local newRoot = getCharacterRoot(latestCharacter)
                createReticle(latestCharacter, newRoot)
                initializeCameraTracking(latestCharacter)
                updateHUDState()
            end
        else
            -- NPCs are only unlocked when they are actually gone or dead.
            -- Distance is not used as a timeout after the initial name-based lock.
            if not currentTarget or not currentTarget:IsDescendantOf(workspace) then
                unlockTarget()
                return
            end
            local npcHumanoid = getHumanoid(currentTarget)
            if not npcHumanoid or npcHumanoid.Health <= 0 then
                unlockTarget()
                return
            end
        end

        local myRoot = getLocalRoot()
        local targetRoot = getCharacterRoot(currentTarget)
        if not myRoot or not targetRoot then
            return -- temporarily unavailable; preserve the lock instead of killing it
        end

        if reticleBillboard and reticleBillboard:FindFirstChild("Container") then
            local container = reticleBillboard.Container
            local infoLabel = container:FindFirstChild("InfoLabel")
            if infoLabel then
                local distance = (targetRoot.Position - myRoot.Position).Magnitude
                infoLabel.Text = string.format(
                    "%s  [%d STUDS]",
                    string.upper(getTargetDisplayName(currentTarget)),
                    math.floor(distance)
                )
            end

            local diamond = container:FindFirstChild("CenterDiamond")
            if diamond then
                diamond.Rotation = 45 + math.sin(os.clock() * 2.5) * 3
            end
        end

        updateLockCamera(dt, myRoot, targetRoot)
    end
)

-----------------------------------------------------------------------
-- INPUT + PLAYER LIST LIFECYCLE
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

Players.PlayerAdded:Connect(function()
    refreshPlayerList()
end)

Players.PlayerRemoving:Connect(function(player)
    if selectedPlayerUserId == player.UserId then
        selectedPlayerUserId = nil
        updatePlayerPickerText()
        if isLocked and currentTargetPlayer == player then
            unlockTarget()
        end
    end
    refreshPlayerList()
    updateHUDState()
end)

localPlayer.CharacterAdded:Connect(function()
    if isLocked then
        unlockTarget()
    end
end)

createHUD()

if script then
    script.Destroying:Connect(function()
        pcall(function()
            RunService:UnbindFromRenderStep(renderBindingName)
        end)
        if isLocked then
            unlockTarget()
        end
    end)
end
