--[[
    HUMANOID TARGET TRACKER v4 - LIVE SERVER ROSTER + TWO-CHARACTER CAMERA

    LocalScript for Roblox.

    PLAYER MODE:
      - Live server roster is always visible in PLAYER mode; click a player to select.
      - Tracks that Player by UserId, so it can follow their new character after respawn.
      - Does not automatically unlock just because the player moves far away.

    NPC MODE:
      - Enter an NPC Model name (exact or partial) and lock it.
      - Searches Workspace descendants while excluding your own character,
        nested humanoid models, and NPCs marked as owned by you.

    CAMERA:
      - Normal range: fixed 22-degree downward camera pitch; frames BOTH characters.
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

    CAMERA_SMOOTH_SPEED = 10,
    CAMERA_YAW_SPEED = math.rad(95),
    CAMERA_PITCH_DEGREES = 22, -- fixed downward pitch during normal-range tracking
    CAMERA_HEIGHT = 3.0,       -- used by the original close-range camera framing
    CAMERA_DISTANCE = 13.5,
    MIN_ZOOM = 7,
    MAX_ZOOM = 22,
    SHOULDER_OFFSET = 1.0,
    MIN_DIRECTION_DISTANCE = 4.5,

    -- The original player-relative camera is blended in only at close range.
    CLOSE_RANGE_FULL_OLD_CAMERA = 5,
    CLOSE_RANGE_NO_OLD_CAMERA = 12,

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
local playerPickerButton = nil -- retained for compatibility; roster is now always visible
local playerListFrame = nil
local playerSearchBox = nil
local playerCountLabel = nil
local playerListLayout = nil
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
local beginPlayerTarget

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

    return true
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
-- MODERN HUD + ALWAYS-VISIBLE LIVE SERVER ROSTER
-----------------------------------------------------------------------
local UI = {
    panel = Color3.fromRGB(14, 18, 27),
    panel2 = Color3.fromRGB(22, 29, 42),
    row = Color3.fromRGB(27, 36, 51),
    rowHover = Color3.fromRGB(37, 52, 72),
    text = Color3.fromRGB(237, 244, 255),
    muted = Color3.fromRGB(143, 160, 182),
    cyan = Color3.fromRGB(65, 205, 255),
    violet = Color3.fromRGB(155, 125, 255),
    green = Color3.fromRGB(73, 220, 157),
    red = Color3.fromRGB(255, 95, 112),
}

local function addCorner(instance, radius)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, radius or 8)
    corner.Parent = instance
    return corner
end

local function addStroke(instance, color, transparency, thickness)
    local stroke = Instance.new("UIStroke")
    stroke.Color = color or UI.cyan
    stroke.Transparency = transparency or 0.65
    stroke.Thickness = thickness or 1
    stroke.Parent = instance
    return stroke
end

local function makeLabel(parent, name, text, position, size, fontSize, color, font)
    local label = Instance.new("TextLabel")
    label.Name = name
    label.Position = position
    label.Size = size
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = color or UI.text
    label.Font = font or Enum.Font.Gotham
    label.TextSize = fontSize or 11
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.Parent = parent
    return label
end

local function makeModeButton(parent, name, text, position, width)
    local button = Instance.new("TextButton")
    button.Name = name
    button.Size = UDim2.fromOffset(width or 150, 29)
    button.Position = position
    button.BackgroundColor3 = UI.row
    button.BorderSizePixel = 0
    button.Text = text
    button.Font = Enum.Font.GothamBold
    button.TextSize = 11
    button.TextColor3 = UI.text
    button.AutoButtonColor = true
    button.Parent = parent
    addCorner(button, 7)
    addStroke(button, Color3.fromRGB(75, 95, 125), 0.72, 1)
    return button
end

local function updateModeButtons()
    if not playerModeButton or not npcModeButton then
        return
    end
    playerModeButton.BackgroundColor3 = targetMode == "PLAYER"
        and Color3.fromRGB(28, 91, 119) or UI.row
    npcModeButton.BackgroundColor3 = targetMode == "NPC"
        and Color3.fromRGB(82, 61, 126) or UI.row
end

local function updateHUDState()
    if not statusBadge then
        return
    end

    if isLocked and currentTargetMode == "PLAYER" and waitingForPlayerCharacter then
        statusBadge.BackgroundColor3 = Color3.fromRGB(64, 61, 37)
        statusBadge.TextColor3 = Color3.fromRGB(255, 220, 125)
        statusBadge.Text = "WAITING FOR SELECTED PLAYER TO SPAWN"
        if lockButton then lockButton.Text = "UNLOCK" end
    elseif isLocked and currentTarget then
        statusBadge.BackgroundColor3 = Color3.fromRGB(27, 82, 66)
        statusBadge.TextColor3 = UI.green
        statusBadge.Text = "TRACKING  •  " .. string.upper(getTargetDisplayName(currentTarget))
        if lockButton then lockButton.Text = "UNLOCK" end
    else
        statusBadge.BackgroundColor3 = UI.panel2
        statusBadge.TextColor3 = UI.muted
        if targetMode == "NPC" then
            statusBadge.Text = getTargetSearchText() == "" and "TYPE AN NPC MODEL NAME" or "NPC READY  •  PRESS LOCK"
        elseif getSelectedPlayer() then
            statusBadge.Text = "PLAYER SELECTED  •  PRESS LOCK"
        else
            statusBadge.Text = "CHOOSE A PLAYER FROM THE SERVER LIST"
        end
        if lockButton then lockButton.Text = "LOCK ON" end
    end
end

local function getOtherServerPlayers()
    local result = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= localPlayer then
            table.insert(result, player)
        end
    end
    table.sort(result, function(a, b)
        local aName = string.lower(a.DisplayName .. a.Name)
        local bName = string.lower(b.DisplayName .. b.Name)
        return aName < bName
    end)
    return result
end

local function setSelectedPlayer(player)
    if not player or player == localPlayer or player.Parent ~= Players then
        return
    end

    selectedPlayerUserId = player.UserId
    if isLocked and currentTargetMode == "PLAYER" then
        beginPlayerTarget(player)
    end
    refreshPlayerList()
    updateHUDState()
end

local function makeRosterRow(parent, player, isSelf, isSelected, rowIndex)
    local row
    if isSelf then
        row = Instance.new("Frame")
    else
        row = Instance.new("TextButton")
        row.AutoButtonColor = true
        row.Text = ""
    end
    row.Name = "Roster_" .. tostring(player.UserId)
    row.Size = UDim2.new(1, -8, 0, 43)
    row.BackgroundColor3 = isSelected and Color3.fromRGB(27, 75, 101) or UI.row
    row.BorderSizePixel = 0
    row.LayoutOrder = rowIndex
    row.Parent = parent
    addCorner(row, 7)
    addStroke(row, isSelected and UI.cyan or Color3.fromRGB(72, 88, 111), isSelected and 0.25 or 0.82, 1)

    local accent = Instance.new("Frame")
    accent.Name = "Accent"
    accent.Size = UDim2.new(0, 3, 1, -12)
    accent.Position = UDim2.fromOffset(6, 6)
    accent.BackgroundColor3 = isSelf and UI.violet or (isSelected and UI.cyan or UI.green)
    accent.BorderSizePixel = 0
    accent.Parent = row
    addCorner(accent, 2)

    local avatar = Instance.new("ImageLabel")
    avatar.Name = "Avatar"
    avatar.Size = UDim2.fromOffset(31, 31)
    avatar.Position = UDim2.fromOffset(13, 6)
    avatar.BackgroundColor3 = Color3.fromRGB(48, 60, 80)
    avatar.BorderSizePixel = 0
    avatar.ScaleType = Enum.ScaleType.Crop
    avatar.Parent = row
    addCorner(avatar, 8)
    addStroke(avatar, isSelf and UI.violet or UI.cyan, 0.55, 1)

    local initials = Instance.new("TextLabel")
    initials.Name = "AvatarFallback"
    initials.Size = UDim2.fromScale(1, 1)
    initials.BackgroundTransparency = 1
    initials.Text = string.upper(string.sub(player.DisplayName or player.Name, 1, 1))
    initials.TextColor3 = UI.text
    initials.Font = Enum.Font.GothamBlack
    initials.TextSize = 14
    initials.Parent = avatar

    task.spawn(function()
        local ok, imageContent = pcall(function()
            local content = Players:GetUserThumbnailAsync(
                player.UserId,
                Enum.ThumbnailType.HeadShot,
                Enum.ThumbnailSize.Size48x48
            )
            return content
        end)
        if ok and avatar.Parent then
            avatar.Image = imageContent
            initials.Visible = false
        end
    end)

    local display = makeLabel(
        row,
        "DisplayName",
        player.DisplayName,
        UDim2.fromOffset(52, 5),
        UDim2.new(1, -122, 0, 17),
        11,
        UI.text,
        Enum.Font.GothamBold
    )
    display.TextTruncate = Enum.TextTruncate.AtEnd

    local username = makeLabel(
        row,
        "Username",
        "@" .. player.Name,
        UDim2.fromOffset(52, 22),
        UDim2.new(1, -122, 0, 14),
        9,
        UI.muted,
        Enum.Font.Gotham
    )
    username.TextTruncate = Enum.TextTruncate.AtEnd

    local tag = Instance.new("TextLabel")
    tag.Name = "Tag"
    tag.AnchorPoint = Vector2.new(1, 0.5)
    tag.Position = UDim2.new(1, -8, 0.5, 0)
    tag.Size = UDim2.fromOffset(isSelf and 44 or 58, 21)
    tag.BackgroundColor3 = isSelf and Color3.fromRGB(62, 48, 103)
        or (isSelected and Color3.fromRGB(28, 107, 137) or Color3.fromRGB(38, 53, 67))
    tag.BorderSizePixel = 0
    tag.Text = isSelf and "YOU" or (isSelected and "TARGET" or "SELECT")
    tag.TextColor3 = isSelf and Color3.fromRGB(205, 190, 255)
        or (isSelected and UI.cyan or UI.muted)
    tag.TextSize = 8
    tag.Font = Enum.Font.GothamBlack
    tag.Parent = row
    addCorner(tag, 5)

    if not isSelf then
        row.MouseButton1Click:Connect(function()
            setSelectedPlayer(player)
        end)
    end
    return row
end

refreshPlayerList = function()
    if not playerListFrame or not playerListLayout then
        return
    end

    for _, child in ipairs(playerListFrame:GetChildren()) do
        if child:IsA("GuiObject") and child ~= playerListLayout then
            child:Destroy()
        end
    end

    local query = playerSearchBox and lower(trim(playerSearchBox.Text)) or ""
    local roster = {}
    local others = getOtherServerPlayers()
    local visibleOthers = {}

    -- Always show the local player as a non-selectable YOU row.
    table.insert(roster, { player = localPlayer, isSelf = true })
    for _, player in ipairs(others) do
        local text = lower(player.Name .. " " .. player.DisplayName)
        if query == "" or string.find(text, query, 1, true) then
            table.insert(roster, { player = player, isSelf = false })
            table.insert(visibleOthers, player)
        end
    end

    if playerCountLabel then
        playerCountLabel.Text = string.format(
            "%d OTHER PLAYER%s  •  %d IN SERVER",
            #others,
            #others == 1 and "" or "S",
            #Players:GetPlayers()
        )
    end

    if #visibleOthers == 0 then
        local empty = makeLabel(
            playerListFrame,
            "EmptyRoster",
            query == "" and "No other players are in this server yet" or "No players match that search",
            UDim2.new(),
            UDim2.new(1, -12, 0, 40),
            10,
            UI.muted,
            Enum.Font.Gotham
        )
        empty.LayoutOrder = 2
    end

    for index, item in ipairs(roster) do
        makeRosterRow(
            playerListFrame,
            item.player,
            item.isSelf,
            not item.isSelf and item.player.UserId == selectedPlayerUserId,
            index
        )
    end

    task.defer(function()
        if playerListFrame and playerListLayout then
            playerListFrame.CanvasSize = UDim2.fromOffset(0, playerListLayout.AbsoluteContentSize.Y + 8)
        end
    end)
end

local function createHUD()
    local playerGui = localPlayer:WaitForChild("PlayerGui")
    local existing = playerGui:FindFirstChild("HumanoidTrackerHUD")
    if existing then existing:Destroy() end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "HumanoidTrackerHUD"
    screenGui.ResetOnSpawn = false
    screenGui.IgnoreGuiInset = true
    screenGui.DisplayOrder = 80
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.Parent = playerGui

    local panel = Instance.new("Frame")
    panel.Name = "NexusPanel"
    panel.Size = UDim2.fromOffset(356, 356)
    panel.AnchorPoint = Vector2.new(1, 1)
    panel.Position = UDim2.new(1, -18, 1, -18)
    panel.BackgroundColor3 = UI.panel
    panel.BackgroundTransparency = 0.04
    panel.BorderSizePixel = 0
    panel.Parent = screenGui
    addCorner(panel, 13)
    addStroke(panel, Color3.fromRGB(82, 119, 154), 0.42, 1.25)

    local topGlow = Instance.new("Frame")
    topGlow.Name = "TopGlow"
    topGlow.Size = UDim2.new(1, -24, 0, 3)
    topGlow.Position = UDim2.fromOffset(12, 0)
    topGlow.BackgroundColor3 = UI.cyan
    topGlow.BorderSizePixel = 0
    topGlow.Parent = panel
    addCorner(topGlow, 2)
    local gradient = Instance.new("UIGradient")
    gradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, UI.cyan),
        ColorSequenceKeypoint.new(0.5, UI.violet),
        ColorSequenceKeypoint.new(1, UI.green),
    })
    gradient.Parent = topGlow

    makeLabel(panel, "Title", "NEXUS  /  TARGET CONTROL", UDim2.fromOffset(13, 10), UDim2.new(1, -26, 0, 21), 14, UI.text, Enum.Font.GothamBlack)
    makeLabel(panel, "Subtitle", "LIVE SERVER TRACKING SYSTEM", UDim2.fromOffset(14, 31), UDim2.new(1, -28, 0, 13), 8, UI.muted, Enum.Font.GothamBold)

    local liveTag = Instance.new("TextLabel")
    liveTag.Name = "LiveTag"
    liveTag.AnchorPoint = Vector2.new(1, 0)
    liveTag.Position = UDim2.new(1, -12, 0, 13)
    liveTag.Size = UDim2.fromOffset(47, 19)
    liveTag.BackgroundColor3 = Color3.fromRGB(24, 70, 60)
    liveTag.BorderSizePixel = 0
    liveTag.Text = "● LIVE"
    liveTag.TextColor3 = UI.green
    liveTag.TextSize = 8
    liveTag.Font = Enum.Font.GothamBlack
    liveTag.Parent = panel
    addCorner(liveTag, 6)

    local divider = Instance.new("Frame")
    divider.Size = UDim2.new(1, -24, 0, 1)
    divider.Position = UDim2.fromOffset(12, 49)
    divider.BackgroundColor3 = Color3.fromRGB(58, 72, 91)
    divider.BackgroundTransparency = 0.3
    divider.BorderSizePixel = 0
    divider.Parent = panel

    playerModeButton = makeModeButton(panel, "PlayerModeButton", "◉  PLAYERS  [P]", UDim2.fromOffset(12, 58), 162)
    npcModeButton = makeModeButton(panel, "NPCModeButton", "◇  NPC NAME  [N]", UDim2.fromOffset(182, 58), 162)

    playerSearchBox = Instance.new("TextBox")
    playerSearchBox.Name = "PlayerSearch"
    playerSearchBox.Size = UDim2.new(1, -24, 0, 27)
    playerSearchBox.Position = UDim2.fromOffset(12, 96)
    playerSearchBox.BackgroundColor3 = UI.panel2
    playerSearchBox.BorderSizePixel = 0
    playerSearchBox.ClearTextOnFocus = false
    playerSearchBox.Font = Enum.Font.Gotham
    playerSearchBox.TextSize = 10
    playerSearchBox.TextColor3 = UI.text
    playerSearchBox.PlaceholderColor3 = UI.muted
    playerSearchBox.PlaceholderText = "  Search players by username or display name..."
    playerSearchBox.Text = ""
    playerSearchBox.TextXAlignment = Enum.TextXAlignment.Left
    playerSearchBox.Parent = panel
    addCorner(playerSearchBox, 7)
    addStroke(playerSearchBox, Color3.fromRGB(69, 91, 117), 0.65, 1)

    targetNameBox = Instance.new("TextBox")
    targetNameBox.Name = "NPCNameBox"
    targetNameBox.Size = UDim2.new(1, -24, 0, 27)
    targetNameBox.Position = UDim2.fromOffset(12, 96)
    targetNameBox.BackgroundColor3 = UI.panel2
    targetNameBox.BorderSizePixel = 0
    targetNameBox.ClearTextOnFocus = false
    targetNameBox.Font = Enum.Font.Gotham
    targetNameBox.TextSize = 10
    targetNameBox.TextColor3 = UI.text
    targetNameBox.PlaceholderColor3 = UI.muted
    targetNameBox.PlaceholderText = "  Enter NPC model name (exact or partial)..."
    targetNameBox.Text = ""
    targetNameBox.TextXAlignment = Enum.TextXAlignment.Left
    targetNameBox.Visible = false
    targetNameBox.Parent = panel
    addCorner(targetNameBox, 7)
    addStroke(targetNameBox, Color3.fromRGB(105, 84, 150), 0.55, 1)

    playerCountLabel = makeLabel(
        panel,
        "PlayerCount",
        "LOADING SERVER PLAYERS...",
        UDim2.fromOffset(13, 126),
        UDim2.new(1, -26, 0, 13),
        8,
        UI.cyan,
        Enum.Font.GothamBold
    )

    playerListFrame = Instance.new("ScrollingFrame")
    playerListFrame.Name = "ServerRoster"
    playerListFrame.Size = UDim2.new(1, -24, 0, 151)
    playerListFrame.Position = UDim2.fromOffset(12, 143)
    playerListFrame.BackgroundColor3 = Color3.fromRGB(17, 23, 34)
    playerListFrame.BorderSizePixel = 0
    playerListFrame.ScrollBarThickness = 4
    playerListFrame.ScrollBarImageColor3 = UI.cyan
    playerListFrame.CanvasSize = UDim2.fromOffset(0, 0)
    playerListFrame.AutomaticCanvasSize = Enum.AutomaticSize.None
    playerListFrame.ScrollingDirection = Enum.ScrollingDirection.Y
    playerListFrame.Visible = true
    playerListFrame.Parent = panel
    addCorner(playerListFrame, 8)
    addStroke(playerListFrame, Color3.fromRGB(60, 79, 103), 0.72, 1)

    playerListLayout = Instance.new("UIListLayout")
    playerListLayout.SortOrder = Enum.SortOrder.LayoutOrder
    playerListLayout.Padding = UDim.new(0, 4)
    playerListLayout.Parent = playerListFrame

    local rosterPadding = Instance.new("UIPadding")
    rosterPadding.PaddingTop = UDim.new(0, 5)
    rosterPadding.PaddingBottom = UDim.new(0, 5)
    rosterPadding.PaddingLeft = UDim.new(0, 4)
    rosterPadding.PaddingRight = UDim.new(0, 4)
    rosterPadding.Parent = playerListFrame

    statusBadge = Instance.new("TextLabel")
    statusBadge.Name = "StatusBadge"
    statusBadge.Size = UDim2.new(1, -122, 0, 27)
    statusBadge.Position = UDim2.fromOffset(12, 302)
    statusBadge.BackgroundColor3 = UI.panel2
    statusBadge.BorderSizePixel = 0
    statusBadge.Font = Enum.Font.GothamBold
    statusBadge.TextSize = 8
    statusBadge.TextColor3 = UI.muted
    statusBadge.Text = "CHOOSE A PLAYER FROM THE SERVER LIST"
    statusBadge.TextTruncate = Enum.TextTruncate.AtEnd
    statusBadge.Parent = panel
    addCorner(statusBadge, 7)

    lockButton = Instance.new("TextButton")
    lockButton.Name = "LockButton"
    lockButton.Size = UDim2.fromOffset(108, 27)
    lockButton.Position = UDim2.new(1, -120, 0, 302)
    lockButton.BackgroundColor3 = Color3.fromRGB(24, 105, 139)
    lockButton.BorderSizePixel = 0
    lockButton.Text = "LOCK ON"
    lockButton.Font = Enum.Font.GothamBlack
    lockButton.TextSize = 10
    lockButton.TextColor3 = Color3.new(1, 1, 1)
    lockButton.Parent = panel
    addCorner(lockButton, 7)

    makeLabel(
        panel,
        "ControlsHint",
        "P PLAYERS   •   N NPC   •   TAB NEXT   •   X / Q LOCK",
        UDim2.fromOffset(13, 333),
        UDim2.new(1, -26, 0, 13),
        8,
        UI.muted,
        Enum.Font.GothamBold
    )

    playerModeButton.MouseButton1Click:Connect(function()
        setTargetMode("PLAYER")
    end)
    npcModeButton.MouseButton1Click:Connect(function()
        setTargetMode("NPC")
    end)
    lockButton.MouseButton1Click:Connect(function()
        toggleLockOn()
    end)
    playerSearchBox:GetPropertyChangedSignal("Text"):Connect(function()
        refreshPlayerList()
    end)
    targetNameBox.FocusLost:Connect(function(enterPressed)
        updateHUDState()
        if enterPressed and targetMode == "NPC" then
            if isLocked then unlockTarget() end
            toggleLockOn()
        end
    end)

    hudGui = screenGui
    refreshPlayerList()
    updateModeButtons()
    updateHUDState()
end

setTargetMode = function(mode)
    if mode ~= "PLAYER" and mode ~= "NPC" then return end
    if isLocked then unlockTarget() end

    targetMode = mode
    if playerSearchBox then playerSearchBox.Visible = mode == "PLAYER" end
    if targetNameBox then targetNameBox.Visible = mode == "NPC" end
    if playerCountLabel then playerCountLabel.Visible = mode == "PLAYER" end
    if playerListFrame then playerListFrame.Visible = mode == "PLAYER" end

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
    local myFocus = localPlayer.Character and getTargetFocusPoint(localPlayer.Character)
    local targetFocus = getTargetFocusPoint(target)
    smoothedFocus = (myFocus and targetFocus) and ((myFocus + targetFocus) * 0.5) or targetFocus
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
    if not currentCamera then return end
    camera = currentCamera

    local targetModel = currentTarget
    local myCharacter = localPlayer.Character
    local myFocus = myCharacter and getTargetFocusPoint(myCharacter)
    local targetFocus = targetModel and getTargetFocusPoint(targetModel)
    if not myFocus or not targetFocus then return end

    local myPosition = myRoot.Position
    local targetPosition = targetRoot.Position
    local separation = (myPosition - targetPosition).Magnitude
    local flatDifference = Vector3.new(
        myPosition.X - targetPosition.X,
        0,
        myPosition.Z - targetPosition.Z
    )

    if not cameraYaw then
        initializeCameraTracking(targetModel)
        if not cameraYaw then return end
    end

    -- Keep the camera on the same side when the characters overlap or a move
    -- briefly swaps their positions. Only update yaw when the direction is stable.
    if flatDifference.Magnitude > CONFIG.MIN_DIRECTION_DISTANCE then
        local desiredYaw = math.atan2(flatDifference.X, flatDifference.Z)
        local yawDelta = wrapAngle(desiredYaw - cameraYaw)
        local maxStep = CONFIG.CAMERA_YAW_SPEED * dt
        cameraYaw = cameraYaw + math.clamp(yawDelta, -maxStep, maxStep)
    end

    local alpha = 1 - math.exp(-CONFIG.CAMERA_SMOOTH_SPEED * dt)
    local midpoint = (myFocus + targetFocus) * 0.5
    smoothedFocus = smoothedFocus and smoothedFocus:Lerp(midpoint, alpha) or midpoint

    local flatDirection = Vector3.new(math.sin(cameraYaw), 0, math.cos(cameraYaw))
    local rightDirection = Vector3.new(0, 1, 0):Cross(flatDirection)
    if rightDirection.Magnitude > 0.001 then
        rightDirection = rightDirection.Unit
    else
        rightDirection = Vector3.new(1, 0, 0)
    end

    local excluded = { targetModel }
    if myCharacter then table.insert(excluded, myCharacter) end

    -- NORMAL RANGE: place the camera BEHIND THE LOCAL PLAYER and aim between
    -- both characters. This keeps your avatar visible instead of framing only
    -- the selected player. Pitch remains fixed regardless of target height.
    local halfSpan = flatDifference.Magnitude * 0.5
    local cameraReach = currentZoom * 1.3 + halfSpan
    local pitchRadians = math.rad(CONFIG.CAMERA_PITCH_DEGREES)
    local normalPosition = smoothedFocus
        + flatDirection * cameraReach
        + Vector3.new(0, math.tan(pitchRadians) * cameraReach, 0)
        + rightDirection * CONFIG.SHOULDER_OFFSET
    normalPosition = applyCameraCollision(smoothedFocus, normalPosition, excluded)
    local normalCFrame = CFrame.lookAt(normalPosition, smoothedFocus, Vector3.new(0, 1, 0))

    -- CLOSE RANGE ONLY: retain the original player-relative framing, blended in
    -- near contact so the tracker behaves naturally during close-up moves.
    local oldCameraPosition = myPosition
        + flatDirection * currentZoom
        + Vector3.new(0, CONFIG.CAMERA_HEIGHT, 0)
        + rightDirection * CONFIG.SHOULDER_OFFSET
    local oldCameraOrigin = myPosition + Vector3.new(0, CONFIG.CAMERA_HEIGHT * 0.65, 0)
    oldCameraPosition = applyCameraCollision(oldCameraOrigin, oldCameraPosition, excluded)
    local closeCFrame = CFrame.lookAt(oldCameraPosition, targetFocus, Vector3.new(0, 1, 0))

    local closeT = 1 - (
        (separation - CONFIG.CLOSE_RANGE_FULL_OLD_CAMERA)
        / (CONFIG.CLOSE_RANGE_NO_OLD_CAMERA - CONFIG.CLOSE_RANGE_FULL_OLD_CAMERA)
    )
    local closeBlend = smoothStep01(closeT)
    local desiredCFrame = normalCFrame:Lerp(closeCFrame, closeBlend)

    smoothedCameraCFrame = smoothedCameraCFrame
        and smoothedCameraCFrame:Lerp(desiredCFrame, alpha)
        or desiredCFrame

    -- CameraType stays Custom; our render binding runs just after Roblox's
    -- camera update so normal Shift Lock input can still drive character yaw.
    currentCamera.CFrame = smoothedCameraCFrame
    currentCamera.Focus = CFrame.new(smoothedFocus)
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

beginPlayerTarget = function(player)
    if not player or player == localPlayer or player.Parent ~= Players then
        return
    end

    if player.Character and isValidTarget(player.Character) then
        lockTarget(player.Character)
        return
    end

    local currentCamera = workspace.CurrentCamera
    if not isLocked and currentCamera then
        cameraTypeBeforeLock = currentCamera.CameraType
        cameraSubjectBeforeLock = currentCamera.CameraSubject
    end

    destroyTargetVisuals()
    currentTarget = nil
    currentTargetPlayer = player
    currentTargetMode = "PLAYER"
    waitingForPlayerCharacter = true
    isLocked = true
    updateHUDState()
end

toggleLockOn = function()
    if isLocked then
        unlockTarget()
        return
    end

    if targetMode == "PLAYER" then
        local selectedPlayer = getSelectedPlayer()
        if selectedPlayer and selectedPlayer ~= localPlayer then
            beginPlayerTarget(selectedPlayer)
            return
        end
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
                    currentTarget = nil
                    waitingForPlayerCharacter = true
                    updateHUDState()
                end
                return
            end

            if latestCharacter ~= currentTarget or waitingForPlayerCharacter then
                local newRoot = getCharacterRoot(latestCharacter)
                if not newRoot then return end
                currentTarget = latestCharacter
                waitingForPlayerCharacter = false
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
    end
    if isLocked and currentTargetPlayer == player then
        unlockTarget()
    end
    refreshPlayerList()
    updateHUDState()
end)

localPlayer.CharacterAdded:Connect(function()
    -- Do not drop the selected target when YOUR character respawns.
    smoothedFocus = nil
    smoothedCameraCFrame = nil
    cameraYaw = nil
    if isLocked and currentTarget then
        initializeCameraTracking(currentTarget)
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
