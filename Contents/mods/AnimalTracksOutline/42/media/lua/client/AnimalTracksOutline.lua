-- Animal Tracks Outline (single player)
-- Outline for animals when Search Mode + focus "Animal Tracks"
require "Foraging/ISSearchManager"
require "Foraging/ISSearchWindow"

local lastHighlightedAnimals = {}
local RADIUS = 50
local PLAYER_NUM = 0

-- Corpses do not move, so rescanning them every frame is wasted work: the scan walks
-- (2*RADIUS+1)^2 squares, i.e. over 10k getGridSquare calls. Doing it on an interval is
-- indistinguishable in game and costs a small fraction of the frames it used to.
local CORPSE_SCAN_INTERVAL_MS = 500
local lastCorpseScanMs = 0
local lastCorpseSet = {}

-- A living animal that leaves the vision cone keeps being rendered for roughly a second
-- and is then dropped from the render pass outright, taking its outline with it. That
-- reads as a hard pop rather than a disappearance. The engine's own render alpha lives on
-- ObjectRenderInfo, which is not in the Lua exposer, so we cannot follow it; instead we
-- fade our own outline alpha to zero inside that window, comfortably before the cull.
-- Tuned by eye against that window: shorter reads as an abrupt snap, longer risks the
-- fade still running when the engine culls the object, which brings the pop back.
local FADE_MS = 1000
local lastSeenMs = {}  -- animal -> timestamp when its square was last visible

-- Corpses deliberately do not fade: they sit on remembered squares, stay rendered, and
-- being able to spot a carcass through tree crowns is the point of the mod.

-- Report each distinct error once instead of once per frame, so an engine change shows up
-- in console.txt without burying the log or costing frames.
local reportedErrors = {}
local function reportError(err)
	local msg = tostring(err)
	if reportedErrors[msg] then return end
	reportedErrors[msg] = true
	print("[AnimalTracksOutline] ERROR: " .. msg)
end

local function clearHighlights()
	for animal, _ in pairs(lastHighlightedAnimals) do
		if animal then
			pcall(function() animal:setOutlineHighlight(PLAYER_NUM, false) end)
		end
	end
	lastHighlightedAnimals = {}
	lastCorpseSet = {}
	lastSeenMs = {}
	lastCorpseScanMs = 0  -- rescan immediately when search mode comes back on
end

local function getObjSquare(obj)
	if obj.getCurrentSquare then return obj:getCurrentSquare() end
	if obj.getSquare then return obj:getSquare() end
	return nil
end

-- Animal corpses are static moving objects on the square, not entries in the cell object
-- list, so they need their own sweep.
local function scanCorpses(plX, plY, plZ)
	local found = {}
	local cell = getCell()
	if not cell then return found end
	local x0, y0, z0 = math.floor(plX), math.floor(plY), math.floor(plZ)
	for x = x0 - RADIUS, x0 + RADIUS do
		for y = y0 - RADIUS, y0 + RADIUS do
			local dx, dy = x - x0, y - y0
			if dx * dx + dy * dy <= RADIUS * RADIUS then
				local sq = cell:getGridSquare(x, y, z0)
				local objs = sq and sq:getStaticMovingObjects()
				if objs then
					for j = 0, objs:size() - 1 do
						local obj = objs:get(j)
						if instanceof(obj, "IsoDeadBody") and obj:isAnimal() then
							found[obj] = true
						end
					end
				end
			end
		end
	end
	return found
end

local function updateAnimalOutline()
	local ok, err = pcall(function()
		local character = getSpecificPlayer(PLAYER_NUM)
		if not character then return end

		local manager = ISSearchManager.getManager(character)
		local searchWindow = ISSearchWindow.players[character]

		local shouldHighlight = manager
			and manager.isSearchMode
			and searchWindow
			and searchWindow.searchFocusCategory == "Tracks"

		if not shouldHighlight then
			clearHighlights()
			return
		end

		local trackingLevel = character:getPerkLevel(Perks.Tracking)
		if trackingLevel <= 0 then
			clearHighlights()
			return
		end

		local lvl = trackingLevel / 10
		local outlineAlpha = math.min(0.1 + (lvl / 3), 1)  -- база 10%, +33% к lvl 10, макс 100%

		local cell = getCell()
		if not cell then return end

		local plX, plY = character:getX(), character:getY()
		local plZ = character:getZ()
		local newHighlighted = {}

		-- Living animals (from cell object list).
		-- B42.20: IsoCell.getObjectList() returns java.util.Set, which has no :get(i), so
		-- the old loop threw on every frame and killed the rest of this function with it.
		-- Vanilla Lua uses getObjectListForLua() (a java.util.List) everywhere.
		local objectList = cell.getObjectListForLua and cell:getObjectListForLua() or cell:getObjectList()
		if not objectList or not objectList.size or not objectList.get then
			reportError("cell object list is not indexable")
			return
		end
		local now = getTimestampMs() or 0
		local playerNum = character:getPlayerNum()
		local newSeenMs = {}

		for i = 0, objectList:size() - 1 do
			local obj = objectList:get(i)
			if instanceof(obj, "IsoAnimal") and obj:isExistInTheWorld() then
				local dx = obj:getX() - plX
				local dy = obj:getY() - plY
				if dx * dx + dy * dy <= RADIUS * RADIUS then
					local sq = getObjSquare(obj)
					local canSee = sq and sq:isCanSee(playerNum)
					-- Three states, not two: visible, fading, and faded out. Dropping the
					-- "last seen" record once the fade reaches zero would make the animal
					-- look never-seen on the very next frame and it would light straight
					-- back up at full alpha. Keep the record for as long as the animal
					-- stays in radius, so faded-out stays faded out.
					local seenAt = lastSeenMs[obj]
					local alpha
					if canSee then
						seenAt = now
						alpha = outlineAlpha
					elseif seenAt ~= nil then
						local k = 1 - (now - seenAt) / FADE_MS
						alpha = (k > 0) and (outlineAlpha * k) or 0
					else
						alpha = 0  -- never been visible; the engine would not draw it anyway
					end
					if seenAt ~= nil then newSeenMs[obj] = seenAt end
					if alpha > 0 then
						obj:setOutlineHighlight(PLAYER_NUM, true)
						obj:setOutlineHighlightCol(PLAYER_NUM, 1, 1, 1, alpha)
						newHighlighted[obj] = true
					end
				end
			end
		end
		lastSeenMs = newSeenMs

		-- Animal corpses, refreshed on an interval rather than every frame.
		if now - lastCorpseScanMs >= CORPSE_SCAN_INTERVAL_MS then
			lastCorpseSet = scanCorpses(plX, plY, plZ)
			lastCorpseScanMs = now
		end
		for obj, _ in pairs(lastCorpseSet) do
			-- A corpse can be butchered or removed between scans; if it is gone the call
			-- throws and we simply drop it from the highlighted set.
			local applied = pcall(function()
				obj:setOutlineHighlight(PLAYER_NUM, true)
				obj:setOutlineHighlightCol(PLAYER_NUM, 1, 1, 1, outlineAlpha)
			end)
			if applied then newHighlighted[obj] = true end
		end

		-- clear animals that left radius or cell
		for animal, _ in pairs(lastHighlightedAnimals) do
			if not newHighlighted[animal] and animal then
				pcall(function() animal:setOutlineHighlight(PLAYER_NUM, false) end)
			end
		end
		lastHighlightedAnimals = newHighlighted
	end)
	if not ok then reportError(err) end
end

Events.OnPlayerUpdate.Add(updateAnimalOutline)
