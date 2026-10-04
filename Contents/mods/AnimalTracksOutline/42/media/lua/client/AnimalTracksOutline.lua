-- Animal Tracks Outline
-- Outline for animals when Search Mode + focus "Animal Tracks"
--
-- Client-side only, and that is enough for multiplayer: setOutlineHighlight is local render
-- state (it registers the object with FBORenderObjectOutline and sends nothing), so every
-- client computes its own outlines and the server never sees them. OnPlayerUpdate fires
-- only for local players -- once per tick normally, once per player in split-screen -- so
-- each pass works on the player it was called for, in that player's outline slot, with its
-- own state. Multiplayer support co-authored by Glapnak, who first built it in "Animal
-- Tracks Outline MP" (Workshop ID 3809241207).
require "Foraging/ISSearchManager"
require "Foraging/ISSearchWindow"

local RADIUS = 50

-- Corpses do not move, so rescanning them every frame is wasted work: the scan walks
-- (2*RADIUS+1)^2 squares, i.e. over 10k getGridSquare calls. Doing it on an interval is
-- indistinguishable in game and costs a small fraction of the frames it used to.
local CORPSE_SCAN_INTERVAL_MS = 500

-- A living animal that leaves the vision cone keeps being rendered for roughly a second
-- and is then dropped from the render pass outright, taking its outline with it. That
-- reads as a hard pop rather than a disappearance. The engine's own render alpha lives on
-- ObjectRenderInfo, which is not in the Lua exposer, so we cannot follow it; instead we
-- fade our own outline alpha to zero inside that window, comfortably before the cull.
-- Tuned by eye against that window: shorter reads as an abrupt snap, longer risks the
-- fade still running when the engine culls the object, which brings the pop back.
local FADE_MS = 1000

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

-- Per local player, keyed by player number (0-3), which is also the outline slot the
-- player's pass writes to. Split-screen players must not share this: one player's pass
-- would clear outlines the other one just set.
local playerStates = {}
local function getState(playerNum)
	local state = playerStates[playerNum]
	if not state then
		state = {
			highlighted = {},       -- object -> true, outlined in this player's slot
			lastSeenMs = {},        -- animal -> timestamp when its square was last visible
			corpses = {},           -- animal corpse -> true, from the last scan
			lastCorpseScanMs = 0,
		}
		playerStates[playerNum] = state
		-- Once per player slot per session: shows in console.txt which local players the mod
		-- is serving, and whether this is a multiplayer client.
		print("[AnimalTracksOutline] serving local player " .. tostring(playerNum)
			.. (isMultiplayer() and " (multiplayer client)" or " (singleplayer)"))
	end
	return state
end

local function clearOutline(obj, playerNum)
	-- Single call in pcall: avoid any other method on obj (stale refs can make them throw).
	local ok = pcall(function()
		obj:setOutlineHighlight(playerNum, false)
	end)
	return ok
end

local function clearAll(state, playerNum)
	for obj, _ in pairs(state.highlighted) do
		clearOutline(obj, playerNum)
	end
	state.highlighted = {}
	state.lastSeenMs = {}
	state.corpses = {}
	state.lastCorpseScanMs = 0  -- rescan immediately when search mode comes back on
end

local function getObjSquare(obj)
	if obj.getCurrentSquare then
		return obj:getCurrentSquare()
	end
	if obj.getSquare then
		return obj:getSquare()
	end
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

local function updateAnimalOutline(character)
	local ok, err = pcall(function()
		if not character then return end
		local playerNum = character:getPlayerNum()
		local state = getState(playerNum)

		local manager = ISSearchManager.getManager(character)
		local searchWindow = ISSearchWindow.players[character]

		local shouldHighlight = manager
			and manager.isSearchMode
			and searchWindow
			and searchWindow.searchFocusCategory == "Tracks"

		if not shouldHighlight then
			clearAll(state, playerNum)
			return
		end

		local trackingLevel = character:getPerkLevel(Perks.Tracking)
		if trackingLevel <= 0 then
			clearAll(state, playerNum)
			return
		end

		local lvl = trackingLevel / 10
		local outlineAlpha = math.min(0.1 + (lvl / 3), 1)  -- base 10%, +33% at level 10, max 100%

		local cell = getCell()
		if not cell then return end

		local plX, plY = character:getX(), character:getY()
		local plZ = character:getZ()
		local newHighlighted = {}

		-- Living animals. getAnimals() walks the same IsoCell.objectList that
		-- getObjectListForLua() copies, but filters IsoAnimal in Java, so this loop only
		-- visits animals instead of every zombie in the cell. (Never getObjectList(): since
		-- B42.20 it returns a java.util.Set, which has no :get(i).)
		local animals = cell:getAnimals()
		if not animals then
			reportError("IsoCell:getAnimals() returned nil")
			return
		end
		local now = getTimestampMs() or 0
		local newSeenMs = {}

		for i = 0, animals:size() - 1 do
			local obj = animals:get(i)
			if obj:isExistInTheWorld() then
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
					local seenAt = state.lastSeenMs[obj]
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
						obj:setOutlineHighlight(playerNum, true)
						obj:setOutlineHighlightCol(playerNum, 1, 1, 1, alpha)
						newHighlighted[obj] = true
					end
				end
			end
		end
		state.lastSeenMs = newSeenMs

		-- Animal corpses, refreshed on an interval rather than every frame.
		if now - state.lastCorpseScanMs >= CORPSE_SCAN_INTERVAL_MS then
			state.corpses = scanCorpses(plX, plY, plZ)
			state.lastCorpseScanMs = now
		end
		for obj, _ in pairs(state.corpses) do
			-- A corpse can be butchered or removed between scans; if it is gone the call
			-- throws and we simply drop it from the highlighted set.
			local applied = pcall(function()
				obj:setOutlineHighlight(playerNum, true)
				obj:setOutlineHighlightCol(playerNum, 1, 1, 1, outlineAlpha)
			end)
			if applied then newHighlighted[obj] = true end
		end

		-- Clear outlines for objects that left radius or cell
		for obj, _ in pairs(state.highlighted) do
			if not newHighlighted[obj] then
				clearOutline(obj, playerNum)
			end
		end
		state.highlighted = newHighlighted
	end)
	if not ok then reportError(err) end
end

-- Only the player who died is cleared; a split-screen partner keeps their outlines.
local function onPlayerDeath(character)
	if not character then return end
	local playerNum = character:getPlayerNum()
	local state = playerStates[playerNum]
	if state then clearAll(state, playerNum) end
end

Events.OnPlayerUpdate.Add(updateAnimalOutline)
Events.OnPlayerDeath.Add(onPlayerDeath)
