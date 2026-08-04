-- ===========================================================================
--  Auto Battle - core logic
--
--  Runs in the InGame UI context (loaded via ImportFiles, include()d by
--  UI/AutoBattle.lua). That context binds UnitManager, CombatManager,
--  PlayersVisibility, unit operations and the map -- all the APIs this needs.
--  The panel calls our globals directly (same Lua VM):
--
--      AutoBattle_SetConfig(enabled, mode)   -- panel -> here
--      AutoBattle_RunPass() -> count         -- panel -> here, returns units acted on
--
--  Modes:
--      1 = Aggressive   2 = In-Between   3 = Passive
--
--  NOTE: some Civ6 Lua APIs vary across patches. Every risky call is wrapped in
--  a pcall and logged, so a signature mismatch produces a diagnostic line in
--  Lua.log instead of a hard crash. Grep the log for "[AutoBattle]".
-- ===========================================================================

print("[AutoBattle] logic loading...")

-- ---------------------------------------------------------------------------
--  Mode constants + shared state
-- ---------------------------------------------------------------------------
local MODE_AGGRESSIVE = 1
local MODE_BALANCED   = 2
local MODE_PASSIVE    = 3

local m_mode = MODE_BALANCED

-- Pending ranged shots: units that were told to move to a firing plot this pass
-- and should fire once their move completes. Keyed by unit ID -> {x=, y=}.
-- Resolved in OnUnitMoveComplete so the RANGE_ATTACK is issued from the unit's
-- NEW position (issuing it before the move resolves gets rejected by the engine).
local m_pendingShots = {}

-- ---------------------------------------------------------------------------
--  Logging
--
--  Log()      -- always printed: lifecycle, warnings, errors, pass summaries.
--  DebugLog() -- only when DEBUG=true: per-unit decision tracing. Flip DEBUG on
--                when something misbehaves to get the full "why" for each unit.
--
--  All lines are prefixed "[AutoBattle]" so you can filter the game's Lua.log:
--      tail -f Lua.log | grep AutoBattle
-- ---------------------------------------------------------------------------

-- Per-unit decision tracing. Defaults ON for initial testing so the first runs
-- are fully diagnosable. Once the mod behaves as expected, set this to false to
-- keep normal-play logs quiet (the always-on Log() lines still record lifecycle,
-- warnings, and errors).
local DEBUG = true

local function Log(msg)
    print("[AutoBattle] " .. tostring(msg))
end

local function DebugLog(msg)
    if DEBUG then print("[AutoBattle][dbg] " .. tostring(msg)) end
end

-- Safe read of a value for logging (never errors, never nil-crashes concat).
local function S(v)
    if v == nil then return "nil" end
    if type(v) == "number" then
        -- Trim float noise for readability.
        if v == math.floor(v) then return tostring(math.floor(v)) end
        return string.format("%.1f", v)
    end
    return tostring(v)
end

-- Guarded call: returns (ok, result). Logs on failure.
local function Try(label, fn)
    local ok, res = pcall(fn)
    if not ok then
        Log("call failed (" .. label .. "): " .. tostring(res))
        return false, nil
    end
    return true, res
end

local function Clamp01(v)
    if v < 0 then return 0 elseif v > 1 then return 1 else return v end
end

-- Distance between two plots by x,y.
local function PlotDistance(x1, y1, x2, y2)
    return Map.GetPlotDistance(x1, y1, x2, y2)
end

-- ---------------------------------------------------------------------------
--  Unit classification
-- ---------------------------------------------------------------------------

-- Recon units (Scout, Skirmisher, Ranger) carry PROMOTION_CLASS_RECON. They HAVE
-- combat strength (Scout=10) so a naive "has combat" filter would treat them as
-- fighters and throw them into losing battles. We exclude them from auto-battle
-- so they keep whatever orders you gave them (e.g. auto-explore).
local function IsRecon(pUnit)
    local ok, ut = Try("GetUnitType", function() return pUnit:GetUnitType() end)
    if not ok or ut == nil then return false end
    local info = GameInfo.Units[ut]
    return info ~= nil and info.PromotionClass == "PROMOTION_CLASS_RECON"
end

-- Returns true for a unit we should auto-control (military combat or religious).
-- Filter = "has offensive strength" (combat / ranged / religious) MINUS explicit
-- role exclusions (recon). Civilians (Builder, Settler, Trader, Great People,
-- Spy, etc.) have zero combat strength and are naturally excluded. Unknown/modded
-- combat units are included by default (graceful).
local function IsEligibleUnit(pUnit)
    if pUnit == nil then return false end
    if pUnit:IsDead() or pUnit:IsDelayedDeath() then return false end

    local info = GameInfo.Units[pUnit:GetUnitType()]
    if info == nil then return false end

    -- Explicit exclusions: recon units are skipped even though they have combat.
    if IsRecon(pUnit) then return false end

    -- Has offensive capability of some kind?
    local combat = pUnit:GetCombat()
    local rangedCombat = pUnit:GetRangedCombat()
    local religiousCombat = 0
    local ok, val = Try("GetReligiousStrength", function() return pUnit:GetReligiousStrength() end)
    if ok and val then religiousCombat = val end

    if (combat and combat > 0) or (rangedCombat and rangedCombat > 0) or (religiousCombat and religiousCombat > 0) then
        return true
    end
    return false
end

local function IsReligious(pUnit)
    local ok, val = Try("GetReligiousStrength", function() return pUnit:GetReligiousStrength() end)
    return ok and val ~= nil and val > 0
end

-- A "spread" religious unit (Missionary/Guru) can spread religion but CANNOT do
-- religious combat -- unlike an Apostle/Inquisitor, which carry a religious
-- PromotionClass (PROMOTION_CLASS_APOSTLE / _INQUISITOR). We route spread units
-- to the convert-and-explore behavior instead of the attack pipeline.
-- Detection: religious + no combat promotion class. (Missionary in Units.xml has
-- no PromotionClass; Apostle has PROMOTION_CLASS_APOSTLE.)
local function IsMissionary(pUnit)
    if not IsReligious(pUnit) then return false end
    local ok, ut = Try("GetUnitType", function() return pUnit:GetUnitType() end)
    if not ok or ut == nil then return false end
    local info = GameInfo.Units[ut]
    if info == nil then return false end
    local pc = info.PromotionClass
    -- Apostles/Inquisitors have a religious promotion class and CAN attack.
    if pc == "PROMOTION_CLASS_APOSTLE" or pc == "PROMOTION_CLASS_INQUISITOR" then
        return false
    end
    -- Otherwise a religious unit with no combat promotion class = spread/support.
    return true
end

-- An Apostle can BOTH attack (religious combat) AND spread religion. Detected by
-- the APOSTLE promotion class.
local function IsApostle(pUnit)
    if not IsReligious(pUnit) then return false end
    local ok, ut = Try("GetUnitType", function() return pUnit:GetUnitType() end)
    if not ok or ut == nil then return false end
    local info = GameInfo.Units[ut]
    return info ~= nil and info.PromotionClass == "PROMOTION_CLASS_APOSTLE"
end

-- Remaining spread charges (runtime). 0 if unavailable/none.
local function SpreadChargesLeft(pUnit)
    local ok, v = Try("GetSpreadCharges", function() return pUnit:GetSpreadCharges() end)
    return (ok and v) or 0
end

-- Domain helpers (GameInfo.Units[...].Domain: DOMAIN_LAND/SEA/AIR).
local function UnitDomain(pUnit)
    local ok, ut = Try("GetUnitType", function() return pUnit:GetUnitType() end)
    if not ok or ut == nil then return nil end
    local info = GameInfo.Units[ut]
    return info and info.Domain or nil
end

-- Air units (fighters, bombers) use AIR_ATTACK / DEPLOY, not tile movement.
local function IsAir(pUnit)
    return UnitDomain(pUnit) == "DOMAIN_AIR"
end

-- Bombard strength (naval broadsides, some siege) is separate from ranged.
local function BombardCombat(pUnit)
    local ok, v = Try("GetBombardCombat", function() return pUnit:GetBombardCombat() end)
    return (ok and v) or 0
end

-- "Ranged" = attacks at a distance without moving adjacent. Covers true ranged
-- combat AND bombard combat (naval broadsides), both of which use RANGE_ATTACK.
local function IsRanged(pUnit)
    local range = pUnit:GetRange() or 0
    if range <= 0 then return false end
    local rc = pUnit:GetRangedCombat() or 0
    local bc = BombardCombat(pUnit)
    return rc > 0 or bc > 0
end

-- Fraction of max HP remaining, 0..1. Civ6 units have max HP of 100.
local MAX_HP = 100
local function HealthFraction(pUnit)
    local dmg = pUnit:GetDamage() or 0
    return Clamp01((MAX_HP - dmg) / MAX_HP)
end

-- Can this unit still DO anything this turn? Used so Run Now can be clicked
-- after the player has already moved some units by hand: units with no moves
-- and no attack left are skipped (rather than issued orders the engine would
-- reject, which also keeps the log clean). A partially-moved unit that still
-- has moves/an attack IS still acted on.
local function CanStillAct(pUnit)
    -- Moves remaining (fractional in some builds; treat >0 as movable).
    local ok, moves = Try("GetMovesRemaining", function() return pUnit:GetMovesRemaining() end)
    if ok and moves ~= nil and moves > 0 then return true end

    -- Attacks still available even with 0 moves (e.g. a ranged unit that only
    -- moved a little). GetAttacksRemaining is the real API (UnitPanel/SelectedUnit).
    local okA, attacks = Try("GetAttacksRemaining", function() return pUnit:GetAttacksRemaining() end)
    if okA and attacks ~= nil and attacks > 0 then return true end

    -- Fallback: if BOTH query APIs were unavailable, don't over-filter.
    if not ok and not okA then return true end

    return false
end

-- ---------------------------------------------------------------------------
--  Execution order.
--
--  Within a single pass we act on units in tactical order. RANGED/SIEGE fire
--  FIRST (in place, or reposition to an empty firing tile without displacing a
--  friend), THEN melee attacks adjacent enemies or steps one tile toward the
--  target. This keeps ranged safely behind the melee line rather than having
--  melee vacate tiles the ranged then walk into. Support repositions last:
--
--      1 = Ranged (archers, crossbows, field cannon — fire before melee close in)
--      2 = Siege (catapult, trebuchet, bombard — bombard, esp. into cities)
--      3 = Melee / anti-cavalry / cavalry (adjacent attackers, incl. religious
--          combatants, which fight by moving adjacent)
--      4 = Support (medics, battering rams, siege towers, observation balloons)
--
--  Lower number executes first.
-- ---------------------------------------------------------------------------
local PRIORITY_RANGED  = 1
local PRIORITY_SIEGE    = 2
local PRIORITY_MELEE   = 3
local PRIORITY_SUPPORT = 4

local function IsSupport(pUnit)
    -- Support units have no combat and no ranged strength but a FORMATION_CLASS
    -- of SUPPORT (e.g. Medic, Battering Ram, Siege Tower, Observation Balloon).
    local info = GameInfo.Units[pUnit:GetUnitType()]
    if info == nil then return false end
    if info.FormationClass == "FORMATION_CLASS_SUPPORT" then return true end
    -- Fallback: no offensive strength at all.
    local combat = pUnit:GetCombat() or 0
    local ranged = pUnit:GetRangedCombat() or 0
    return combat == 0 and ranged == 0 and not IsReligious(pUnit)
end

-- Siege units (Catapult, Trebuchet, Bombard) carry the SIEGE promotion class.
local function IsSiege(pUnit)
    local info = GameInfo.Units[pUnit:GetUnitType()]
    return info ~= nil and info.PromotionClass == "PROMOTION_CLASS_SIEGE"
end

-- Returns the execution priority bucket for a unit (1 = first).
local function GetExecutionPriority(pUnit)
    if IsSupport(pUnit) then
        return PRIORITY_SUPPORT
    end
    -- Air strikes act like ranged fire support: fire after melee soften targets.
    if IsAir(pUnit) then
        return PRIORITY_RANGED
    end
    -- Ranged & siege both attack at distance and benefit from melee going first,
    -- but siege fires after pure ranged (e.g. archers first, then bombards).
    if IsRanged(pUnit) then
        if IsSiege(pUnit) then
            return PRIORITY_SIEGE
        end
        return PRIORITY_RANGED
    end
    -- Everything else that can fight adjacently: melee / cavalry / religious.
    return PRIORITY_MELEE
end

-- Compact human-readable descriptor of a unit for the log, e.g.
--   "u#42 WARRIOR @(5,5) hp=80% [melee]".
local function DescribeUnit(pUnit)
    local ok, ut = Try("GetUnitType", function() return pUnit:GetUnitType() end)
    local typeName = "?"
    if ok and ut ~= nil then
        local info = GameInfo.Units[ut]
        typeName = (info and (info.UnitType or ut)) or tostring(ut)
    end
    local kind = "melee"
    if IsAir(pUnit) then kind = "air"
    elseif IsApostle(pUnit) then kind = "apostle"
    elseif IsMissionary(pUnit) then kind = "missionary"
    elseif IsReligious(pUnit) then kind = "religious"
    elseif IsRanged(pUnit) then kind = IsSiege(pUnit) and "siege" or "ranged" end
    return string.format("u#%s %s @(%s,%s) hp=%s%% [%s]",
        S(pUnit:GetID()), S(typeName), S(pUnit:GetX()), S(pUnit:GetY()),
        S(HealthFraction(pUnit) * 100), kind)
end

-- ---------------------------------------------------------------------------
--  Enemy discovery
-- ---------------------------------------------------------------------------

local function AreEnemies(pPlayerA_id, pPlayerB_id)
    if pPlayerA_id == pPlayerB_id then return false end
    local pPlayerA = Players[pPlayerA_id]
    if pPlayerA == nil then return false end
    local pDiplo = pPlayerA:GetDiplomacy()
    if pDiplo == nil then return false end
    local ok, atWar = Try("IsAtWarWith", function() return pDiplo:IsAtWarWith(pPlayerB_id) end)
    return ok and atWar == true
end

-- Is plot (x,y) currently visible to selfPlayerId (revealed, not fogged)?
-- Uses PlayersVisibility, the standard per-player fog-of-war query.
local function IsPlotVisibleTo(selfPlayerId, x, y)
    if PlayersVisibility == nil then return true end  -- API absent: don't over-filter
    local vis = PlayersVisibility[selfPlayerId]
    if vis == nil then return true end
    local ok, isVisible = Try("IsVisible", function() return vis:IsVisible(x, y) end)
    if not ok then return true end  -- query failed: fall back to including it
    return isVisible == true
end

-- Collect ALL currently-visible enemy targets (units and cities) for a unit.
-- No distance cap: any enemy on a tile your civ can currently see is a
-- candidate; fogged/never-seen enemies are excluded. Each target records its
-- tile distance from the unit so callers can prioritize by proximity.
-- Returns a list of { kind="unit"|"city", obj=..., x=, y=, playerId=, dist= }.
-- True if this plot is a water tile (naval units sit here; land melee can't
-- attack into it). Defensive: unknown -> treat as land (don't over-filter).
local function PlotIsWater(x, y)
    if Map == nil or Map.GetPlot == nil then return false end
    local ok, isWater = Try("IsWater", function()
        local p = Map.GetPlot(x, y)
        return p ~= nil and p:IsWater() == true
    end)
    return ok and isWater == true
end

local function GatherEnemyTargets(pUnit, selfPlayerId)
    local targets = {}
    local ux, uy = pUnit:GetX(), pUnit:GetY()
    local attackerReligious = IsReligious(pUnit)

    -- Cross-domain MELEE rule: a melee LAND unit cannot attack a target on a WATER
    -- tile (enemy ship), and a melee NAVAL unit cannot attack a target on a LAND
    -- tile. Ranged/air units CAN hit across domains within range, so this only
    -- applies to melee. We check the TARGET'S plot (water vs land), which is what
    -- actually gates a melee reach. attackerMeleeDomain is nil for ranged/air.
    local attackerMeleeDomain = nil
    if not IsRanged(pUnit) and not IsAir(pUnit) then
        attackerMeleeDomain = UnitDomain(pUnit)   -- DOMAIN_LAND / DOMAIN_SEA
    end

    for _, player in ipairs(Game.GetPlayers()) do
        local pid = player:GetID()
        -- Which foreign players are targetable depends on the attacker:
        --   * MILITARY: only players we are AT WAR with.
        --   * RELIGIOUS (theological combat): ANY foreign player -- religious
        --     units can fight each other in peacetime too, so war is NOT required.
        --     The engine's CanStartOperation (in TryOperation) is the final gate on
        --     whether a specific religious attack is actually legal; we just stop
        --     pre-filtering valid religious targets out by war status.
        local considerPlayer = (pid ~= selfPlayerId)
            and (attackerReligious or AreEnemies(selfPlayerId, pid))
        if considerPlayer then

            -- Enemy units
            local pUnits = player:GetUnits()
            if pUnits ~= nil then
                for _, e in pUnits:Members() do
                    if e ~= nil and not e:IsDead() then
                        -- Targeting rule (asymmetric):
                        --   * A RELIGIOUS attacker can only fight other religious
                        --     units (theological combat).
                        --   * A MILITARY attacker can hit military targets, but NOT
                        --     enemy religious CIVILIANS: those have 0 military
                        --     combat strength and are removed via the special
                        --     "Condemn Heretic" COMMAND (move adjacent + button),
                        --     not via a combat attack. Issuing an attack at them
                        --     just wastes the unit's turn, so we skip them here.
                        --     (A religious unit that somehow HAS military combat
                        --     strength would still be targetable.)
                        local validPair = true
                        if attackerReligious then
                            validPair = IsReligious(e)
                        else
                            -- Military attacker: exclude no-combat religious civilians.
                            local eCombat  = e:GetCombat() or 0
                            local eRanged  = e:GetRangedCombat() or 0
                            if IsReligious(e) and eCombat == 0 and eRanged == 0 then
                                validPair = false
                            end
                        end
                        local ex, ey = e:GetX(), e:GetY()

                        -- Cross-domain melee filter: drop targets a melee unit can't
                        -- reach across the land/water boundary.
                        if validPair and attackerMeleeDomain ~= nil then
                            local tgtOnWater = PlotIsWater(ex, ey)
                            if attackerMeleeDomain == "DOMAIN_LAND" and tgtOnWater then
                                validPair = false      -- land melee can't hit a ship
                            elseif attackerMeleeDomain == "DOMAIN_SEA" and not tgtOnWater then
                                validPair = false      -- naval melee can't hit a land unit
                            end
                        end

                        if validPair and IsPlotVisibleTo(selfPlayerId, ex, ey) then
                            table.insert(targets, {
                                kind = "unit", obj = e, x = ex, y = ey, playerId = pid,
                                dist = PlotDistance(ux, uy, ex, ey),
                            })
                        end
                    end
                end
            end

            -- Enemy cities (only meaningful for non-religious military)
            if not attackerReligious then
                local pCities = player:GetCities()
                if pCities ~= nil then
                    for _, c in pCities:Members() do
                        if c ~= nil then
                            local cx, cy = c:GetX(), c:GetY()
                            if IsPlotVisibleTo(selfPlayerId, cx, cy) then
                                table.insert(targets, {
                                    kind = "city", obj = c, x = cx, y = cy, playerId = pid,
                                    dist = PlotDistance(ux, uy, cx, cy),
                                })
                            end
                        end
                    end
                end
            end
        end
    end
    return targets
end

-- ---------------------------------------------------------------------------
--  Missionary (spread religious unit) support: convert cities, else explore.
-- ---------------------------------------------------------------------------

-- Forward declarations: these positioning helpers are defined later but used by
-- FindExplorePlot below. Declaring them here makes the later `function X()`
-- definitions assign to these locals (shared upvalue), so the reference resolves.
local GetReachablePlots
local DoMoveTo

-- Our player's founded religion type, or nil if none / unavailable.
local function OurReligionType(selfPlayerId)
    local pPlayer = Players[selfPlayerId]
    if pPlayer == nil then return nil end
    local ok, rel = Try("GetReligion", function() return pPlayer:GetReligion() end)
    if not ok or rel == nil then return nil end
    local ok2, rtype = Try("GetReligionTypeCreated", function() return rel:GetReligionTypeCreated() end)
    if not ok2 then return nil end
    return rtype
end

-- Is this city's majority religion NOT ours (i.e. worth converting)?
local function CityNeedsConversion(pCity, ourReligion)
    if ourReligion == nil then return true end  -- no religion known: treat all as targets
    local ok, rel = Try("city GetReligion", function() return pCity:GetReligion() end)
    if not ok or rel == nil then return true end
    local ok2, majority = Try("GetMajorityReligion", function() return rel:GetMajorityReligion() end)
    if not ok2 then return true end
    return majority ~= ourReligion
end

-- Gather visible cities that need our religion, tagged own/foreign for priority.
-- Returns list of { obj, x, y, dist, isOwn }.
local function GatherConversionTargets(pUnit, selfPlayerId)
    local targets = {}
    local ux, uy = pUnit:GetX(), pUnit:GetY()
    local ourReligion = OurReligionType(selfPlayerId)

    for _, player in ipairs(Game.GetPlayers()) do
        local pid = player:GetID()
        local pCities = player:GetCities()
        if pCities ~= nil then
            for _, c in pCities:Members() do
                if c ~= nil then
                    local cx, cy = c:GetX(), c:GetY()
                    if IsPlotVisibleTo(selfPlayerId, cx, cy)
                       and CityNeedsConversion(c, ourReligion) then
                        table.insert(targets, {
                            obj = c, x = cx, y = cy,
                            dist = PlotDistance(ux, uy, cx, cy),
                            isOwn = (pid == selfPlayerId),
                        })
                    end
                end
            end
        end
    end
    return targets
end

-- Pick the best conversion target: OUR unconverted cities first (nearest), then
-- foreign/neutral (nearest). Returns the target or nil.
local function ChooseConversionTarget(convTargets)
    local bestOwn, bestOwnDist = nil, math.huge
    local bestOther, bestOtherDist = nil, math.huge
    for _, t in ipairs(convTargets) do
        if t.isOwn then
            if t.dist < bestOwnDist then bestOwnDist = t.dist; bestOwn = t end
        else
            if t.dist < bestOtherDist then bestOtherDist = t.dist; bestOther = t end
        end
    end
    if bestOwn ~= nil then return bestOwn end
    return bestOther
end

-- Find the reachable plot closest to the nearest UNREVEALED tile (fog edge), so
-- an idle missionary wanders outward to explore. Returns x,y or nil.
local function FindExplorePlot(pUnit, selfPlayerId)
    local vis = PlayersVisibility and PlayersVisibility[selfPlayerId] or nil
    local reach = GetReachablePlots and GetReachablePlots(pUnit) or nil
    if reach == nil then return nil end

    -- For each reachable plot, score by how close it is to unrevealed territory.
    -- We approximate "near the fog edge" as: a reachable plot that has at least
    -- one not-yet-revealed neighbor is ideal; otherwise take the plot furthest
    -- from our current position (push outward).
    local ux, uy = pUnit:GetX(), pUnit:GetY()

    local function IsRevealed(x, y)
        if vis == nil then return true end
        local ok, r = Try("IsRevealed", function()
            -- IsRevealed takes a plot index in the real API; convert via Map.
            local pPlot = Map.GetPlot and Map.GetPlot(x, y) or nil
            if pPlot == nil then return true end
            return vis:IsRevealed(pPlot:GetIndex())
        end)
        if not ok then return true end
        return r == true
    end

    -- Count how many of a plot's 6 hex neighbors are still fogged. More fogged
    -- neighbors = a plot deeper on the frontier that reveals more when reached.
    local function UnrevealedNeighborCount(x, y)
        local n = 0
        -- Even/odd-row hex neighbor offsets (Civ6 uses offset coords).
        local odd = (y % 2) ~= 0
        local offs = odd
            and { {1,0},{-1,0},{0,1},{1,1},{0,-1},{1,-1} }
            or  { {1,0},{-1,0},{-1,1},{0,1},{-1,-1},{0,-1} }
        for _, o in ipairs(offs) do
            if not IsRevealed(x + o[1], y + o[2]) then n = n + 1 end
        end
        return n
    end

    -- Pick the FURTHEST reachable plot that still borders fog. Rationale:
    -- exploration should commit to a heading and cover ground -- reach the edge of
    -- this turn's movement, out where the frontier is, and reveal new tiles there.
    -- Ranking by fog-COUNT instead (densest pocket) makes the unit swing toward
    -- whichever direction has the most fog each turn and oscillate ("patrol") near
    -- home; ranking by CLOSEST fog reveals a one-tile pocket and stops, wasting the
    -- rest of the move. Distance-primary among fog-bordering tiles avoids both:
    -- it uses full movement and keeps pushing outward. Fog-count is only a tiebreak
    -- between equidistant frontier tiles (open toward the bigger unknown).
    local bestX, bestY = nil, nil
    local bestDist, bestFog = -1, -1
    -- Furthest-from-start fallback used only if NOTHING reachable touches fog.
    local farX, farY, farDist = nil, nil, -1

    for _, p in ipairs(reach) do
        local d = PlotDistance(ux, uy, p.x, p.y)
        if d > farDist then farDist = d; farX, farY = p.x, p.y end

        local fog = UnrevealedNeighborCount(p.x, p.y)
        if fog > 0 then
            if d > bestDist or (d == bestDist and fog > bestFog) then
                bestDist, bestFog = d, fog
                bestX, bestY = p.x, p.y
            end
        end
    end

    if bestX ~= nil then return bestX, bestY end
    return farX, farY
end

-- ---------------------------------------------------------------------------
--  Combat prediction
--
--  Uses CombatManager.SimulateAttackVersus(attackerCID, defenderCID [,type]),
--  the same call the real UI uses for its combat preview
--  (UI/Panels/UnitPanel.lua:3352). The result is a table indexed by the
--  CombatResultParameters enum:
--     res[ATTACKER] / res[DEFENDER] -> per-side sub-tables, each with:
--        DAMAGE_TO       = damage dealt to that side THIS attack
--        FINAL_DAMAGE_TO = that side's CUMULATIVE damage after the attack
--        MAX_HIT_POINTS  = that side's max HP
--  A side dies when FINAL_DAMAGE_TO >= MAX_HIT_POINTS.
--
--  We normalize into our internal contract:
--     { attackerRemaining=, defenderRemaining=, attackerDamage=, defenderDamage= }
--  where *Remaining is HP left (<=0 means dead), *Damage is dealt to that side.
-- ---------------------------------------------------------------------------

local m_combatPredictor = nil  -- resolved once, then reused

-- Pick the CombatType enum value for an attacker vs. a target.
local function CombatTypeFor(attacker, target)
    if CombatTypes == nil then return 0 end
    if IsAir(attacker) then
        return CombatTypes.AIR
    end
    if IsReligious(attacker) then
        return CombatTypes.RELIGIOUS
    end
    if IsRanged(attacker) then
        -- Siege units bombard; other ranged units use RANGED.
        if IsSiege(attacker) then
            return CombatTypes.BOMBARD
        end
        return CombatTypes.RANGED
    end
    return CombatTypes.MELEE
end

local function ResolvePredictor()
    if m_combatPredictor ~= nil then return m_combatPredictor end

    if CombatManager ~= nil and CombatManager.SimulateAttackVersus ~= nil
       and CombatResultParameters ~= nil then
        m_combatPredictor = function(attacker, target)
            local eCombatType = CombatTypeFor(attacker, target)
            local res = CombatManager.SimulateAttackVersus(
                attacker:GetComponentID(),
                target.obj:GetComponentID(),
                eCombatType)
            if res == nil then return nil end
            local a = res[CombatResultParameters.ATTACKER]
            local d = res[CombatResultParameters.DEFENDER]
            if a == nil or d == nil then return nil end

            local aMax = a[CombatResultParameters.MAX_HIT_POINTS] or MAX_HP
            local dMax = d[CombatResultParameters.MAX_HIT_POINTS] or MAX_HP
            local aFinal = a[CombatResultParameters.FINAL_DAMAGE_TO] or 0  -- cumulative
            local dFinal = d[CombatResultParameters.FINAL_DAMAGE_TO] or 0
            local aDmg = a[CombatResultParameters.DAMAGE_TO] or 0          -- this hit
            local dDmg = d[CombatResultParameters.DAMAGE_TO] or 0

            return {
                -- Remaining HP after the attack (<=0 => that side dies).
                attackerRemaining = aMax - aFinal,
                defenderRemaining = dMax - dFinal,
                -- Damage each side takes from this attack.
                attackerDamage    = dDmg,  -- damage WE deal to the defender
                defenderDamage    = aDmg,  -- damage the defender deals to US
            }
        end
        Log("combat predictor = CombatManager.SimulateAttackVersus")
        return m_combatPredictor
    end

    Log("WARNING: CombatManager.SimulateAttackVersus unavailable; using strength heuristic fallback.")
    -- Fallback: crude strength-ratio heuristic (last resort, no RNG modelling)
    m_combatPredictor = function(attacker, target)
        local atkStr = IsRanged(attacker) and attacker:GetRangedCombat() or attacker:GetCombat()
        if IsReligious(attacker) then
            local ok, rs = Try("GetReligiousStrength", function() return attacker:GetReligiousStrength() end)
            atkStr = ok and rs or atkStr
        end
        local defStr = 10
        if target.kind == "unit" then
            defStr = target.obj:GetCombat() or 10
            if IsReligious(attacker) then
                local ok, rs = Try("def GetReligiousStrength", function() return target.obj:GetReligiousStrength() end)
                defStr = ok and rs or defStr
            end
        else
            local ok, cs = Try("city defense", function() return target.obj:GetDefenseStrength() end)
            defStr = ok and cs or 20
        end
        -- Civ6 damage curve approximation: 30 * exp(0.04 * diff)
        local diff = (atkStr or 10) - (defStr or 10)
        local dmgToDef = 30 * math.exp(0.04 * diff)
        local dmgToAtk = IsRanged(attacker) and 0 or (30 * math.exp(-0.04 * diff))
        local aCur = attacker:GetDamage() or 0
        local dCur = (target.kind == "unit") and (target.obj:GetDamage() or 0) or 0
        return {
            attackerRemaining = MAX_HP - (aCur + dmgToAtk),
            defenderRemaining = MAX_HP - (dCur + dmgToDef),
            attackerDamage    = dmgToDef,
            defenderDamage    = dmgToAtk,
        }
    end
    return m_combatPredictor
end

-- Predict the outcome of attacker hitting target. Returns the table or nil.
local function PredictCombat(attacker, target)
    local predictor = ResolvePredictor()
    if predictor == nil then return nil end
    local ok, res = Try("PredictCombat", function() return predictor(attacker, target) end)
    if not ok then return nil end
    return res
end

-- ---------------------------------------------------------------------------
--  Target scoring: kill first, else maximum damage, with DISTANCE as the
--  tie-breaker (closer enemy wins). Priority order: kill > damage > distance.
--  Returns bestTarget, bestPrediction  (or nil, nil)
-- ---------------------------------------------------------------------------

-- Damage values within this many HP of each other count as a tie, so distance
-- decides between them (combat previews are estimates, not exact).
local DMG_TIE_EPSILON = 1.0

-- Rank a set of targets by kill-first -> max-damage -> closest, over the given
-- list only. Returns (target, pred) or (nil, nil).
local function RankTargets(pUnit, list)
    local bestKillTarget, bestKillPred = nil, nil
    local bestDmgTarget,  bestDmgPred  = nil, nil
    local bestKillDist = math.huge
    local bestDmg      = -math.huge
    local bestDmgDist  = math.huge

    for _, tgt in ipairs(list) do
        local pred = PredictCombat(pUnit, tgt)
        if pred ~= nil and pred.defenderRemaining ~= nil then
            local dmg  = pred.attackerDamage or (MAX_HP - pred.defenderRemaining)
            local dist = tgt.dist or math.huge

            if pred.defenderRemaining <= 0 then
                if dist < bestKillDist then
                    bestKillDist = dist
                    bestKillTarget, bestKillPred = tgt, pred
                end
            end

            if dmg > bestDmg + DMG_TIE_EPSILON then
                bestDmg = dmg
                bestDmgDist = dist
                bestDmgTarget, bestDmgPred = tgt, pred
            elseif dmg > bestDmg - DMG_TIE_EPSILON and dist < bestDmgDist then
                if dmg > bestDmg then bestDmg = dmg end
                bestDmgDist = dist
                bestDmgTarget, bestDmgPred = tgt, pred
            end
        end
    end

    if bestKillTarget ~= nil then return bestKillTarget, bestKillPred end
    return bestDmgTarget, bestDmgPred
end

-- Choose the best target, with ATTACK-THIS-TURN taking absolute priority over
-- chasing. We split candidates into those the unit can hit this turn (in place or
-- by move-and-attack) vs. the rest, then rank the ATTACKABLE group first. Only if
-- nothing is attackable this turn do we fall back to the best distant target to
-- advance toward. This stops a unit from ignoring an adjacent enemy to chase a
-- far low-HP / high-damage target -- while still ALLOWING a move-and-attack that
-- reaches the target this turn (that target is in the attackable group).
-- (CanAttackThisTurn is defined below, after CanAttackNow/GetReachablePlots; it is
-- forward-declared here so this closure captures it as an upvalue.)
local CanAttackThisTurn
local function ChooseBestTarget(pUnit, candidateTargets)
    local attackable, rest = {}, {}
    for _, tgt in ipairs(candidateTargets) do
        if CanAttackThisTurn(pUnit, tgt) then
            table.insert(attackable, tgt)
        else
            table.insert(rest, tgt)
        end
    end

    if #attackable > 0 then
        local t, p = RankTargets(pUnit, attackable)
        if t ~= nil then return t, p end
    end

    -- Nothing attackable this turn -> we must ADVANCE. Use STRONG LOCALITY here:
    -- pick the NEAREST enemy, ignoring kill/damage quality. This keeps units (and
    -- separated groups) engaging enemies in THEIR area instead of marching half the
    -- map toward a marginally better global target. Quality re-enters the decision
    -- next turn once something is actually attackable (the tier above). Distance is
    -- to the unit's current position (tgt.dist was filled in GatherEnemyTargets).
    local nearest, nearestDist, nearestPred = nil, math.huge, nil
    for _, tgt in ipairs(rest) do
        local d = tgt.dist or math.huge
        if d < nearestDist then
            nearestDist = d
            nearest = tgt
            nearestPred = PredictCombat(pUnit, tgt)  -- ok if nil; advance doesn't need it
        end
    end
    return nearest, nearestPred
end

-- ---------------------------------------------------------------------------
--  Reachability / range checks
-- ---------------------------------------------------------------------------

-- Can this unit attack that target THIS turn from where it currently stands?
local function CanAttackNow(pUnit, tgt)
    local ux, uy = pUnit:GetX(), pUnit:GetY()
    local dist = PlotDistance(ux, uy, tgt.x, tgt.y)
    if IsAir(pUnit) then
        -- Air units strike anywhere within their operational range from base.
        local range = pUnit:GetRange() or 0
        return range > 0 and dist <= range
    end
    if IsRanged(pUnit) then
        local range = pUnit:GetRange() or 1
        return dist <= range
    end
    -- Melee / religious: must be adjacent.
    return dist <= 1
end

-- Can this unit attack that target THIS TURN -- either from where it stands
-- (CanAttackNow) OR by moving within its remaining movement to a tile from which
-- it can hit? For melee: a reachable tile adjacent to the target. For ranged/air:
-- a reachable tile within range (air never paths, so only CanAttackNow applies).
-- This is what makes "attack" beat "chase a distant target": a far low-HP enemy
-- is NOT attackable-this-turn, so it loses to an adjacent one that is.
-- (Assigns to the forward-declared local above ChooseBestTarget.)
function CanAttackThisTurn(pUnit, tgt)
    if CanAttackNow(pUnit, tgt) then return true end
    if IsAir(pUnit) then return false end            -- air can't reposition to attack
    local range = IsRanged(pUnit) and (pUnit:GetRange() or 1) or 1
    local reach = GetReachablePlots(pUnit)
    if reach == nil then return false end
    for _, p in ipairs(reach) do
        local d = PlotDistance(p.x, p.y, tgt.x, tgt.y)
        if d >= 1 and d <= range then return true end  -- can reach a firing/adjacent tile
    end
    return false
end

-- ---------------------------------------------------------------------------
--  Unit operations (attack / move / fortify), all guarded.
-- ---------------------------------------------------------------------------

-- Guarded RequestOperation: only issues if CanStartOperation approves (matches
-- how the real UI gates every operation -- Civ6Common.lua / WorldInput.lua).
-- Returns true if the operation was actually requested.
local function TryOperation(label, pUnit, opType, params)
    local ok, canStart = Try(label .. ".CanStart", function()
        -- Signature: CanStartOperation(unit, opType, nil, tParameters)
        if UnitManager.CanStartOperation == nil then return true end  -- API absent: attempt anyway
        return UnitManager.CanStartOperation(pUnit, opType, nil, params)
    end)
    if ok and canStart == false then
        DebugLog(string.format("    op %s SKIPPED (CanStartOperation=false) unit=%s",
            S(label), S(pUnit:GetID())))
        return false  -- engine says this op isn't legal now; skip quietly
    end
    local issued = Try(label, function()
        UnitManager.RequestOperation(pUnit, opType, params)
    end)
    DebugLog(string.format("    op %s %s unit=%s%s",
        S(label), issued and "issued" or "FAILED", S(pUnit:GetID()),
        (params and params[UnitOperationTypes.PARAM_X] ~= nil)
            and (" -> (" .. S(params[UnitOperationTypes.PARAM_X]) .. "," ..
                 S(params[UnitOperationTypes.PARAM_Y]) .. ")") or ""))
    return issued
end

-- "Hold this turn" -- the idle/no-op action. IMPORTANT: Fortify is a MILITARY
-- action; religious units (Missionary/Apostle/etc.) and other civilians CANNOT
-- fortify -- the game gives them Sleep / Skip Turn instead. So we pick the right
-- op by unit type and let CanStartOperation gate each candidate, using the first
-- that's legal. This avoids issuing a Fortify the engine would reject (which
-- would leave a religious unit doing nothing and spam the log).
local function DoHold(pUnit)
    local isCivilianReligious = IsReligious(pUnit)
        or (UnitDomain(pUnit) ~= nil and pUnit:GetCombat() == 0
            and pUnit:GetRangedCombat() == 0)

    if not isCivilianReligious then
        -- Combat unit: fortify (defensive bonus + heal).
        if TryOperation("Fortify", pUnit, UnitOperationTypes.FORTIFY, nil) then
            return true
        end
    end
    -- Civilian/religious (or fortify was illegal): sleep, else skip turn.
    if UnitOperationTypes.SLEEP ~= nil then
        if TryOperation("Sleep", pUnit, UnitOperationTypes.SLEEP, nil) then
            return true
        end
    end
    if UnitOperationTypes.SKIP_TURN ~= nil then
        if TryOperation("SkipTurn", pUnit, UnitOperationTypes.SKIP_TURN, nil) then
            return true
        end
    end
    return false
end

local function DoAttackAt(pUnit, x, y)
    local params = {}
    params[UnitOperationTypes.PARAM_X] = x
    params[UnitOperationTypes.PARAM_Y] = y

    if IsAir(pUnit) then
        -- Air units (fighters/bombers) strike via AIR_ATTACK from their base --
        -- no tile movement. Same PARAM_X/Y target (WorldInput.lua UnitAirAttack).
        return TryOperation("AirAttack", pUnit, UnitOperationTypes.AIR_ATTACK, params)
    elseif IsRanged(pUnit) then
        -- Ranged / siege / naval bombard: dedicated RANGE_ATTACK op.
        return TryOperation("RangeAttack", pUnit, UnitOperationTypes.RANGE_ATTACK, params)
    else
        -- Melee / religious: MOVE_TO onto the target WITH the ATTACK modifier.
        -- Without PARAM_MODIFIERS = ATTACK the engine may reject / not attack
        -- (see Civ6Common.lua RequestMoveOperation).
        if UnitOperationMoveModifiers ~= nil then
            params[UnitOperationTypes.PARAM_MODIFIERS] = UnitOperationMoveModifiers.ATTACK
        end
        return TryOperation("MoveAttack", pUnit, UnitOperationTypes.MOVE_TO, params)
    end
end

function DoMoveTo(pUnit, x, y)  -- assigns to the forward-declared local
    local params = {}
    params[UnitOperationTypes.PARAM_X] = x
    params[UnitOperationTypes.PARAM_Y] = y
    if UnitOperationMoveModifiers ~= nil then
        -- MOVE_IGNORE_UNEXPLORED_DESTINATION: let the engine path toward a fogged
        -- destination instead of clamping the move to the last explored tile. Without
        -- it, advancing/exploring toward unrevealed territory stops short and leaves
        -- movement unused (a 4-move unit only steps 1-2 tiles). Fall back to NONE if
        -- the modifier enum isn't present on this build.
        local mods = UnitOperationMoveModifiers.NONE
        if UnitOperationMoveModifiers.MOVE_IGNORE_UNEXPLORED_DESTINATION ~= nil then
            mods = UnitOperationMoveModifiers.MOVE_IGNORE_UNEXPLORED_DESTINATION
        end
        params[UnitOperationTypes.PARAM_MODIFIERS] = mods
    end
    return TryOperation("MoveTo", pUnit, UnitOperationTypes.MOVE_TO, params)
end

-- Spread religion at the unit's current plot (Missionary must be on/adjacent to
-- the target city; the engine validates via CanStartOperation).
local function DoSpreadReligion(pUnit)
    return TryOperation("SpreadReligion", pUnit, UnitOperationTypes.SPREAD_RELIGION, nil)
end

-- ---------------------------------------------------------------------------
--  Positioning: find the reachable plot (within movement) that minimizes
--  distance to the chosen enemy. For ranged "move to max range then attack",
--  find a reachable plot at exactly <= range but as far as possible.
-- ---------------------------------------------------------------------------

-- Returns a list of {x,y} plots the unit can reach this turn.
function GetReachablePlots(pUnit)  -- assigns to the forward-declared local
    local plots = {}
    local ok, tbl = Try("GetReachableMovement", function()
        return UnitManager.GetReachableMovement(pUnit)
    end)
    if ok and tbl ~= nil then
        for _, plotIndex in ipairs(tbl) do
            local pPlot = Map.GetPlotByIndex(plotIndex)
            if pPlot ~= nil then
                table.insert(plots, { x = pPlot:GetX(), y = pPlot:GetY() })
            end
        end
    end
    -- Fallback: at least the current plot.
    if #plots == 0 then
        table.insert(plots, { x = pUnit:GetX(), y = pUnit:GetY() })
    end
    return plots
end

-- Move to minimize distance to target. Returns true if a move was issued.
-- oneTile=true restricts the move to a SINGLE adjacent step (melee stepping in
-- one tile per Run Now so ranged fire ahead of the closing line); otherwise it
-- picks the best reachable plot within full movement.
-- FALLBACK: candidate plots are tried in order of closeness-to-target; if the
-- best one's MOVE_TO is rejected (path blocked by a unit, engine refusal, etc.)
-- we try the next-best, so a unit isn't left frozen when its ideal tile fails.
local function AdvanceTowardTarget(pUnit, tgt, oneTile)
    local reach = GetReachablePlots(pUnit)
    local ux, uy = pUnit:GetX(), pUnit:GetY()

    -- Build the list of candidate destinations (excluding the current tile),
    -- each scored by distance to the target.
    local cands = {}
    for _, p in ipairs(reach) do
        if (p.x ~= ux or p.y ~= uy)
           and (not oneTile or PlotDistance(ux, uy, p.x, p.y) == 1) then
            table.insert(cands, { x = p.x, y = p.y, d = PlotDistance(p.x, p.y, tgt.x, tgt.y) })
        end
    end
    table.sort(cands, function(a, b)
        if a.d ~= b.d then return a.d < b.d end
        return (a.x * 1000 + a.y) < (b.x * 1000 + b.y)  -- stable tiebreak
    end)

    -- Try closest-to-target first; fall through to the next if the move fails.
    for _, c in ipairs(cands) do
        if DoMoveTo(pUnit, c.x, c.y) then return true end
        DebugLog(string.format("    advance dest (%s,%s) rejected; trying next", S(c.x), S(c.y)))
    end
    return false
end

-- True if a plot is empty of OTHER units (so a ranged unit repositioning there
-- doesn't displace/swap with a friendly). The unit's own current tile counts as
-- empty. Defensive: if the occupancy API is absent, treat as empty (don't block).
local function PlotIsFreeForMove(pUnit, x, y)
    if x == pUnit:GetX() and y == pUnit:GetY() then return true end
    if Units == nil or Units.GetUnitsInPlot == nil then return true end
    local ok, occupied = Try("GetUnitsInPlot", function()
        local list = Units.GetUnitsInPlot(x, y)
        if list == nil then return false end
        for _, other in ipairs(list) do
            if other ~= nil and other:GetID() ~= pUnit:GetID() then return true end
        end
        return false
    end)
    if not ok then return true end   -- API hiccup: don't over-restrict
    return occupied ~= true
end

-- For ranged: all reachable plots from which the target is within range and that
-- aren't held by a friendly, RANKED by preference (max range first = safest).
-- Returned as a sorted list so callers can try the next-best if a move fails.
local function RankedFiringPlots(pUnit, tgt)
    local range = pUnit:GetRange() or 1
    local reach = GetReachablePlots(pUnit)
    local plots = {}
    for _, p in ipairs(reach) do
        local d = PlotDistance(p.x, p.y, tgt.x, tgt.y)
        if d <= range and d >= 1 and PlotIsFreeForMove(pUnit, p.x, p.y) then
            table.insert(plots, { x = p.x, y = p.y, d = d })
        end
    end
    -- Prefer MAX range (fire from as far as possible), stable tiebreak.
    table.sort(plots, function(a, b)
        if a.d ~= b.d then return a.d > b.d end
        return (a.x * 1000 + a.y) < (b.x * 1000 + b.y)
    end)
    return plots
end

-- Best single firing plot (or nil,nil). Kept for the DecideAction moveattack path.
local function FindMaxRangeFiringPlot(pUnit, tgt)
    local plots = RankedFiringPlots(pUnit, tgt)
    if #plots > 0 then return plots[1].x, plots[1].y end
    return nil, nil
end

-- ---------------------------------------------------------------------------
--  Mode decision: given a unit + best target, decide the action.
--  Returns one of: "attack", "advance", "fortify", "moveattack".
-- ---------------------------------------------------------------------------

local function DecideAction(pUnit, tgt, pred, mode)
    local hp = HealthFraction(pUnit)
    local ranged = IsRanged(pUnit)

    -- wouldKill: only true if we have a concrete prediction that the defender
    -- dies. Unknown -> false (don't assume a kill).
    local wouldKill = pred ~= nil and pred.defenderRemaining ~= nil and pred.defenderRemaining <= 0
    -- wouldDie: treat an UNKNOWN attacker outcome as risky (true), so a missing
    -- prediction never gets read as "safe to attack". Only a concrete prediction
    -- of survival clears it.
    local wouldDie
    if pred ~= nil and pred.attackerRemaining ~= nil then
        wouldDie = pred.attackerRemaining <= 0
    else
        wouldDie = true
    end
    -- takesDamage = does OUR unit lose HP by attacking (retaliation)? This drives
    -- the Passive rule. NOTE: defenderDamage in the prediction table is damage
    -- dealt TO the defender; retaliation to us is attackerRemaining dropping
    -- below full. Compute it from the attacker side.
    local curDamage = pUnit:GetDamage() or 0
    local takesDamage
    if pred ~= nil and pred.attackerRemaining ~= nil then
        -- We take damage if predicted remaining HP is below our current HP.
        takesDamage = pred.attackerRemaining < (MAX_HP - curDamage)
    elseif ranged then
        -- Ranged attacks normally draw no retaliation; unknown -> assume none.
        takesDamage = false
    else
        -- Melee with unknown outcome -> assume retaliation (conservative).
        takesDamage = true
    end
    local canHitNow = CanAttackNow(pUnit, tgt)

    -- Air units are a special case: they strike from base via AIR_ATTACK and do
    -- NOT path across tiles (their "move" is a strategic rebase/DEPLOY we don't
    -- automate). So they only ever attack-in-range or hold -- never advance or
    -- moveattack. They still respect each mode's aggression gates.
    if IsAir(pUnit) then
        if not canHitNow then
            return "fortify"  -- no target in air-strike range; hold
        end
        if mode == MODE_AGGRESSIVE then
            -- Strike unless it would down our own aircraft without a kill.
            if wouldDie and not wouldKill then return "fortify" end
            return "attack"
        elseif mode == MODE_BALANCED then
            if hp < 0.5 and not wouldKill then return "fortify" end
            if wouldDie and not wouldKill then return "fortify" end
            return "attack"
        else -- MODE_PASSIVE
            if wouldKill and not wouldDie then return "attack" end
            if not takesDamage and not wouldDie then return "attack" end
            return "fortify"
        end
    end

    -- Ranged move+attack availability (In-Between rule).
    local firingX, firingY = nil, nil
    if ranged and not canHitNow then
        firingX, firingY = FindMaxRangeFiringPlot(pUnit, tgt)
    end

    if mode == MODE_AGGRESSIVE then
        -- Always attack unless suicide; otherwise advance; fortify if nothing.
        if canHitNow then
            if wouldDie and not wouldKill then return "fortify" end
            return "attack"
        elseif ranged and firingX ~= nil then
            if wouldDie and not wouldKill then return "advance" end
            return "moveattack", firingX, firingY
        else
            -- Not in range: advance to minimize distance.
            return "advance"
        end

    elseif mode == MODE_BALANCED then
        -- Fortify if <50% HP unless attack would kill.
        if hp < 0.5 and not wouldKill then
            return "fortify"
        end
        if canHitNow then
            if wouldDie and not wouldKill then return "fortify" end
            return "attack"
        end
        -- Ranged: move to max range and attack if possible.
        if ranged and firingX ~= nil then
            if wouldDie and not wouldKill then
                -- Only advance if healthy enough (>50%).
                if hp > 0.5 then return "advance" else return "fortify" end
            end
            return "moveattack", firingX, firingY
        end
        -- Advance only if >50% HP.
        if hp > 0.5 then return "advance" end
        return "fortify"

    else -- MODE_PASSIVE
        -- Only attack if it costs no health, unless it kills. Never advance.
        if canHitNow then
            -- Kill is allowed even at HP cost, but never trade our own unit away
            -- on a mutual kill.
            if wouldKill and not wouldDie then return "attack" end
            -- No-cost attack (typically ranged with no retaliation).
            if not takesDamage and not wouldDie then return "attack" end
            -- Otherwise hold.
            return "fortify"
        end
        -- Passive never advances toward enemies.
        return "fortify"
    end
end

-- ---------------------------------------------------------------------------
--  Execute one unit's turn.
-- ---------------------------------------------------------------------------

-- Forward declarations for the shared execute helpers (defined below), used by
-- ProcessMissionary here and by ProcessApostle further down.
local ExecuteSpread, ExecuteExplore

-- Missionary/Guru: convert the nearest unconverted city (our cities first, then
-- foreign/neutral); if none visible, wander toward the fog edge to explore.
-- Behavior is identical in all modes (these units can't fight).
local function ProcessMissionary(pUnit, selfPlayerId)
    if ExecuteSpread(pUnit, selfPlayerId) then return true end
    if ExecuteExplore(pUnit, selfPlayerId) then return true end
    DebugLog("  missionary: nothing to convert or explore -> fortify")
    DoHold(pUnit)
    return true
end

-- Run the combat pipeline for a unit: gather enemies, pick the best target, and
-- act per the mode's rules. Returns:
--   "acted"     an operation was issued (attack/moveattack/advance/fortify)
--   "notarget"  no enemy target existed at all (caller may fall through)
-- The `fortifyIfNoTarget` flag controls whether we fortify (true) or just report
-- "notarget" (false) when there's nothing to attack -- Apostles want to fall
-- through to spread/explore instead of fortifying.
local function ExecuteCombat(pUnit, selfPlayerId, mode, fortifyIfNoTarget)
    local targets = GatherEnemyTargets(pUnit, selfPlayerId)

    if #targets == 0 then
        if fortifyIfNoTarget then
            -- No enemy in view. In Aggressive/Balanced, keep the map opening up:
            -- move toward the fog edge (reuses the missionary explorer). Passive
            -- holds position. If exploring isn't possible (nowhere to go), hold.
            if (mode == MODE_AGGRESSIVE or mode == MODE_BALANCED)
               and ExecuteExplore(pUnit, selfPlayerId) then
                DebugLog("  no visible enemy target -> explore")
                return "acted"
            end
            DebugLog("  no visible enemy target -> fortify")
            DoHold(pUnit)
            return "acted"
        end
        return "notarget"
    end
    DebugLog("  " .. S(#targets) .. " candidate target(s) in view")

    local tgt, pred = ChooseBestTarget(pUnit, targets)
    if tgt == nil then
        if fortifyIfNoTarget then
            DebugLog("  no predictable target -> fortify")
            DoHold(pUnit)
            return "acted"
        end
        return "notarget"
    end

    -- Trace the chosen target + the prediction numbers that drive the decision.
    if pred ~= nil then
        DebugLog(string.format(
            "  target %s @(%s,%s) dist=%s | pred: defRemain=%s atkRemain=%s dmgToDef=%s dmgToUs=%s",
            S(tgt.kind), S(tgt.x), S(tgt.y), S(tgt.dist),
            S(pred.defenderRemaining), S(pred.attackerRemaining),
            S(pred.attackerDamage), S(pred.defenderDamage)))
    else
        DebugLog(string.format("  target %s @(%s,%s) dist=%s | pred: <none>",
            S(tgt.kind), S(tgt.x), S(tgt.y), S(tgt.dist)))
    end

    local action, fx, fy = DecideAction(pUnit, tgt, pred, mode)
    DebugLog("  decision: " .. S(action)
        .. ((fx ~= nil) and (" via (" .. S(fx) .. "," .. S(fy) .. ")") or ""))

    if action == "attack" then
        DoAttackAt(pUnit, tgt.x, tgt.y)

    elseif action == "moveattack" then
        -- Move to the firing plot this pass, then fire ONCE THE MOVE COMPLETES.
        -- Firing before the move resolves is issued from the old tile and the
        -- engine rejects it, so we register a pending shot keyed by unit ID and
        -- let OnUnitMoveComplete issue the RANGE_ATTACK from the new position.
        if fx ~= nil then
            m_pendingShots[pUnit:GetID()] = { x = tgt.x, y = tgt.y }
            DoMoveTo(pUnit, fx, fy)
        else
            -- No firing plot resolved; fall back to attacking in place if we can.
            DoAttackAt(pUnit, tgt.x, tgt.y)
        end

    elseif action == "advance" then
        -- Melee steps ONE tile per pass in Aggressive/Balanced (ranged already
        -- fired this pass, ahead of the closing line). Ranged that fell through to
        -- "advance" (no firing plot) and all other cases move full distance.
        local oneTile = (not IsRanged(pUnit)) and (not IsAir(pUnit))
                        and (mode == MODE_AGGRESSIVE or mode == MODE_BALANCED)
        AdvanceTowardTarget(pUnit, tgt, oneTile)

    else -- fortify
        DoHold(pUnit)
    end

    return "acted"
end

-- Spread religion at the nearest unconverted city (our cities first). Returns
-- true if it acted (spread or advanced toward a city), false if none to convert.
function ExecuteSpread(pUnit, selfPlayerId)  -- assigns to forward-declared local
    local convTargets = GatherConversionTargets(pUnit, selfPlayerId)
    local target = ChooseConversionTarget(convTargets)
    if target == nil then return false end

    local dist = PlotDistance(pUnit:GetX(), pUnit:GetY(), target.x, target.y)
    DebugLog(string.format("  spread: %s city @(%s,%s) dist=%s",
        target.isOwn and "OWN" or "foreign", S(target.x), S(target.y), S(dist)))
    if dist <= 1 then
        if DoSpreadReligion(pUnit) then return true end
    end
    AdvanceTowardTarget(pUnit, target)
    return true
end

-- Move toward the fog edge to explore. Returns true if it moved.
function ExecuteExplore(pUnit, selfPlayerId)  -- assigns to forward-declared local
    local ex, ey = FindExplorePlot(pUnit, selfPlayerId)
    if ex ~= nil and (ex ~= pUnit:GetX() or ey ~= pUnit:GetY()) then
        DebugLog(string.format("  explore toward (%s,%s)", S(ex), S(ey)))
        DoMoveTo(pUnit, ex, ey)
        return true
    end
    return false
end

-- Distance to the nearest enemy religious unit we could attack (or math.huge).
local function NearestAttackDist(pUnit, selfPlayerId)
    local targets = GatherEnemyTargets(pUnit, selfPlayerId)
    local best = math.huge
    for _, t in ipairs(targets) do
        if (t.dist or math.huge) < best then best = t.dist end
    end
    return best
end

-- Distance to the nearest conversion target (or math.huge).
local function NearestSpreadDist(pUnit, selfPlayerId)
    local convTargets = GatherConversionTargets(pUnit, selfPlayerId)
    local target = ChooseConversionTarget(convTargets)
    if target == nil then return math.huge end
    return PlotDistance(pUnit:GetX(), pUnit:GetY(), target.x, target.y)
end

-- Apostle: can attack AND spread. Mode decides which to prioritize; NEVER spread
-- on the last charge (attack instead, or explore if no enemy). Fall back to
-- explore when neither is possible.
local function ProcessApostle(pUnit, selfPlayerId, mode)
    local charges = SpreadChargesLeft(pUnit)
    local lastCharge = (charges <= 1)
    local attackDist = NearestAttackDist(pUnit, selfPlayerId)
    local spreadDist = NearestSpreadDist(pUnit, selfPlayerId)
    local hasAttack = attackDist < math.huge
    local hasSpread = spreadDist < math.huge
    DebugLog(string.format("  apostle: charges=%s lastCharge=%s attackDist=%s spreadDist=%s",
        S(charges), tostring(lastCharge), S(attackDist), S(spreadDist)))

    -- Last charge: never spread. Attack if possible, else explore (save charge).
    -- Use AGGRESSIVE combat rules here regardless of the panel mode -- the
    -- last-charge rule is "prioritize attack", so we don't want Passive's
    -- don't-attack gate to turn a forced attack into a fortify. (Suicide is still
    -- avoided; Aggressive rules already guard against attacks that kill us.)
    if lastCharge then
        if hasAttack then
            return ExecuteCombat(pUnit, selfPlayerId, MODE_AGGRESSIVE, true)
        end
        if not ExecuteExplore(pUnit, selfPlayerId) then DoHold(pUnit) end
        return true
    end

    -- >1 charge: mode decides attack vs spread.
    local preferAttack
    if mode == MODE_AGGRESSIVE then
        preferAttack = hasAttack                 -- attack whenever an enemy is visible
    elseif mode == MODE_PASSIVE then
        preferAttack = not hasSpread             -- spread always; attack only if no spread
    else -- MODE_BALANCED
        preferAttack = (attackDist <= spreadDist) -- whichever is closer
    end

    if preferAttack and hasAttack then
        if ExecuteCombat(pUnit, selfPlayerId, mode, false) == "acted" then return true end
    end
    if hasSpread then
        if ExecuteSpread(pUnit, selfPlayerId) then return true end
    end
    -- Secondary: if we preferred spread but it fell through, try attack.
    if hasAttack then
        if ExecuteCombat(pUnit, selfPlayerId, mode, false) == "acted" then return true end
    end
    -- Nothing to do -> explore.
    if not ExecuteExplore(pUnit, selfPlayerId) then DoHold(pUnit) end
    return true
end

-- ---------------------------------------------------------------------------
--  Ranged/siege/air executor (the "Run Ranged" button). Single fixed behavior,
--  NO mode and NO advance-toward-enemy: if the unit can shoot in place, shoot;
--  else if it can move to an EMPTY firing tile and shoot, do that; otherwise
--  WAIT (hold). Never walks toward the enemy without a shot -- that's the melee
--  job. This is why ranged has its own button: mixing it into the mode pipeline
--  made ranged either advance pointlessly or freeze. No safety/HP gate: if a
--  shot is available it is taken.
-- ---------------------------------------------------------------------------
-- Pick a target for a ranged unit WITHOUT requiring a combat prediction. The
-- ranged button is "always shoot if in range" (no safety gate), so a failed
-- SimulateAttackVersus must NOT stop the unit from firing -- which is exactly
-- the bug in ChooseBestTarget (it silently drops any target with no prediction).
-- Preference: a target already in range (closest wins); otherwise the nearest
-- target overall (so we can try to reposition into range).
local function ChooseRangedTarget(pUnit, targets)
    -- Split into "in range right now" vs. the rest, then rank each group by
    -- kill-first -> max-damage -> closest (RankTargets). Firing at an in-range
    -- target beats repositioning, and WITHIN the in-range group we now prioritize
    -- a predicted KILL and then max damage instead of just the nearest tile --
    -- so a low-HP enemy we can finish gets shot before a healthier nearer one.
    local inRange, rest = {}, {}
    for _, t in ipairs(targets) do
        if CanAttackNow(pUnit, t) then
            table.insert(inRange, t)
        else
            table.insert(rest, t)
        end
    end

    if #inRange > 0 then
        local t = RankTargets(pUnit, inRange)
        -- RankTargets can return nil if prediction failed for ALL in-range
        -- targets; never freeze -> fall back to the closest in-range one.
        if t ~= nil then return t end
        local closest, cd = nil, math.huge
        for _, x in ipairs(inRange) do
            local d = x.dist or math.huge
            if d < cd then cd = d; closest = x end
        end
        return closest
    end

    -- None in range: pick the best target to reposition toward (kill/damage
    -- ranked; falls back to nearest if prediction is unavailable).
    local t = RankTargets(pUnit, rest)
    if t ~= nil then return t end
    local closest, cd = nil, math.huge
    for _, x in ipairs(rest) do
        local d = x.dist or math.huge
        if d < cd then cd = d; closest = x end
    end
    return closest
end

local function ExecuteRanged(pUnit, selfPlayerId)
    local targets = GatherEnemyTargets(pUnit, selfPlayerId)
    if #targets == 0 then
        DebugLog("  ranged: no visible enemy -> wait")
        DoHold(pUnit)
        return false   -- nothing to shoot; didn't really act
    end

    -- Prediction-independent target choice (see ChooseRangedTarget). Never gate
    -- firing on a combat prediction succeeding.
    local tgt = ChooseRangedTarget(pUnit, targets)
    if tgt == nil then
        DebugLog("  ranged: no target -> wait")
        DoHold(pUnit)
        return false
    end

    -- 1) Shoot in place if the target is already in range.
    if CanAttackNow(pUnit, tgt) then
        DebugLog(string.format("  ranged: fire in place at (%s,%s) dist=%s", S(tgt.x), S(tgt.y), S(tgt.dist)))
        DoAttackAt(pUnit, tgt.x, tgt.y)
        return true
    end

    -- 2) Else move to an EMPTY firing tile and fire once the move completes. Try
    --    firing plots in ranked order (max range first); if a move is rejected
    --    (path blocked, engine refusal), fall through to the next-best plot so a
    --    blocked ideal tile doesn't leave the unit idle.
    local plots = RankedFiringPlots(pUnit, tgt)
    for _, fp in ipairs(plots) do
        m_pendingShots[pUnit:GetID()] = { x = tgt.x, y = tgt.y }
        if DoMoveTo(pUnit, fp.x, fp.y) then
            DebugLog(string.format("  ranged: move&shoot via (%s,%s) -> (%s,%s)",
                S(fp.x), S(fp.y), S(tgt.x), S(tgt.y)))
            return true
        end
        m_pendingShots[pUnit:GetID()] = nil  -- move failed; clear the pending shot
        DebugLog(string.format("    ranged firing tile (%s,%s) rejected; trying next", S(fp.x), S(fp.y)))
    end

    -- 3) No shot and no clear firing move -> wait.
    DebugLog("  ranged: cannot shoot or reposition cleanly -> wait")
    DoHold(pUnit)
    return false
end

-- True if a unit belongs to the "Run Ranged" button (fires at distance): ranged,
-- siege, or air. Everything else (melee/cav/religious/support) is "Run Now".
local function IsRangedFamily(pUnit)
    return IsRanged(pUnit) or IsAir(pUnit)   -- IsRanged already covers siege
end

-- Dispatch ONE unit for the melee pass ("Run Now"). Ranged/siege/air are handled
-- by the ranged pass instead, so they are skipped here.
local function ProcessMeleeUnit(pUnit, selfPlayerId, mode)
    DebugLog("processing " .. DescribeUnit(pUnit))

    -- Missionaries/Gurus can't fight -> convert-and-explore behavior.
    if IsMissionary(pUnit) then
        return ProcessMissionary(pUnit, selfPlayerId)
    end

    -- Apostles can attack AND spread -> mode-driven priority + last-charge rule.
    if IsApostle(pUnit) then
        return ProcessApostle(pUnit, selfPlayerId, mode)
    end

    -- Melee / cavalry / religious combatants: standard mode pipeline.
    return (ExecuteCombat(pUnit, selfPlayerId, mode, true) == "acted")
end

-- ---------------------------------------------------------------------------
--  Shared pass over the local player's units. `want(unit)` selects which family
--  this pass handles; `act(unit, playerId)` runs one unit; `label` is for logs.
--  The two buttons call this with different filters/processors.
-- ---------------------------------------------------------------------------

local function RunPassFiltered(label, want, act)
    -- Don't query/order the game core while it is busy (resolving combat, a
    -- move, or a turn transition) -- predictions can come back stale and
    -- operations may be dropped. Mirrors the real UI's guard
    -- (UI/Panels/UnitPanel.lua). Skip this invocation; the next turn-begin or
    -- Run Now click retries. Guard is tolerant: only skips when the API exists
    -- and actually reports busy.
    if UI ~= nil and UI.IsGameCoreBusy ~= nil then
        local ok, busy = Try("IsGameCoreBusy", function() return UI.IsGameCoreBusy() end)
        if ok and busy == true then
            Log("game core busy; deferring pass.")
            return 0
        end
    end

    local selfPlayerId = Game.GetLocalPlayer()
    if selfPlayerId == nil or selfPlayerId < 0 then
        Log("no valid local player; skipping.")
        return 0
    end

    local pPlayer = Players[selfPlayerId]
    if pPlayer == nil then return 0 end

    local pUnits = pPlayer:GetUnits()
    if pUnits == nil then return 0 end

    local processed = 0
    -- Snapshot units first, since operations can mutate the collection. `want`
    -- filters which family this pass handles; `act` runs one unit.
    local unitList = {}
    local skipped = 0
    for _, u in pUnits:Members() do
        if IsEligibleUnit(u) and want(u) then
            if CanStillAct(u) then
                table.insert(unitList, { unit = u, priority = GetExecutionPriority(u) })
            else
                skipped = skipped + 1  -- already used by the player this turn
            end
        end
    end

    -- Deterministic order within the pass (siege after pure ranged, etc., then
    -- by unit ID). The melee/ranged split is now by BUTTON, not by this sort.
    table.sort(unitList, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        return a.unit:GetID() < b.unit:GetID()
    end)

    for _, entry in ipairs(unitList) do
        local pUnit = entry.unit
        local ok = Try("ProcessOne", function() return act(pUnit, selfPlayerId) end)
        if ok then processed = processed + 1 end
    end

    Log(("%s pass: acted on %d unit(s), skipped %d already-used")
        :format(label, processed, skipped))
    return processed
end

-- Public: run the MELEE pass ("Run Now"). Melee/cav/religious + apostle/missionary;
-- ranged/siege/air are excluded (handled by Run Ranged). Uses the selected mode.
function AutoBattle_RunMelee()
    return RunPassFiltered("melee",
        function(u) return not IsRangedFamily(u) end,
        function(u, pid) return ProcessMeleeUnit(u, pid, m_mode) end)
end

-- Public: run the RANGED pass ("Run Ranged"). Ranged/siege/air only. Fixed
-- shoot-or-wait behavior, no mode.
function AutoBattle_RunRanged()
    return RunPassFiltered("ranged",
        function(u) return IsRangedFamily(u) end,
        function(u, pid) return ExecuteRanged(u, pid) end)
end

-- ---------------------------------------------------------------------------
--  Public API (this file is include()d by UI/AutoBattle.lua into the SAME Lua
--  VM, so the panel calls these globals directly -- no LuaEvents bridge, which
--  would only be needed to cross between separate Lua states).
-- ---------------------------------------------------------------------------

-- Set the active mode from the panel. Run-Now-only: there is no enable flag and
-- no auto-run at turn start, so this just records which mode Run Now will use.
function AutoBattle_SetConfig(mode)
    if mode ~= nil then m_mode = mode end
    Log(("config set: mode=%d"):format(m_mode))
end

-- AutoBattle_RunMelee() and AutoBattle_RunRanged() (defined above) are the two
-- public run entry points the panel calls; each returns the number of units
-- acted on so the panel can update its status line.

-- Fire pending ranged shots once a move-to-firing-plot completes. The engine
-- reports (playerID, unitID, ...) for this event across builds; we only act on
-- our local player's units that we registered a pending shot for.
local function OnUnitMoveComplete(playerID, unitID)
    if next(m_pendingShots) == nil then return end
    local shot = m_pendingShots[unitID]
    if shot == nil then return end
    -- Clear first so a failed/again event can't double-fire.
    m_pendingShots[unitID] = nil

    DebugLog(string.format("UnitMoveComplete: player=%s unit=%s -> pending shot at (%s,%s)",
        S(playerID), S(unitID), S(shot.x), S(shot.y)))

    if playerID ~= Game.GetLocalPlayer() then return end
    local pPlayer = Players[playerID]
    if pPlayer == nil then return end
    local pUnits = pPlayer:GetUnits()
    if pUnits == nil then return end
    local pUnit = pUnits:FindID(unitID)
    if pUnit == nil or pUnit:IsDead() then
        DebugLog("  pending shot aborted: unit gone/dead after move")
        return
    end

    -- Only fire if the target is now actually in range from the new position.
    local dist = PlotDistance(pUnit:GetX(), pUnit:GetY(), shot.x, shot.y)
    local range = pUnit:GetRange() or 1
    if dist >= 1 and dist <= range then
        DebugLog(string.format("  firing on arrival from (%s,%s) dist=%s range=%s",
            S(pUnit:GetX()), S(pUnit:GetY()), S(dist), S(range)))
        DoAttackAt(pUnit, shot.x, shot.y)
    else
        Log(("pending shot skipped: unit %s out of range after move (dist=%s range=%s)")
            :format(S(unitID), S(dist), S(range)))
    end
end

-- Clear any stale pending shots at the start of each turn.
local function ClearPendingShots()
    m_pendingShots = {}
end

-- Register engine event hooks (available in the InGame UI context). Run-Now-only:
-- we hook turn begin ONLY to clear stale pending ranged shots, not to auto-run.
if Events ~= nil and Events.LocalPlayerTurnBegin ~= nil then
    Events.LocalPlayerTurnBegin.Add(ClearPendingShots)
    Log("hooked LocalPlayerTurnBegin (clears pending shots; no auto-run).")
else
    Log("WARNING: Events.LocalPlayerTurnBegin unavailable.")
end

if Events ~= nil and Events.UnitMoveComplete ~= nil then
    Events.UnitMoveComplete.Add(OnUnitMoveComplete)
    Log("hooked UnitMoveComplete (ranged move-then-fire).")
else
    Log("WARNING: Events.UnitMoveComplete unavailable; ranged units will move but not auto-fire the same turn.")
end

Log("AutoBattle logic loaded OK.")
