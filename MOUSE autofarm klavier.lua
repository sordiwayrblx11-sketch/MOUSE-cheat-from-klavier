--============================================================
-- MOUSE HELPER - V49 INSTANT LOCK-ON SEARCH
-- Place in StarterPlayer > StarterPlayerScripts
-- Mickey ESP | Searchables ESP | Dropped Key ESP | Autofarm | Noclip | Fullbright
--============================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local ProximityPromptService = game:GetService("ProximityPromptService")
local SoundService = game:GetService("SoundService")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

print("[MOUSE] Starting helper...")

--============================================================
-- CLEANUP
--============================================================

local oldGui = playerGui:FindFirstChild("MOUSE_HELPER")
if oldGui then oldGui:Destroy() end

local oldESP = workspace:FindFirstChild("_MOUSE_CLIENT_ESP")
if oldESP then oldESP:Destroy() end

pcall(function()
    RunService:UnbindFromRenderStep("MOUSE_GUI_CURSOR")
end)

local espFolder = Instance.new("Folder")
espFolder.Name = "_MOUSE_CLIENT_ESP"
espFolder.Parent = workspace

--============================================================
-- STATE
--============================================================

local enabled = {
    Mickey = true,
    Searchables = true,
    DroppedKeys = true,
    Autofarm = false, -- auto-started after GUI initialization
    Noclip = true,
    Fullbright = true
}

local farmStatus = "Idle"
local farmToken = 0
local farmRandom = Random.new()
local SEARCH_DISABLED_CONFIRM_SECONDS = 2.50 -- avoid mistaking a brief server cooldown for a completed search
-- Forward declaration: teleportToCandidate is defined before the Autofarm
-- section, but calls farmRunning. Declare it here so Luau captures this local
-- instead of trying to call a missing global at runtime.
local farmRunning
local waitForLivingCharacter
local scanning = false
local gui
local modalButton

-- Any respawn/evasion invalidates an older temporary Scriptable camera lock.
local cameraControlGeneration = 0

local counts = {
    Mickey = 0,
    Searchables = 0,
    DroppedKeys = 0
}

local highlights = {
    Mickey = {},
    Searchables = {},
    DroppedKeys = {}
}

local toggleRender = {}
local originalCollision = setmetatable({}, {__mode = "k"})
local promptRangeOriginal = setmetatable({}, {__mode = "k"})
local promptRangeFallbackWarned = setmetatable({}, {__mode = "k"})
local originalLighting = {}
local savedMouse = nil

for _, property in ipairs({
    "Brightness",
    "ClockTime",
    "FogStart",
    "FogEnd",
    "GlobalShadows",
    "Ambient",
    "OutdoorAmbient",
    "ExposureCompensation"
}) do
    pcall(function()
        originalLighting[property] = Lighting[property]
    end)
end

--============================================================
-- CHARACTER / BOAT
--============================================================

local function getCharacter()
    return player.Character
end

local function getRoot()
    local character = getCharacter()
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
    local character = getCharacter()
    return character and character:FindFirstChildOfClass("Humanoid")
end

local function getBoat()
    return workspace:FindFirstChild("Boat")
end

-- Keep completed searchable identities across Autofarm stop/start and player
-- deaths. A key loss must not make already-searched containers searchable again.
local searchableCompletion = {
    Boat = nil,
    Seed = nil,
    Prompts = setmetatable({}, {__mode = "k"}),
    DisabledSince = setmetatable({}, {__mode = "k"}),
    Reenabled = setmetatable({}, {__mode = "k"})
}

local function prepareSearchableCompletionCache()
    local boat = getBoat()
    local seed = boat and boat:GetAttribute("Seed") or nil

    if boat ~= searchableCompletion.Boat or seed ~= searchableCompletion.Seed then
        searchableCompletion.Boat = boat
        searchableCompletion.Seed = seed
        searchableCompletion.Prompts = setmetatable({}, {__mode = "k"})
        searchableCompletion.DisabledSince = setmetatable({}, {__mode = "k"})
        searchableCompletion.Reenabled = setmetatable({}, {__mode = "k"})
        print("[MOUSE AUTOFARM] New boat/round detected; searchable prompt cache reset.")
    end
end

-- Completion detector is assigned its full implementation further below.
-- Keep a callable fallback from startup so queue scans can never nil-call it.
local hasExplicitSearchCompletion = function()
    return false
end

local function safeHasExplicitSearchCompletion(prompt, model)
    local detector = hasExplicitSearchCompletion
    if type(detector) ~= "function" then
        return false
    end
    local ok, result = pcall(detector, prompt, model)
    return ok and result == true
end

-- A game-reported terminal state is authoritative. A prompt that merely
-- remains disabled is NOT complete while keys are missing. IMPORTANT: a prompt can be disabled temporarily by
-- server-side rummage/cooldown logic and then re-enabled. When that happens,
-- clear any old *inferred* completion so it can re-enter the queue. This avoids
-- the 4/5-key stall where a temporarily disabled fifth-key searchable was
-- cached as complete and then permanently skipped after it became enabled.
local function isSearchableCompleted(model, prompt, runCompleted)
    if not prompt then return false end

    -- A genuine game-owned terminal state is authoritative.
    if safeHasExplicitSearchCompletion(prompt, model) then
        searchableCompletion.Prompts[prompt] = true
        if runCompleted then runCompleted[prompt] = true end
        return true
    end

    -- Only clear inferred completion when this prompt actually transitions
    -- from disabled back to enabled. Do not erase the cache on every scan.
    if prompt.Parent and prompt.Enabled and searchableCompletion.Reenabled[prompt] then
        searchableCompletion.Prompts[prompt] = nil
        searchableCompletion.DisabledSince[prompt] = nil
        searchableCompletion.Reenabled[prompt] = nil
        if runCompleted then runCompleted[prompt] = nil end
        print("[MOUSE AUTOFARM] Search prompt re-enabled; returning it to the searchable queue:", prompt:GetFullName())
    end

    if searchableCompletion.Prompts[prompt] == true
        or (runCompleted ~= nil and runCompleted[prompt] == true) then
        return true
    end

    -- A prompt that stays disabled for the configured quiet window is treated
    -- as searched. If it was only a cooldown, getSearchEntries/Triggered
    -- records the disabled-to-enabled transition and clears this inferred state.
    local disabledAt = searchableCompletion.DisabledSince[prompt]
    if prompt.Parent and not prompt.Enabled and disabledAt
        and os.clock() - disabledAt >= SEARCH_DISABLED_CONFIRM_SECONDS then
        searchableCompletion.Prompts[prompt] = true
        if runCompleted then runCompleted[prompt] = true end
        return true
    end

    return false
end

local function markSearchableCompleted(model, prompt)
    if not prompt then return end

    -- Keep completion in this script's memory only; don't persist a stale
    -- attribute on the prompt across Autofarm restarts.
    searchableCompletion.Prompts[prompt] = true
end

local function getKeys()
    local boat = getBoat()
    return boat and (tonumber(boat:GetAttribute("Keys")) or 0) or 0
end

local function getKeysTotal()
    local boat = getBoat()
    return boat and (tonumber(boat:GetAttribute("KeysTotal")) or 5) or 5
end

--============================================================
-- MOUSE CONTROL
--============================================================

local function setGuiOpen(open)
    if not gui then return end

    if open then
        if not gui.Enabled then
            savedMouse = {
                Icon = UserInputService.MouseIconEnabled,
                Behavior = UserInputService.MouseBehavior
            }
        end

        gui.Enabled = true
        modalButton.Visible = true
        UserInputService.MouseIconEnabled = true
        UserInputService.MouseBehavior = Enum.MouseBehavior.Default
    else
        gui.Enabled = false
        modalButton.Visible = false

        if savedMouse then
            UserInputService.MouseIconEnabled = savedMouse.Icon
            UserInputService.MouseBehavior = savedMouse.Behavior
            savedMouse = nil
        end
    end
end

-- A visible modal button prevents the default camera from recapturing the
-- cursor while the panel is open. Keep it behind the actual panel controls.
RunService:BindToRenderStep(
    "MOUSE_GUI_CURSOR",
    Enum.RenderPriority.Last.Value,
    function()
        if gui and gui.Parent and gui.Enabled then
            if modalButton then modalButton.Visible = true end
            UserInputService.MouseIconEnabled = true
            UserInputService.MouseBehavior = Enum.MouseBehavior.Default
        end
    end
)

--============================================================
-- SEARCH PROMPT HELPERS
--============================================================

local function isSearchPrompt(obj)
    return obj:IsA("ProximityPrompt")
        and obj.ActionText:lower():find("search", 1, true) ~= nil
end

local function getContainer(prompt, boat)
    local current = prompt.Parent
    local nearestModel = nil

    while current and current ~= boat do
        if current:IsA("Model") then
            nearestModel = nearestModel or current
            if current:GetAttribute("Kit") ~= nil then
                return current
            end
        end
        current = current.Parent
    end

    return nearestModel
end

local function getPromptAnchor(prompt)
    local parent = prompt and prompt.Parent
    if not parent then return nil, nil, nil end

    if parent:IsA("Attachment") then
        return parent.WorldPosition, parent.Parent, parent.WorldCFrame
    end

    if parent:IsA("BasePart") then
        return parent.Position, parent, parent.CFrame
    end

    if parent:IsA("Model") then
        local part = parent.PrimaryPart or parent:FindFirstChildWhichIsA("BasePart", true)
        if part then
            return part.Position, part, part.CFrame
        end
    end

    local part = parent:FindFirstAncestorWhichIsA("BasePart")
    if part then
        return part.Position, part, part.CFrame
    end

    return nil, nil, nil
end

local function getTargetAnchor(target)
    if not target then return nil, nil, nil end

    if target:IsA("ProximityPrompt") then
        return getPromptAnchor(target)
    elseif target:IsA("BasePart") then
        return target.Position, target, target.CFrame
    elseif target:IsA("Model") then
        local cf = target:GetBoundingBox()
        local part = target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart", true)
        return cf.Position, part, part and part.CFrame or cf
    end

    return nil, nil, nil
end

local function getTargetModel(target)
    if not target then return nil end
    if target:IsA("Model") then return target end

    local current = target.Parent
    while current and current ~= workspace do
        if current:IsA("Model") then
            return current
        end
        current = current.Parent
    end

    return nil
end

local function getSearchEntries()
    local boat = getBoat()
    local result = {}
    if not boat then return result end

    for _, obj in ipairs(boat:GetDescendants()) do
        if isSearchPrompt(obj) then
            if obj.Enabled then
                if searchableCompletion.DisabledSince[obj] ~= nil then
                    searchableCompletion.Reenabled[obj] = true
                end
                searchableCompletion.DisabledSince[obj] = nil
            elseif searchableCompletion.DisabledSince[obj] == nil then
                searchableCompletion.DisabledSince[obj] = os.clock()
            end

            local model = getContainer(obj, boat)
            local position = getPromptAnchor(obj)
            if model and position then
                table.insert(result, {
                    Prompt = obj,
                    Model = model,
                    Position = position
                })
            end
        end
    end

    return result
end

-- MOUSE's earlier Studio inspection showed PromptReach = 9 on searchable
-- props. Read it from the prompt, host part, item model, ancestors, attributes,
-- and NumberValue/IntValue/StringValue children. Some props store this value
-- on a child rather than as an attribute, which v13 did not detect.
local MOUSE_SEARCH_REACH_FALLBACK = 9
local REACH_ATTRIBUTE_NAMES = {
    promptreach = true,
    searchreach = true,
    activationdistance = true,
    promptrange = true,
    searchrange = true
}

local function readReachFromNode(node)
    if not node then return nil end

    for attributeName, value in pairs(node:GetAttributes()) do
        local normalized = tostring(attributeName):lower():gsub("[^%w]", "")
        if REACH_ATTRIBUTE_NAMES[normalized] then
            local number = tonumber(value)
            if number and number >= 2 and number <= 100 then
                return number
            end
        end
    end

    for _, child in ipairs(node:GetChildren()) do
        local normalized = child.Name:lower():gsub("[^%w]", "")
        if REACH_ATTRIBUTE_NAMES[normalized] then
            local value
            if child:IsA("NumberValue") or child:IsA("IntValue") then
                value = child.Value
            elseif child:IsA("StringValue") then
                value = tonumber(child.Value)
            end

            value = tonumber(value)
            if value and value >= 2 and value <= 100 then
                return value
            end
        end
    end

    return nil
end

local function getPromptRange(prompt, model)
    local currentRange = tonumber(prompt.MaxActivationDistance) or 0
    local bestRange = currentRange
    local visited = {}

    local function inspect(node)
        if not node or visited[node] then return end
        visited[node] = true
        local reach = readReachFromNode(node)
        if reach then
            bestRange = math.max(bestRange, reach)
        end
    end

    -- Include the ProximityPrompt itself (v13 started at its parent).
    inspect(prompt)

    -- Check the prompt's host part/Attachment and every ancestor, including
    -- the actual Kit model and Boat.
    local current = prompt.Parent
    while current and current ~= workspace do
        inspect(current)
        current = current.Parent
    end

    -- Some searchable items store PromptReach on a sibling/descendant part.
    -- Search only this item's subtree, not the whole Workspace.
    if model then
        inspect(model)
        for _, descendant in ipairs(model:GetDescendants()) do
            inspect(descendant)
        end
    end

    local usedKnownFallback = false
    if bestRange < MOUSE_SEARCH_REACH_FALLBACK then
        -- Earlier Studio inspection found PromptReach = 9 on MOUSE searchable
        -- items. Some prompts replicate a smaller/default MaxActivationDistance
        -- while their owning item exposes the actual PromptReach. Use the known
        -- game value as the minimum search radius; never reject an item merely
        -- because its local prompt distance is stale or zero.
        bestRange = MOUSE_SEARCH_REACH_FALLBACK
        usedKnownFallback = true
    end

    return bestRange, bestRange > currentRange, usedKnownFallback
end

local function applyLocalPromptRange(prompt, model)
    local range, usedFallback, usedKnownFallback = getPromptRange(prompt, model)
    if usedFallback then
        if promptRangeOriginal[prompt] == nil then
            promptRangeOriginal[prompt] = prompt.MaxActivationDistance
        end
        pcall(function()
            prompt.MaxActivationDistance = range
        end)
    end
    return range, usedKnownFallback
end

local function restoreLocalPromptRange(prompt)
    local old = promptRangeOriginal[prompt]
    if old ~= nil and prompt and prompt.Parent then
        pcall(function()
            prompt.MaxActivationDistance = old
        end)
        promptRangeOriginal[prompt] = nil
    end
end

--============================================================
-- DROPPED KEY DISCOVERY (also used by the always-on Key ESP)
--============================================================

local function isKeyObjectName(name)
    local lower = tostring(name):lower()
    if lower == "key" or lower == "droppedkey" or lower == "boatkey" then
        return true
    end
    return lower:match("^key[%w_%-]*$") ~= nil
        or lower:match("^droppedkey[%w_%-]*$") ~= nil
        or lower:match("^boatkey[%w_%-]*$") ~= nil
end

local function isPlayerOwnedObject(object)
    for _, otherPlayer in ipairs(Players:GetPlayers()) do
        local character = otherPlayer.Character
        if character and (object == character or object:IsDescendantOf(character)) then
            return true
        end
        local backpack = otherPlayer:FindFirstChildOfClass("Backpack")
        if backpack and (object == backpack or object:IsDescendantOf(backpack)) then
            return true
        end
    end
    return false
end

local function isKeyObjectClass(object)
    return object:IsA("Model")
        or object:IsA("BasePart")
        or object:IsA("Tool")
        or object:IsA("Accessory")
end

local function getDroppedKeyObjects()
    local folder = workspace:FindFirstChild("DroppedKeys", true)
    local searchRoot = folder or workspace
    local candidates = {}
    local objects = {searchRoot}

    for _, object in ipairs(searchRoot:GetDescendants()) do
        table.insert(objects, object)
    end

    for _, object in ipairs(objects) do
        if object ~= searchRoot
            and isKeyObjectClass(object)
            and isKeyObjectName(object.Name)
            and not isPlayerOwnedObject(object) then

            -- Prefer the highest named key root; do not return its
            -- nested Key part as a second, duplicate dropped item.
            local nestedUnderKey = false
            local ancestor = object.Parent
            while ancestor and ancestor ~= searchRoot do
                if isKeyObjectClass(ancestor) and isKeyObjectName(ancestor.Name) then
                    nestedUnderKey = true
                    break
                end
                ancestor = ancestor.Parent
            end

            if not nestedUnderKey then
                table.insert(candidates, object)
            end
        end
    end

    return candidates, folder
end

local function getDroppedKeyHighlightTarget(keyObject)
    if not keyObject or not keyObject.Parent then return nil end
    if keyObject:IsA("Model") or keyObject:IsA("BasePart") then
        return keyObject
    elseif keyObject:IsA("Tool") or keyObject:IsA("Accessory") then
        local handle = keyObject:FindFirstChild("Handle")
        if handle and handle:IsA("BasePart") then
            return handle
        end
    end
    return nil
end

local function getDroppedKeyPrompt(keyObject)
    if keyObject:IsA("ProximityPrompt") and keyObject.Enabled then
        return keyObject
    end
    for _, object in ipairs(keyObject:GetDescendants()) do
        if object:IsA("ProximityPrompt") and object.Enabled then
            return object
        end
    end
    return nil
end

local function isStillDropped(keyObject, folder)
    if not keyObject or not keyObject.Parent then
        return false
    end

    if folder then
        return keyObject == folder or keyObject:IsDescendantOf(folder)
    end

    -- Fallback if this game temporarily removes/recreates the folder:
    -- include world key instances, but never a key already carried by a player.
    return keyObject:IsDescendantOf(workspace)
        and not isPlayerOwnedObject(keyObject)
end

local function getCarriedKeyCount()
    local character = getCharacter()
    if not character then return 0 end

    local belt = character:FindFirstChild("KeyBelt", true)
    if not belt then return 0 end

    local count = 0
    for _, child in ipairs(belt:GetChildren()) do
        if isKeyObjectClass(child) and isKeyObjectName(child.Name) then
            count += 1
        else
            for _, descendant in ipairs(child:GetDescendants()) do
                if isKeyObjectClass(descendant) and isKeyObjectName(descendant.Name) then
                    count += 1
                    break
                end
            end
        end
    end
    return count
end

local function getDroppedKeyTouchPart(keyObject)
    if keyObject:IsA("BasePart") then
        return keyObject
    end

    if keyObject:IsA("Model") and keyObject.PrimaryPart then
        return keyObject.PrimaryPart
    end

    local best = nil
    for _, object in ipairs(keyObject:GetDescendants()) do
        if object:IsA("BasePart") and object.CanTouch then
            if not best then
                best = object
            elseif object.CanCollide == false and best.CanCollide == true then
                best = object
            end
        end
    end
    return best
end

--============================================================
-- ESP
--============================================================

local espColors = {
    Mickey = {
        Fill = Color3.fromRGB(255, 45, 45),
        Outline = Color3.fromRGB(255, 110, 110),
        Transparency = 0.82
    },
    Searchables = {
        Fill = Color3.fromRGB(0, 190, 255),
        Outline = Color3.fromRGB(100, 225, 255),
        Transparency = 0.88
    },
    DroppedKeys = {
        Fill = Color3.fromRGB(255, 190, 20),
        Outline = Color3.fromRGB(255, 245, 120),
        Transparency = 0.2
    }
}

local function addHighlight(kind, target)
    if not target or not target.Parent then return end
    if highlights[kind][target] then return end

    local data = espColors[kind]
    local highlight = Instance.new("Highlight")
    highlight.Name = "MOUSE_" .. kind .. "_ESP"
    highlight.Adornee = target
    highlight.Enabled = true
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.FillColor = data.Fill
    highlight.OutlineColor = data.Outline
    highlight.FillTransparency = data.Transparency
    highlight.OutlineTransparency = 0
    highlight.Parent = espFolder

    highlights[kind][target] = highlight
end

local function syncHighlights(kind, desired)
    local registry = highlights[kind]

    for target, highlight in pairs(registry) do
        if not desired[target] or not target.Parent then
            highlight:Destroy()
            registry[target] = nil
        end
    end

    for target in pairs(desired) do
        addHighlight(kind, target)
    end
end

local function scanWorld()
    if scanning then return end
    scanning = true

    local wantedMickey = {}
    local wantedMickeyTargets = {}
    local wantedSearchables = {}
    local wantedDroppedKeys = {}

    -- Cache the named monster objects for the safety monitor even when ESP is
    -- switched off. Prefer the outer Model named Mickey when a visual submodel
    -- is nested inside it, so line-of-sight checks include the whole character.
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Model") or obj:IsA("BasePart") then
            local name = obj.Name:lower()
            if name == "mickey" or name == "mickeyvisual" then
                local target = obj
                if not target:IsA("Model") then
                    target = target:FindFirstAncestorOfClass("Model") or target
                end

                local ancestor = target
                local outerMickey = nil
                while ancestor and ancestor ~= workspace do
                    if ancestor:IsA("Model") and ancestor.Name:lower() == "mickey" then
                        outerMickey = ancestor
                    end
                    ancestor = ancestor.Parent
                end
                target = outerMickey or target
                wantedMickeyTargets[target] = true

                if enabled.Mickey then
                    wantedMickey[obj] = true
                end
            end
        end
    end

    if enabled.Searchables then
        for _, entry in ipairs(getSearchEntries()) do
            wantedSearchables[entry.Model] = true
        end
    end

    -- Dropped Key ESP is ON by default and is not reset by player death.
    if enabled.DroppedKeys then
        local droppedObjects = getDroppedKeyObjects()
        for _, keyObject in ipairs(droppedObjects) do
            local target = getDroppedKeyHighlightTarget(keyObject)
            if target then
                wantedDroppedKeys[target] = true
            end
        end
    end

    syncHighlights("Mickey", wantedMickey)
    syncHighlights("Searchables", wantedSearchables)
    syncHighlights("DroppedKeys", wantedDroppedKeys)

    counts.Mickey = 0
    counts.Searchables = 0
    counts.DroppedKeys = 0

    for _ in pairs(wantedMickey) do counts.Mickey += 1 end
    for _ in pairs(wantedSearchables) do counts.Searchables += 1 end
    for _ in pairs(wantedDroppedKeys) do counts.DroppedKeys += 1 end

    scanning = false
end

--============================================================
-- APPROACH POSITION VALIDATION
--============================================================

local function isInsidePromptParent(hitInstance, prompt, searchableModel)
    if not hitInstance or not prompt then return false end

    local parent = prompt.Parent
    local anchor, hostPart = getPromptAnchor(prompt)

    -- The prompt's actual host is always a valid hit.
    if hitInstance == parent or (hostPart and hitInstance == hostPart) then
        return true
    end

    -- A prompt may be attached to an Attachment on the host part.
    if parent and parent:IsA("Attachment") and hitInstance == parent.Parent then
        return true
    end

    -- Some items use a small Model as the prompt parent. Do not automatically
    -- accept every descendant: in MOUSE, a Kit ancestor can contain an entire
    -- room. Only nearby pieces of the item itself may count as the visible target.
    local belongsToTarget = (parent and parent:IsA("Model") and hitInstance:IsDescendantOf(parent))
        or (searchableModel and hitInstance:IsDescendantOf(searchableModel))
    if belongsToTarget and anchor and hitInstance:IsA("BasePart") then
        local localAnchor = hitInstance.CFrame:PointToObjectSpace(anchor)
        local half = hitInstance.Size * 0.5
        local closestLocal = Vector3.new(
            math.clamp(localAnchor.X, -half.X, half.X),
            math.clamp(localAnchor.Y, -half.Y, half.Y),
            math.clamp(localAnchor.Z, -half.Z, half.Z)
        )
        local closestWorld = hitInstance.CFrame:PointToWorldSpace(closestLocal)
        if (closestWorld - anchor).Magnitude <= 2.75 then
            return true
        end
    end

    return false
end

local function hasClearView(position, anchor, prompt, searchableModel, forceLineOfSight)
    -- Search and padlock approach points must have a clear view even when the
    -- prompt itself permits through-wall activation. This prevents choosing
    -- the opposite side of a room wall.
    if not forceLineOfSight and (not prompt or not prompt.RequiresLineOfSight) then
        return true
    end

    local eye = position + Vector3.new(0, 1.8, 0)
    local direction = anchor - eye
    if direction.Magnitude < 0.05 then return true end

    local character = getCharacter()
    if not character then return false end

    local excluded = {character, espFolder}
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = excluded
    params.IgnoreWater = true

    -- Ignore non-collidable decorations, then check the first real blocker.
    for _ = 1, 12 do
        local result = workspace:Raycast(eye, direction, params)
        if not result then
            return true
        end

        if isInsidePromptParent(result.Instance, prompt, searchableModel) then
            return true
        end

        -- The shared padlock prompt sits among several separate lock meshes.
        -- Those meshes are part of the target interaction, not a wall blocking
        -- the prompt. Permit only clearly lock-named parts/ancestors here.
        local promptText = (tostring(prompt.ActionText) .. " " .. tostring(prompt.ObjectText)):lower()
        if promptText:find("padlock", 1, true) or promptText:find("lock", 1, true) then
            local ancestor = result.Instance
            while ancestor and ancestor ~= workspace do
                local ancestorName = ancestor.Name:lower()
                if ancestorName:find("padlock", 1, true)
                    or ancestorName:find("lock", 1, true) then
                    return true
                end
                ancestor = ancestor.Parent
            end
        end

        if result.Instance:IsA("BasePart") and not result.Instance.CanCollide then
            table.insert(excluded, result.Instance)
            params.FilterDescendantsInstances = excluded
        else
            return false
        end
    end

    return false
end

local function hasStandingRoom(position, targetModel, additionalExcludes)
    local character = getCharacter()
    if not character then return false end

    local params = OverlapParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude

    local excludes = {character, espFolder}
    if targetModel then
        table.insert(excludes, targetModel)
    end
    for _, instance in ipairs(additionalExcludes or {}) do
        if instance and instance.Parent then
            table.insert(excludes, instance)
        end
    end
    params.FilterDescendantsInstances = excludes
    params.MaxParts = 30

    local parts = workspace:GetPartBoundsInBox(
        CFrame.new(position),
        -- Narrower shoulder clearance works better in the boat's tight bunks
        -- and passages, without accepting an obviously blocked character spot.
        Vector3.new(1.05, 3.5, 1.05),
        params
    )

    for _, part in ipairs(parts) do
        if part:IsA("BasePart") and part.CanCollide then
            return false
        end
    end

    return true
end

local function addDirection(list, direction)
    if typeof(direction) ~= "Vector3" then return end

    local flat = Vector3.new(direction.X, 0, direction.Z)
    if flat.Magnitude < 0.05 then return end
    flat = flat.Unit

    for _, existing in ipairs(list) do
        if existing:Dot(flat) > 0.985 then
            return
        end
    end

    table.insert(list, flat)
end

local function getApproachDirections(prompt, hostPart, phase)
    local directions = {}
    local promptFrame = nil

    if prompt.Parent:IsA("Attachment") then
        promptFrame = prompt.Parent.WorldCFrame
    elseif hostPart then
        promptFrame = hostPart.CFrame
    end

    if promptFrame then
        -- Prefer the front of the prompt attachment, then the reverse.
        addDirection(directions, promptFrame.LookVector)
        addDirection(directions, -promptFrame.LookVector)
        addDirection(directions, promptFrame.RightVector)
        addDirection(directions, -promptFrame.RightVector)
    end

    -- Add a ring of alternatives for props whose attachment is not
    -- oriented toward the room. Rotate the ring on subsequent retries.
    local phaseOffset = (phase or 0) * math.rad(11.25)
    for index = 0, 31 do
        local angle = (math.pi * 2 * index / 32) + phaseOffset
        addDirection(directions, Vector3.new(math.cos(angle), 0, math.sin(angle)))
    end

    return directions
end

local function isLikelyWalkableSurface(instance)
    if not instance or not instance:IsA("BasePart") or not instance.CanCollide then
        return false
    end

    local name = instance.Name:lower()
    for _, word in ipairs({"floor", "deck", "ground", "walkway", "plank", "platform"}) do
        if name:find(word, 1, true) then
            return true
        end
    end

    -- A ship deck is normally a broad part or a broad floor tile. Small
    -- circular/box-shaped tops are deliberately rejected (barrels, crates,
    -- and other props must not be mistaken for safe ground).
    local horizontalA = instance.Size.X
    local horizontalB = instance.Size.Z
    local largest = math.max(horizontalA, horizontalB)
    local smallest = math.min(horizontalA, horizontalB)
    -- Deck boards can be long but comparatively narrow. Permit narrow,
    -- elongated floor pieces; small barrel/crate tops remain rejected.
    return (largest >= 3.2 and smallest >= 0.35)
        or (smallest >= 2.6 and largest >= 2.6)
end

-- The two troublesome MOUSE search prompts are nested under Bunk models,
-- but their physical searchable geometry is the actual descendant Model named
-- "Bed". Use that full model's bounds instead of a tiny internal prompt host
-- part when choosing a safe floor position.
local function findBedGeometryModel(prompt, fallbackModel)
    local boat = getBoat()
    local current = prompt and prompt.Parent
    while current and current ~= boat and current ~= workspace do
        if current:IsA("Model") then
            local name = current.Name:lower()
            local kit = tostring(current:GetAttribute("Kit") or ""):lower()
            if name == "bed" or name:match("bed$") or kit == "bed" then
                return current
            end
        end
        current = current.Parent
    end

    if fallbackModel and fallbackModel:IsA("Model") then
        local name = fallbackModel.Name:lower()
        local kit = tostring(fallbackModel:GetAttribute("Kit") or ""):lower()
        if name == "bed" or name:match("bed$") or kit == "bed" then
            return fallbackModel
        end
    end

    return nil
end

-- Resolve the actual searchable geometry instead of blindly using its nearest
-- Kit ancestor. Some Kit models are whole rooms; excluding those from floor
-- raycasts can make the route planner find a lower deck underneath the item.
local function getSearchGeometryBounds(prompt, targetModel, hostPart, bedGeometry)
    local function boundsFor(instance)
        if not instance or not instance.Parent then return nil end
        local ok, frame, size = pcall(function()
            if instance:IsA("Model") then
                return instance:GetBoundingBox()
            elseif instance:IsA("BasePart") then
                return instance.CFrame, instance.Size
            end
            return nil, nil
        end)
        if not ok or not frame or not size then return nil end

        local largest = math.max(size.X, size.Y, size.Z)
        local volume = size.X * size.Y * size.Z
        if largest < 0.12 or largest > 18 or volume < 0.015 then
            return nil
        end
        return frame, size, volume
    end

    -- Beds have a known nested physical model named Bed. Use it first, but
    -- validate its vertical relationship to the actual prompt host as well.
    -- A multi-level Bunk/Bed wrapper must never move the target between decks.
    if bedGeometry then
        local frame, size = boundsFor(bedGeometry)
        if frame then
            local hostY = hostPart and hostPart:IsA("BasePart") and hostPart.Position.Y or frame.Position.Y
            local verticalCentreDelta = math.abs(frame.Position.Y - hostY)
            if size.Y <= 5.0 and verticalCentreDelta <= 2.5 then
                return frame, size, bedGeometry
            end
            warn(
                "[MOUSE AUTOFARM] Rejected bed bounds spanning another level:",
                bedGeometry:GetFullName(),
                "| height:", string.format("%.2f", size.Y),
                "| centre delta from prompt host:", string.format("%.2f", verticalCentreDelta)
            )
        end
    end

    -- The old resolver trusted targetModel (the nearest Model carrying a Kit
    -- attribute). In some MOUSE layouts that Kit is a room/structure containing
    -- multiple levels. Its bounding-box centre can therefore sit on the wrong
    -- floor even though the prompt itself is on the lower deck.
    --
    -- Walk from the prompt host outward and select the nearest compact model
    -- that actually contains the host part. Reject room-sized and multi-level
    -- groups; those are never valid searchable geometry for this target.
    local boat = getBoat()
    local current = prompt and prompt.Parent
    local visited = {}
    while current and current ~= boat and current ~= workspace do
        if current:IsA("Model") and not visited[current] then
            visited[current] = true
            local containsHost = hostPart
                and (current == hostPart or hostPart:IsDescendantOf(current))
            if containsHost then
                local frame, size, volume = boundsFor(current)
                if frame then
                    local largestHorizontal = math.max(size.X, size.Z)
                    local hostY = hostPart and hostPart:IsA("BasePart")
                        and hostPart.Position.Y or frame.Position.Y
                    local verticalCentreDelta = math.abs(frame.Position.Y - hostY)
                    -- Tight vertical bounds are the crucial floor guard. A Kit
                    -- that encloses both the first and second decks is rejected
                    -- even if its total bounding box happens to be under 18 studs.
                    local sameDeckItem = size.Y <= 5.0
                        and verticalCentreDelta <= 2.5
                    local compactItem = largestHorizontal <= 10.5
                        and sameDeckItem
                        and volume <= 450
                    if compactItem then
                        print(
                            "[MOUSE AUTOFARM] Search geometry selected:",
                            current:GetFullName(),
                            "| size:", tostring(size),
                            "| centre:", tostring(frame.Position)
                        )
                        return frame, size, current
                    end
                end
            end
        end
        current = current.Parent
    end

    -- A Kit/ancestor that contains multiple rooms or floors is intentionally
    -- not used. The actual prompt host is tied to the correct searchable and
    -- always preserves that item's own deck height.
    if hostPart and hostPart:IsA("BasePart") then
        local frame, size = boundsFor(hostPart)
        if frame then
            print(
                "[MOUSE AUTOFARM] Using prompt host as floor-safe item geometry:",
                hostPart:GetFullName(),
                "| size:", tostring(size),
                "| centre:", tostring(frame.Position)
            )
            return frame, size, hostPart
        end
    end

    -- Attachment prompt fallback: use its host BasePart, even if a full item
    -- model is unavailable.
    local _, resolvedHost = getPromptAnchor(prompt)
    if resolvedHost and resolvedHost:IsA("BasePart") then
        local frame, size = boundsFor(resolvedHost)
        if frame then return frame, size, resolvedHost end
    end

    -- Do not fall back to a potentially multi-floor targetModel. A wrong-level
    -- destination is worse than declining this target and retrying it.
    return nil, nil, nil
end


-- Resolve a searchable's interior target using its own deck level.
-- Important: Model:GetBoundingBox() on a Bunk/Kit wrapper can span more than
-- one deck. Therefore, only same-level BaseParts around the actual prompt host
-- contribute to the item centre. The vertical level is anchored to the prompt
-- host and verified against the floor directly beneath that same level.
-- Select a position ON the selected searchable, not beside it.
-- The chosen point is the top surface centre whenever the prompt range allows
-- it. If a top-surface point is too far from the prompt, use a point INSIDE the
-- same item's bounds. It never falls back to an exterior floor/side position.
local function getLevelLockedSearchTarget(prompt, targetModel, hostPart, anchor, root, humanoid)
    if not prompt or not prompt.Parent or not anchor then
        return nil, nil, "Search prompt has no usable anchor"
    end
    if not root or not humanoid then
        return nil, nil, "Character root or Humanoid unavailable"
    end

    -- The prompt host is the authoritative deck reference. Never derive the
    -- floor from a broad Bunk/Kit/room model, since those can span two decks.
    local promptParent = prompt.Parent
    local physicalHost = hostPart
    if promptParent:IsA("BasePart") then
        physicalHost = promptParent
    elseif promptParent:IsA("Attachment") and promptParent.Parent
        and promptParent.Parent:IsA("BasePart") then
        physicalHost = promptParent.Parent
    end
    local hostPosition = physicalHost and physicalHost.Position or anchor
    local hostY = hostPosition.Y

    local bedGeometry = findBedGeometryModel(prompt, targetModel)
    local geometryRoot = bedGeometry
    local boat = getBoat()

    -- Prefer the nearest compact model that contains the prompt's real host.
    -- This usually resolves Barrel.Barrel, Bed, PotatoBag, or CoalPit without
    -- using a whole room/Kit bounding box.
    if not geometryRoot then
        local current = promptParent
        while current and current ~= boat and current ~= workspace do
            if current:IsA("Model") then
                local containsHost = physicalHost
                    and physicalHost:IsDescendantOf(current)
                if containsHost then
                    local ok, frame, size = pcall(function()
                        return current:GetBoundingBox()
                    end)
                    if ok and frame and size then
                        local largestHorizontal = math.max(size.X, size.Z)
                        local nearHost = (frame.Position - hostPosition).Magnitude <= 9.0
                        local compactSameLevel = largestHorizontal <= 14.0
                            and size.Y <= 9.0
                            and math.abs(frame.Position.Y - hostY) <= 4.5
                        if nearHost and compactSameLevel then
                            geometryRoot = current
                            break
                        end
                    end
                end
            end
            current = current.Parent
        end
    end

    -- Do not blindly use targetModel if it is a room/Kit wrapper. It is only
    -- a last source of local physical parts, filtered tightly around this prompt.
    geometryRoot = geometryRoot
        or (promptParent:IsA("Model") and promptParent)
        or targetModel
        or physicalHost

    local sourceParts = {}
    local sourceSet = {}
    local function addParts(instance)
        if not instance then return end
        if instance:IsA("BasePart") then
            if not sourceSet[instance] then
                sourceSet[instance] = true
                table.insert(sourceParts, instance)
            end
        elseif instance:IsA("Model") then
            for _, descendant in ipairs(instance:GetDescendants()) do
                if descendant:IsA("BasePart") and not sourceSet[descendant] then
                    sourceSet[descendant] = true
                    table.insert(sourceParts, descendant)
                end
            end
        end
    end

    addParts(geometryRoot)
    addParts(promptParent)
    addParts(physicalHost)
    -- If the local item model was sparse, also inspect the Kit descendants;
    -- candidate parts are still required to be very close to this prompt host.
    if #sourceParts < 2 and targetModel and targetModel ~= geometryRoot then
        addParts(targetModel)
    end

    local function isFloorOrRoomPart(part)
        local name = tostring(part.Name):lower()
        for _, word in ipairs({
            "floor", "deck", "ground", "walkway", "platform", "plank",
            "wall", "bulkhead", "ceiling", "railing", "stair", "ladder"
        }) do
            if name:find(word, 1, true) then return true end
        end
        local size = part.Size
        local broadThinSlab = size.Y <= 0.60
            and math.min(size.X, size.Z) >= 6.5
        return broadThinSlab
    end

    local candidates = {}
    for _, part in ipairs(sourceParts) do
        if part.Parent and part:IsA("BasePart") then
            local size = part.Size
            local maxDimension = math.max(size.X, size.Y, size.Z)
            local volume = size.X * size.Y * size.Z
            local name = tostring(part.Name):lower()
            local marker = (name:find("prompt", 1, true)
                or name:find("trigger", 1, true)
                or name:find("interaction", 1, true))
                and part.Transparency >= 0.5
            local horizontalDistance = Vector3.new(
                part.Position.X - hostPosition.X, 0,
                part.Position.Z - hostPosition.Z
            ).Magnitude
            local verticalHalfExtent = size.Y * 0.5
            local verticalGap = math.max(0, math.abs(part.Position.Y - hostY) - verticalHalfExtent)
            local isPhysicalHost = part == physicalHost
            local reasonable = maxDimension <= 26
                and size.Y <= 12
                and volume >= 0.004
            local sameDeck = verticalGap <= 4.75
            local localToPrompt = horizontalDistance <= 8.5

            if reasonable and sameDeck and localToPrompt
                and not isFloorOrRoomPart(part) and (not marker or isPhysicalHost) then
                local score = horizontalDistance
                    + verticalGap * 1.6
                    + (part.CanCollide and 0 or 0.20)
                    + (isPhysicalHost and -2.0 or 0)
                table.insert(candidates, {Part = part, Score = score})
            end
        end
    end

    table.sort(candidates, function(a, b)
        return a.Score < b.Score
    end)

    -- Anchor fallback: a ProximityPrompt's host is already attached to the
    -- selected searchable. If its mesh/model is unusually named or invisible,
    -- using this exact host/attachment point is safer than rejecting the item
    -- or sending the avatar to an unrelated floor/side position.
    local selectedParts = {}
    local selectedSet = {}
    local bestPart = candidates[1] and candidates[1].Part or nil
    if not bestPart and physicalHost and physicalHost.Parent
        and not isFloorOrRoomPart(physicalHost) then
        bestPart = physicalHost
    end

    if bestPart then
        local bestPosition = bestPart.Position
        for _, candidate in ipairs(candidates) do
            local part = candidate.Part
            local localCluster = (part.Position - bestPosition).Magnitude <= 4.75
                and math.abs(part.Position.Y - bestPosition.Y) <= 4.25
            if localCluster and not selectedSet[part] then
                selectedSet[part] = true
                table.insert(selectedParts, part)
            end
        end
        if #selectedParts == 0 then
            selectedParts[1] = bestPart
        end
    elseif physicalHost and physicalHost.Parent and not isFloorOrRoomPart(physicalHost) then
        selectedParts[1] = physicalHost
        bestPart = physicalHost
    end

    local minX, minY, minZ = math.huge, math.huge, math.huge
    local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
    for _, part in ipairs(selectedParts) do
        local half = part.Size * 0.5
        local cf = part.CFrame
        local right, up, look = cf.RightVector, cf.UpVector, cf.LookVector
        local ex = math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(look.X) * half.Z
        local ey = math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(look.Y) * half.Z
        local ez = math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(look.Z) * half.Z
        minX = math.min(minX, part.Position.X - ex)
        maxX = math.max(maxX, part.Position.X + ex)
        minY = math.min(minY, part.Position.Y - ey)
        maxY = math.max(maxY, part.Position.Y + ey)
        minZ = math.min(minZ, part.Position.Z - ez)
        maxZ = math.max(maxZ, part.Position.Z + ez)
    end

    local usedAnchorFallback = #selectedParts == 0
    if usedAnchorFallback then
        -- A small virtual box centred on the exact prompt anchor guarantees a
        -- same-floor target even when the game uses a non-physical prompt host.
        minX, maxX = anchor.X - 0.45, anchor.X + 0.45
        minY, maxY = anchor.Y - 0.45, anchor.Y + 0.45
        minZ, maxZ = anchor.Z - 0.45, anchor.Z + 0.45
        warn("[MOUSE AUTOFARM] No item mesh found; using the selected prompt's exact anchor:", prompt:GetFullName())
    end

    local width = maxX - minX
    local depth = maxZ - minZ
    local height = maxY - minY

    -- A loose Kit can still have pulled unrelated nearby parts into the cluster.
    -- If the resulting bounds are room-sized, keep only the closest real part.
    if width > 12.0 or depth > 12.0 or height > 8.0 then
        if bestPart then
            local half = bestPart.Size * 0.5
            local cf = bestPart.CFrame
            local right, up, look = cf.RightVector, cf.UpVector, cf.LookVector
            local ex = math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(look.X) * half.Z
            local ey = math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(look.Y) * half.Z
            local ez = math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(look.Z) * half.Z
            minX, maxX = bestPart.Position.X - ex, bestPart.Position.X + ex
            minY, maxY = bestPart.Position.Y - ey, bestPart.Position.Y + ey
            minZ, maxZ = bestPart.Position.Z - ez, bestPart.Position.Z + ez
            selectedParts = {bestPart}
            width, depth, height = maxX - minX, maxZ - minZ, maxY - minY
        else
            minX, maxX = anchor.X - 0.45, anchor.X + 0.45
            minY, maxY = anchor.Y - 0.45, anchor.Y + 0.45
            minZ, maxZ = anchor.Z - 0.45, anchor.Z + 0.45
            usedAnchorFallback = true
        end
    end

    -- Degenerate meshes (for example a thin trigger mesh) still get a usable
    -- interior box centred on their real host rather than causing a hard failure.
    local centerX = (minX + maxX) * 0.5
    local centerY = (minY + maxY) * 0.5
    local centerZ = (minZ + maxZ) * 0.5
    if width < 0.35 then minX, maxX = centerX - 0.175, centerX + 0.175 end
    if depth < 0.35 then minZ, maxZ = centerZ - 0.175, centerZ + 0.175 end
    if height < 0.35 then minY, maxY = centerY - 0.175, centerY + 0.175 end

    width, depth, height = maxX - minX, maxZ - minZ, maxY - minY
    local standingHeight = humanoid.HipHeight + root.Size.Y * 0.5 + 0.12
    local topPosition = Vector3.new(
        (minX + maxX) * 0.5,
        maxY + standingHeight,
        (minZ + maxZ) * 0.5
    )
    local insidePosition = Vector3.new(
        (minX + maxX) * 0.5,
        (minY + maxY) * 0.5,
        (minZ + maxZ) * 0.5
    )

    local promptRange = applyLocalPromptRange(prompt, targetModel)
    local safeRange = math.max(0.5, promptRange - 0.20)
    local destination, destinationMode
    if not usedAnchorFallback and (topPosition - anchor).Magnitude <= safeRange then
        destination = topPosition
        destinationMode = "TOP OF SELECTED ITEM"
    elseif (insidePosition - anchor).Magnitude <= safeRange then
        destination = insidePosition
        destinationMode = "INSIDE SELECTED ITEM"
    else
        -- The prompt anchor itself belongs to this selected searchable and is
        -- always the closest valid same-deck point. Never substitute a side or
        -- a floor from another level simply to satisfy range/geometry checks.
        destination = anchor
        destinationMode = "EXACT SELECTED PROMPT ANCHOR"
        usedAnchorFallback = true
    end

    print(
        "[MOUSE AUTOFARM] VALIDATED ITEM TARGET:", prompt:GetFullName(),
        "| root:", geometryRoot and geometryRoot:GetFullName() or "prompt anchor",
        "| parts:", #selectedParts,
        "| mode:", destinationMode,
        "| bounds:", string.format("X %.2f..%.2f Y %.2f..%.2f Z %.2f..%.2f", minX, maxX, minY, maxY, minZ, maxZ),
        "| anchor:", tostring(anchor),
        "| destination:", tostring(destination)
    )

    local meta = {
        BoundsMin = Vector3.new(minX, minY, minZ),
        BoundsMax = Vector3.new(maxX, maxY, maxZ),
        AnchorY = anchor.Y,
        TopRootY = topPosition.Y,
        StandingHeight = standingHeight,
        Mode = destinationMode,
        UsedAnchorFallback = usedAnchorFallback,
        ItemHeight = height,
        GeometryPart = bestPart
    }
    return destination, minY, nil, meta
end

local function isBedSearchEntry(prompt, model)
    if not prompt then return false end
    if findBedGeometryModel(prompt, model) then return true end

    local path = prompt:GetFullName():lower()
    return path:find(".bunk.bed", 1, true) ~= nil
        or path:find(".bunk.bunk.bed", 1, true) ~= nil
end

local function findPromptCenteredPositions(prompt, model, phase, floorMode, anchor, hostPart, range, root, humanoid)
    local targetModel = model or getTargetModel(prompt)
    local bedGeometry = floorMode == "search" and findBedGeometryModel(prompt, targetModel) or nil
    local verticalBoundsFrame, verticalBoundsSize, searchableGeometry
    if floorMode == "search" then
        verticalBoundsFrame, verticalBoundsSize, searchableGeometry =
            getSearchGeometryBounds(prompt, targetModel, hostPart, bedGeometry)
    end
    -- Avoid treating a large room/Kit ancestor as the searchable itself.
    local geometryModel = bedGeometry or searchableGeometry
        or (hostPart and hostPart:IsA("BasePart") and hostPart)
        or (targetModel and targetModel:IsA("BasePart") and targetModel)
    local character = getCharacter()
    if not character then
        return {}, "Character unavailable"
    end

    -- Search targets are computed from the selected item's same-deck physical
    -- parts. This prevents a two-storey Bunk/Kit bounding box from selecting
    -- the wrong level while keeping the destination inside the selected item.
    if floorMode == "search" then
        local center, floorY, targetError, targetMeta = getLevelLockedSearchTarget(
            prompt, targetModel, hostPart, anchor, root, humanoid
        )
        if not center then
            return {}, targetError or "Could not validate the selected searchable's prompt-local position"
        end

        local towardCenter = Vector3.new(
            center.X - root.Position.X,
            0,
            center.Z - root.Position.Z
        )
        local facingDirection = towardCenter.Magnitude > 0.05
            and towardCenter.Unit
            or Vector3.new(0, 0, -1)

        return {{
            Position = center,
            ItemCenter = center,
            ItemCenterY = center.Y,
            FloorY = floorY,
            ItemBoundsMin = targetMeta and targetMeta.BoundsMin or nil,
            ItemBoundsMax = targetMeta and targetMeta.BoundsMax or nil,
            AnchorY = targetMeta and targetMeta.AnchorY or anchor.Y,
            TopRootY = targetMeta and targetMeta.TopRootY or center.Y,
            StandingHeight = targetMeta and targetMeta.StandingHeight or (humanoid.HipHeight + root.Size.Y * 0.5),
            ItemHeight = targetMeta and targetMeta.ItemHeight or 1.0,
            TargetMode = targetMeta and targetMeta.Mode or "PROMPT ANCHOR",
            UsedAnchorFallback = targetMeta and targetMeta.UsedAnchorFallback or false,
            Score = (center - root.Position).Magnitude,
            Direction = facingDirection,
            Radius = 0,
            Interior = true,
            CenteredInside = true
        }}, "Using level-locked centre of selected searchable"
    end

    local promptFrame = nil
    if prompt.Parent and prompt.Parent:IsA("Attachment") then
        promptFrame = prompt.Parent.WorldCFrame
    elseif hostPart then
        promptFrame = hostPart.CFrame
    end

    if bedGeometry then
        local ok, bedFrame = pcall(function()
            local frame = bedGeometry:GetBoundingBox()
            return frame
        end)
        if ok and bedFrame then
            promptFrame = bedFrame
        end
    end

    local forward = Vector3.new(0, 0, -1)
    local right = Vector3.new(1, 0, 0)
    if promptFrame then
        local look = Vector3.new(promptFrame.LookVector.X, 0, promptFrame.LookVector.Z)
        local side = Vector3.new(promptFrame.RightVector.X, 0, promptFrame.RightVector.Z)
        if look.Magnitude > 0.05 then forward = look.Unit end
        if side.Magnitude > 0.05 then right = side.Unit end
    else
        local fromPlayer = Vector3.new(root.Position.X - anchor.X, 0, root.Position.Z - anchor.Z)
        if fromPlayer.Magnitude > 0.05 then forward = fromPlayer.Unit end
        right = Vector3.new(-forward.Z, 0, forward.X)
    end

    -- At the start of this phase the character has just used the engine
    -- stopper, which is on the ship's interior side. Prefer that live position
    -- as the reference for "behind the padlocks". The Boat bounding-box centre
    -- is only a fallback because it can be skewed by the hull/rigging models.
    local inward = -forward
    local directionSource = "prompt orientation fallback"
    local playerSide = Vector3.new(
        root.Position.X - anchor.X,
        0,
        root.Position.Z - anchor.Z
    )
    if floorMode == "padlock" and playerSide.Magnitude > 1.25 then
        inward = playerSide.Unit
        directionSource = "current engine-side player position"
    else
        local boatForDirection = getBoat()
        if boatForDirection then
            local ok, boxFrame = pcall(function()
                if boatForDirection:IsA("Model") then
                    return boatForDirection:GetBoundingBox()
                elseif boatForDirection:IsA("BasePart") then
                    return boatForDirection.CFrame
                end
                return nil
            end)
            if ok and boxFrame then
                local towardCenter = Vector3.new(
                    boxFrame.Position.X - anchor.X,
                    0,
                    boxFrame.Position.Z - anchor.Z
                )
                if towardCenter.Magnitude > 1.0 then
                    inward = towardCenter.Unit
                    directionSource = "boat bounding-box centre"
                end
            end
        end
    end
    right = Vector3.new(-inward.Z, 0, inward.X)

    if floorMode == "padlock" then
        print(
            "[MOUSE AUTOFARM] Padlock inside direction:",
            directionSource,
            "| direction:",
            tostring(inward),
            "| player position:",
            tostring(root.Position),
            "| prompt position:",
            tostring(anchor)
        )
    end

    local offsets = {}
    local function addOffset(offset)
        local flat = Vector3.new(offset.X, 0, offset.Z)
        for _, existing in ipairs(offsets) do
            if (existing - flat).Magnitude < 0.12 then
                return
            end
        end
        table.insert(offsets, flat)
    end

    if floorMode == "padlock" then
        -- Only generate positions on the interior/behind side. The old
        -- reverse and full-ring fallbacks allowed a front-side point to win
        -- whenever the lock meshes blocked the line-of-sight/standing checks.
        -- These offsets move past the lock row while staying close enough to
        -- the shared prompt (the later 3-D range check is authoritative).
        for _, distance in ipairs({3.0, 3.35, 3.7, 4.05, 4.4, 4.7}) do
            addOffset(inward * distance)
        end
        for _, sideOffset in ipairs({0.30, 0.55, 0.80}) do
            for _, distance in ipairs({3.25, 3.75, 4.25}) do
                addOffset(inward * distance + right * sideOffset)
                addOffset(inward * distance - right * sideOffset)
            end
        end
    else
        -- Never place the character at the center of a bed/barrel/bag. The old
        -- zero-to-one-stud offsets could overlap the searchable after its model
        -- was excluded from the floor ray. Stand outside its projected bounds.
        local searchDirections = {
            forward, -forward, right, -right,
            (forward + right).Unit,
            (forward - right).Unit,
            (-forward + right).Unit,
            (-forward - right).Unit
        }

        -- The search entry's Kit model can be an entire room/structure rather
        -- than the item itself (notably CaptainWillie.CoalPit). Use the actual
        -- prompt host part first so the computed approach stays within the
        -- room and inside the prompt's reach. The full model is only a fallback
        -- when the prompt has no usable host part.
        local boundsCenter = anchor
        local boundsSize = Vector3.new(2, 1, 2)
        local boundsFrame = CFrame.new(anchor)
        if bedGeometry then
            local ok, boxFrame, size = pcall(function()
                return bedGeometry:GetBoundingBox()
            end)
            if ok and boxFrame and size then
                boundsFrame = boxFrame
                boundsCenter = boxFrame.Position
                boundsSize = size
            end
        elseif hostPart and hostPart:IsA("BasePart") then
            boundsFrame = hostPart.CFrame
            boundsCenter = hostPart.Position
            boundsSize = hostPart.Size
        elseif targetModel and targetModel:IsA("Model") then
            local ok, boxFrame, size = pcall(function()
                return targetModel:GetBoundingBox()
            end)
            if ok and boxFrame and size then
                boundsFrame = boxFrame
                boundsCenter = boxFrame.Position
                boundsSize = size
            end
        elseif targetModel and targetModel:IsA("BasePart") then
            boundsFrame = targetModel.CFrame
            boundsCenter = targetModel.Position
            boundsSize = targetModel.Size
        end

        if bedGeometry then
            -- Rotate the preferred sides on each deferred retry. This avoids
            -- repeating the exact same rejected bunk-side destination.
            local shift = (tonumber(phase) or 0) % #searchDirections
            for _ = 1, shift do
                table.insert(searchDirections, 1, table.remove(searchDirections))
            end
        end

        for _, direction in ipairs(searchDirections) do
            -- Project the oriented bounding box onto the world-space approach
            -- direction so rotated props cannot be approached through their
            -- physical footprint.
            local boxRight = Vector3.new(boundsFrame.RightVector.X, 0, boundsFrame.RightVector.Z)
            local boxLook = Vector3.new(boundsFrame.LookVector.X, 0, boundsFrame.LookVector.Z)
            if boxRight.Magnitude > 0.05 then boxRight = boxRight.Unit end
            if boxLook.Magnitude > 0.05 then boxLook = boxLook.Unit end
            local halfExtent = math.abs(direction:Dot(boxRight)) * boundsSize.X * 0.5
                + math.abs(direction:Dot(boxLook)) * boundsSize.Z * 0.5
            local anchorToCenter = Vector3.new(
                boundsCenter.X - anchor.X,
                0,
                boundsCenter.Z - anchor.Z
            )
            local bedClearance = bedGeometry and 1.55 or 0.95
            local minimumOutsideOffset = bedGeometry and 1.75 or 1.45
            local maxApproachDistance = math.max(1.35, range - (bedGeometry and 1.0 or 0.85))
            local requiredOffset = math.clamp(
                math.max(minimumOutsideOffset, halfExtent + anchorToCenter:Dot(direction) + bedClearance),
                1.35,
                maxApproachDistance
            )

            local extraOffsets = bedGeometry
                and {0, 0.35, 0.70, 1.05}
                or {0, 0.45, 0.9, 1.35, 1.8}
            for _, extra in ipairs(extraOffsets) do
                local distance = requiredOffset + extra
                if distance <= range - 0.65 then
                    addOffset(direction * distance)
                end
            end
        end
    end

    local baseFilters = {character, espFolder}
    if floorMode == "search" then
        -- Exclude only the actual item geometry. Do not exclude a large Kit
        -- ancestor (which may contain the real deck surface below the item).
        if searchableGeometry then
            table.insert(baseFilters, searchableGeometry)
        elseif targetModel and targetModel:IsA("BasePart") then
            table.insert(baseFilters, targetModel)
        end
    elseif bedGeometry then
        table.insert(baseFilters, bedGeometry)
    elseif targetModel then
        table.insert(baseFilters, targetModel)
    end

    -- The padlock row may be made from several adjacent lock meshes rather
    -- than one named Model. Ignore only lock-named pieces close to this prompt
    -- during deck and standing-room checks, so those meshes don't hide the
    -- deck or falsely report that the player cannot stand just behind them.
    local nearbyLockParts = {}
    if floorMode == "padlock" then
        for _, object in ipairs(workspace:GetDescendants()) do
            if object:IsA("BasePart")
                and (object.Position - anchor).Magnitude <= 5.5 then
                local cursor = object
                local lockNamed = false
                while cursor and cursor ~= workspace do
                    local objectName = cursor.Name:lower()
                    if objectName:find("padlock", 1, true)
                        or objectName:match("%f[%a]lock%f[%A]")
                        or objectName:find("lock_", 1, true)
                        or objectName:find("_lock", 1, true) then
                        lockNamed = true
                        break
                    end
                    cursor = cursor.Parent
                end
                if lockNamed and object ~= targetModel then
                    table.insert(nearbyLockParts, object)
                    table.insert(baseFilters, object)
                end
            end
        end
    end

    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.IgnoreWater = true

    local standingHeight = humanoid.HipHeight + root.Size.Y * 0.5 + 0.12
    local minFloorDrop
    if floorMode == "padlock" then
        -- The shared prompt can be attached below or beside the deck edge.
        -- Permit the deck to be slightly above the prompt anchor, but continue
        -- to require a broad, collidable, upward-facing floor/deck surface.
        minFloorDrop = -0.75
    else
        minFloorDrop = -0.60
    end
    local maxFloorDrop = range + standingHeight + 2.0
    local rayLength = range + standingHeight + 18.0
    local candidates = {}

    for offsetIndex, offset in ipairs(offsets) do
        local x = anchor.X + offset.X
        local z = anchor.Z + offset.Z
        local origin = Vector3.new(x, anchor.Y + 8.0, z)
        local currentFilters = table.clone(baseFilters)

        -- Keep casting at this exact prompt-side X/Z, ignoring raised object
        -- surfaces until the deck/floor below the searchable is reached.
        for _ = 1, 28 do
            rayParams.FilterDescendantsInstances = currentFilters
            local hit = workspace:Raycast(
                origin,
                Vector3.new(0, -rayLength, 0),
                rayParams
            )

            if not hit then
                break
            end

            local floorDrop = anchor.Y - hit.Position.Y
            local floorAlignedWithItem = true
            if floorMode == "search" and verticalBoundsFrame and verticalBoundsSize then
                local itemBottomY = verticalBoundsFrame.Position.Y - verticalBoundsSize.Y * 0.5
                local floorBelowItemBottom = itemBottomY - hit.Position.Y
                -- Reject a lower deck/floor far beneath the searchable. A valid
                -- floor should be close to the item's bottom, not a level below it.
                floorAlignedWithItem = floorBelowItemBottom >= -0.90
                    and floorBelowItemBottom <= 3.50
            end

            local usableFloor = isLikelyWalkableSurface(hit.Instance)
                and hit.Normal.Y >= 0.70
                and hit.Material ~= Enum.Material.Water
                and floorDrop >= minFloorDrop
                and floorDrop <= maxFloorDrop
                and floorAlignedWithItem

            if usableFloor then
                local positionY = hit.Position.Y + standingHeight
                if floorMode == "search" and verticalBoundsFrame then
                    -- Keep the root at least at deck standing height, but lift
                    -- it toward the item's centre when its prompt/floor reference
                    -- would otherwise place the avatar underneath a raised prop.
                    local itemCenterY = verticalBoundsFrame.Position.Y
                    local preferredY = math.max(positionY, itemCenterY + 0.10)
                    local horizontalInset = 0.55
                    local usablePromptRange = math.max(0, range - 0.25)
                    local verticalReach = math.sqrt(math.max(
                        0,
                        usablePromptRange * usablePromptRange - horizontalInset * horizontalInset
                    ))
                    local maxYWithinPromptRange = anchor.Y + verticalReach
                    positionY = math.max(positionY, math.min(preferredY, maxYWithinPromptRange))
                end

                local position = Vector3.new(x, positionY, z)
                local promptDistance = (position - anchor).Magnitude
                local rangeMargin = floorMode == "padlock" and 0.25 or 0.20
                local inRange = promptDistance <= range - rangeMargin

                -- A point behind the lock row is expected to be visually
                -- occluded by the chains/lock bodies. Do not reject it as a
                -- wall. The padlock interaction temporarily disables the
                -- prompt's client-side LOS requirement and restores it after.
                local clear
                if floorMode == "padlock" then
                    clear = inRange
                else
                    clear = inRange and hasClearView(
                        position,
                        anchor,
                        prompt,
                        geometryModel,
                        true
                    )
                end

                local room = false
                if clear then
                    if floorMode == "padlock" then
                        -- This route deliberately places the avatar behind and
                        -- partially inside the lock row. Collision clearance
                        -- against those meshes is not a valid rejection test;
                        -- the deck raycast and prompt-range checks remain active.
                        room = true
                    else
                        room = hasStandingRoom(position, geometryModel, nil)
                    end
                end

                local inwardDistance = offset:Dot(inward)
                local isInteriorSide = floorMode ~= "padlock" or inwardDistance >= 2.85

                if inRange and clear and room and isInteriorSide then
                    local playerDistance = (position - root.Position).Magnitude
                    local inwardBonus = floorMode == "padlock" and inwardDistance or 0

                    table.insert(candidates, {
                        Position = position,
                        ItemCenterY = verticalBoundsFrame and verticalBoundsFrame.Position.Y or nil,
                        Score = floorMode == "padlock"
                            and (offset.Magnitude * 1.0
                                + promptDistance * 0.04
                                + playerDistance * 0.002
                                - inwardBonus * 3.0)
                            or (bedGeometry
                                and (offset.Magnitude * 1.65
                                    + promptDistance * 0.035
                                    + playerDistance * 0.012)
                                or (offset.Magnitude * 3.0
                                    + promptDistance * 0.08
                                    + playerDistance * 0.005)),
                        Direction = offset.Magnitude > 0.05 and offset.Unit or forward,
                        Radius = offset.Magnitude,
                        Interior = floorMode == "padlock"
                    })
                    break
                end
            end

            -- If this hit is a container lid, lock plate, railing, or other
            -- elevated surface, exclude it and continue toward the deck.
            table.insert(currentFilters, hit.Instance)
        end
    end

    table.sort(candidates, function(a, b)
        return a.Score < b.Score
    end)

    local filtered = {}
    for _, candidate in ipairs(candidates) do
        local duplicate = false
        for _, existing in ipairs(filtered) do
            if (candidate.Position - existing.Position).Magnitude < 0.45 then
                duplicate = true
                break
            end
        end
        if not duplicate then
            table.insert(filtered, candidate)
            if #filtered >= 10 then break end
        end
    end

    if #filtered > 0 then
        return filtered
    end

    -- Never use a guessed Y coordinate as a padlock fallback. If no floor
    -- surface was validated, retry the prompt instead of risking a teleport
    -- onto the lock housing, inside a wall, or through the deck.
    return {}, floorMode == "padlock"
        and "No validated deck position was found on the inside/behind side of the padlocks"
        or "No safe floor position outside the searchable was found"
end

local function findApproachPositions(prompt, model, phase, preferBack, forceLineOfSight, floorMode)
    local root = getRoot()
    local humanoid = getHumanoid()
    if not root or not humanoid then
        return {}, "Character unavailable"
    end

    if not prompt or not prompt.Parent then
        return {}, "Prompt disappeared"
    end

    local anchor, hostPart = getPromptAnchor(prompt)
    if not anchor or not hostPart then
        return {}, "Prompt has no parent part"
    end

    local range, usedKnownFallback = applyLocalPromptRange(prompt, model)
    if range < 2 then
        return {}, "Prompt reach unavailable"
    end
    if usedKnownFallback and not promptRangeFallbackWarned[prompt] then
        promptRangeFallbackWarned[prompt] = true
        warn(
            "[MOUSE AUTOFARM] Using the inspected MOUSE fallback reach of 9 for:",
            prompt:GetFullName()
        )
    end

    local targetModel = model or getTargetModel(prompt)

    if floorMode == "search" or floorMode == "padlock" then
        return findPromptCenteredPositions(
            prompt,
            targetModel,
            phase or 0,
            floorMode,
            anchor,
            hostPart,
            range,
            root,
            humanoid
        )
    end

    local filters = {getCharacter(), espFolder}
    if targetModel then table.insert(filters, targetModel) end

    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = filters
    rayParams.IgnoreWater = true

    local rootHalfHeight = root.Size.Y * 0.5
    local standingHeight = humanoid.HipHeight + rootHalfHeight + 0.12

    local baseRadius = 1.25
    if hostPart then
        local footprint = math.max(hostPart.Size.X, hostPart.Size.Z)
        baseRadius = math.clamp(footprint * 0.18 + 0.85, 1.25, 2.7)
    end

    local radii = {
        baseRadius,
        baseRadius + 0.35,
        baseRadius + 0.7,
        baseRadius + 1.05,
        baseRadius + 1.4,
        baseRadius + 1.75,
        baseRadius + 2.1
    }

    local candidates = {}
    local directions = getApproachDirections(prompt, hostPart, phase)
    local preferredBackDirection = nil

    if preferBack then
        local promptFrame = nil
        if prompt.Parent:IsA("Attachment") then
            promptFrame = prompt.Parent.WorldCFrame
        elseif hostPart then
            promptFrame = hostPart.CFrame
        end

        if promptFrame then
            local back = -promptFrame.LookVector
            local flatBack = Vector3.new(back.X, 0, back.Z)
            if flatBack.Magnitude > 0.05 then
                preferredBackDirection = flatBack.Unit
            end
        end
    end

    for _, direction in ipairs(directions) do
        for _, radius in ipairs(radii) do
            if radius < range - 0.35 then
                local candidateXZ = anchor + direction * radius
                -- Start just above the prompt's own deck. Starting 35 studs
                -- above the player's current floor often raycasts the upper
                -- deck/ceiling and misses the correct room floor below.
                local rayOrigin = Vector3.new(
                    candidateXZ.X,
                    anchor.Y + 9,
                    candidateXZ.Z
                )

                local currentFilters = table.clone(filters)

                -- Try successive floor surfaces. This lets us ignore a
                -- ceiling/upper deck and test the floor on the target deck.
                for _ = 1, 12 do
                    rayParams.FilterDescendantsInstances = currentFilters
                    local hit = workspace:Raycast(
                        rayOrigin,
                        Vector3.new(0, -55, 0),
                        rayParams
                    )

                    if not hit then break end

                    local floorDrop = anchor.Y - hit.Position.Y
                    local minFloorDrop = (floorMode == "padlock") and 0.8 or 0.10
                    local maxFloorDrop = (floorMode == "padlock") and 9.0 or 12.0

                    -- Reject raised horizontal surfaces (such as the tops of
                    -- lock housings or containers) and continue raycasting to
                    -- the deck/floor beneath them.
                    local usableFloor = hit.Instance:IsA("BasePart")
                        and hit.Instance.CanCollide
                        and hit.Normal.Y >= 0.68
                        and hit.Material ~= Enum.Material.Water
                        and floorDrop >= minFloorDrop
                        and floorDrop <= maxFloorDrop

                    if usableFloor then
                        local position = Vector3.new(
                            candidateXZ.X,
                            hit.Position.Y + standingHeight,
                            candidateXZ.Z
                        )

                        local promptDistance = (position - anchor).Magnitude
                        local inRange = promptDistance <= range - 0.25
                        local clear = inRange and hasClearView(position, anchor, prompt, targetModel, forceLineOfSight == true)
                        local room = clear and hasStandingRoom(position, targetModel)

                        if inRange and clear and room then
                            local playerDistance = (position - root.Position).Magnitude
                            local facingBonus = direction:Dot(
                                getApproachDirections(prompt, hostPart, 0)[1] or direction
                            )

                            local backSideBonus = 0
                            if preferredBackDirection then
                                backSideBonus = direction:Dot(preferredBackDirection)
                            end

                            local score = playerDistance
                                + promptDistance * 0.12
                                - facingBonus * 0.35
                                - backSideBonus * 5.0

                            table.insert(candidates, {
                                Position = position,
                                Score = score,
                                Direction = direction,
                                Radius = radius
                            })
                        end

                        -- If this deck is too far vertically or out of range,
                        -- exclude this floor surface and test lower surfaces.
                        if inRange and clear and room then
                            break
                        end
                    end

                    table.insert(currentFilters, hit.Instance)
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        return a.Score < b.Score
    end)

    local unique = {}
    local filtered = {}

    for _, candidate in ipairs(candidates) do
        local duplicate = false
        for _, existing in ipairs(filtered) do
            if (candidate.Position - existing.Position).Magnitude < 1.2 then
                duplicate = true
                break
            end
        end

        if not duplicate then
            table.insert(filtered, candidate)
            if #filtered >= 10 then break end
        end
    end

    if #filtered == 0 then
        return {}, "No clear, walkable approach position found"
    end

    return filtered
end

--============================================================
-- CAMERA FACING + PROMPT INPUT
--============================================================

local function restoreCameraToCurrentCharacter()
    cameraControlGeneration += 1

    local camera = workspace.CurrentCamera
    local character = player.Character
    if not camera then return false end

    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.Health > 0 then
        camera.CameraType = Enum.CameraType.Custom
        camera.CameraSubject = humanoid
        return true
    end

    -- Leaving Scriptable mode prevents a dead character's last camera frame
    -- from being held while Roblox builds the replacement character.
    camera.CameraType = Enum.CameraType.Custom
    return false
end

local function withCameraFacing(prompt, token, callback)
    local camera = workspace.CurrentCamera
    local originalCharacter = getCharacter()
    local root = getRoot()
    local humanoid = getHumanoid()
    local anchor = getPromptAnchor(prompt)

    if not camera or not originalCharacter or not root or not humanoid
        or humanoid.Health <= 0 or not anchor then
        return false, "Camera, live character, root, or prompt unavailable"
    end

    cameraControlGeneration += 1
    local myCameraGeneration = cameraControlGeneration

    local savedCamera = {
        Type = camera.CameraType,
        Subject = camera.CameraSubject,
        CFrame = camera.CFrame,
        Focus = camera.Focus,
        FieldOfView = camera.FieldOfView
    }

    local oldAutoRotate = humanoid.AutoRotate
    humanoid.AutoRotate = false
    local active = true
    local cameraConnection = nil

    local function restoreOwnedCamera()
        active = false
        if cameraConnection then
            cameraConnection:Disconnect()
            cameraConnection = nil
        end

        -- A respawn or emergency evasion has already taken ownership. Never
        -- restore a stale pre-death camera subject over the new live character.
        if cameraControlGeneration ~= myCameraGeneration then
            return
        end

        local currentCamera = workspace.CurrentCamera
        if currentCamera and currentCamera.Parent then
            local currentCharacter = player.Character
            local currentHumanoid = currentCharacter
                and currentCharacter:FindFirstChildOfClass("Humanoid")

            if currentCharacter ~= originalCharacter or not humanoid.Parent
                or humanoid.Health <= 0 then
                restoreCameraToCurrentCharacter()
            else
                currentCamera.CameraType = savedCamera.Type
                if savedCamera.Subject and savedCamera.Subject.Parent then
                    currentCamera.CameraSubject = savedCamera.Subject
                elseif currentHumanoid then
                    currentCamera.CameraSubject = currentHumanoid
                end
                currentCamera.FieldOfView = savedCamera.FieldOfView
                if savedCamera.Type == Enum.CameraType.Scriptable then
                    currentCamera.CFrame = savedCamera.CFrame
                    currentCamera.Focus = savedCamera.Focus
                end
            end
        end
    end

    local function facePrompt()
        if player.Character ~= originalCharacter or not root.Parent or humanoid.Health <= 0 then
            return false
        end

        -- Refresh the target every frame so the body/camera lock follows the
        -- selected Search prompt rather than a stale point captured earlier.
        local liveAnchor = getPromptAnchor(prompt)
        if liveAnchor then anchor = liveAnchor end

        local flatTarget = Vector3.new(anchor.X, root.Position.Y, anchor.Z)
        if (flatTarget - root.Position).Magnitude > 0.05 then
            root.CFrame = CFrame.lookAt(root.Position, flatTarget)
        end

        local head = originalCharacter:FindFirstChild("Head")
        local eye = head and head.Position or (root.Position + Vector3.new(0, 2.2, 0))
        camera.CFrame = CFrame.lookAt(eye, anchor)
        camera.Focus = CFrame.new(anchor)
        return true
    end

    camera.CameraType = Enum.CameraType.Scriptable
    if isSearchPrompt(prompt) then
        print("[MOUSE AUTOFARM] LOCKED ONTO selected Search prompt:", prompt:GetFullName())
    end
    facePrompt()

    cameraConnection = RunService.RenderStepped:Connect(function()
        if not active then return end

        if cameraControlGeneration ~= myCameraGeneration
            or player.Character ~= originalCharacter
            or not humanoid.Parent
            or humanoid.Health <= 0 then
            restoreOwnedCamera()
            return
        end

        if camera.Parent then
            facePrompt()
        end
    end)

    RunService.RenderStepped:Wait()

    if token ~= farmToken or not enabled.Autofarm
        or player.Character ~= originalCharacter or humanoid.Health <= 0 then
        restoreOwnedCamera()
        if humanoid.Parent then humanoid.AutoRotate = oldAutoRotate end
        return false, "Autofarm stopped or character changed"
    end

    local ok, result, extra, extra2, extra3 = pcall(callback)
    restoreOwnedCamera()

    if humanoid.Parent then
        humanoid.AutoRotate = oldAutoRotate
    end

    if not ok then
        return false, tostring(result)
    end

    return result, extra, extra2, extra3
end

-- MOUSE searchable interactions can continue after the prompt fires.
-- Search prompts wait one second after teleport, then receive short E taps at
-- a controlled interval until activity or terminal game state is observed.
-- Search prompts use short taps; the engine stopper is explicitly held for at least one second.
local MIN_SEARCH_HOLD = 0.0 -- searchable prompts are quick taps, never long holds
local ENGINE_STOPPER_MIN_HOLD = 1.5 -- always physically hold E for the engine-stopper objective
local SEARCH_ARRIVAL_SETTLE = 0.0 -- send the first E press immediately after arrival
local SEARCH_TRAVEL_SPEED = 24.0 -- moderately fast TweenService travel between searchables
local SEARCH_TRAVEL_MIN_TIME = 0.30
local SEARCH_TRAVEL_MAX_TIME = 10.0
local SEARCH_ITEM_INSET = 0.55 -- retained for the original search-position tuning; final tween ends at the prompt-host centre
local EN_ROUTE_SEARCH_SCAN_INTERVAL = 0.05 -- check frequently enough to catch an item while crossing its prompt radius
local EN_ROUTE_SEARCH_RANGE_MARGIN = 1.25 -- stay safely inside the prompt activation radius
local SEARCH_TAP_DURATION = 0.08 -- short, immediate press/release edge
local SEARCH_TAP_RETRY_INTERVAL = 0.65 -- leaves time for the server to process each E tap
local PROMPT_EVENT_GRACE = 0.80 -- preserve original acknowledgement timing for non-search objectives
local SEARCH_EVENT_GRACE = 0.12 -- quick acknowledgement check for instant searchable taps
local SEARCH_FINISH_DWELL = 0.10 -- tiny replication grace after explicit completion
local SEARCH_SOUND_QUIET_TIME = 0.25
local PROMPT_STATE_QUIET_TIME = 0.25
local PROMPT_DISABLED_QUIET_TIME = SEARCH_DISABLED_CONFIRM_SECONDS
local LOOPED_SOUND_MAX_WAIT = 12.0

local SEARCH_STATE_WORDS = {
    search = true,
    searched = true,
    complete = true,
    completed = true,
    rummage = true,
    loot = true,
    item = true,
    content = true,
    reward = true,
    opened = true,
    open = true,
    empty = true,
    key = true,
    progress = true,
    found = true
}

local function nameHasSearchStateWord(name)
    local normalized = tostring(name):lower():gsub('[^%w]', '')
    for word in pairs(SEARCH_STATE_WORDS) do
        if normalized:find(word, 1, true) then
            return true
        end
    end
    return false
end

local function getSearchStateSignature(prompt, model)
    local parts = {}

    if prompt then
        table.insert(parts, 'P.Enabled=' .. tostring(prompt.Enabled))
        table.insert(parts, 'P.ActionText=' .. tostring(prompt.ActionText))
        table.insert(parts, 'P.ObjectText=' .. tostring(prompt.ObjectText))
    end

    local nodes = {}
    local seen = {}
    local function addNode(node)
        if node and not seen[node] then
            seen[node] = true
            table.insert(nodes, node)
        end
    end

    addNode(prompt)
    addNode(model)
    if prompt and prompt.Parent then addNode(prompt.Parent) end

    if model then
        for _, descendant in ipairs(model:GetDescendants()) do
            addNode(descendant)
        end
    end

    for _, node in ipairs(nodes) do
        local attributes = node:GetAttributes()
        local attributeNames = {}
        for attributeName in pairs(attributes) do
            if nameHasSearchStateWord(attributeName) then
                table.insert(attributeNames, attributeName)
            end
        end
        table.sort(attributeNames)

        for _, attributeName in ipairs(attributeNames) do
            table.insert(parts,
                node:GetFullName() .. '.A.' .. attributeName .. '=' .. tostring(attributes[attributeName]))
        end

        if node:IsA('ValueBase') and nameHasSearchStateWord(node.Name) then
            local value
            pcall(function() value = node.Value end)
            table.insert(parts, node:GetFullName() .. '.V=' .. tostring(value))
        end
    end

    table.sort(parts)
    return table.concat(parts, '|')
end

local function isSearchActivitySound(sound)
    if not sound:IsA('Sound') then
        return false
    end

    local name = sound.Name:lower():gsub('[^%w]', '')

    -- KeysPickup and BagPickupAndDrop are separate pickup/drop effects. They
    -- can play while the search itself is still running, so they must never
    -- be mistaken for the end of the rummage sequence.
    return name:find('rummage', 1, true) ~= nil
        or name:find('search', 1, true) ~= nil
end

local SEARCH_COMPLETE_NAMES = {
    searched = true,
    hassearched = true,
    searchcomplete = true,
    searchcompleted = true,
    searchfinished = true,
    rummagecomplete = true,
    rummagecompleted = true,
    rummaged = true,
    isrummaged = true,
    lootcomplete = true,
    lootcompleted = true,
    looted = true,
    islooted = true
}

local SEARCH_TERMINAL_TEXT = {
    searched = true,
    alreadysearched = true,
    empty = true,
    alreadyempty = true,
    nothingfound = true,
    searchcomplete = true,
    searchcompleted = true,
    rummagecomplete = true,
    rummagecompleted = true,
    looted = true,
    alreadylooted = true
}

local SEARCH_BUSY_TEXT = {
    searching = true,
    rummaging = true,
    rummageinprogress = true,
    pleasewait = true,
    opening = true,
    working = true,
    loading = true
}

local function normalizeSearchText(value)
    return tostring(value or ""):lower():gsub("[^%w]", "")
end

local function hasTerminalSearchText(value)
    local normalized = normalizeSearchText(value)
    if normalized == "" or SEARCH_BUSY_TEXT[normalized] then return false end
    if SEARCH_TERMINAL_TEXT[normalized] then return true end

    -- Only unambiguous multi-word terminal markers may match inside a label.
    -- Generic words like "empty" or "searched" can occur in item names.
    local markers = {
        "alreadysearched", "notsearchable", "cannotsearch", "cantsearch",
        "nothingfound", "nothingleft", "nothingtosearch", "noitemsleft",
        "searchcomplete", "searchcompleted", "searchfinished",
        "rummagecomplete", "rummagecompleted", "alreadylooted"
    }
    for _, marker in ipairs(markers) do
        if normalized:find(marker, 1, true) then return true end
    end
    return false
end

hasExplicitSearchCompletion = function(prompt, model)
    if not prompt then return false end
    if not prompt.Parent then return true end

    if hasTerminalSearchText(prompt.ActionText)
        or hasTerminalSearchText(prompt.ObjectText) then
        return true
    end

    local nodes, seen = {}, {}
    local function add(node)
        if node and not seen[node] then
            seen[node] = true
            table.insert(nodes, node)
        end
    end

    add(prompt)
    add(model)
    add(prompt.Parent)
    if model then
        for _, descendant in ipairs(model:GetDescendants()) do add(descendant) end
    end

    for _, node in ipairs(nodes) do
        for attributeName, value in pairs(node:GetAttributes()) do
            local name = normalizeSearchText(attributeName)
            if SEARCH_COMPLETE_NAMES[name]
                and (value == true or value == 1 or hasTerminalSearchText(value)) then
                return true
            end
            if (name == "searchable" or name == "issearchable"
                or name == "cansearch" or name == "canbesearched")
                and value == false then
                return true
            end
            if (name:find("search", 1, true)
                or name:find("rummage", 1, true)
                or name:find("loot", 1, true))
                and hasTerminalSearchText(value) then
                return true
            end
        end

        if node:IsA("ValueBase") then
            local name = normalizeSearchText(node.Name)
            local value
            pcall(function() value = node.Value end)
            if SEARCH_COMPLETE_NAMES[name]
                and (value == true or value == 1 or hasTerminalSearchText(value)) then
                return true
            end
            if (name == "searchable" or name == "issearchable"
                or name == "cansearch" or name == "canbesearched")
                and value == false then
                return true
            end
            if (name:find("search", 1, true)
                or name:find("rummage", 1, true)
                or name:find("loot", 1, true))
                and hasTerminalSearchText(value) then
                return true
            end
        end
    end

    return false
end

local function triggerPrompt(prompt, model, token, minimumHoldDuration)
    -- Backwards-compatible two-argument form used by the dropped-key
    -- recovery path: triggerPrompt(prompt, token).
    if typeof(model) == 'number' and token == nil then
        token = model
        model = getTargetModel(prompt)
    end

    if token == nil then
        token = farmToken
    end

    if not model or typeof(model) ~= 'Instance' then
        model = getTargetModel(prompt)
    end

    if not prompt or not prompt.Parent or not prompt.Enabled then
        return false, 'Prompt unavailable', false
    end

    if token ~= farmToken then
        return false, 'Autofarm stopped', false
    end

    local triggered = false
    local holdBegan = false
    local activityDetected = false
    local promptStateChanged = false
    local triggerTime = nil
    local lastPromptChange = os.clock()
    local lastSoundChange = os.clock()
    local promptWasDisabled = false
    local promptReturnedEnabled = false
    local soundEverPlayed = false
    local currentlyPlaying = {}
    local trackedSounds = {}
    local soundStartedAt = {}
    local stalledLoopedSounds = {}
    local connections = {}

    local originalAction = prompt.ActionText
    local originalObject = prompt.ObjectText
    local originalEnabled = prompt.Enabled
    local originalHoldDuration = prompt.HoldDuration
    local originalRequiresLineOfSight = prompt.RequiresLineOfSight
    local instantHoldOverridden = false
    local instantLineOfSightOverridden = false
    local forcedHoldOverridden = false
    local interactionCharacter = getCharacter()
    local interactionHumanoid = getHumanoid()
    local function interactionStillValid()
        return player.Character == interactionCharacter
            and interactionCharacter ~= nil
            and interactionHumanoid ~= nil
            and interactionHumanoid.Parent ~= nil
            and interactionHumanoid.Health > 0
    end
    local initialStateSignature = getSearchStateSignature(prompt, model)
    local lastObservedSearchSignature = initialStateSignature
    local searchStateChanged = false
    local lastSearchStateChange = os.clock()

    local function markTriggered(who)
        if who == nil or who == player then
            if not triggered then
                triggerTime = os.clock()
            end
            triggered = true
        end
    end

    local function markPromptActivity()
        activityDetected = true
        promptStateChanged = true
        lastPromptChange = os.clock()
    end

    local function soundBelongsToCurrentSearch(sound)
        if model and sound:IsDescendantOf(model) then return true end
        if prompt.Parent and sound:IsDescendantOf(prompt.Parent) then return true end
        if player.Character and sound:IsDescendantOf(player.Character) then return true end

        -- Some MOUSE sounds are parented to a 3D emitter rather than the bed
        -- model. Only accept nearby emitters; ignore unrelated players' rummage.
        local anchor = getPromptAnchor(prompt)
        if not anchor then return false end
        local emitter = nil
        local current = sound.Parent
        while current and current ~= workspace do
            if current:IsA('Attachment') then
                emitter = current.WorldPosition
                break
            elseif current:IsA('BasePart') then
                emitter = current.Position
                break
            end
            current = current.Parent
        end
        return emitter ~= nil and (emitter - anchor).Magnitude <= 24
    end

    local function attachSound(sound)
        if not isSearchActivitySound(sound)
            or not soundBelongsToCurrentSearch(sound)
            or trackedSounds[sound] then
            return
        end

        trackedSounds[sound] = true
        currentlyPlaying[sound] = sound.Playing

        if sound.Playing then
            soundEverPlayed = true
            soundStartedAt[sound] = os.clock()
            lastSoundChange = os.clock()
        end

        table.insert(connections, sound:GetPropertyChangedSignal('Playing'):Connect(function()
            local playing = sound.Parent ~= nil and sound.Playing
            currentlyPlaying[sound] = playing
            lastSoundChange = os.clock()

            if playing then
                soundEverPlayed = true
                soundStartedAt[sound] = os.clock()
                stalledLoopedSounds[sound] = nil
                activityDetected = true
                lastPromptChange = os.clock()
            else
                stalledLoopedSounds[sound] = nil
            end
        end))

        table.insert(connections, sound.AncestryChanged:Connect(function()
            if not sound:IsDescendantOf(game) then
                currentlyPlaying[sound] = false
                stalledLoopedSounds[sound] = nil
                lastSoundChange = os.clock()
            end
        end))
    end

    local function watchRoot(root)
        if not root then return end

        if root:IsA('Sound') then
            attachSound(root)
        end

        for _, object in ipairs(root:GetDescendants()) do
            if object:IsA('Sound') then
                attachSound(object)
            end
        end

        table.insert(connections, root.DescendantAdded:Connect(function(object)
            if object:IsA('Sound') then
                attachSound(object)
            end
        end))
    end

    local function disconnectAll()
        for _, connection in ipairs(connections) do
            pcall(function() connection:Disconnect() end)
        end
        table.clear(connections)
    end

    -- Track this container's rummage sounds, the character's local search
    -- audio, and nearby 3D workspace emitters. Global key-pickup audio is not
    -- accepted as proof that this item's rummage has finished.
    watchRoot(model)
    if prompt.Parent then watchRoot(prompt.Parent) end
    if player.Character then watchRoot(player.Character) end
    watchRoot(workspace)

    table.insert(connections, prompt.Triggered:Connect(markTriggered))
    table.insert(connections, ProximityPromptService.PromptTriggered:Connect(function(triggeredPrompt, who)
        if triggeredPrompt == prompt then
            markTriggered(who)
        end
    end))

    table.insert(connections, prompt.PromptButtonHoldBegan:Connect(function(who)
        if who == nil or who == player then
            holdBegan = true
        end
    end))

    table.insert(connections, ProximityPromptService.PromptButtonHoldBegan:Connect(function(heldPrompt, who)
        if heldPrompt == prompt and (who == nil or who == player) then
            holdBegan = true
        end
    end))

    local previousEnabled = prompt.Enabled
    table.insert(connections, prompt:GetPropertyChangedSignal('Enabled'):Connect(function()
        local currentEnabled = prompt.Enabled
        if previousEnabled and not currentEnabled then
            promptWasDisabled = true
            promptReturnedEnabled = false
            searchableCompletion.DisabledSince[prompt] = os.clock()
        elseif not previousEnabled and currentEnabled then
            promptReturnedEnabled = true
            searchableCompletion.Reenabled[prompt] = true
            searchableCompletion.DisabledSince[prompt] = nil
        end
        previousEnabled = currentEnabled
        markPromptActivity()
    end))
    table.insert(connections, prompt:GetPropertyChangedSignal('ActionText'):Connect(markPromptActivity))
    table.insert(connections, prompt:GetPropertyChangedSignal('ObjectText'):Connect(markPromptActivity))

    local result, message, completionConfirmed = withCameraFacing(prompt, token, function()
        if not prompt.Parent or not prompt.Enabled then
            return false, 'Prompt became unavailable', false
        end

        local inputHeld = false
        local configuredHold = tonumber(originalHoldDuration) or 0
        local requestedMinimumHold = math.max(0, tonumber(minimumHoldDuration) or 0)
        -- Explicit hold requests (engine stopper) always use the hold branch,
        -- even if the prompt text happens to contain the word "Search".
        local useInstantTap = isSearchPrompt(prompt) and requestedMinimumHold <= 0
        local effectiveHoldDuration = math.max(configuredHold, requestedMinimumHold)
        local holdDeadline = useInstantTap
            and os.clock()
            or (os.clock() + math.max(effectiveHoldDuration + 0.35, MIN_SEARCH_HOLD))

        local callbackOK, callbackResult, callbackMessage, callbackCompletionConfirmed = pcall(function()
            local searchTapCount = 0
            local nextSearchTapAt = 0

            local function isTerminalSearchStateNow()
                if safeHasExplicitSearchCompletion(prompt, model) then
                    return true
                end
                local disabledAt = searchableCompletion.DisabledSince[prompt]
                return prompt.Parent ~= nil
                    and not prompt.Enabled
                    and disabledAt ~= nil
                    and os.clock() - disabledAt >= PROMPT_DISABLED_QUIET_TIME
            end

            local function sendInstantSearchTap()
                if not prompt.Parent or not prompt.Enabled then
                    return false, "Search prompt is unavailable"
                end

                local setInstantOK, setInstantError = pcall(function()
                    prompt.HoldDuration = 0
                end)
                if not setInstantOK
                    or math.abs((tonumber(prompt.HoldDuration) or 0)) > 0.05 then
                    return false,
                        "Could not set searchable prompt to instant input"
                            .. (setInstantError and (": " .. tostring(setInstantError)) or "")
                end
                instantHoldOverridden = true
                -- The avatar is tweened into the selected item's geometry. Its
                -- own mesh should not hide the prompt from the local UI raycast.
                local losOK = pcall(function()
                    prompt.RequiresLineOfSight = false
                end)
                instantLineOfSightOverridden = losOK

                local beginOK, beginError = pcall(function()
                    prompt:InputHoldBegin()
                end)
                if not beginOK then
                    return false, "InputHoldBegin failed: " .. tostring(beginError)
                end

                inputHeld = true
                holdBegan = true
                task.wait(SEARCH_TAP_DURATION)
                if inputHeld then
                    pcall(function() prompt:InputHoldEnd() end)
                    inputHeld = false
                end

                -- Keep the local prompt at zero for subsequent taps too.
                if prompt.Parent then
                    pcall(function() prompt.HoldDuration = 0 end)
                end
                searchTapCount += 1
                nextSearchTapAt = os.clock() + SEARCH_TAP_RETRY_INTERVAL
                farmStatus = string.format(
                    "Searching %s | tap %d",
                    model and model.Name or "item",
                    searchTapCount
                )
                print(
                    "[MOUSE AUTOFARM] Quick search tap",
                    searchTapCount,
                    "at", model and model:GetFullName() or prompt:GetFullName()
                )
                return true
            end

            if useInstantTap then
                -- First E tap is sent immediately after the one-frame camera
                -- lock. Retry this exact selected prompt until a terminal game
                -- state is observed or the bounded acknowledgement window ends.
                -- Engine, padlock, lever, and key interactions remain unchanged.
                if isTerminalSearchStateNow() then
                    triggered = true
                    triggerTime = os.clock()
                    return true, "Game already reports this item as no longer searchable", true
                end

                while token == farmToken and interactionStillValid() do
                    if isTerminalSearchStateNow() then
                        triggered = true
                        triggerTime = triggerTime or os.clock()
                        return true, "Game marked item no longer searchable", true
                    end
                    if not prompt.Parent then
                        triggered = true
                        triggerTime = triggerTime or os.clock()
                        return true, "Selected Search prompt was removed by the game", true
                    end

                    if not prompt.Enabled then
                        local disabledAt = searchableCompletion.DisabledSince[prompt]
                        if not disabledAt then
                            disabledAt = os.clock()
                            searchableCompletion.DisabledSince[prompt] = disabledAt
                        end
                        if os.clock() - disabledAt >= PROMPT_DISABLED_QUIET_TIME then
                            triggered = true
                            triggerTime = triggerTime or os.clock()
                            return true, "Game left the selected Search prompt disabled", true
                        end
                        -- A temporary server cooldown must not make us abandon
                        -- this selected random item. Wait for it to re-enable.
                        task.wait(0.05)
                        continue
                    end

                    local tapped, tapError = sendInstantSearchTap()
                    if not tapped then
                        warn("[MOUSE AUTOFARM] Search tap could not be sent; retaining this selected item:", tostring(tapError))
                    end

                    local acknowledgementDeadline = os.clock() + SEARCH_EVENT_GRACE
                    while os.clock() < acknowledgementDeadline
                        and token == farmToken and interactionStillValid() do
                        if isTerminalSearchStateNow() then
                            triggered = true
                            triggerTime = triggerTime or os.clock()
                            return true, "Server marked item no longer searchable", true
                        end
                        if triggered then break end
                        task.wait(0.025)
                    end

                    if triggered then break end
                    local remaining = nextSearchTapAt - os.clock()
                    if remaining > 0 then task.wait(remaining) end
                end

                -- If no Triggered event was replicated, but the server did
                -- make this exact prompt terminal, accept that authoritative
                -- state rather than treating the input event as mandatory.
                if not triggered and isTerminalSearchStateNow() then
                    triggered = true
                    triggerTime = triggerTime or os.clock()
                    return true, "Server changed item to no-longer-searchable", true
                end
                        else
                -- Objective interaction: actually hold E instead of merely
                -- waiting for the configured duration. The engine stopper
                -- passes ENGINE_STOPPER_MIN_HOLD so even a zero-duration
                -- prompt receives a deliberate 1.5-second hold.
                if requestedMinimumHold > configuredHold then
                    local holdSetOK, holdSetError = pcall(function()
                        prompt.HoldDuration = effectiveHoldDuration
                    end)
                    local observedHold = tonumber(prompt.HoldDuration)
                    if not holdSetOK or not observedHold
                        or math.abs(observedHold - effectiveHoldDuration) > 0.05 then
                        return false,
                            "Could not set the engine-stopper hold duration"
                                .. (holdSetError and (": " .. tostring(holdSetError)) or ""),
                            false
                    end
                    forcedHoldOverridden = true
                end

                local actualHoldSeconds = math.max(effectiveHoldDuration, 0.10)
                local holdStartedAt = os.clock()
                local beginOK, beginError = pcall(function()
                    prompt:InputHoldBegin()
                    inputHeld = true
                    holdBegan = true
                end)
                if not beginOK then
                    return false, "Objective InputHoldBegin failed: " .. tostring(beginError), false
                end

                while os.clock() - holdStartedAt < actualHoldSeconds
                    and token == farmToken and interactionStillValid()
                    and prompt.Parent ~= nil do
                    -- Reassert the requested hold if the local prompt refreshes
                    -- its property while E is physically held down.
                    if forcedHoldOverridden then
                        local liveHold = tonumber(prompt.HoldDuration)
                        if not liveHold or liveHold + 0.05 < effectiveHoldDuration then
                            pcall(function() prompt.HoldDuration = effectiveHoldDuration end)
                        end
                    end
                    task.wait(0.025)
                end

                if inputHeld then
                    pcall(function() prompt:InputHoldEnd() end)
                    inputHeld = false
                end

                local eventDeadline = os.clock() + PROMPT_EVENT_GRACE
                while not triggered and os.clock() < eventDeadline
                    and token == farmToken and interactionStillValid() do
                    task.wait(0.05)
                end
            end

            if token ~= farmToken then return end
            if not interactionStillValid() then
                return false, 'Character changed during the searchable interaction', false
            end
            if not triggered and useInstantTap then
                -- Some game versions suppress the client Triggered callback
                -- even though the server has already changed the prompt to its
                -- terminal no-longer-searchable state. Trust that authoritative
                -- state, but never infer completion from the tap alone.
                local terminalDeadline = os.clock() + SEARCH_EVENT_GRACE
                while os.clock() < terminalDeadline
                    and token == farmToken and interactionStillValid() do
                    local disabledAt = searchableCompletion.DisabledSince[prompt]
                    local disabledSettled = prompt.Parent ~= nil
                        and not prompt.Enabled
                        and disabledAt ~= nil
                        and os.clock() - disabledAt >= PROMPT_DISABLED_QUIET_TIME
                    if safeHasExplicitSearchCompletion(prompt, model) or disabledSettled then
                        triggered = true
                        triggerTime = os.clock()
                        return true,
                            'Server changed this item to its terminal no-longer-searchable state',
                            true
                    end
                    task.wait(0.025)
                end
            end

            if not triggered then
                return false,
                    useInstantTap and 'Instant E tap did not trigger and the server left the item searchable'
                        or 'Configured prompt hold did not trigger the interaction',
                    false
            end

            local acceptedAt = triggerTime or os.clock()
            local earliestFinish = math.max(holdDeadline, acceptedAt + SEARCH_FINISH_DWELL)
            local searchSettled = false
            local completionReason = nil

            while token == farmToken and interactionStillValid() do
                local now = os.clock()
                local anyBlockingSound = false

                for sound in pairs(currentlyPlaying) do
                    if sound.Parent and sound.Playing then
                        local startedAt = soundStartedAt[sound] or now
                        local soundAge = now - startedAt
                        local maxLoopWait = LOOPED_SOUND_MAX_WAIT

                        if sound.Looped then
                            local soundLength = tonumber(sound.TimeLength) or 0
                            if soundLength > 0 then
                                maxLoopWait = math.clamp(soundLength * 2.0, 3.0, LOOPED_SOUND_MAX_WAIT)
                            end
                            if soundAge >= maxLoopWait then
                                -- A loop that exceeds its expected duration is
                                -- treated as stalled, not as a completed search.
                                -- It no longer blocks the retry timeout, but it
                                -- cannot by itself mark the item complete.
                                stalledLoopedSounds[sound] = true
                            end
                        end
                        anyBlockingSound = true
                    else
                        currentlyPlaying[sound] = false
                    end
                end

                local currentSignature = getSearchStateSignature(prompt, model)
                if currentSignature ~= lastObservedSearchSignature then
                    searchStateChanged = true
                    lastObservedSearchSignature = currentSignature
                    lastSearchStateChange = now
                end

                local explicitComplete = safeHasExplicitSearchCompletion(prompt, model)
                local disabledAt = searchableCompletion.DisabledSince[prompt]
                local disabledSettled = promptWasDisabled
                    and not promptReturnedEnabled
                    and prompt.Parent ~= nil
                    and not prompt.Enabled
                    and disabledAt ~= nil
                    and now - disabledAt >= PROMPT_DISABLED_QUIET_TIME

                -- Sound ending and temporary disable/re-enable cycles only
                -- show that activity paused; they do NOT mean the game made
                -- the item unsearchable. Require a terminal game state or a
                -- prompt disabled by the game and left disabled.
                local completionSignal = explicitComplete or disabledSettled

                -- Continue pressing/releasing E on this SAME selected prompt
                -- until the game reports it searched. A local Triggered event,
                -- sound, or intermediate prompt activity alone does not stop
                -- the retries; the game's terminal completion state does.
                if useInstantTap
                    and not completionSignal
                    and prompt.Parent and prompt.Enabled
                    and now >= nextSearchTapAt then
                    local tapped, tapError = sendInstantSearchTap()
                    if not tapped and tapError then
                        warn("[MOUSE AUTOFARM] Search retry tap failed:", tostring(tapError))
                    end
                end

                if completionSignal and now >= earliestFinish
                    and (explicitComplete or not anyBlockingSound) then
                    searchSettled = true
                    completionReason = explicitComplete
                        and "game reports no longer searchable"
                        or "game left this prompt disabled after the search"
                    break
                end

                -- No local timeout is allowed to rotate Autofarm onto another
                -- random item while this selected prompt remains searchable.
                -- Keep waiting/retrying until explicit completion or a stable
                -- game-owned disabled/removal state is observed.

                task.wait(0.05)
            end

            if not interactionStillValid() then
                return false, 'Character changed or Mickey evasion interrupted the search', false
            end

            if not searchSettled then
                return true,
                    "Prompt accepted but completion was not confirmed; this item stays queued for retry",
                    false
            end

            return true,
                "Full search confirmed: " .. tostring(completionReason),
                true
        end)

        if inputHeld then
            pcall(function() prompt:InputHoldEnd() end)
        end
        if instantHoldOverridden and prompt.Parent then
            -- Do not restore a stale multi-second hold after an instant tap.
            pcall(function() prompt.HoldDuration = 0 end)
            instantHoldOverridden = false
        end
        if instantLineOfSightOverridden and prompt.Parent then
            pcall(function() prompt.RequiresLineOfSight = originalRequiresLineOfSight end)
            instantLineOfSightOverridden = false
        end
        if forcedHoldOverridden and prompt.Parent then
            -- Restore the game's original setting after the engine E hold ends.
            pcall(function() prompt.HoldDuration = originalHoldDuration end)
            forcedHoldOverridden = false
        end

        if not callbackOK then
            return false, tostring(callbackResult), false
        end

        if token ~= farmToken then
            return false, 'Autofarm stopped', false
        end

        if not triggered then
            if holdBegan then
                return false, 'E hold began but the prompt did not confirm Triggered', false
            end
            return false, 'Prompt did not accept input', false
        end

        return callbackResult == true,
            callbackMessage or 'Prompt result unavailable',
            callbackCompletionConfirmed == true
    end)

    disconnectAll()
    restoreLocalPromptRange(prompt)

    if result then
        return true, message, completionConfirmed == true
    end

    return false, message, false
end

--============================================================
-- TELEPORT TO AN APPROACH POINT
--============================================================

local function teleportToCandidate(candidate, target, prompt, token, rangeModel, smoothSearchTravel)
    if token ~= farmToken or not enabled.Autofarm then
        return false, "Autofarm stopped"
    end

    local character = getCharacter()
    local root = getRoot()
    local anchor = getTargetAnchor(target)

    if not character or not root or not anchor then
        return false, "Character or target unavailable"
    end

    local destination = candidate.Position
    local entryDirection = nil

    if smoothSearchTravel then
        -- Use the exact level-locked position validated when this candidate was
        -- created. Do not resolve model bounds again here: a second resolution
        -- could select a different ancestor or another level of a bunk/Kit.
        destination = candidate.ItemCenter or candidate.Position

        if candidate.Direction then
            entryDirection = Vector3.new(
                candidate.Direction.X,
                0,
                candidate.Direction.Z
            )
            if entryDirection.Magnitude > 0.05 then
                entryDirection = entryDirection.Unit
            else
                entryDirection = nil
            end
        end

        if candidate.FloorY then
            print(
                "[MOUSE AUTOFARM] Tween locked to selected item's deck:",
                prompt:GetFullName(),
                "| itemBottomY:", string.format("%.2f", candidate.FloorY),
                "| destination:", tostring(destination)
            )
        end
    end

    local lookAt
    local horizontalToPrompt = Vector3.new(
        anchor.X - destination.X,
        0,
        anchor.Z - destination.Z
    )
    if horizontalToPrompt.Magnitude >= 0.05 then
        lookAt = destination + horizontalToPrompt
    elseif entryDirection then
        -- Face inward from the approach side while the root is inside the item.
        lookAt = destination - entryDirection
    else
        lookAt = destination + Vector3.new(0, 0, -1)
    end

    local destinationRootCFrame = CFrame.lookAt(destination, lookAt)
    local targetSearchCompletedDuringTravel = false

    if smoothSearchTravel then
        -- Tween a CFrameValue with TweenService, then apply each interpolated
        -- pivot to the complete character model. This keeps the avatar visibly
        -- moving (rather than snapping). The selected item is the only prompt
        -- that will be triggered during this search cycle.
        local startRootCFrame = root.CFrame
        local startPivot = character:GetPivot()
        local rootToPivot = startRootCFrame:ToObjectSpace(startPivot)
        local destinationPivot = destinationRootCFrame * rootToPivot
        local distance = (destination - root.Position).Magnitude
        local travelDuration = math.clamp(
            distance / SEARCH_TRAVEL_SPEED,
            SEARCH_TRAVEL_MIN_TIME,
            SEARCH_TRAVEL_MAX_TIME
        )

        local tweenValue = Instance.new("CFrameValue")
        tweenValue.Value = startPivot
        local movementTween = TweenService:Create(
            tweenValue,
            TweenInfo.new(
                travelDuration,
                Enum.EasingStyle.Linear,
                Enum.EasingDirection.Out
            ),
            {Value = destinationPivot}
        )
        local movementAbortReason = nil
        movementTween:Play()

        while movementTween.PlaybackState == Enum.PlaybackState.Playing do
            if token ~= farmToken or not enabled.Autofarm then
                movementAbortReason = "Autofarm stopped during tween movement to searchable"
                movementTween:Cancel()
                break
            end
            if player.Character ~= character or not character.Parent then
                movementAbortReason = "Character changed during tween movement to searchable"
                movementTween:Cancel()
                break
            end

            local movedOK, moveError = pcall(function()
                character:PivotTo(tweenValue.Value)
            end)
            if not movedOK then
                movementAbortReason = "Tweened searchable movement failed: " .. tostring(moveError)
                movementTween:Cancel()
                break
            end

            -- Deliberately do not trigger neighbouring prompts during travel.
            -- The selected random item owns this tween; it will be searched only
            -- after arrival and position validation, so nearby items cannot
            -- suspend or redirect the active movement task.

            RunService.Heartbeat:Wait()
        end

        local tweenCompleted = movementTween.PlaybackState == Enum.PlaybackState.Completed
        movementTween:Destroy()
        tweenValue:Destroy()

        if movementAbortReason then
            return false, movementAbortReason
        end
        if not tweenCompleted then
            return false, "Tween movement did not complete"
        end

        -- Snap only the final sub-frame rounding error, not the travel itself.
        local finalMoveOK, finalMoveError = pcall(function()
            character:PivotTo(destinationPivot)
        end)
        if not finalMoveOK then
            return false, "Could not finish tween at searchable: " .. tostring(finalMoveError)
        end
    else
        -- Other objectives retain their existing immediate approach behaviour.
        character:PivotTo(destinationRootCFrame)
    end

    root = getRoot()
    if root then
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end

    -- Wait only one physics frame for the final position to settle before
    -- immediately activating the selected prompt.
    RunService.Heartbeat:Wait()

    if token ~= farmToken then
        return false, "Autofarm stopped"
    end

    root = getRoot()
    if not root then return false, "Character disappeared" end

    local finalOffset = (root.Position - destination).Magnitude
    if smoothSearchTravel and candidate.CenteredInside then
        local minBounds = candidate.ItemBoundsMin
        local maxBounds = candidate.ItemBoundsMax
        local anchorY = tonumber(candidate.AnchorY) or anchor.Y
        local sameDeckTolerance = math.clamp((tonumber(candidate.ItemHeight) or 1.0) + 2.75, 4.0, 6.0)
        local anchorLevelMatch = math.abs(root.Position.Y - anchorY) <= sameDeckTolerance
        local topLevelMatch = math.abs(root.Position.Y - (tonumber(candidate.TopRootY) or destination.Y)) <= 2.25
        local sameDeck = anchorLevelMatch or topLevelMatch
        local insideOrTop = false

        if typeof(minBounds) == "Vector3" and typeof(maxBounds) == "Vector3" then
            local horizontalMargin = 1.75
            local insideXZ = root.Position.X >= minBounds.X - horizontalMargin
                and root.Position.X <= maxBounds.X + horizontalMargin
                and root.Position.Z >= minBounds.Z - horizontalMargin
                and root.Position.Z <= maxBounds.Z + horizontalMargin
            local verticalWindow = root.Position.Y >= minBounds.Y - 1.75
                and root.Position.Y <= maxBounds.Y + (tonumber(candidate.StandingHeight) or 3.0) + 2.0
            local onTopWindow = math.abs(root.Position.Y - (tonumber(candidate.TopRootY) or destination.Y)) <= 2.25
            insideOrTop = insideXZ and verticalWindow
                and (root.Position.Y <= maxBounds.Y + 1.25 or onTopWindow)
        end

        -- A server may nudge PivotTo movement by 1-2 studs. Accept that only
        -- when the avatar is still over/inside the SAME selected item's volume,
        -- on the prompt's deck, and within the actual prompt activation radius.
        local sameItemNear = finalOffset <= 2.50 and sameDeck
        if not sameDeck or not (insideOrTop or sameItemNear) then
            return false, string.format(
                "Server corrected movement %.2f studs outside the selected item's same-deck top/inside zone; retrying this item",
                finalOffset
            )
        end
    else
        local allowedOffset = candidate.Interior and 1.5 or (smoothSearchTravel and 2.0 or 7.0)
        if finalOffset > allowedOffset then
            return false, string.format("Server corrected the move %.2f studs from its validated destination", finalOffset)
        end
    end

    local promptPosition = getPromptAnchor(prompt)
    local range = applyLocalPromptRange(prompt, rangeModel or getContainer(prompt, getBoat()))

    if not promptPosition or (root.Position - promptPosition).Magnitude > range - 0.1 then
        return false, "Outside prompt activation range"
    end

    -- Final safety check: a broad Kit/room model must never make a wall count
    -- as the searchable itself. If the chosen standing point is still blocked,
    -- reject it so searchOneEntry can try the next clear-side candidate.
    if smoothSearchTravel and not candidate.CenteredInside and not targetSearchCompletedDuringTravel
        and not hasClearView(root.Position, promptPosition, prompt, rangeModel or getContainer(prompt, getBoat()), true) then
        return false, "Approach point is on the blocked side of the searchable; trying another clear-side position"
    end

    return true, nil, smoothSearchTravel and targetSearchCompletedDuringTravel == true
end

-- If the game rejects the client-side pivot, try reaching the same inside-side
-- padlock point through ordinary Humanoid movement. This respects the game's
-- server movement rules instead of repeatedly forcing a rejected CFrame.
local function moveNormallyToPadlockCandidate(candidate, prompt, token, rangeModel)
    local humanoid = getHumanoid()
    local root = getRoot()
    if not humanoid or not root or not candidate or not candidate.Position then
        return false, "Character unavailable for normal padlock movement"
    end

    local characterAtStart = getCharacter()
    local destination = candidate.Position
    local distance = (root.Position - destination).Magnitude
    local speed = math.max(humanoid.WalkSpeed, 8)
    local deadline = os.clock() + math.clamp(distance / speed + 3.0, 3.0, 12.0)
    local refreshAt = os.clock() + 5.5
    local oldAutoRotate = humanoid.AutoRotate
    humanoid.AutoRotate = true

    local success, err = pcall(function()
        humanoid:MoveTo(destination)
        while farmRunning(token) and os.clock() < deadline do
            if player.Character ~= characterAtStart then
                error("Character changed during padlock approach")
            end

            local currentRoot = getRoot()
            local currentHumanoid = getHumanoid()
            if not currentRoot or not currentHumanoid or currentHumanoid.Health <= 0 then
                error("Character unavailable during padlock approach")
            end

            local remaining = (currentRoot.Position - destination).Magnitude
            if remaining <= 1.5 then
                local promptPosition = getPromptAnchor(prompt)
                local promptRange = applyLocalPromptRange(prompt, rangeModel or getTargetModel(prompt))
                if promptPosition and (currentRoot.Position - promptPosition).Magnitude <= promptRange - 0.15 then
                    currentHumanoid:MoveTo(currentRoot.Position)
                    return true
                end
            end

            if os.clock() >= refreshAt then
                currentHumanoid:MoveTo(destination)
                refreshAt = os.clock() + 5.5
            end
            task.wait(0.05)
        end
        return false
    end)

    local currentHumanoid = getHumanoid()
    local currentRoot = getRoot()
    if currentHumanoid and currentHumanoid.Parent then
        pcall(function()
            currentHumanoid:MoveTo(currentRoot and currentRoot.Position or destination)
            currentHumanoid.AutoRotate = oldAutoRotate
        end)
    end

    if not success then
        return false, tostring(err)
    end
    if err == true then
        return true, "Reached inside padlock position using normal movement"
    end
    return false, "Normal movement could not reach the inside padlock position"
end

--============================================================
-- RANDOMIZED SEARCHABLE SELECTION
--============================================================

local function shuffleInPlace(items)
    for index = #items, 2, -1 do
        local swapIndex = farmRandom:NextInteger(1, index)
        items[index], items[swapIndex] = items[swapIndex], items[index]
    end
    return items
end

local function findRandomSearchable(completed, failures, lastPrompt, retryAfter, blocked)
    local fresh = {}
    local retry = {}
    local blockedReady = {}
    local disabledRetry = {}
    local disabledRemaining = 0
    local coolingRemaining = 0
    local blockedRemaining = 0
    local nextRetryAt = math.huge
    local now = os.clock()

    for _, entry in ipairs(getSearchEntries()) do
        local prompt = entry.Prompt
        local model = entry.Model

        if prompt.Parent and not isSearchableCompleted(model, prompt, completed) then
            if not prompt.Enabled then
                disabledRemaining += 1
                -- A disabled prompt may only be in a temporary server cooldown.
                -- Keep it as a fallback target so Autofarm moves to it, waits
                -- briefly, and retries when the server re-enables it.
                if not safeHasExplicitSearchCompletion(prompt, model) then
                    table.insert(disabledRetry, entry)
                end
            else
                local retryTime = retryAfter[prompt] or 0
                if now < retryTime then
                    coolingRemaining += 1
                    nextRetryAt = math.min(nextRetryAt, retryTime)
                elseif blocked and blocked[prompt] then
                    blockedRemaining += 1
                    table.insert(blockedReady, entry)
                elseif (failures[prompt] or 0) == 0 then
                    table.insert(fresh, entry)
                else
                    table.insert(retry, entry)
                end
            end
        end
    end

    -- Enabled, never-attempted items remain first choice; then normal retries;
    -- then difficult enabled prompts; finally disabled prompts whose cooldown
    -- may clear while the character is waiting at the selected item.
    local pool
    if #fresh > 0 then
        pool = fresh
    elseif #retry > 0 then
        pool = retry
    elseif #blockedReady > 0 then
        pool = blockedReady
    else
        pool = disabledRetry
    end

    if #pool == 0 then
        return nil, 0, disabledRemaining, coolingRemaining, nextRetryAt, blockedRemaining
    end

    shuffleInPlace(pool)
    if #pool > 1 and pool[1].Prompt == lastPrompt then
        pool[1], pool[2] = pool[2], pool[1]
    end

    return pool[1], #fresh + #retry + #blockedReady + coolingRemaining,
        disabledRemaining, coolingRemaining, nextRetryAt, blockedRemaining
end

--============================================================
-- ENGINE STOPPER / PADLOCKS / LEVER
--============================================================

local function getContext(obj)
    local pieces = {}

    if obj:IsA("ProximityPrompt") then
        table.insert(pieces, obj.Name)
        table.insert(pieces, obj.ActionText)
        table.insert(pieces, obj.ObjectText)
    end

    local current = obj
    while current and current ~= workspace do
        table.insert(pieces, current.Name)
        current = current.Parent
    end

    return table.concat(pieces, " "):lower()
end

local function findEngineStopper()
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("ProximityPrompt") and obj.Enabled then
            local context = getContext(obj)
            local hasEngine = context:find("engine", 1, true)
                or context:find("motor", 1, true)
            local hasStop = context:find("stop", 1, true)
                or context:find("turn off", 1, true)
                or context:find("disable", 1, true)
                or context:find("shutdown", 1, true)
                or context:find("pull", 1, true)

            if hasEngine and hasStop then
                return obj
            end
        end
    end

    return nil
end

local function engineStopperIsDisabled()
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("ProximityPrompt") and not obj.Enabled then
            local context = getContext(obj)
            local hasEngine = context:find("engine", 1, true)
                or context:find("motor", 1, true)
            local hasStop = context:find("stop", 1, true)
                or context:find("turn off", 1, true)
                or context:find("disable", 1, true)
                or context:find("shutdown", 1, true)
                or context:find("pull", 1, true)
            if hasEngine and hasStop then
                return true
            end
        end
    end
    return false
end

local function parsePadlockProgress(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") then
        return nil, nil
    end

    local combined = table.concat({
        tostring(prompt.Name or ""),
        tostring(prompt.ActionText or ""),
        tostring(prompt.ObjectText or "")
    }, " "):lower()

    local current, total = combined:match("%(%s*(%d+)%s*/%s*(%d+)%s*%)")
    if not current then
        current, total = combined:match("(%d+)%s*/%s*(%d+)")
    end

    if current and total then
        return tonumber(current), tonumber(total)
    end

    return nil, nil
end

local function isPadlockPrompt(prompt)
    if not prompt:IsA("ProximityPrompt") then
        return false
    end

    local context = getContext(prompt)
    local action = tostring(prompt.ActionText or ""):lower()
    local objectText = tostring(prompt.ObjectText or ""):lower()

    if action:find("search", 1, true) then
        return false
    end

    local containsPadlock = context:find("padlock", 1, true) ~= nil
        or objectText:find("padlock", 1, true) ~= nil
        or action:find("padlock", 1, true) ~= nil

    local hasProgress = parsePadlockProgress(prompt) ~= nil
    local hasLockWord = context:match("%f[%a]lock%f[%A]") ~= nil
        or context:match("%f[%a]lock[%w_%-]*") ~= nil

    local unlockAction = action:find("unlock", 1, true) ~= nil
        or action:find("open", 1, true) ~= nil
        or action:find("release", 1, true) ~= nil
        or action:find("remove", 1, true) ~= nil
        or action:find("lock", 1, true) ~= nil
        or action:find("pull", 1, true) ~= nil
        or action:find("activate", 1, true) ~= nil

    return containsPadlock or hasProgress or (hasLockWord and unlockAction)
end

-- MOUSE displays one shared action such as "Open a padlock (0/5)" over
-- the five-lock assembly. That prompt must be activated repeatedly; it is
-- not five separate prompt instances.
local function isSharedPadlockPrompt(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") then
        return false
    end

    local action = tostring(prompt.ActionText or ""):lower()
    local objectText = tostring(prompt.ObjectText or ""):lower()
    local current, total = parsePadlockProgress(prompt)

    if current ~= nil and total ~= nil and total > 1 then
        return true
    end

    return action:find("open a padlock", 1, true) ~= nil
        or action:find("open padlock", 1, true) ~= nil
        or objectText:find("padlocks", 1, true) ~= nil
end

local function getPadlockRoot(prompt)
    local current = prompt.Parent
    local fallback = current

    if current and current:IsA("Attachment") and current.Parent then
        fallback = current.Parent
        current = current.Parent
    end

    while current and current ~= workspace do
        local name = current.Name:lower()
        local isLockAssembly = current:IsA("Model")
            and (name:find("padlock", 1, true) ~= nil
                or name:find("lockassembly", 1, true) ~= nil
                or name == "locks")

        if isLockAssembly then
            return current
        end

        current = current.Parent
    end

    -- If MOUSE names the group differently, retain the prompt's host part.
    -- The approach planner will reject the raised lock surfaces and find deck.
    return fallback or prompt.Parent
end

local function findPadlockPrompts()
    local results = {}
    local seenPrompts = {}

    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("ProximityPrompt") and isPadlockPrompt(obj) then
            -- Keep distinct prompts even when they share the same host part.
            -- A shared aggregate prompt will intentionally appear once and
            -- will be reused until its 0/5 counter reaches 5/5.
            if not seenPrompts[obj] then
                seenPrompts[obj] = true
                table.insert(results, {
                    Prompt = obj,
                    Root = getPadlockRoot(obj),
                    Shared = isSharedPadlockPrompt(obj)
                })
            end
        end
    end

    return results
end

local function getPadlocksOpen()
    local boat = getBoat()
    local attributeCount = 0

    if boat then
        attributeCount = tonumber(boat:GetAttribute("PadlocksOpen"))
            or tonumber(boat:GetAttribute("LocksOpen"))
            or 0
    end

    local textCount = 0
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("ProximityPrompt") then
            local context = getContext(obj)
            if context:find("padlock", 1, true) then
                local current = parsePadlockProgress(obj)
                if current then
                    textCount = math.max(textCount, current)
                end
            end
        end
    end

    return math.max(attributeCount, textCount)
end

local function getPadlocksTotal()
    local boat = getBoat()
    local attributeTotal = 0

    if boat then
        attributeTotal = tonumber(boat:GetAttribute("PadlocksTotal"))
            or tonumber(boat:GetAttribute("LocksTotal"))
            or 0
    end

    local textTotal = 0
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("ProximityPrompt") then
            local context = getContext(obj)
            if context:find("padlock", 1, true) then
                local _, total = parsePadlockProgress(obj)
                if total then
                    textTotal = math.max(textTotal, total)
                end
            end
        end
    end

    return math.max(attributeTotal, textTotal, 5)
end

local function padlockLooksOpen(entry)
    local prompt = entry and entry.Prompt
    local root = entry and entry.Root

    if not prompt then
        return false
    end

    local nodes = {prompt}
    if root and root.Parent then
        table.insert(nodes, root)
        for _, descendant in ipairs(root:GetDescendants()) do
            table.insert(nodes, descendant)
        end
    end

    for _, node in ipairs(nodes) do
        for attributeName, value in pairs(node:GetAttributes()) do
            local name = attributeName:lower():gsub("[^%w]", "")
            if (name == "unlocked" or name == "isopen" or name == "opened"
                or name == "isunlocked" or name == "padlockopen") and value == true then
                return true
            end
            if name == "locked" and value == false then
                return true
            end
        end
    end

    return false
end

local function findLever()
    local boat = getBoat()
    local root = getRoot()
    local candidates = {}

    local function scorePrompt(prompt)
        if not prompt or not prompt:IsA("ProximityPrompt") or not prompt.Parent then
            return nil
        end
        local context = getContext(prompt)
        if not context:find("lever", 1, true) then
            return nil
        end
        if context:find("engine", 1, true) or context:find("motor", 1, true) then
            return nil
        end

        local underBoat = boat ~= nil and prompt:IsDescendantOf(boat)
        if not underBoat then
            return nil
        end

        local score = 100
        if context:find("lower", 1, true) then score -= 35 end
        if context:find("boat", 1, true) then score -= 25 end
        if context:find("drop", 1, true) then score -= 20 end
        if context:find("launch", 1, true) then score -= 15 end
        if context:find("escape", 1, true) then score -= 10 end
        if prompt.Enabled then score -= 5 end

        local anchor = getPromptAnchor(prompt)
        if root and anchor then
            score += (root.Position - anchor).Magnitude * 0.15
        end
        return score, context
    end

    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("ProximityPrompt") then
            local score, context = scorePrompt(obj)
            if score then
                table.insert(candidates, {
                    Prompt = obj,
                    Score = score,
                    Context = context
                })
            end
        end
    end

    table.sort(candidates, function(a, b)
        return a.Score < b.Score
    end)

    if candidates[1] then
        print(
            "[MOUSE AUTOFARM] Selected final boat lever:",
            candidates[1].Prompt:GetFullName(),
            "| context:", candidates[1].Context,
            "| local hold duration:", candidates[1].Prompt.HoldDuration
        )
        return candidates[1].Prompt
    end

    return nil
end

--============================================================
-- AUTOFARM
--============================================================

local startAutofarm
local stopAutofarm

farmRunning = function(token)
    return enabled.Autofarm and token == farmToken
end

-- If Mickey catches the player, keep the Autofarm task alive while the
-- character respawns instead of turning the button off just because the
-- HumanoidRootPart temporarily disappeared. This resumes from the server's
-- current Boat.Keys value; it cannot override the game's server-side key-drop rule.
waitForLivingCharacter = function(token)
    local candidateCharacter = nil
    local stableSince = nil

    while farmRunning(token) do
        local character = getCharacter()
        local humanoid = getHumanoid()
        local root = getRoot()

        if character and humanoid and humanoid.Health > 0 and root and root.Parent then
            if candidateCharacter ~= character then
                candidateCharacter = character
                stableSince = os.clock()
            elseif stableSince and os.clock() - stableSince >= 0.18 then
                return true
            end
        else
            candidateCharacter = nil
            stableSince = nil
            farmStatus = "Waiting for respawn"
        end

        task.wait(0.08)
    end

    return false
end

local function droppedKeyWasRecovered(keyObject, folder, keysBefore, carriedBefore)
    if getKeys() > (keysBefore or 0) then
        return true
    end
    if getCarriedKeyCount() > (carriedBefore or 0) then
        return true
    end
    return not isStillDropped(keyObject, folder)
end

local function tryPickupDroppedKeyWithPrompt(keyObject, prompt, folder, token, keysBefore, carriedBefore)
    if not prompt or not prompt.Parent or not prompt.Enabled then
        return false, "Dropped key has no enabled pickup prompt"
    end

    local triggered = false
    local connections = {}
    local function markTriggered(who)
        if who == nil or who == player then
            triggered = true
        end
    end

    table.insert(connections, prompt.Triggered:Connect(markTriggered))
    table.insert(connections, ProximityPromptService.PromptTriggered:Connect(function(otherPrompt, who)
        if otherPrompt == prompt then
            markTriggered(who)
        end
    end))

    local originalRequiresLineOfSight = nil
    local changedLineOfSight = false
    pcall(function()
        originalRequiresLineOfSight = prompt.RequiresLineOfSight
        prompt.RequiresLineOfSight = false
        changedLineOfSight = true
    end)

    applyLocalPromptRange(prompt, keyObject)
    local success, message = withCameraFacing(prompt, token, function()
        if not prompt.Parent or not prompt.Enabled then
            return false, "Dropped-key prompt became unavailable"
        end

        local characterAtStart = getCharacter()
        local humanoidAtStart = getHumanoid()
        if not characterAtStart or not humanoidAtStart or humanoidAtStart.Health <= 0 then
            return false, "Character unavailable before dropped-key pickup"
        end

        local holdSeconds = math.clamp(tonumber(prompt.HoldDuration) or 0, 0, 8)
        local holdDeadline = os.clock() + math.max(0.12, holdSeconds + 0.12)
        local began = false
        local ok, err = pcall(function()
            prompt:InputHoldBegin()
            began = true
            while os.clock() < holdDeadline and farmRunning(token)
                and player.Character == characterAtStart
                and humanoidAtStart.Parent and humanoidAtStart.Health > 0 do
                task.wait(0.02)
            end
        end)

        if began and prompt.Parent then
            pcall(function() prompt:InputHoldEnd() end)
        end

        if not ok then
            return false, "Dropped-key input failed: " .. tostring(err)
        end
        if not farmRunning(token) then
            return false, "Autofarm stopped during dropped-key pickup"
        end
        if player.Character ~= characterAtStart or not humanoidAtStart.Parent
            or humanoidAtStart.Health <= 0 then
            return false, "Character changed during dropped-key pickup"
        end

        local confirmDeadline = os.clock() + 2.0
        repeat
            if droppedKeyWasRecovered(keyObject, folder, keysBefore, carriedBefore) then
                return true, "Dropped key collected and confirmed"
            end
            task.wait(0.05)
        until os.clock() >= confirmDeadline or not farmRunning(token)

        if triggered then
            return false, "Pickup prompt triggered, but the key is still listed as dropped"
        end
        return false, "Pickup prompt did not produce a server-confirmed key pickup"
    end)

    for _, connection in ipairs(connections) do
        pcall(function() connection:Disconnect() end)
    end
    if changedLineOfSight and prompt and prompt.Parent then
        pcall(function() prompt.RequiresLineOfSight = originalRequiresLineOfSight end)
    end
    restoreLocalPromptRange(prompt)

    return success == true, message
end

local function tryPickupDroppedKeyByTouch(keyObject, folder, token, keysBefore, carriedBefore)
    local touchPart = getDroppedKeyTouchPart(keyObject)
    if not touchPart or not touchPart.Parent then
        return false, "Dropped key has no touchable part"
    end

    if not waitForLivingCharacter(token) then
        return false, "Autofarm stopped while waiting for respawn"
    end

    local character = getCharacter()
    local root = getRoot()
    local humanoid = getHumanoid()
    if not character or not root or not humanoid or humanoid.Health <= 0 then
        return false, "Character unavailable for dropped-key touch pickup"
    end

    local targetPosition = touchPart.Position + Vector3.new(0, math.max(0.35, root.Size.Y * 0.28), 0)
    local targetFrame = CFrame.lookAt(targetPosition, targetPosition + Vector3.new(0, 0, -1))
    local ok, err = pcall(function()
        character:PivotTo(targetFrame)
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)
    if not ok then
        return false, "Could not approach dropped key: " .. tostring(err)
    end

    task.wait(0.4)
    if not farmRunning(token) then
        return false, "Autofarm stopped during dropped-key touch pickup"
    end
    if getCharacter() ~= character or humanoid.Health <= 0 then
        return false, "Character changed during dropped-key touch pickup"
    end

    if droppedKeyWasRecovered(keyObject, folder, keysBefore, carriedBefore) then
        return true, "Dropped key collected by touch and confirmed"
    end
    return false, "Touched the dropped-key area, but the server still reports the key as dropped"
end

-- Death previously called a missing recoverDroppedKeys() function, which
-- raised an error and switched Autofarm OFF. Recover every dropped key first,
-- waiting through respawns and retrying instead of terminating the farm.
local function recoverDroppedKeys(token)
    local lastNoticeAt = 0
    local pass = 0

    while farmRunning(token) do
        if not waitForLivingCharacter(token) then
            return false, "Autofarm stopped while waiting for respawn"
        end

        local droppedObjects, folder = getDroppedKeyObjects()
        if #droppedObjects == 0 then
            return true, "No dropped keys remain"
        end

        pass += 1
        farmStatus = "Recovering " .. #droppedObjects .. " dropped key(s)"

        local anyRecovered = false
        for _, keyObject in ipairs(droppedObjects) do
            if not farmRunning(token) then
                return false, "Autofarm stopped during dropped-key recovery"
            end
            if not waitForLivingCharacter(token) then
                return false, "Autofarm stopped while waiting for respawn"
            end
            if not isStillDropped(keyObject, folder) then
                anyRecovered = true
                continue
            end

            local keysBefore = getKeys()
            local carriedBefore = getCarriedKeyCount()
            local prompt = getDroppedKeyPrompt(keyObject)
            local recovered = false
            local reason = "No pickup prompt found"

            if prompt then
                local candidates, approachReason = findApproachPositions(
                    prompt, keyObject, (pass - 1) % 8, false, false, nil
                )

                for index = 1, math.min(4, #candidates) do
                    if not waitForLivingCharacter(token) then
                        return false, "Autofarm stopped while waiting for respawn"
                    end
                    local moved, moveMessage = teleportToCandidate(
                        candidates[index], prompt, prompt, token, keyObject
                    )
                    if moved then
                        recovered, reason = tryPickupDroppedKeyWithPrompt(
                            keyObject, prompt, folder, token, keysBefore, carriedBefore
                        )
                        if recovered or droppedKeyWasRecovered(keyObject, folder, keysBefore, carriedBefore) then
                            recovered = true
                            break
                        end
                    else
                        reason = tostring(moveMessage or approachReason)
                    end
                end

                if #candidates == 0 then
                    reason = tostring(approachReason or reason)
                end
            end

            if not recovered and isStillDropped(keyObject, folder) then
                recovered, reason = tryPickupDroppedKeyByTouch(
                    keyObject, folder, token, keysBefore, carriedBefore
                )
            end

            if recovered or droppedKeyWasRecovered(keyObject, folder, keysBefore, carriedBefore) then
                anyRecovered = true
                print("[MOUSE AUTOFARM] Dropped key recovered:", keyObject.Name)
            elseif os.clock() - lastNoticeAt >= 8 then
                warn(
                    "[MOUSE AUTOFARM] A dropped key is still server-owned and will be retried after a short pause:",
                    keyObject:GetFullName(),
                    "|",
                    reason
                )
                lastNoticeAt = os.clock()
            end
        end

        if #getDroppedKeyObjects() == 0 then
            return true, "All dropped keys recovered"
        end

        if not anyRecovered then
            task.wait(0.75)
        else
            task.wait(0.12)
        end
    end

    return false, "Autofarm stopped during dropped-key recovery"
end

-- Mickey LOS safety pausing and automatic evasion are disabled at the
-- user's request. Mickey ESP/highlighting remains enabled and continues to
-- identify Mickey, but its estimated sightline can no longer stop Autofarm.
local function startMickeySafetyMonitor(_token)
    -- Intentionally disabled.
end

local function waitForMickeySafety(token)
    return farmRunning(token)
end

local function isRespawnRelatedFailure(message)
    local text = tostring(message or ""):lower()
    return text:find("character", 1, true) ~= nil
        or text:find("live character", 1, true) ~= nil
        or text:find("root unavailable", 1, true) ~= nil
        or text:find("camera", 1, true) ~= nil
end

local function updateAutofarmButton()
    if toggleRender.Autofarm then
        toggleRender.Autofarm()
    end
end

local function finishFarm(token, message)
    if token ~= farmToken then return end

    farmStatus = "Retrying automatically: " .. tostring(message)
    updateAutofarmButton()
    warn("[MOUSE AUTOFARM]", message, "| Autofarm remains ON and will retry.")
end

local function searchOneEntry(entry, failures, token)
    local prompt = entry.Prompt
    local model = entry.Model
    local id = prompt
    local displayId = model:GetFullName()
    local phase = failures[id] or 0

    local candidates, reason = findApproachPositions(prompt, model, phase, false, true, "search")
    if #candidates == 0 then
        restoreLocalPromptRange(prompt)
        return false, reason
    end

    -- Try several distinct clear approach points in this pass. Failed
    -- prompts remain in the global queue and are retried with a rotated phase.
    local bedPrompt = isBedSearchEntry(prompt, model)
    -- These hanging bunks have cramped geometry. Trying multiple positions in
    -- one visit can bounce the avatar between neighbouring beds; use one best
    -- floor candidate per visit and rotate the side on each immediate retry.
    local maxCandidateAttempts = bedPrompt and 1 or math.min(4, #candidates)

    for index = 1, maxCandidateAttempts do
        if not farmRunning(token) then
            return false, "Autofarm stopped"
        end

        local candidate = candidates[index]
        -- Start timing immediately before the teleport attempt so the
        -- 0.18-second settle and the entire E/rummage sequence are included.
        local candidateTeleportStartedAt = os.clock()
        farmStatus = "Moving to " .. model.Name
        local teleported, teleportMessage, searchedDuringTravel = teleportToCandidate(
            candidate,
            prompt,
            prompt,
            token,
            model,
            true -- searchable items use visible, gradual noclip tween movement
        )

        if not teleported then
            warn(
                "[MOUSE AUTOFARM] Candidate " .. index .. " failed:",
                displayId,
                teleportMessage
            )
        elseif searchedDuringTravel then
            -- Defensive compatibility branch: only the selected item may report
            -- a completion during travel; neighbouring items are never triggered.
            markSearchableCompleted(model, prompt)
            restoreLocalPromptRange(prompt)
            print("[MOUSE AUTOFARM] Target item was completed during travel:", displayId)
            return true, "Search completed while travelling to item"
        else
            -- Search-specific settle: allow the server-owned prompt and the
            -- character position to replicate for the configured arrival window.
            -- Objective, padlock, and lever phases are not delayed.
            farmStatus = "Locking onto and instantly searching " .. model.Name
            if SEARCH_ARRIVAL_SETTLE > 0 then
                task.wait(SEARCH_ARRIVAL_SETTLE)
            end
            if not farmRunning(token) then
                restoreLocalPromptRange(prompt)
                return false, "Autofarm stopped during searchable arrival settle"
            end
            if safeHasExplicitSearchCompletion(prompt, model) then
                markSearchableCompleted(model, prompt)
                restoreLocalPromptRange(prompt)
                print("[MOUSE AUTOFARM] Game explicitly marked item no longer searchable during arrival settle:", displayId)
                return true, "Game marked item no longer searchable during arrival settle"
            end
            if not prompt.Parent then
                restoreLocalPromptRange(prompt)
                return false, "Search prompt was removed during the arrival settle"
            end
            if not prompt.Enabled then
                local reenableDeadline = os.clock() + 3.0
                farmStatus = "Waiting for selected Search prompt: " .. model.Name
                while farmRunning(token) and prompt.Parent and not prompt.Enabled
                    and os.clock() < reenableDeadline do
                    if safeHasExplicitSearchCompletion(prompt, model) then
                        markSearchableCompleted(model, prompt)
                        restoreLocalPromptRange(prompt)
                        return true, "Game explicitly confirmed this item is no longer searchable"
                    end
                    task.wait(0.10)
                end
                if not farmRunning(token) then
                    restoreLocalPromptRange(prompt)
                    return false, "Autofarm stopped while waiting for the Search prompt"
                end
                if not prompt.Parent then
                    restoreLocalPromptRange(prompt)
                    return false, "Search prompt was removed while waiting for re-enable"
                end
                if not prompt.Enabled then
                    restoreLocalPromptRange(prompt)
                    return false, "Selected Search prompt is still in a server cooldown; it remains eligible for another visit"
                end
            end

            -- The next searchable is selected immediately after this prompt
            -- reaches the game's terminal no-longer-searchable state.
            local beforeKeys = getKeys()
            farmStatus = "Facing and searching " .. model.Name

            local triggered, triggerMessage, fullSearchConfirmed =
                triggerPrompt(prompt, model, token)

            if triggered and fullSearchConfirmed then
                -- Only cache a prompt when the search/rummage completion
                -- signal was observed. A plain Triggered event is not enough:
                -- it can start a longer server-side rummage operation.
                markSearchableCompleted(model, prompt)
                
                local found = getKeys() > beforeKeys
                if found then
                    print(
                        "[MOUSE AUTOFARM] KEY FOUND:",
                        getKeys(), "/", getKeysTotal(), "at", displayId
                    )
                else
                    print("[MOUSE AUTOFARM] FULL SEARCH CONFIRMED; teleporting to next item immediately:", displayId)
                end

                restoreLocalPromptRange(prompt)
                return true, found and "Key found" or "Full search confirmed"

            elseif triggered and not fullSearchConfirmed then
                -- The spaced quick-tap sequence ran, but the game's terminal
                -- state has not replicated. Do not mark it complete from a
                -- Triggered event or key-count change; leave this prompt queued
                -- for another immediate retry pass.
                if getKeys() > beforeKeys then
                    print(
                        "[MOUSE AUTOFARM] Key count advanced; checking this item's own terminal state before leaving:",
                        getKeys(), "/", getKeysTotal(), "at", displayId
                    )
                end

                if safeHasExplicitSearchCompletion(prompt, model) then
                    markSearchableCompleted(model, prompt)
                    restoreLocalPromptRange(prompt)
                    return true, "Game explicitly marked item no longer searchable"
                end

                warn(
                    "[MOUSE AUTOFARM] Prompt accepted but is not yet marked unsearchable; keeping it queued:",
                    displayId,
                    triggerMessage
                )
                restoreLocalPromptRange(prompt)
                return false, "Search accepted but game still reports item searchable; queued for retry"

            else
                -- If Mickey interrupted this interaction, the character changed,
                -- or the server temporarily disabled the prompt, do not teleport
                -- through the remaining positions around this same searchable.
                -- The run loop will keep this exact prompt eligible immediately.
                local lowerMessage = tostring(triggerMessage or ""):lower()
                local interrupted = lowerMessage:find("character changed", 1, true)
                    or lowerMessage:find("mickey evasion", 1, true)
                    or lowerMessage:find("autofarm stopped", 1, true)
                local unavailable = not prompt.Parent or not prompt.Enabled
                    or lowerMessage:find("prompt became unavailable", 1, true)
                    or lowerMessage:find("prompt unavailable", 1, true)

                if interrupted or unavailable then
                    restoreLocalPromptRange(prompt)
                    return false,
                        (triggerMessage or "Search interaction interrupted")
                            .. "; deferred without trying adjacent positions"
                end

                -- If the server key counter increased despite a suppressed
                -- client event, the search definitely produced a key.
                if getKeys() > beforeKeys then
                    print(
                        "[MOUSE AUTOFARM] KEY FOUND, but this prompt still needs its own terminal state:",
                        getKeys(), "/", getKeysTotal(), "at", displayId
                    )
                end

                if safeHasExplicitSearchCompletion(prompt, model) then
                    markSearchableCompleted(model, prompt)
                    restoreLocalPromptRange(prompt)
                    return true, "Game marked item no longer searchable"
                end

                warn(
                    "[MOUSE AUTOFARM] Prompt did not trigger from candidate "
                    .. index .. ":",
                    displayId,
                    triggerMessage
                )
            end
        end

        task.wait(0.02)
    end

    restoreLocalPromptRange(prompt)
    return false, "All approach positions failed"
end

local function activateObjective(prompt, token, preferBack)
    if not prompt or not prompt.Parent then
        return false, "Objective prompt missing"
    end

    local model = getContainer(prompt, getBoat()) or getTargetModel(prompt)
    local candidates, reason = findApproachPositions(prompt, model, 0, preferBack == true, true, "objective")

    if #candidates == 0 then
        restoreLocalPromptRange(prompt)
        return false, reason
    end

    for index = 1, math.min(12, #candidates) do
        local teleported, message = teleportToCandidate(
            candidates[index], prompt, prompt, token
        )

        if teleported then
            return triggerPrompt(prompt, model, token, ENGINE_STOPPER_MIN_HOLD)
        end

        warn("[MOUSE AUTOFARM] Objective approach failed:", message)
    end

    return false, "No valid objective approach position"
end

-- Activate padlock prompts quickly while respecting each prompt's configured hold.
-- This is separate from the longer rummage/search completion watcher.
local function triggerPadlockPrompt(prompt, token)
    if not prompt or not prompt.Parent or not prompt.Enabled then
        return false, "Padlock prompt unavailable"
    end

    local triggered = false
    local interactionCharacter = getCharacter()
    local interactionHumanoid = getHumanoid()
    local function interactionStillValid()
        return player.Character == interactionCharacter
            and interactionHumanoid ~= nil
            and interactionHumanoid.Parent ~= nil
            and interactionHumanoid.Health > 0
    end

    local beforeProgress = getPadlocksOpen()
    local originalRequiresLineOfSight = nil
    local changedLineOfSight = false
    pcall(function()
        originalRequiresLineOfSight = prompt.RequiresLineOfSight
        prompt.RequiresLineOfSight = false
        changedLineOfSight = true
    end)

    local connections = {}
    local function markTriggered(who)
        if who == nil or who == player then
            triggered = true
        end
    end

    table.insert(connections, prompt.Triggered:Connect(markTriggered))
    table.insert(connections, ProximityPromptService.PromptTriggered:Connect(function(otherPrompt, who)
        if otherPrompt == prompt then
            markTriggered(who)
        end
    end))

    local ok, result = withCameraFacing(prompt, token, function()
        if not prompt.Parent or not prompt.Enabled then
            return false, "Padlock prompt became unavailable"
        end

        local holdDuration = tonumber(prompt.HoldDuration) or 0
        local holdSeconds = math.max(holdDuration + 0.12, 0.25)
        local started = os.clock()
        local inputHeld = false

        local success, err = pcall(function()
            prompt:InputHoldBegin()
            inputHeld = true

            while os.clock() - started < holdSeconds and farmRunning(token) and interactionStillValid() do
                task.wait(0.02)
            end
        end)

        if inputHeld and prompt.Parent then
            pcall(function()
                prompt:InputHoldEnd()
            end)
        end

        if not success then
            return false, tostring(err)
        end

        if not farmRunning(token) then
            return false, "Autofarm stopped"
        end
        if not interactionStillValid() then
            return false, "Character changed or Mickey evasion interrupted padlock interaction"
        end

        -- Prompt.Triggered is a client event; it does not prove that the
        -- server accepted the key or opened a lock. Wait for the replicated
        -- 0/5 counter or an explicit open/unlocked attribute instead.
        local deadline = os.clock() + 1.35
        local confirmed = false
        while os.clock() < deadline and farmRunning(token) and interactionStillValid() do
            local progress = getPadlocksOpen()
            local entry = {
                Prompt = prompt,
                Root = getPadlockRoot(prompt)
            }
            if progress > beforeProgress or padlockLooksOpen(entry) then
                confirmed = true
                break
            end
            task.wait(0.035)
        end

        local finalProgress = getPadlocksOpen()
        local finalEntry = {
            Prompt = prompt,
            Root = getPadlockRoot(prompt)
        }
        confirmed = confirmed or finalProgress > beforeProgress or padlockLooksOpen(finalEntry)

        if confirmed then
            return true, finalProgress > beforeProgress
                and ("Padlock progress confirmed: " .. tostring(finalProgress))
                or "Padlock open state confirmed"
        end

        if triggered then
            return false, string.format(
                "Client accepted E, but server did not confirm a padlock opening; Boat.Keys reports %d/%d and prompt says '%s'",
                getKeys(),
                getKeysTotal(),
                tostring(prompt.ActionText)
            )
        end
        return false, "No server-confirmed padlock progress"
    end)

    for _, connection in ipairs(connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end

    if changedLineOfSight and prompt and prompt.Parent then
        pcall(function()
            prompt.RequiresLineOfSight = originalRequiresLineOfSight
        end)
    end

    return ok == true, result
end

local function activatePadlockEntry(entry, token, phase)
    local prompt = entry and entry.Prompt
    if not prompt or not prompt.Parent then
        return false, "Padlock prompt disappeared"
    end

    local root = entry.Root or getTargetModel(prompt)
    local candidates, reason = findApproachPositions(
        prompt,
        root,
        phase or 0,
        true, -- prefer the inward/back side of the shared lock assembly
        false, -- interior padlock interaction temporarily bypasses prompt LOS
        "padlock" -- raycast to the deck beneath the locks, never onto the lock tops
    )

    if #candidates == 0 then
        warn(
            "[MOUSE AUTOFARM] No inside-side padlock position:",
            prompt:GetFullName(),
            "|",
            reason
        )
        return false, reason
    end

    print(
        "[MOUSE AUTOFARM] Inside-side padlock destination:",
        prompt:GetFullName(),
        "| position:",
        tostring(candidates[1].Position),
        "| distance:",
        string.format("%.2f", (candidates[1].Position - getPromptAnchor(prompt)).Magnitude),
        "| candidates:",
        #candidates
    )

    for index = 1, math.min(12, #candidates) do
        if not farmRunning(token) then
            return false, "Autofarm stopped"
        end

        local moved, moveMessage = teleportToCandidate(
            candidates[index],
            prompt,
            prompt,
            token,
            root
        )

        if not moved and tostring(moveMessage):find("Server corrected the client-side move", 1, true) then
            warn(
                "[MOUSE AUTOFARM] Server rejected the inside-side pivot; trying normal movement instead:",
                moveMessage
            )
            moved, moveMessage = moveNormallyToPadlockCandidate(
                candidates[index],
                prompt,
                token,
                root
            )
        end

        if moved then
            local success, message = triggerPadlockPrompt(prompt, token)
            if success then
                return true, message
            end

            warn(
                "[MOUSE AUTOFARM] Padlock prompt did not advance at candidate "
                    .. index .. ":",
                message
            )
        else
            warn(
                "[MOUSE AUTOFARM] Padlock approach candidate "
                    .. index .. " failed:",
                moveMessage
            )
        end
    end

    return false, "No usable approach/interaction position"
end

-- MOUSE's screenshot shows one shared prompt: "Open a padlock (0/5)".
-- That same prompt must be activated five times. If the game instead exposes
-- five separate prompts, each prompt is activated once. In both cases the
-- boat counter and the visible 0/5 text are used as progress signals.
local function unlockAllPadlocks(token)
    local total = getPadlocksTotal()
    local startingOpen = getPadlocksOpen()
    local actionsConfirmed = 0
    local completedIndividual = {}
    local failureCounts = {}
    local phaseByPrompt = {}
    local lastPadlockCFrame = nil
    local lastProgressAt = os.clock()
    local lastNoPromptNotice = 0
    local loopCount = 0
    local printedPadlockScan = false

    while farmRunning(token) do
        if not waitForLivingCharacter(token) then
            return false, "Autofarm stopped while waiting for a living character", lastPadlockCFrame
        end
        loopCount += 1

        local liveOpen = getPadlocksOpen()
        total = math.max(total, getPadlocksTotal())
        local confirmedOpen = math.max(
            liveOpen,
            startingOpen + actionsConfirmed
        )

        if confirmedOpen >= total then
            print(
                "[MOUSE AUTOFARM] All padlocks unlocked:",
                confirmedOpen,
                "/",
                total
            )
            return true, "All padlocks unlocked", lastPadlockCFrame
        end

        local entries = findPadlockPrompts()
        if not printedPadlockScan then
            printedPadlockScan = true
            print("[MOUSE AUTOFARM] Padlock prompt scan found", #entries, "candidate prompt(s).")
            for _, discovered in ipairs(entries) do
                print(
                    "[MOUSE AUTOFARM] Padlock candidate:",
                    discovered.Prompt:GetFullName(),
                    "| Action:", discovered.Prompt.ActionText,
                    "| Object:", discovered.Prompt.ObjectText,
                    "| Enabled:", discovered.Prompt.Enabled,
                    "| Shared:", discovered.Shared
                )
            end
        end
        local shared = {}
        local individual = {}

        -- A shared progress prompt (for example "Open a padlock (0/5)")
        -- stays reusable even if a second lock-related prompt is discovered.
        -- Separate prompts without a progress counter are handled individually.
        for _, entry in ipairs(entries) do
            local prompt = entry.Prompt
            local isSharedEntry = entry.Shared or isSharedPadlockPrompt(prompt)

            if prompt.Parent and prompt.Enabled and not padlockLooksOpen(entry) then
                if isSharedEntry then
                    table.insert(shared, entry)
                elseif not completedIndividual[prompt] then
                    table.insert(individual, entry)
                end
            end
        end

        local entry = nil
        local isShared = false

        -- Reuse the one aggregate prompt until its progress reaches 5/5.
        if #shared > 0 then
            entry = shared[1]
            isShared = true
        elseif #individual > 0 then
            shuffleInPlace(individual)
            entry = individual[1]
        end

        if not entry then
            if os.clock() - lastNoPromptNotice > 5 then
                warn(
                    "[MOUSE AUTOFARM] Waiting for padlock interaction to appear/update:",
                    confirmedOpen,
                    "/",
                    total,
                    "| prompts visible:",
                    #entries
                )
                lastNoPromptNotice = os.clock()
            end

            -- The prompt may briefly disable while the server opens a lock.
            -- Stay in the padlock phase rather than switching the farm off.
            farmStatus = "Waiting for padlocks " .. confirmedOpen .. "/" .. total
            task.wait(0.15)
            continue
        end

        local prompt = entry.Prompt
        local promptKey = prompt
        local beforeOpen = getPadlocksOpen()
        local wasShared = isShared

        farmStatus = "Unlocking padlock " .. tostring(confirmedOpen + 1)
            .. "/" .. tostring(total)

        print(
            "[MOUSE AUTOFARM] Moving behind padlock row (inside ship):",
            entry.Root and entry.Root:GetFullName() or prompt:GetFullName(),
            "| Shared prompt:",
            wasShared,
            "| Current progress:",
            confirmedOpen,
            "/",
            total
        )

        local phase = phaseByPrompt[promptKey] or 0
        local success, message = activatePadlockEntry(entry, token, phase)

        if success then
            failureCounts[promptKey] = nil
            phaseByPrompt[promptKey] = 0

            -- Wait briefly for server attributes or the prompt's "(n/5)" text.
            local progressDeadline = os.clock() + 0.45
            while os.clock() < progressDeadline and farmRunning(token) do
                local updated = getPadlocksOpen()
                if updated > beforeOpen then
                    break
                end
                if not prompt.Parent or not prompt.Enabled then
                    break
                end
                task.wait(0.025)
            end

            local afterOpen = getPadlocksOpen()
            local openAttributeConfirmed = padlockLooksOpen(entry)
            if afterOpen > beforeOpen then
                actionsConfirmed = math.max(
                    actionsConfirmed,
                    afterOpen - startingOpen
                )
            elseif openAttributeConfirmed then
                -- Individual lock models can expose a Bool attribute without
                -- changing the shared text counter. Count only that explicit
                -- open state, never the client-side Triggered event alone.
                actionsConfirmed += 1
            else
                failureCounts[promptKey] = (failureCounts[promptKey] or 0) + 1
                warn(
                    "[MOUSE AUTOFARM] Padlock interaction was not server-confirmed; staying in the padlock phase:",
                    prompt:GetFullName(),
                    "| progress:",
                    afterOpen,
                    "/",
                    total
                )
                task.wait(0.2)
                continue
            end

            if not wasShared then
                completedIndividual[promptKey] = true
            end

            -- Remember the actual safe deck position used for the final lock.
            -- The next 15-second interaction remains here instead of moving
            -- the player away from the padlock area.
            local safeRoot = getRoot()
            if safeRoot then
                lastPadlockCFrame = safeRoot.CFrame
            end

            lastProgressAt = os.clock()

            print(
                "[MOUSE AUTOFARM] Padlock interaction accepted:",
                confirmedOpen + 1,
                "/",
                total,
                "| Prompt:",
                prompt:GetFullName(),
                "| Server/text count:",
                getPadlocksOpen(),
                "| Local accepted actions:",
                actionsConfirmed
            )

            -- Short state replication pause; do not add the search/rummage delay here.
            task.wait(0.08)
        else
            failureCounts[promptKey] = (failureCounts[promptKey] or 0) + 1
            phaseByPrompt[promptKey] = (phase + 1) % 8

            warn(
                "[MOUSE AUTOFARM] Padlock attempt failed:",
                prompt:GetFullName(),
                "| failures:",
                failureCounts[promptKey],
                "| reason:",
                message
            )

            -- On a shared prompt, rotate the approach position and retry it.
            -- On separate locks, other prompts are chosen before this one repeats.
            task.wait(0.12)
        end

        -- If neither the replicated value nor prompt text advances over several
        -- accepted triggers, keep trying the shared action rather than exiting.
        if os.clock() - lastProgressAt > 20 then
            warn(
                "[MOUSE AUTOFARM] Padlock progress has not replicated yet; continuing retries at the lock assembly.",
                confirmedOpen,
                "/",
                total
            )
            lastProgressAt = os.clock()
        end

        if loopCount % 100 == 0 then
            task.wait(0.1)
        end
    end

    return false, "Autofarm stopped"
end

-- The final boat-lowering lever must remain held for fifteen seconds.
-- Some rounds configure the prompt itself for only ten seconds. If we leave
-- that value unchanged, Roblox can fire the server interaction at ten seconds
-- even though this helper continues holding E for another five seconds.
-- Temporarily set the local prompt's hold duration to fifteen BEFORE beginning
-- the hold, then restore its original value after InputHoldEnd.
local function holdLeverFor15Seconds(prompt, token)
    if not prompt or not prompt.Parent then
        return false, "Lever prompt missing"
    end

    local holdSeconds = 15.0
    local triggered = false
    local triggeredAt = nil
    local connections = {}
    local originalHoldDuration = prompt.HoldDuration
    local holdDurationOverridden = false
    local holdActive = false

    local function markTriggered(who)
        if who == nil or who == player then
            if not triggeredAt then
                triggeredAt = os.clock()
            end
            triggered = true
        end
    end

    local function reassertFifteenSeconds()
        if holdActive and prompt.Parent then
            local current = tonumber(prompt.HoldDuration)
            if not current or math.abs(current - holdSeconds) > 0.05 then
                pcall(function()
                    prompt.HoldDuration = holdSeconds
                end)
            end
        end
    end

    table.insert(connections, prompt.Triggered:Connect(markTriggered))
    table.insert(connections, ProximityPromptService.PromptTriggered:Connect(function(otherPrompt, who)
        if otherPrompt == prompt then
            markTriggered(who)
        end
    end))
    table.insert(connections, prompt:GetPropertyChangedSignal("HoldDuration"):Connect(reassertFifteenSeconds))

    local model = getTargetModel(prompt)
    local range = applyLocalPromptRange(prompt, model)
    local rootBeforeHold = getRoot()
    local promptPosition = getPromptAnchor(prompt)

    -- Stay in the padlock shelter. Use the prompt only when it remains nearby.
    if rootBeforeHold and promptPosition then
        local distance = (rootBeforeHold.Position - promptPosition).Magnitude
        if distance > range then
            local expandedRange = math.min(24, distance + 0.75)
            if expandedRange > range then
                if promptRangeOriginal[prompt] == nil then
                    promptRangeOriginal[prompt] = prompt.MaxActivationDistance
                end
                pcall(function()
                    prompt.MaxActivationDistance = expandedRange
                end)
                range = expandedRange
            end
        end

        if distance > range + 0.5 then
            for _, connection in ipairs(connections) do pcall(function() connection:Disconnect() end) end
            restoreLocalPromptRange(prompt)
            return false, string.format(
                "Final lever is %.1f studs away; staying inside the padlocks as requested",
                distance
            )
        end
    end

    local setHoldOK, setHoldError = pcall(function()
        prompt.HoldDuration = holdSeconds
    end)
    local observedHoldDuration = tonumber(prompt.HoldDuration)
    if not setHoldOK or not observedHoldDuration
        or math.abs(observedHoldDuration - holdSeconds) > 0.05 then
        for _, connection in ipairs(connections) do pcall(function() connection:Disconnect() end) end
        restoreLocalPromptRange(prompt)
        return false,
            "Could not set the local lever prompt HoldDuration to 15 seconds"
                .. (setHoldError and (": " .. tostring(setHoldError)) or "")
    end
    holdDurationOverridden = true

    print(
        "[MOUSE AUTOFARM] Lever hold configured locally:",
        tostring(originalHoldDuration), "-> 15 seconds; confirm the server companion is installed for server-side enforcement."
    )

    task.wait()

    local ok, message, startedAt, holdFinishedAt = withCameraFacing(prompt, token, function()
        if not prompt.Parent or not prompt.Enabled then
            return false, "Final boat lever prompt is unavailable"
        end

        pcall(function() prompt.HoldDuration = holdSeconds end)
        local currentHoldDuration = tonumber(prompt.HoldDuration)
        if not currentHoldDuration or math.abs(currentHoldDuration - holdSeconds) > 0.05 then
            return false, "Lever HoldDuration was not 15 seconds immediately before E began"
        end

        local started = os.clock()
        local deadline = started + holdSeconds
        local inputHeld = false
        holdActive = true

        local success, err = pcall(function()
            prompt:InputHoldBegin()
            inputHeld = true

            while os.clock() < deadline and farmRunning(token) do
                -- Keep resetting a game-side local change during the active hold.
                reassertFifteenSeconds()
                local elapsed = math.clamp(os.clock() - started, 0, holdSeconds)
                farmStatus = string.format("HOLDING FINAL LEVER: %.1f/15.0s", elapsed)
                task.wait(0.025)
            end
        end)

        if inputHeld and prompt.Parent then
            pcall(function() prompt:InputHoldEnd() end)
        end
        holdActive = false
        local finished = os.clock()

        if not success then
            return false, tostring(err)
        end
        if not farmRunning(token) then
            return false, "Autofarm stopped during the 15-second lever hold"
        end
        if finished - started < 14.90 then
            return false, string.format(
                "Lever hold was interrupted after %.2f seconds; refusing to start the escape sequence",
                finished - started
            )
        end

        if triggeredAt and triggeredAt < started + 14.85 then
            warn(
                "[MOUSE AUTOFARM] The client Triggered event arrived early at %.2fs. E was still held until 15.0s; checking the server's measured hold before continuing.",
                triggeredAt - started
            )
        end

        -- Local HoldDuration is not authoritative. Require the companion
        -- Script to report that the server itself observed PromptTriggered
        -- after at least 14.8 seconds. Do not enter the cutscene/escape phase
        -- if the game's server still fires this prompt at ten seconds.
        local statusRemote = ReplicatedStorage:FindFirstChild("MOUSE_GetLever15Status")
        if not statusRemote or not statusRemote:IsA("RemoteFunction") then
            warn(
                "[MOUSE AUTOFARM] The client held E for the full 15.00 seconds, but the server companion is missing; server-side HoldDuration cannot be verified. Continuing to the cutscene and escape-edge walk instead of shutting Autofarm off."
            )
            return true,
                "Client held E for the full 15 seconds; server confirmation unavailable, continuing escape sequence",
                started,
                finished
        end

        local serverConfirmed = false
        local serverElapsed = 0
        local serverPromptName = "unknown"
        local confirmDeadline = os.clock() + 3.0
        repeat
            local requestOK, confirmed, elapsed, promptName = pcall(function()
                return statusRemote:InvokeServer()
            end)
            if requestOK then
                serverConfirmed = confirmed == true
                serverElapsed = tonumber(elapsed) or 0
                serverPromptName = tostring(promptName or "unknown")
                if serverConfirmed and serverElapsed >= 14.80 then
                    break
                end
            end
            task.wait(0.10)
        until os.clock() >= confirmDeadline or not farmRunning(token)

        if not serverConfirmed or serverElapsed < 14.80 then
            warn(string.format(
                "[MOUSE AUTOFARM] Client held E for 15.00 seconds, but the server reported only %.2fs for %s. Continuing the escape sequence; install/enable the server companion to enforce the server-side 15-second prompt duration.",
                serverElapsed,
                serverPromptName
            ))
            return true, string.format(
                "Client held E for 15 seconds; server measured %.2fs, continuing to escape edge",
                serverElapsed
            ), started, finished
        end

        print(string.format(
            "[MOUSE AUTOFARM] SERVER CONFIRMED FINAL LEVER HOLD: %.2f seconds | %s",
            serverElapsed,
            serverPromptName
        ))

        return true,
            "Client and server confirmed the full 15-second lever hold",
            started,
            finished
    end)

    holdActive = false
    if holdDurationOverridden and prompt.Parent then
        pcall(function() prompt.HoldDuration = originalHoldDuration end)
    end
    for _, connection in ipairs(connections) do
        pcall(function() connection:Disconnect() end)
    end
    restoreLocalPromptRange(prompt)

    return ok == true, message, startedAt, holdFinishedAt, triggeredAt
end

local function getBoatWorldPosition(boat)
    if not boat then return nil end

    if boat:IsA("Model") then
        local ok, pivot = pcall(function() return boat:GetPivot() end)
        if ok and pivot then return pivot.Position end
    elseif boat:IsA("BasePart") then
        return boat.Position
    end

    return nil
end

local function waitForBoatDropCutscene(token, actionStartedAt, holdFinishedAt, leverTriggeredAt)
    -- The cutscene starts when the game accepts the lever prompt. Always keep
    -- E held for the full local 15 seconds, then wait until five seconds have
    -- elapsed from the game's trigger (or from hold end if no trigger was seen).
    local holdEnd = tonumber(holdFinishedAt) or os.clock()
    local cutsceneStart = tonumber(leverTriggeredAt) or holdEnd
    local deadline = math.max(holdEnd, cutsceneStart + 5.0)

    while farmRunning(token) do
        local remaining = deadline - os.clock()
        if remaining <= 0 then
            return true, "Five-second boat-drop cutscene has finished after the full lever hold"
        end

        farmStatus = string.format("Boat-drop cutscene: %.1fs", remaining)
        task.wait(math.min(0.05, remaining))
    end

    return false, "Autofarm stopped during the boat-drop cutscene"
end

local function normalizeObjectiveText(value)
    return tostring(value or ""):lower():gsub("[^%w]", "")
end

local function findSpatialAncestor(instance)
    local current = instance
    while current and current ~= workspace do
        if current:IsA("Model") or current:IsA("BasePart") then
            return current
        elseif current:IsA("Attachment") and current.Parent and current.Parent:IsA("BasePart") then
            return current.Parent
        end
        current = current.Parent
    end
    return nil
end

local function addLifeboatCandidate(list, seen, instance, source, rank)
    if not instance then return end

    local spatial = instance
    if not (spatial:IsA("Model") or spatial:IsA("BasePart")) then
        -- A marker can be held in a Folder named LIFEBOAT under the main ship.
        -- In that case, resolve the actual spatial child instead of climbing
        -- straight to the unrelated Workspace.Boat ancestor.
        if spatial:IsA("Folder") then
            local preferredChild = nil
            for _, descendant in ipairs(spatial:GetDescendants()) do
                if descendant:IsA("Model") or descendant:IsA("BasePart") then
                    preferredChild = descendant
                    if descendant:IsA("Model") then break end
                end
            end
            if preferredChild then
                spatial = preferredChild
            else
                spatial = findSpatialAncestor(instance)
            end
        else
            spatial = findSpatialAncestor(instance)
        end
    end

    if not spatial or seen[spatial] then return end
    if not (spatial:IsA("Model") or spatial:IsA("BasePart")) then return end

    seen[spatial] = true
    table.insert(list, {
        Instance = spatial,
        Source = source,
        Rank = rank or 5
    })
end

local function findLifeboatTarget(root)
    local candidates = {}
    local seen = {}

    for _, object in ipairs(workspace:GetDescendants()) do
        local normalizedName = normalizeObjectiveText(object.Name)
        if normalizedName:find("lifeboat", 1, true) then
            addLifeboatCandidate(candidates, seen, object, "instance name " .. object:GetFullName(), 1)
        end

        if object:IsA("BillboardGui") or object:IsA("SurfaceGui") then
            local labelFound = false
            for _, guiObject in ipairs(object:GetDescendants()) do
                if (guiObject:IsA("TextLabel") or guiObject:IsA("TextButton"))
                    and normalizeObjectiveText(guiObject.Text):find("lifeboat", 1, true) then
                    labelFound = true
                    break
                end
            end

            if labelFound then
                local adornee = nil
                pcall(function() adornee = object.Adornee end)
                addLifeboatCandidate(
                    candidates,
                    seen,
                    adornee or object.Parent,
                    "LIFEBOAT world marker " .. object:GetFullName(),
                    2
                )
            end
        elseif object:IsA("ProximityPrompt") then
            local context = normalizeObjectiveText(
                object.Name .. " " .. object.ActionText .. " " .. object.ObjectText
            )
            if context:find("lifeboat", 1, true) then
                addLifeboatCandidate(
                    candidates,
                    seen,
                    object.Parent,
                    "LIFEBOAT prompt " .. object:GetFullName(),
                    3
                )
            end
        end

        -- Some objective markers store their display name in an Attribute
        -- rather than in the Instance name or a BillboardGui label.
        for attributeName, attributeValue in pairs(object:GetAttributes()) do
            local attrName = normalizeObjectiveText(attributeName)
            local attrValue = normalizeObjectiveText(attributeValue)
            if (attrName:find("objective", 1, true)
                    or attrName:find("target", 1, true)
                    or attrName:find("marker", 1, true))
                and attrValue:find("lifeboat", 1, true) then
                addLifeboatCandidate(
                    candidates,
                    seen,
                    object,
                    "LIFEBOAT objective attribute on " .. object:GetFullName(),
                    2
                )
            end
        end
    end

    if #candidates == 0 then
        return nil, "No spatial LIFEBOAT name, marker, prompt, or objective attribute was found"
    end

    local best = nil
    local bestRank = math.huge
    local bestDistance = math.huge
    for _, candidate in ipairs(candidates) do
        local instance = candidate.Instance
        local position = nil
        if instance:IsA("BasePart") then
            position = instance.Position
        elseif instance:IsA("Model") then
            local ok, frame = pcall(function() return instance:GetBoundingBox() end)
            if ok and frame then position = frame.Position end
        end

        if position then
            local distance = root and (position - root.Position).Magnitude or 0
            if candidate.Rank < bestRank
                or (candidate.Rank == bestRank and distance < bestDistance) then
                best = candidate
                bestRank = candidate.Rank
                bestDistance = distance
            end
        end
    end

    if not best then
        return nil, "LIFEBOAT marker was found but had no usable world position"
    end

    return best.Instance, best.Source
end

local function isSupportedByBoatDeck(position, boat, standingHeight)
    if not position or not boat then return false end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    params.FilterDescendantsInstances = {boat}
    params.IgnoreWater = true

    -- Probe the centre and four foot-area offsets. This also supports a deck
    -- assembled from multiple adjacent wooden planks instead of one large part.
    local offsets = {
        Vector2.new(0, 0),
        Vector2.new(-0.75, 0),
        Vector2.new(0.75, 0),
        Vector2.new(0, -0.75),
        Vector2.new(0, 0.75)
    }
    local supportCount = 0
    local centreSupported = false
    local downDistance = math.max(7.0, (standingHeight or 3.0) + 4.5)

    for index, offset in ipairs(offsets) do
        local origin = position + Vector3.new(offset.X, 1.5, offset.Y)
        local hit = workspace:Raycast(origin, Vector3.new(0, -downDistance, 0), params)
        local safeHit = hit ~= nil
            and hit.Instance ~= nil
            and hit.Instance:IsA("BasePart")
            and hit.Instance.CanCollide
            and hit.Instance:IsDescendantOf(boat)
            and hit.Normal.Y >= 0.70
            and hit.Material ~= Enum.Material.Water
            and isLikelyWalkableSurface(hit.Instance)

        if safeHit then
            supportCount += 1
            if index == 1 then centreSupported = true end
        end
    end

    return centreSupported and supportCount >= 3
end

local function getLifeboatSprintGoal(root)
    if not root then return nil, "Character root unavailable" end

    local target, source = findLifeboatTarget(root)
    if not target then return nil, source end

    local markerPosition
    if target:IsA("BasePart") then
        markerPosition = target.Position
    elseif target:IsA("Model") then
        local ok, frame = pcall(function() return target:GetBoundingBox() end)
        if ok and frame then markerPosition = frame.Position end
    end
    if not markerPosition then
        return nil, "LIFEBOAT marker had no readable world position"
    end

    local boat = getBoat()
    if not boat then
        return nil, "Main Boat model was unavailable for a safe deck-edge approach"
    end

    local humanoid = getHumanoid()
    local standingHeight = humanoid
        and (humanoid.HipHeight + root.Size.Y * 0.5 + 0.12)
        or 3.0

    -- The LIFEBOAT marker sits outside the main ship. The previous version
    -- aimed beyond the target model's near edge, which could put the goal in
    -- open water. Instead, sample the actual collidable deck parts of the main
    -- Boat and choose the closest safe point that remains several studs INSIDE
    -- the ship's edge, on the side facing the LIFEBOAT marker.
    local includeBoat = RaycastParams.new()
    includeBoat.FilterType = Enum.RaycastFilterType.Include
    includeBoat.FilterDescendantsInstances = {boat}
    includeBoat.IgnoreWater = true

    local candidates = {}
    local parts = {}
    if boat:IsA("BasePart") then
        table.insert(parts, boat)
    end
    for _, object in ipairs(boat:GetDescendants()) do
        if object:IsA("BasePart") then
            table.insert(parts, object)
        end
    end

    local excludedNameWords = {
        "hull", "keel", "rail", "rope", "chain", "mast", "ladder",
        "wall", "door", "crate", "barrel", "bed", "seat", "wheel"
    }

    for _, part in ipairs(parts) do
        local partName = part.Name:lower()
        local nameRejected = false
        for _, word in ipairs(excludedNameWords) do
            if partName:find(word, 1, true) then
                nameRejected = true
                break
            end
        end

        local halfX = part.Size.X * 0.5
        local halfZ = part.Size.Z * 0.5
        local isDeckCandidate = not nameRejected
            and part.CanCollide
            and part.Size.Y <= 4.5
            and part.CFrame.UpVector.Y >= 0.78
            and isLikelyWalkableSurface(part)
            and math.max(part.Size.X, part.Size.Z) >= 4.0
            and math.min(part.Size.X, part.Size.Z) >= 0.30

        if isDeckCandidate then
            local localTarget = part.CFrame:PointToObjectSpace(markerPosition)
            -- Inset about 1.65 studs from the escape-facing deck edges so the avatar's collision body
            -- remains supported even if the marker is almost directly outside
            -- the ship's railing or outer deck boundary.
            local marginX = math.min(1.65, math.max(0.25, halfX - 0.35))
            local marginZ = math.min(1.65, math.max(0.25, halfZ - 0.35))
            local minX, maxX = -halfX + marginX, halfX - marginX
            local minZ, maxZ = -halfZ + marginZ, halfZ - marginZ
            local baseX = math.clamp(localTarget.X, minX, maxX)
            local baseZ = math.clamp(localTarget.Z, minZ, maxZ)

            local samples = {
                Vector2.new(0, 0),
                Vector2.new(-0.9, 0), Vector2.new(0.9, 0),
                Vector2.new(0, -0.9), Vector2.new(0, 0.9),
                Vector2.new(-0.9, -0.9), Vector2.new(0.9, -0.9),
                Vector2.new(-0.9, 0.9), Vector2.new(0.9, 0.9)
            }

            for _, sample in ipairs(samples) do
                local localX = math.clamp(baseX + sample.X, minX, maxX)
                local localZ = math.clamp(baseZ + sample.Y, minZ, maxZ)
                local surfacePoint = part.CFrame:PointToWorldSpace(
                    Vector3.new(localX, part.Size.Y * 0.5, localZ)
                )
                local hit = workspace:Raycast(
                    surfacePoint + Vector3.new(0, 5, 0),
                    Vector3.new(0, -12, 0),
                    includeBoat
                )

                if hit and hit.Instance and hit.Instance:IsA("BasePart")
                    and hit.Instance.CanCollide
                    and hit.Normal.Y >= 0.72
                    and hit.Material ~= Enum.Material.Water
                    and hit.Instance:IsDescendantOf(boat)
                    and math.abs(hit.Position.Y - surfacePoint.Y) <= 2.25
                    and isLikelyWalkableSurface(hit.Instance) then

                    local standingPoint = hit.Position + Vector3.new(0, standingHeight, 0)
                    if isSupportedByBoatDeck(standingPoint, boat, standingHeight)
                        and hasStandingRoom(standingPoint, nil, nil) then
                        local towardMarker = Vector3.new(
                            markerPosition.X - standingPoint.X,
                            0,
                            markerPosition.Z - standingPoint.Z
                        )
                        if towardMarker.Magnitude < 0.05 then
                            towardMarker = Vector3.new(0, 0, 0)
                        else
                            towardMarker = towardMarker.Unit
                        end

                        -- The previous edge point was safe but stopped a few
                        -- studs short of MOUSE's escape trigger. Try progressively
                        -- farther forward toward the LIFEBOAT marker. Each advance
                        -- must still be supported by the actual Boat deck and have
                        -- clear standing room; unsupported points are discarded.
                        for _, advance in ipairs({0, 0.75, 1.5, 2.0, 2.4}) do
                            local advancedPoint = standingPoint + towardMarker * advance
                            if isSupportedByBoatDeck(advancedPoint, boat, standingHeight)
                                and hasStandingRoom(advancedPoint, nil, nil) then
                                local markerDistance = Vector2.new(
                                    advancedPoint.X - markerPosition.X,
                                    advancedPoint.Z - markerPosition.Z
                                ).Magnitude
                                local heightPenalty = math.abs(advancedPoint.Y - root.Position.Y) * 0.22
                                local nameBonus = 0
                                if partName:find("deck", 1, true)
                                    or partName:find("floor", 1, true)
                                    or partName:find("plank", 1, true) then
                                    nameBonus = 2.5
                                end

                                table.insert(candidates, {
                                    Position = advancedPoint,
                                    Surface = hit.Instance,
                                    Advance = advance,
                                    Score = markerDistance + heightPenalty - nameBonus
                                })
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        return a.Score < b.Score
    end)

    if #candidates == 0 then
        return nil, "LIFEBOAT marker found, but no verified walkable point was found on the main ship deck"
    end

    local chosen = candidates[1]
    print(
        "[MOUSE AUTOFARM] Escape deck spot resolved toward LIFEBOAT marker:",
        source,
        "| surface:", chosen.Surface:GetFullName(),
        "| goal:", tostring(chosen.Position),
        "| forward advance:", string.format("%.2f studs", tonumber(chosen.Advance) or 0),
        "| marker distance:", string.format("%.1f", chosen.Score)
    )
    return chosen.Position, source .. "; safe point on main Boat deck"
end

local function horizontalDistance(a, b)
    return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function waitForDeckMove(token, destination, boat, standingHeight, humanoid)
    local root = getRoot()
    if not root or not humanoid then return false, "Character unavailable" end

    local startDistance = horizontalDistance(root.Position, destination)
    if startDistance <= 1.0 then
        return isSupportedByBoatDeck(root.Position, boat, standingHeight), "Already at the escape-edge deck point"
    end

    humanoid:MoveTo(destination)
    local walkSpeed = math.max(tonumber(humanoid.WalkSpeed) or 16, 12)
    local deadline = os.clock() + math.clamp(startDistance / walkSpeed + 6.0, 6.0, 22.0)
    local bestDistance = startDistance
    local lastProgressAt = os.clock()

    while farmRunning(token) and os.clock() < deadline do
        root = getRoot()
        humanoid = getHumanoid()
        if not root or not humanoid or humanoid.Health <= 0 then
            return false, "Character changed or died during escape-edge movement"
        end

        local currentBoat = getBoat()
        if not currentBoat or currentBoat ~= boat then
            return false, "Boat changed during escape-edge movement"
        end

        local currentDistance = horizontalDistance(root.Position, destination)
        if currentDistance <= 1.0 then
            if isSupportedByBoatDeck(root.Position, boat, standingHeight) then
                humanoid:Move(Vector3.zero, false)
                return true, "Reached the supported escape-edge deck point"
            end
            return false, "Reached the target coordinates but the character is not supported by the boat deck"
        end

        -- Stop if the character is being pushed/falling off the boat rather
        -- than blindly continuing toward an unsupported point.
        if not isSupportedByBoatDeck(root.Position, boat, standingHeight) then
            humanoid:Move(Vector3.zero, false)
            return false, "Movement left the supported boat deck; route will be recalculated"
        end

        if currentDistance < bestDistance - 0.20 then
            bestDistance = currentDistance
            lastProgressAt = os.clock()
        elseif os.clock() - lastProgressAt > 4.0 then
            humanoid:Move(Vector3.zero, false)
            return false, "No progress toward the escape edge; route will be recalculated"
        end

        task.wait(0.08)
    end

    if not farmRunning(token) then
        return false, "Autofarm stopped during escape-edge movement"
    end

    humanoid = getHumanoid()
    root = getRoot()
    if humanoid then humanoid:Move(Vector3.zero, false) end
    if root and isSupportedByBoatDeck(root.Position, boat, standingHeight)
        and horizontalDistance(root.Position, destination) <= 1.5 then
        return true, "Reached the supported escape-edge deck point"
    end
    return false, "Timed out while walking to the escape edge"
end

local function walkToEscapeEdge(token)
    if not waitForLivingCharacter(token) then
        return false, "No living character is available for the escape walk"
    end

    local character = getCharacter()
    local humanoid = getHumanoid()
    local root = getRoot()
    local boat = getBoat()
    if not character or not humanoid or not root or not boat then
        return false, "Character or main boat unavailable"
    end

    local originalWalkSpeed = humanoid.WalkSpeed
    local originalAutoRotate = humanoid.AutoRotate
    local standingHeight = humanoid.HipHeight + root.Size.Y * 0.5 + 0.12
    humanoid.AutoRotate = true
    humanoid.WalkSpeed = math.max(originalWalkSpeed, 16)

    local completed = false
    local lastReason = "Escape edge not resolved"
    local attempt = 0

    -- Keep Autofarm ON and keep trying until the character reaches the deck
    -- point or the user switches Autofarm off. Every goal is recalculated from
    -- the LIVE boat/marker position, and every destination must have deck support.
    while farmRunning(token) and not completed do
        root = getRoot()
        humanoid = getHumanoid()
        boat = getBoat()
        if not root or not humanoid or humanoid.Health <= 0 or not boat then
            if not waitForLivingCharacter(token) then break end
            root = getRoot()
            humanoid = getHumanoid()
            boat = getBoat()
            if not root or not humanoid or not boat then
                task.wait(0.2)
                continue
            end
            standingHeight = humanoid.HipHeight + root.Size.Y * 0.5 + 0.12
        end

        local goal, goalMessage = getLifeboatSprintGoal(root)
        if not goal then
            lastReason = tostring(goalMessage)
            farmStatus = "Finding escape edge: " .. lastReason
            task.wait(0.35)
            continue
        end

        if not isSupportedByBoatDeck(goal, boat, standingHeight) then
            lastReason = "Resolved escape-edge goal is not supported by the current boat deck"
            farmStatus = "Rechecking escape deck position"
            task.wait(0.35)
            continue
        end

        local distance = horizontalDistance(root.Position, goal)
        if distance <= 1.0 and isSupportedByBoatDeck(root.Position, boat, standingHeight) then
            completed = true
            break
        end

        attempt += 1
        farmStatus = string.format("Walking to escape edge (attempt %d)", attempt)
        print(
            "[MOUSE AUTOFARM] Walking to escape edge:",
            tostring(goal),
            "| distance:", string.format("%.1f", distance),
            "| target:", tostring(goalMessage)
        )

        local path = PathfindingService:CreatePath({
            AgentRadius = 1.8,
            AgentHeight = 5.0,
            AgentCanJump = true,
            AgentCanClimb = true,
            WaypointSpacing = 3.0
        })
        local pathOK = pcall(function()
            path:ComputeAsync(root.Position, goal)
        end)

        local pathWorked = false
        if pathOK and path.Status == Enum.PathStatus.Success then
            pathWorked = true
            local waypoints = path:GetWaypoints()
            for _, waypoint in ipairs(waypoints) do
                if not farmRunning(token) then
                    pathWorked = false
                    break
                end

                root = getRoot()
                humanoid = getHumanoid()
                boat = getBoat()
                if not root or not humanoid or not boat or humanoid.Health <= 0 then
                    pathWorked = false
                    break
                end

                -- Verify that each waypoint projects onto the actual boat deck;
                -- reject navmesh shortcuts that would send the player over water.
                local projectedWaypoint = Vector3.new(
                    waypoint.Position.X,
                    root.Position.Y,
                    waypoint.Position.Z
                )
                if not isSupportedByBoatDeck(projectedWaypoint, boat, standingHeight) then
                    pathWorked = false
                    lastReason = "Path waypoint leaves the supported boat deck"
                    break
                end

                if horizontalDistance(root.Position, waypoint.Position) <= 1.0 then
                    continue
                end

                if waypoint.Action == Enum.PathWaypointAction.Jump then
                    humanoid.Jump = true
                end

                local moved, moveMessage = waitForDeckMove(
                    token,
                    waypoint.Position,
                    boat,
                    standingHeight,
                    humanoid
                )
                if not moved then
                    pathWorked = false
                    lastReason = tostring(moveMessage)
                    break
                end
            end
        else
            lastReason = "Pathfinding could not calculate a deck route"
        end

        if pathWorked and farmRunning(token) then
            root = getRoot()
            boat = getBoat()
            if root and boat and isSupportedByBoatDeck(root.Position, boat, standingHeight)
                and horizontalDistance(root.Position, goal) <= 1.5 then
                completed = true
                break
            end
            lastReason = "Path ended before the escape-edge deck point"
        end

        -- Fallback: direct Humanoid movement to the same verified deck point.
        -- The movement watcher cancels if the player loses deck support.
        if farmRunning(token) then
            root = getRoot()
            humanoid = getHumanoid()
            boat = getBoat()
            if root and humanoid and boat and isSupportedByBoatDeck(goal, boat, standingHeight) then
                local moved, moveMessage = waitForDeckMove(
                    token,
                    goal,
                    boat,
                    standingHeight,
                    humanoid
                )
                if moved then
                    completed = true
                    break
                end
                lastReason = tostring(moveMessage)
            end
        end

        farmStatus = "Replanning escape-edge walk: " .. tostring(lastReason)
        task.wait(0.35)
    end

    humanoid = getHumanoid()
    if humanoid and humanoid.Parent then
        humanoid.WalkSpeed = originalWalkSpeed
        humanoid.AutoRotate = originalAutoRotate
        humanoid:Move(Vector3.zero, false)
    end

    if not farmRunning(token) then
        return false, "Autofarm stopped before reaching the escape edge"
    end
    if completed then
        return true, "Player walked onto the supported escape edge; game escape trigger can activate"
    end
    return false, lastReason
end

local function runAutofarm(token)
    print("[MOUSE AUTOFARM] Started.")

    while farmRunning(token) and not getBoat() do
        farmStatus = "Waiting for Boat to load"
        task.wait(0.35)
    end
    if not farmRunning(token) then return end

    -- Key ESP stays on during Autofarm, including after respawn.
    enabled.DroppedKeys = true
    if toggleRender.DroppedKeys then toggleRender.DroppedKeys() end
    scanWorld()
    startMickeySafetyMonitor(token)

    prepareSearchableCompletionCache()

    local targetKeys = getKeysTotal()
    -- Per-prompt run state plus the shared instance cache survive Autofarm
    -- stop/start and character deaths without suppressing sibling prompts.
    local completed = {}
    local failures = {}
    local retryAfter = {}
    local blockedThisRun = {}
    local attempts = 0
    local lastObservedKeys = getKeys()
    local emptyPromptScans = 0
    local lastPrompt = nil
        local MAX_FAILED_PASSES_PER_PROMPT = 4

    while farmRunning(token) do
        if not waitForLivingCharacter(token) then
            return
        end
        if not waitForMickeySafety(token) then
            return
        end

        -- If death dropped keys, the dropped objects are always recovered
        -- before any further searchable is visited, even if Boat.Keys did
        -- not replicate its decrease yet.
        local droppedObjects = getDroppedKeyObjects()
        if #droppedObjects > 0 then
            farmStatus = "Recovering " .. #droppedObjects .. " dropped key(s)"
            print("[MOUSE AUTOFARM] Prioritizing dropped keys:", #droppedObjects)

            local recovered, recoveryMessage = recoverDroppedKeys(token)
            scanWorld()

            if not recovered then
                -- A dropped key can replicate late or its pickup prompt can be
                -- temporarily unavailable. Do not turn Autofarm off at 4/5;
                -- retry recovery and keep the worker alive until the key is
                -- confirmed back in Boat.Keys or the dropped object disappears.
                farmStatus = "Retrying dropped-key recovery: " .. tostring(recoveryMessage)
                warn("[MOUSE AUTOFARM] Dropped-key recovery was not confirmed; staying ON and retrying:", recoveryMessage)
                task.wait(0.45)
                continue
            end

            -- Continue at the top to check for any additional keys spawned
            -- during recovery before searching another container.
            if #getDroppedKeyObjects() > 0 then
                task.wait(0.08)
                continue
            end
        end

        prepareSearchableCompletionCache()

        local currentKeys = getKeys()
        if currentKeys < lastObservedKeys then
            warn(
                "[MOUSE AUTOFARM] Key count decreased. Recovering dropped keys; keeping completed searchable cache."
            )
            -- Do NOT clear completed. A death/drop changes inventory count,
            -- not whether a container has already been searched. Dropped keys
            -- are recovered above before the next searchable is considered.
        end
        lastObservedKeys = currentKeys

        if currentKeys >= targetKeys then
            break
        end

        attempts += 1

        local entry, enabledRemaining, disabledRemaining, coolingRemaining, nextRetryAt, blockedRemaining =
            findRandomSearchable(completed, failures, lastPrompt, retryAfter, blockedThisRun)

        if not entry then
            -- Do not shut Autofarm off merely because the current visible
            -- queue is empty. Prompts can be disabled during server rummaging,
            -- temporarily unparented, or still replicating after a key/drop.
            if (disabledRemaining or 0) > 0 then
                emptyPromptScans = 0
                farmStatus = "No enabled Search prompt; checking disabled cooldown targets ("
                    .. tostring(disabledRemaining) .. ")"
                task.wait(0.25)
                continue
            end

            if (coolingRemaining or 0) > 0 then
                emptyPromptScans = 0
                local waitForRetry = math.max(0.1, (nextRetryAt or os.clock()) - os.clock())
                farmStatus = "Retrying " .. tostring(coolingRemaining)
                    .. " difficult searchable(s)"
                task.wait(math.clamp(waitForRetry, 0.1, 0.75))
                continue
            end

            if (blockedRemaining or 0) > 0 then
                -- This is a safety fallback: normal selection should include
                -- blockedReady prompts once their cooldown expires. Never mark
                -- these remaining prompts complete or terminate at 4/5.
                emptyPromptScans = 0
                farmStatus = "Recycling " .. tostring(blockedRemaining)
                    .. " difficult searchable(s)"
                task.wait(0.35)
                continue
            end

            emptyPromptScans += 1
            local visibleEntries = getSearchEntries()
            local visiblePrompts = #visibleEntries
            local advertisedSearchables = tonumber(
                getBoat() and getBoat():GetAttribute("Searchable")
            ) or 0

            -- A locally confirmed full rummage stays complete for this round.
            -- Do not clear those identities and send the player back through the
            -- same beds/bags just because the key counter is still replicating.
            -- Unconfirmed prompts remain eligible through the retry queue
            -- without any helper-imposed per-prompt delay.

            farmStatus = "Refreshing search list ("
                .. tostring(emptyPromptScans) .. ") | Keys: "
                .. tostring(currentKeys) .. "/" .. tostring(targetKeys)

            -- MOUSE's Boat previously exposed Searchable=36. If the round
            -- still advertises searchable objects and fewer than five keys
            -- have been collected, keep polling rather than falsely ending.
            -- This also allows late-replicating prompts to enter the queue.
            if emptyPromptScans == 1 or emptyPromptScans % 20 == 0 then
                warn(
                    "[MOUSE AUTOFARM] No currently eligible prompt; staying active and rescanning.",
                    "Keys:", currentKeys, "/", targetKeys,
                    "Visible prompts:", visiblePrompts,
                    "Boat.Searchable:", advertisedSearchables
                )
            end

            task.wait(0.5)
            continue
        end

        emptyPromptScans = 0

        local id = entry.Prompt
        local displayId = entry.Model:GetFullName()
        lastPrompt = entry.Prompt

        if isSearchableCompleted(entry.Model, entry.Prompt, completed) then
            completed[id] = true
            task.wait(0.01)
            continue
        end

        farmStatus = "Approaching " .. entry.Model.Name
        print(
            "[MOUSE AUTOFARM] Next searchable:",
            displayId,
            "| Previous failed passes:",
            failures[id] or 0,
            "| Enabled remaining:",
            enabledRemaining
        )

        local success, result = searchOneEntry(entry, failures, token)

        if not farmRunning(token) then return end

        if success and not isSearchableCompleted(entry.Model, entry.Prompt, completed) then
            success = false
            result = "The game's prompt still reports this item as searchable; keeping it queued"
        end

        if success then
            completed[id] = true
            markSearchableCompleted(entry.Model, entry.Prompt)
            failures[id] = nil
            retryAfter[id] = nil
            print("[MOUSE AUTOFARM] Game confirmed this item is no longer searchable:", displayId)
            -- Briefly space out searchable teleports so the server can finish
            -- replicating the completed rummage before the next arrival.
            farmStatus = "Letting server register " .. entry.Model.Name
            task.wait(0.40)
            if not farmRunning(token) then return end
        else
            failures[id] = (failures[id] or 0) + 1
            local failureCount = failures[id]

            -- v42 keeps the helper's own per-item retry backoff removed. This does
            -- not override a private cooldown inside the game's server handler,
            -- but it prevents this LocalScript from adding another delay after
            -- a failed/ignored search interaction.
            retryAfter[id] = 0

            if failureCount >= MAX_FAILED_PASSES_PER_PROMPT then
                blockedThisRun[id] = true
                warn(
                    "[MOUSE AUTOFARM] Difficult prompt remains eligible for immediate retry:",
                    displayId,
                    "| failed passes:", failureCount,
                    "| local retry cooldown: 0s",
                    "| reason:", result
                )
            else
                warn(
                    "[MOUSE AUTOFARM] Search attempt failed ("
                        .. failureCount .. "/" .. MAX_FAILED_PASSES_PER_PROMPT
                        .. "); keeping item eligible immediately:",
                    displayId,
                    "| local retry cooldown: 0s",
                    "| reason:", result
                )
            end

            if isBedSearchEntry(entry.Prompt, entry.Model) then
                -- Do not apply the former 18-24 second group delay to beds.
                for _, otherEntry in ipairs(getSearchEntries()) do
                    if isBedSearchEntry(otherEntry.Prompt, otherEntry.Model) then
                        retryAfter[otherEntry.Prompt] = 0
                    end
                end
                print(
                    "[MOUSE AUTOFARM] Bunk-bed group has no helper-imposed retry cooldown:",
                    displayId
                )
            end
        end

        farmStatus = "Keys: " .. getKeys() .. "/" .. targetKeys
        -- No success delay: the next loop iteration selects and approaches
        -- another searchable immediately after the game marks this one done.
    end

    if not farmRunning(token) then return end

    -- Check for dropped keys one final time before moving to the objectives.
    local finalDrops = getDroppedKeyObjects()
    if #finalDrops > 0 then
        local recovered, message = recoverDroppedKeys(token)
        if not recovered then
            finishFarm(token, message)
            return
        end
    end

    if getKeys() < targetKeys then
        finishFarm(token, "Could not collect all keys")
        return
    end

    print("[MOUSE AUTOFARM] All keys confirmed.")

    -- ENGINE STOPPER PHASE. A death during the interaction invalidates only
    -- that attempt; wait for the new character and retry the same objective.
    local engineOK = false
    local engineMessage = nil
    local engineAttempts = 0
    local lastEngineNotice = 0
    while farmRunning(token) and not engineOK do
        if not waitForLivingCharacter(token) then return end

        local enginePrompt = findEngineStopper()
        if not enginePrompt then
            if engineStopperIsDisabled() then
                engineOK = true
                engineMessage = "Game has disabled the engine-stopper prompt; treating the objective as complete"
            else
                farmStatus = "Waiting for engine stopper prompt"
                if os.clock() - lastEngineNotice >= 5 then
                    warn("[MOUSE AUTOFARM] Engine stopper is not available yet; Autofarm remains ON and will keep checking.")
                    lastEngineNotice = os.clock()
                end
                task.wait(0.35)
            end
        else
            engineAttempts += 1
            farmStatus = string.format("HOLDING ENGINE STOPPER | attempt %d", engineAttempts)
            print("[MOUSE AUTOFARM] Engine stopper hold attempt:", engineAttempts, enginePrompt:GetFullName())
            local attemptOK, attemptMessage = activateObjective(enginePrompt, token)
            if attemptOK then
                engineOK = true
                engineMessage = attemptMessage or "Engine stopper hold accepted"
            elseif engineStopperIsDisabled() or (enginePrompt.Parent and not enginePrompt.Enabled) then
                engineOK = true
                engineMessage = "Game disabled the engine-stopper prompt after the hold"
            else
                local currentHumanoid = getHumanoid()
                local respawnFailure = (not currentHumanoid or currentHumanoid.Health <= 0)
                    or isRespawnRelatedFailure(attemptMessage)
                if respawnFailure then
                    farmStatus = "Waiting for respawn before retrying engine stopper hold"
                    if not waitForLivingCharacter(token) then return end
                else
                    farmStatus = "Engine hold not confirmed - retrying | " .. tostring(attemptMessage)
                    warn("[MOUSE AUTOFARM] Engine stopper hold was not confirmed; keeping Autofarm ON and retrying:", tostring(attemptMessage))
                end
                task.wait(0.65)
            end
        end
    end

    if not farmRunning(token) then return end
    print("[MOUSE AUTOFARM] Engine stopper activated. Scanning for padlock prompts now.")
    task.wait(0.25)
    if not farmRunning(token) then return end

    -- PADLOCK PHASE: keep Autofarm ON until all five are unlocked.
    farmStatus = "Finding padlocks"
    local padlocksOK, padlockMessage, padlockStayCFrame = unlockAllPadlocks(token)

    if not padlocksOK then
        if farmRunning(token) then
            finishFarm(token, "Padlock phase stopped: " .. tostring(padlockMessage))
        end
        return
    end

    if not farmRunning(token) then return end
    if not waitForLivingCharacter(token) then return end

    -- Keep the character at the final successful deck position inside the
    -- padlock area. The boat-lowering hold happens from this exact position.
    local padlockRoot = getRoot()
    local padlockCharacter = getCharacter()
    if padlockStayCFrame and padlockRoot and padlockCharacter
        and (padlockRoot.Position - padlockStayCFrame.Position).Magnitude > 1.5 then
        padlockCharacter:PivotTo(padlockStayCFrame)
        padlockRoot.AssemblyLinearVelocity = Vector3.zero
        padlockRoot.AssemblyAngularVelocity = Vector3.zero
        task.wait(0.18)
    end

    -- The lowering interaction is the existing 15-second lever prompt. Do not
    -- teleport to it: remain sheltered at the padlock position as requested.
    farmStatus = "Finding boat-lowering prompt"
    local lever = findLever()

    while farmRunning(token) and not lever do
        farmStatus = "Waiting for boat-lowering prompt"
        task.wait(0.4)
        lever = findLever()
    end

    if not farmRunning(token) then return end

    if not lever:IsA("ProximityPrompt") then
        local embeddedPrompt = lever:FindFirstChildWhichIsA("ProximityPrompt", true)
        if embeddedPrompt then
            lever = embeddedPrompt
        else
            finishFarm(token, "Boat-lowering prompt found without a ProximityPrompt")
            return
        end
    end

    local boat = getBoat()

    local leverOK = false
    local leverMessage = nil
    local leverActionStartedAt = nil
    local leverHoldFinishedAt = nil
    local leverTriggeredAt = nil

    while farmRunning(token) and not leverOK do
        if not waitForLivingCharacter(token) then return end

        local refreshedLever = findLever()
        if refreshedLever then
            lever = refreshedLever
        elseif not lever or not lever.Parent then
            farmStatus = "Waiting for boat-lowering prompt after respawn"
            task.wait(0.25)
            continue
        end

        if not lever:IsA("ProximityPrompt") then
            local embeddedPrompt = lever:FindFirstChildWhichIsA("ProximityPrompt", true)
            if embeddedPrompt then
                lever = embeddedPrompt
            else
                farmStatus = "Waiting for boat-lowering prompt after respawn"
                task.wait(0.25)
                continue
            end
        end

        -- If the previous character died after unlocking the padlocks, put the
        -- replacement character back at the same sheltered padlock position.
        if padlockStayCFrame then
            local liveCharacter = getCharacter()
            local liveRoot = getRoot()
            if liveCharacter and liveRoot
                and (liveRoot.Position - padlockStayCFrame.Position).Magnitude > 1.5 then
                pcall(function()
                    liveCharacter:PivotTo(padlockStayCFrame)
                    liveRoot.AssemblyLinearVelocity = Vector3.zero
                    liveRoot.AssemblyAngularVelocity = Vector3.zero
                end)
                task.wait(0.18)
            end
        end

        farmStatus = "HOLDING FINAL LEVER: 0.0/15.0s"
        leverOK, leverMessage, leverActionStartedAt, leverHoldFinishedAt, leverTriggeredAt =
            holdLeverFor15Seconds(lever, token)

        if not leverOK then
            local currentHumanoid = getHumanoid()
            local respawnFailure = (not currentHumanoid or currentHumanoid.Health <= 0)
                or isRespawnRelatedFailure(leverMessage)
            if respawnFailure then
                farmStatus = "Waiting for respawn before retrying the 15-second lever"
                if not waitForLivingCharacter(token) then return end
                task.wait(0.15)
            else
                finishFarm(token, "Boat-lowering hold failed: " .. tostring(leverMessage))
                return
            end
        end
    end

    if not farmRunning(token) then return end
    print("[MOUSE AUTOFARM]", leverMessage)

    -- Keep the Autofarm task alive after the lever. Wait for the complete
    -- cutscene, then use ordinary Humanoid pathfinding to WALK across the deck
    -- to the LIFEBOAT-facing escape edge. This avoids a client teleport that
    -- the server may correct and avoids switching Autofarm off at the lever.
    local cutsceneOK, cutsceneMessage = waitForBoatDropCutscene(
        token,
        leverActionStartedAt,
        leverHoldFinishedAt,
        leverTriggeredAt
    )
    if not cutsceneOK or not farmRunning(token) then
        return
    end
    print("[MOUSE AUTOFARM]", cutsceneMessage)

    restoreCameraToCurrentCharacter()
    task.wait(0.18)
    restoreCameraToCurrentCharacter()
    if not farmRunning(token) then return end

    local escapeOK, escapeMessage = walkToEscapeEdge(token)
    if not farmRunning(token) then return end

    if escapeOK then
        farmStatus = "ESCAPE EDGE REACHED - waiting for game escape"
        updateAutofarmButton()
        print("[MOUSE AUTOFARM]", escapeMessage)
        print("[MOUSE AUTOFARM] Autofarm remains ON at the escape edge until you switch it off or the game changes rounds.")
    else
        farmStatus = "Escape-edge walk needs attention - Autofarm remains ON: " .. tostring(escapeMessage)
        updateAutofarmButton()
        warn("[MOUSE AUTOFARM]", escapeMessage)
    end
end

startAutofarm = function()
    if enabled.Autofarm then return end

    farmToken = farmToken + 1
    local token = farmToken
    enabled.Autofarm = true
    enabled.DroppedKeys = true
    farmStatus = "Starting"
    if toggleRender.DroppedKeys then toggleRender.DroppedKeys() end
    updateAutofarmButton()

    task.spawn(function()
        local workerRestartCount = 0
        while farmRunning(token) do
            local ok, err = xpcall(function()
                runAutofarm(token)
            end, debug.traceback)

            if not farmRunning(token) then
                break
            end

            -- Five keys are only the transition into the engine/padlock/lever
            -- objectives. Keep the worker alive and restart that phase until
            -- the escape edge is reached.
            local reachedEscape = tostring(farmStatus):find("ESCAPE EDGE REACHED", 1, true) ~= nil
            if getKeys() >= getKeysTotal() and reachedEscape then
                if not ok then
                    warn("[MOUSE AUTOFARM ERROR after escape edge]", err)
                end
                break
            end

            workerRestartCount += 1
            if not ok then
                warn("[MOUSE AUTOFARM ERROR - AUTO RECOVERY]", err)
            else
                warn("[MOUSE AUTOFARM] Search worker returned before collecting all keys; restarting the searchable scan.")
            end

            farmStatus = "Recovering search worker " .. tostring(workerRestartCount)
                .. " | Keys: " .. tostring(getKeys()) .. "/" .. tostring(getKeysTotal())
            updateAutofarmButton()
            task.wait(math.min(0.35 + workerRestartCount * 0.10, 1.5))
        end
    end)
end

stopAutofarm = function()
    farmToken = farmToken + 1
    enabled.Autofarm = false
    farmStatus = "Stopped by user"
    updateAutofarmButton()
end

--============================================================
-- NOCLIP
--============================================================

local function restoreCollision()
    for part, originalValue in pairs(originalCollision) do
        if part and part.Parent then
            pcall(function()
                part.CanCollide = originalValue
            end)
        end
        originalCollision[part] = nil
    end
end

RunService.Stepped:Connect(function()
    if not enabled.Noclip then return end

    local character = getCharacter()
    if not character then return end

    for _, obj in ipairs(character:GetDescendants()) do
        if obj:IsA("BasePart") then
            if originalCollision[obj] == nil then
                originalCollision[obj] = obj.CanCollide
            end
            obj.CanCollide = false
        end
    end
end)

--============================================================
-- FULLBRIGHT
--============================================================

local function applyFullbright()
    Lighting.Brightness = 3
    Lighting.ClockTime = 14
    Lighting.FogStart = 0
    Lighting.FogEnd = 1000000
    Lighting.GlobalShadows = false
    Lighting.Ambient = Color3.new(1, 1, 1)
    Lighting.OutdoorAmbient = Color3.new(1, 1, 1)
    Lighting.ExposureCompensation = 0.25
end

local function restoreLighting()
    for property, value in pairs(originalLighting) do
        pcall(function()
            Lighting[property] = value
        end)
    end
end

--============================================================
-- GUI
--============================================================

gui = Instance.new("ScreenGui")
gui.Name = "MOUSE_HELPER"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 100
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Enabled = false
gui.Parent = playerGui

-- A modal button keeps the cursor unlocked, while ZIndex keeps it behind
-- the panel so the panel itself remains clickable and draggable.
modalButton = Instance.new("TextButton")
modalButton.Name = "MouseUnlock"
modalButton.Size = UDim2.fromScale(1, 1)
modalButton.Position = UDim2.fromScale(0, 0)
modalButton.BackgroundTransparency = 1
modalButton.Text = ""
modalButton.TextTransparency = 1
modalButton.AutoButtonColor = false
modalButton.Active = false
modalButton.Modal = true
modalButton.Visible = true
modalButton.ZIndex = 0
modalButton.Parent = gui

local panel = Instance.new("Frame")
panel.Name = "MainPanel"
panel.Size = UDim2.fromOffset(340, 525)
panel.Position = UDim2.new(0, 25, 0.5, -262)
panel.BackgroundColor3 = Color3.fromRGB(19, 22, 30)
panel.BorderSizePixel = 0
panel.Active = true
panel.ZIndex = 2
panel.Parent = gui

local function addCorner(object, radius)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, radius)
    corner.Parent = object
end

addCorner(panel, 12)

local panelStroke = Instance.new("UIStroke")
panelStroke.Color = Color3.fromRGB(65, 76, 96)
panelStroke.Thickness = 1.3
panelStroke.Parent = panel

local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 49)
header.BackgroundColor3 = Color3.fromRGB(26, 31, 42)
header.BorderSizePixel = 0
header.Active = true
header.ZIndex = 3
header.Parent = panel
addCorner(header, 12)

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(14, 6)
title.Size = UDim2.new(1, -60, 0, 23)
title.Font = Enum.Font.GothamBold
title.Text = "Made by klavier"
title.TextSize = 16
title.TextColor3 = Color3.fromRGB(240, 244, 255)
title.TextXAlignment = Enum.TextXAlignment.Left
title.ZIndex = 4
title.Parent = header

local subtitle = Instance.new("TextLabel")
subtitle.BackgroundTransparency = 1
subtitle.Position = UDim2.fromOffset(15, 28)
subtitle.Size = UDim2.new(1, -60, 0, 14)
subtitle.Font = Enum.Font.Gotham
subtitle.Text = "HORROR GAME HELPER"
subtitle.TextSize = 9
subtitle.TextColor3 = Color3.fromRGB(135, 149, 171)
subtitle.TextXAlignment = Enum.TextXAlignment.Left
subtitle.ZIndex = 4
subtitle.Parent = header

local close = Instance.new("TextButton")
close.Size = UDim2.fromOffset(30, 30)
close.Position = UDim2.new(1, -40, 0, 9)
close.BackgroundColor3 = Color3.fromRGB(55, 61, 76)
close.Text = "×"
close.TextSize = 22
close.Font = Enum.Font.Gotham
close.TextColor3 = Color3.new(1, 1, 1)
close.ZIndex = 5
close.Parent = header
addCorner(close, 7)

-- Reliable drag handling: sample mouse movement while the header is held.
local dragging = false
local dragStart = nil
local startPosition = nil

header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        -- InputObject.Position is Vector3; GetMouseLocation() is Vector2.
        -- Store matching 2D values before subtracting them in RenderStepped.
        dragStart = Vector2.new(input.Position.X, input.Position.Y)
        startPosition = panel.Position
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)

RunService.RenderStepped:Connect(function()
    if dragging and dragStart and startPosition and gui.Enabled then
        local current = UserInputService:GetMouseLocation()
        local delta = current - dragStart

        panel.Position = UDim2.new(
            startPosition.X.Scale,
            startPosition.X.Offset + delta.X,
            startPosition.Y.Scale,
            startPosition.Y.Offset + delta.Y
        )
    end
end)

-- TABS
local tabs = Instance.new("Frame")
tabs.BackgroundTransparency = 1
tabs.Position = UDim2.fromOffset(12, 57)
tabs.Size = UDim2.new(1, -24, 0, 32)
tabs.ZIndex = 3
tabs.Parent = panel

local mainTab = Instance.new("TextButton")
mainTab.Size = UDim2.new(0.5, -4, 1, 0)
mainTab.BackgroundColor3 = Color3.fromRGB(56, 91, 130)
mainTab.Text = "MAIN"
mainTab.Font = Enum.Font.GothamBold
mainTab.TextSize = 12
mainTab.TextColor3 = Color3.new(1, 1, 1)
mainTab.ZIndex = 4
mainTab.Parent = tabs
addCorner(mainTab, 7)

local settingsTab = Instance.new("TextButton")
settingsTab.Size = UDim2.new(0.5, -4, 1, 0)
settingsTab.Position = UDim2.new(0.5, 4, 0, 0)
settingsTab.BackgroundColor3 = Color3.fromRGB(35, 40, 53)
settingsTab.Text = "SETTINGS"
settingsTab.Font = Enum.Font.GothamBold
settingsTab.TextSize = 12
settingsTab.TextColor3 = Color3.fromRGB(165, 177, 195)
settingsTab.ZIndex = 4
settingsTab.Parent = tabs
addCorner(settingsTab, 7)

local mainPage = Instance.new("Frame")
mainPage.BackgroundTransparency = 1
mainPage.Position = UDim2.fromOffset(12, 100)
mainPage.Size = UDim2.new(1, -24, 0, 350)
mainPage.ZIndex = 3
mainPage.Parent = panel

local settingsPage = Instance.new("Frame")
settingsPage.BackgroundTransparency = 1
settingsPage.Position = mainPage.Position
settingsPage.Size = mainPage.Size
settingsPage.Visible = false
settingsPage.ZIndex = 3
settingsPage.Parent = panel

local function addLayout(parent)
    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 8)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = parent
end

addLayout(mainPage)
addLayout(settingsPage)

local function createToggle(parent, label, key, order)
    local button = Instance.new("TextButton")
    button.Name = key .. "Toggle"
    button.Size = UDim2.new(1, 0, 0, 43)
    button.LayoutOrder = order
    button.BackgroundColor3 = Color3.fromRGB(34, 39, 52)
    button.BorderSizePixel = 0
    button.Text = ""
    button.AutoButtonColor = false
    button.ZIndex = 4
    button.Parent = parent
    addCorner(button, 8)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(61, 70, 88)
    stroke.Parent = button

    local nameLabel = Instance.new("TextLabel")
    nameLabel.BackgroundTransparency = 1
    nameLabel.Position = UDim2.fromOffset(13, 0)
    nameLabel.Size = UDim2.new(1, -90, 1, 0)
    nameLabel.Font = Enum.Font.GothamSemibold
    nameLabel.Text = label
    nameLabel.TextSize = 13
    nameLabel.TextColor3 = Color3.fromRGB(235, 240, 250)
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.ZIndex = 5
    nameLabel.Parent = button

    local stateLabel = Instance.new("TextLabel")
    stateLabel.Name = "State"
    stateLabel.BackgroundTransparency = 1
    stateLabel.Position = UDim2.new(1, -68, 0, 0)
    stateLabel.Size = UDim2.fromOffset(55, 43)
    stateLabel.Font = Enum.Font.GothamBold
    stateLabel.TextSize = 11
    stateLabel.TextXAlignment = Enum.TextXAlignment.Right
    stateLabel.ZIndex = 5
    stateLabel.Parent = button

    local function render()
        local active = enabled[key]
        stateLabel.Text = active and "ON" or "OFF"
        stateLabel.TextColor3 = active
            and Color3.fromRGB(100, 255, 160)
            or Color3.fromRGB(145, 153, 168)
        button.BackgroundColor3 = active
            and Color3.fromRGB(34, 65, 57)
            or Color3.fromRGB(34, 39, 52)
        stroke.Color = active
            and Color3.fromRGB(55, 135, 100)
            or Color3.fromRGB(61, 70, 88)
    end

    toggleRender[key] = render

    button.MouseButton1Click:Connect(function()
        if key == "Autofarm" then
            if enabled.Autofarm then
                stopAutofarm()
            else
                startAutofarm()
            end
        else
            enabled[key] = not enabled[key]

            if key == "Noclip" and not enabled.Noclip then
                restoreCollision()
            elseif key == "Fullbright" then
                if enabled.Fullbright then
                    applyFullbright()
                else
                    restoreLighting()
                end
            end

            render()
            scanWorld()
        end
    end)

    render()
end

createToggle(mainPage, "Mickey ESP", "Mickey", 1)
createToggle(mainPage, "Searchables ESP", "Searchables", 2)
createToggle(mainPage, "Dropped Key ESP", "DroppedKeys", 3)
createToggle(mainPage, "Autofarm", "Autofarm", 4)

local mainInfo = Instance.new("TextLabel")
mainInfo.BackgroundTransparency = 1
mainInfo.Size = UDim2.new(1, 0, 0, 62)
mainInfo.LayoutOrder = 5
mainInfo.Font = Enum.Font.Gotham
mainInfo.Text = "Mickey: red | Searchables: cyan | Dropped keys: gold\nAutofarm searches all 5 keys, unlocks padlocks, lowers the boat, then sprints toward it."
mainInfo.TextSize = 11
mainInfo.TextColor3 = Color3.fromRGB(157, 171, 191)
mainInfo.TextWrapped = true
mainInfo.TextXAlignment = Enum.TextXAlignment.Left
mainInfo.ZIndex = 4
mainInfo.Parent = mainPage

createToggle(settingsPage, "Noclip", "Noclip", 1)
createToggle(settingsPage, "Fullbright", "Fullbright", 2)

local settingsInfo = Instance.new("TextLabel")
settingsInfo.BackgroundTransparency = 1
settingsInfo.Size = UDim2.new(1, 0, 0, 115)
settingsInfo.LayoutOrder = 3
settingsInfo.Font = Enum.Font.Gotham
settingsInfo.Text = "RightShift: hide/show GUI.\n\nCursor is visible and movable while open.\nOriginal mouse settings return when closed.\n\nDrag the top bar to move the panel."
settingsInfo.TextSize = 11
settingsInfo.TextColor3 = Color3.fromRGB(157, 171, 191)
settingsInfo.TextWrapped = true
settingsInfo.TextXAlignment = Enum.TextXAlignment.Left
settingsInfo.TextYAlignment = Enum.TextYAlignment.Top
settingsInfo.ZIndex = 4
settingsInfo.Parent = settingsPage

local function showTab(name)
    local isMain = name == "Main"
    mainPage.Visible = isMain
    settingsPage.Visible = not isMain

    mainTab.BackgroundColor3 = isMain
        and Color3.fromRGB(56, 91, 130)
        or Color3.fromRGB(35, 40, 53)

    settingsTab.BackgroundColor3 = not isMain
        and Color3.fromRGB(56, 91, 130)
        or Color3.fromRGB(35, 40, 53)

    mainTab.TextColor3 = isMain
        and Color3.new(1, 1, 1)
        or Color3.fromRGB(165, 177, 195)

    settingsTab.TextColor3 = not isMain
        and Color3.new(1, 1, 1)
        or Color3.fromRGB(165, 177, 195)
end

mainTab.MouseButton1Click:Connect(function()
    showTab("Main")
end)

settingsTab.MouseButton1Click:Connect(function()
    showTab("Settings")
end)

-- FOOTER
local footer = Instance.new("Frame")
footer.Position = UDim2.new(0, 12, 1, -53)
footer.Size = UDim2.new(1, -24, 0, 42)
footer.BackgroundColor3 = Color3.fromRGB(26, 31, 42)
footer.BorderSizePixel = 0
footer.ZIndex = 3
footer.Parent = panel
addCorner(footer, 7)

local metrics = Instance.new("TextLabel")
metrics.BackgroundTransparency = 1
metrics.Position = UDim2.fromOffset(9, 3)
metrics.Size = UDim2.new(1, -18, 0, 17)
metrics.Font = Enum.Font.GothamSemibold
metrics.TextSize = 10
metrics.TextColor3 = Color3.fromRGB(220, 230, 243)
metrics.TextXAlignment = Enum.TextXAlignment.Left
metrics.ZIndex = 4
metrics.Parent = footer

local status = Instance.new("TextLabel")
status.BackgroundTransparency = 1
status.Position = UDim2.fromOffset(9, 20)
status.Size = UDim2.new(1, -18, 0, 16)
status.Font = Enum.Font.Gotham
status.TextSize = 9
status.TextColor3 = Color3.fromRGB(145, 164, 187)
status.TextXAlignment = Enum.TextXAlignment.Left
status.ZIndex = 4
status.Parent = footer

--============================================================
-- GUI OPEN / CLOSE
--============================================================

close.MouseButton1Click:Connect(function()
    setGuiOpen(false)
end)

UserInputService.InputBegan:Connect(function(input, processed)
    if input.KeyCode == Enum.KeyCode.RightShift then
        setGuiOpen(not gui.Enabled)
    end
end)

--============================================================
-- STATUS UPDATES
--============================================================

local function updateStatus()
    metrics.Text = string.format(
        "M:%d | S:%d | Key ESP:%s | Keys:%d/%d | Dropped:%d",
        counts.Mickey,
        counts.Searchables,
        enabled.DroppedKeys and "ON" or "OFF",
        getKeys(),
        getKeysTotal(),
        counts.DroppedKeys
    )

    status.Text = "Autofarm: " .. farmStatus
end

task.spawn(function()
    while gui.Parent do
        scanWorld()
        updateStatus()
        task.wait(0.8)
    end
end)

task.spawn(function()
    while gui.Parent do
        if enabled.Fullbright then
            applyFullbright()
        end
        task.wait(1)
    end
end)

-- Invalidate temporary camera locks as soon as the old character is removed.
player.CharacterRemoving:Connect(function()
    cameraControlGeneration += 1
    local camera = workspace.CurrentCamera
    if camera then
        camera.CameraType = Enum.CameraType.Custom
    end
end)

-- Keep dropped-key highlighting alive and rebind the camera to the new live
-- Humanoid after every respawn, rather than leaving it at the death location.
player.CharacterAdded:Connect(function(character)
    enabled.DroppedKeys = true
    if toggleRender.DroppedKeys then toggleRender.DroppedKeys() end

    task.spawn(function()
        local humanoid = character:WaitForChild("Humanoid", 10)
        character:WaitForChild("HumanoidRootPart", 10)
        if character == player.Character and humanoid and humanoid.Health > 0 then
            restoreCameraToCurrentCharacter()
        end
    end)

    task.delay(0.25, function()
        if gui and gui.Parent then
            scanWorld()
            updateStatus()
        end
    end)
end)

--============================================================
-- STARTUP
--============================================================

showTab("Main")
scanWorld()
updateStatus()
setGuiOpen(true)

print("========================================")
print("[MOUSE] HELPER v49 KEY RETRY RECOVERY FIX LOADED SUCCESSFULLY")
print("[MOUSE] Mickey ESP: ON")
print("[MOUSE] Searchables ESP: ON")
print("[MOUSE] Dropped Key ESP: ON")
print("[MOUSE] Search item travel: TweenService full-character movement to the selected prompt-local item centre/top; geometry falls back to the exact prompt anchor on the same deck; server nudges are accepted only inside the selected item zone and prompt range.")
print("[MOUSE] Search lock/tap: body and camera face the selected prompt continuously; first E tap occurs immediately on arrival, then repeats every 0.25 seconds until terminal completion. Non-search objective timing is unchanged.")
print("[MOUSE] Autofarm: AUTO-START ON")
print("[MOUSE] Noclip: ON")
print("[MOUSE] Fullbright: ON")
print("[MOUSE] Search order is randomized. The complete character tweens only to the selected random item; neighbouring prompts are never triggered during travel. After arrival it waits 1.5 seconds, then taps E using the existing retry timing.")
print("[MOUSE] Autofarm survives character death/respawn, retries interrupted objectives, and keeps retrying dropped-key recovery instead of shutting down while keys are missing.")
print("[MOUSE] Mickey LOS pausing/evasion disabled; Mickey ESP remains enabled and Autofarm does not wait for visibility checks.")
print("[MOUSE] After the 15-second lever and cutscene, Autofarm pathfinds/walks to a supported LIFEBOAT-facing escape-edge deck point and stays ON at arrival.")
print("[MOUSE] Search completion requires an explicit terminal game state. Disabled prompts are treated as possible server cooldowns while keys remain missing, revisited by the random queue, and retried after re-enabling.")
print("[MOUSE] Only the selected random item is searched. No neighbouring item is triggered en route; disabled prompts remain fallback targets while keys are missing, so the character continues moving and retries them after cooldown.")
print("[MOUSE] Wall-aware validation is preserved; one level-locked item-centre target is validated once and reused by the final tween, preventing a second model-bounds lookup from switching decks.")
print("[MOUSE] After engine activation: approaches the inside of the padlocks, holds the final lever E for a full local 15 seconds, waits for the cutscene, then walks to the supported LIFEBOAT-facing escape edge. Autofarm remains ON at arrival.")
print("[MOUSE] A server-side companion Script is required to set the final lever prompt HoldDuration to 15 seconds on the server; see MOUSE_Lever15_Server.server.lua.")
print("[MOUSE] Searchable teleports reject small raised prop tops; Mickey visibility checks do not interrupt Autofarm.")
print("[MOUSE] Camera lock is released safely on death/respawn; camera is rebound after the escape cutscene ends.")
print("[MOUSE] Queue recovery fix: stale completion is cleared only after a real disabled-to-enabled transition; when enabled items are exhausted, disabled non-terminal prompts become fallback destinations and are retried after cooldown.")
print("[MOUSE] A Search prompt disabled continuously for 2.50 seconds is treated as searched; if it re-enables sooner, its inferred completion is cleared and it returns to the queue.")
print("[MOUSE] Engine stopper: physically holds E for at least 1.5 seconds or the prompt longer configured duration; retries while Autofarm remains ON.")
print("[MOUSE] Startup defaults: Fullbright ON, Noclip ON, Autofarm auto-start ON.")
print("[MOUSE] Search worker watchdog: unexpected exit/error before all keys triggers automatic scan restart; Autofarm button remains ON.")
print("[MOUSE] Server companion required: MOUSE_Lever15_Server.server.lua in ServerScriptService (own place only).")
local instantSearchReady = ReplicatedStorage:FindFirstChild("MOUSE_InstantSearchReady")
if instantSearchReady and instantSearchReady:IsA("BoolValue") and instantSearchReady.Value then
    print("[MOUSE] Server companion confirmed: every Boat Search prompt is configured for instant activation.")
else
    warn("[MOUSE] Instant-search server companion not detected. Client-side zero HoldDuration alone cannot change server-owned prompt timing. Install MOUSE_Lever15_Server_v36.server.lua in ServerScriptService of a place you control.")
end
print("[MOUSE] ProximityPromptService connected:", ProximityPromptService ~= nil)
print("[MOUSE] RightShift hides/shows GUI.")
print("========================================")

-- Apply requested defaults immediately after GUI and character hooks exist.
if enabled.Fullbright then
    applyFullbright()
end
if enabled.Noclip and getCharacter() then
    for _, part in ipairs(getCharacter():GetDescendants()) do
        if part:IsA("BasePart") then
            if originalCollision[part] == nil then
                originalCollision[part] = part.CanCollide
            end
            part.CanCollide = false
        end
    end
end
if not enabled.Autofarm then
    startAutofarm()
end

--============================================================
-- PLAY AGAIN: AUTOMATICALLY CLICK THE LEFT-HAND YES BUTTON
--============================================================
-- The user's Explorer inspection confirmed this ScreenGui path:
-- PlayerGui.PlayAgain. Its two TextButtons are laid out YES (left), LOBBY (right).
-- Use Roblox's supported VirtualInput API so the game's existing button input
-- handlers receive a normal mouse press/release. Do not invoke a made-up event.

task.spawn(function()
    local function isGuiBranchVisible(object, screenGui)
        if not screenGui or not screenGui.Parent or not screenGui.Enabled then
            return false
        end

        local current = object
        while current and current ~= screenGui do
            if current:IsA("GuiObject") and not current.Visible then
                return false
            end
            current = current.Parent
        end

        return current == screenGui
    end

    local function findYesButton(screenGui)
        local explicitYes = {}
        local leftToRight = {}

        for _, object in ipairs(screenGui:GetDescendants()) do
            if object:IsA("TextButton") or object:IsA("ImageButton") then
                if isGuiBranchVisible(object, screenGui)
                    and object.AbsoluteSize.X > 4
                    and object.AbsoluteSize.Y > 4 then

                    local textValue = ""
                    if object:IsA("TextButton") then
                        textValue = tostring(object.Text or ""):lower()
                    end
                    local objectName = tostring(object.Name or ""):lower()

                    if textValue:match("^%s*yes%s*$")
                        or objectName:match("^%s*yes%s*$") then
                        table.insert(explicitYes, object)
                    else
                        table.insert(leftToRight, object)
                    end
                end
            end
        end

        local candidates = #explicitYes > 0 and explicitYes or leftToRight
        table.sort(candidates, function(a, b)
            if math.abs(a.AbsolutePosition.X - b.AbsolutePosition.X) < 1 then
                return a.AbsolutePosition.Y < b.AbsolutePosition.Y
            end
            return a.AbsolutePosition.X < b.AbsolutePosition.X
        end)

        -- In this PlayAgain layout, YES is the left-hand TextButton.
        return candidates[1]
    end

    local handledScreens = setmetatable({}, {__mode = "k"})
    local virtualInput = nil
    local virtualInputChecked = false
    local retryAt = 0

    while script.Parent do
        local screenGui = playerGui:FindFirstChild("PlayAgain")
        if screenGui and screenGui:IsA("ScreenGui") then
            local yesButton = screenGui.Enabled and findYesButton(screenGui) or nil

            -- A hidden/reused replay GUI represents a later round; allow one
            -- fresh YES click when it becomes visible again.
            if not screenGui.Enabled or not yesButton then
                handledScreens[screenGui] = nil
                retryAt = 0
            end

            if screenGui.Enabled and yesButton and not handledScreens[screenGui]
                and os.clock() >= retryAt then
                if not virtualInputChecked then
                    virtualInputChecked = true
                    local ok, result = pcall(function()
                        return UserInputService:CreateVirtualInput()
                    end)
                    if ok then
                        virtualInput = result
                    else
                        warn("[MOUSE] Could not create VirtualInput for PlayAgain YES:", result)
                    end
                end

                if virtualInput then
                    local clickPosition = yesButton.AbsolutePosition
                        + (yesButton.AbsoluteSize * 0.5)

                    -- Mark before injecting input to prevent duplicate clicks if
                    -- the GUI remains visible during its replay countdown.
                    handledScreens[screenGui] = true

                    local moved, moveError = pcall(function()
                        virtualInput:SendMousePosition(clickPosition)
                    end)

                    if moved then
                        task.wait(0.08)
                        local pressed, pressError = pcall(function()
                            virtualInput:SendMouseButton(
                                clickPosition,
                                Enum.UserInputType.MouseButton1,
                                true,
                                0
                            )
                        end)

                        if pressed then
                            task.wait(0.09)
                            local released, releaseError = pcall(function()
                                virtualInput:SendMouseButton(
                                    clickPosition,
                                    Enum.UserInputType.MouseButton1,
                                    false,
                                    0
                                )
                            end)

                            if released then
                                print("[MOUSE] Automatically clicked PlayAgain YES.")
                            else
                                warn("[MOUSE] YES click release failed:", releaseError)
                            end
                        else
                            -- Ensure a partially-started mouse press is not left held.
                            pcall(function()
                                virtualInput:SendMouseButton(
                                    clickPosition,
                                    Enum.UserInputType.MouseButton1,
                                    false,
                                    0
                                )
                            end)
                            warn("[MOUSE] YES click press failed:", pressError)
                            handledScreens[screenGui] = nil
                            retryAt = os.clock() + 1.0
                        end
                    else
                        warn("[MOUSE] Could not move pointer to PlayAgain YES:", moveError)
                        handledScreens[screenGui] = nil
                        retryAt = os.clock() + 1.0
                    end
                else
                    warn("[MOUSE] PlayAgain YES was found, but VirtualInput is unavailable on this client.")
                    handledScreens[screenGui] = true
                end
            end
        end

        task.wait(0.15)
    end
end)

