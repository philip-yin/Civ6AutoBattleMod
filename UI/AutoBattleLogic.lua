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

local m_isEnabled = false
local m_mode      = MODE_BALANCED

-- Pending ranged shots: units that were told to move to a firing plot this pass
-- and should fire once their move completes. Keyed by unit ID -> {x=, y=}.
-- Resolved in OnUnitMoveComplete so the RANGE_ATTACK is issued from the unit's
-- NEW position (issuing it before the move resolves gets rejected by the engine).
local m_pendingShots = {}

-- ---------------------------------------------------------------------------
--  Small helpers
-- ---------------------------------------------------------------------------

local function Log(msg)
    print("[AutoBattle] " .. tostring(msg))
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

-- Returns true for a unit we should auto-control (military combat or religious).
local function IsEligibleUnit(pUnit)
    if pUnit == nil then return false end
    if pUnit:IsDead() or pUnit:IsDelayedDeath() then return false end

    local info = GameInfo.Units[pUnit:GetUnitType()]
    if info == nil then return false end

    -- Military: has combat strength and is a real attacking class.
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

local function IsRanged(pUnit)
    local rc = pUnit:GetRangedCombat()
    return rc ~= nil and rc > 0 and pUnit:GetRange() ~= nil and pUnit:GetRange() > 0
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
--  Within a single pass we act on units in tactical order so melee open the
--  fight and take tiles, ranged/siege then fire into softened targets, and
--  support units reposition last:
--
--      1 = Melee / anti-cavalry / cavalry (adjacent attackers, incl. religious
--          combatants, which fight by moving adjacent)
--      2 = Ranged (archers, crossbows, field cannon — fire into what melee softened)
--      3 = Siege (catapult, trebuchet, bombard — bombard, esp. into cities)
--      4 = Support (medics, battering rams, siege towers, observation balloons)
--
--  Lower number executes first.
-- ---------------------------------------------------------------------------
local PRIORITY_MELEE   = 1
local PRIORITY_RANGED  = 2
local PRIORITY_SIEGE   = 3
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
local function GatherEnemyTargets(pUnit, selfPlayerId)
    local targets = {}
    local ux, uy = pUnit:GetX(), pUnit:GetY()
    local attackerReligious = IsReligious(pUnit)

    for _, player in ipairs(Game.GetPlayers()) do
        local pid = player:GetID()
        if pid ~= selfPlayerId and AreEnemies(selfPlayerId, pid) then

            -- Enemy units
            local pUnits = player:GetUnits()
            if pUnits ~= nil then
                for _, e in pUnits:Members() do
                    if e ~= nil and not e:IsDead() then
                        -- Targeting rule (asymmetric):
                        --   * A RELIGIOUS attacker can only fight other religious
                        --     units (theological combat).
                        --   * A MILITARY attacker can hit anything, including
                        --     enemy religious units (normal combat kills them).
                        local validPair = true
                        if attackerReligious then
                            validPair = IsReligious(e)
                        end
                        local ex, ey = e:GetX(), e:GetY()
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

local function ChooseBestTarget(pUnit, candidateTargets)
    local bestKillTarget, bestKillPred = nil, nil
    local bestDmgTarget,  bestDmgPred  = nil, nil
    local bestKillDist = math.huge   -- among killable, prefer the closest
    local bestDmg      = -math.huge
    local bestDmgDist  = math.huge

    for _, tgt in ipairs(candidateTargets) do
        local pred = PredictCombat(pUnit, tgt)
        if pred ~= nil and pred.defenderRemaining ~= nil then
            local dmg  = pred.attackerDamage or (MAX_HP - pred.defenderRemaining)
            local dist = tgt.dist or math.huge

            -- Killable? (defender predicted HP <= 0) -> pick the closest kill.
            if pred.defenderRemaining <= 0 then
                if dist < bestKillDist then
                    bestKillDist = dist
                    bestKillTarget, bestKillPred = tgt, pred
                end
            end

            -- Track max-damage; break damage ties by distance.
            if dmg > bestDmg + DMG_TIE_EPSILON then
                bestDmg = dmg
                bestDmgDist = dist
                bestDmgTarget, bestDmgPred = tgt, pred
            elseif dmg > bestDmg - DMG_TIE_EPSILON and dist < bestDmgDist then
                -- Effectively equal damage, but closer.
                if dmg > bestDmg then bestDmg = dmg end
                bestDmgDist = dist
                bestDmgTarget, bestDmgPred = tgt, pred
            end
        end
    end

    if bestKillTarget ~= nil then
        return bestKillTarget, bestKillPred
    end
    return bestDmgTarget, bestDmgPred
end

-- ---------------------------------------------------------------------------
--  Reachability / range checks
-- ---------------------------------------------------------------------------

-- Can this unit attack that target THIS turn from where it currently stands?
local function CanAttackNow(pUnit, tgt)
    local ux, uy = pUnit:GetX(), pUnit:GetY()
    local dist = PlotDistance(ux, uy, tgt.x, tgt.y)
    if IsRanged(pUnit) then
        local range = pUnit:GetRange() or 1
        return dist <= range
    end
    -- Melee / religious: must be adjacent.
    return dist <= 1
end

-- ---------------------------------------------------------------------------
--  Unit operations (attack / move / fortify), all guarded.
-- ---------------------------------------------------------------------------

local function DoFortify(pUnit)
    Try("Fortify", function()
        UnitManager.RequestOperation(pUnit, UnitOperationTypes.FORTIFY)
    end)
end

local function DoAttackAt(pUnit, x, y)
    -- RANGE_ATTACK for ranged units; MOVE_TO (which auto-attacks on contact)
    -- for melee/religious when adjacent.
    if IsRanged(pUnit) then
        local ok = Try("RangeAttack", function()
            local params = {}
            params[UnitOperationTypes.PARAM_X] = x
            params[UnitOperationTypes.PARAM_Y] = y
            UnitManager.RequestOperation(pUnit, UnitOperationTypes.RANGE_ATTACK, params)
        end)
        return ok
    else
        local ok = Try("MoveTo(attack)", function()
            local params = {}
            params[UnitOperationTypes.PARAM_X] = x
            params[UnitOperationTypes.PARAM_Y] = y
            UnitManager.RequestOperation(pUnit, UnitOperationTypes.MOVE_TO, params)
        end)
        return ok
    end
end

local function DoMoveTo(pUnit, x, y)
    return Try("MoveTo", function()
        local params = {}
        params[UnitOperationTypes.PARAM_X] = x
        params[UnitOperationTypes.PARAM_Y] = y
        UnitManager.RequestOperation(pUnit, UnitOperationTypes.MOVE_TO, params)
    end)
end

-- ---------------------------------------------------------------------------
--  Positioning: find the reachable plot (within movement) that minimizes
--  distance to the chosen enemy. For ranged "move to max range then attack",
--  find a reachable plot at exactly <= range but as far as possible.
-- ---------------------------------------------------------------------------

-- Returns a list of {x,y} plots the unit can reach this turn.
local function GetReachablePlots(pUnit)
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
local function AdvanceTowardTarget(pUnit, tgt)
    local reach = GetReachablePlots(pUnit)
    local bestX, bestY, bestDist = nil, nil, math.huge
    for _, p in ipairs(reach) do
        local d = PlotDistance(p.x, p.y, tgt.x, tgt.y)
        if d < bestDist then
            bestDist = d
            bestX, bestY = p.x, p.y
        end
    end
    if bestX ~= nil and (bestX ~= pUnit:GetX() or bestY ~= pUnit:GetY()) then
        return DoMoveTo(pUnit, bestX, bestY)
    end
    return false
end

-- For ranged: find reachable plot from which the target is within range,
-- preferring the plot at the MAXIMUM range (safest). Returns x,y or nil.
local function FindMaxRangeFiringPlot(pUnit, tgt)
    local range = pUnit:GetRange() or 1
    local reach = GetReachablePlots(pUnit)
    local bestX, bestY, bestRangeDist = nil, nil, -1
    for _, p in ipairs(reach) do
        local d = PlotDistance(p.x, p.y, tgt.x, tgt.y)
        if d <= range and d >= 1 and d > bestRangeDist then
            bestRangeDist = d
            bestX, bestY = p.x, p.y
        end
    end
    if bestX ~= nil then return bestX, bestY end
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

local function ProcessUnit(pUnit, selfPlayerId, mode)
    local targets = GatherEnemyTargets(pUnit, selfPlayerId)

    if #targets == 0 then
        -- Nothing to do; fortify to heal/hold. (Aggressive explicitly wants this.)
        DoFortify(pUnit)
        return true
    end

    local tgt, pred = ChooseBestTarget(pUnit, targets)
    if tgt == nil then
        DoFortify(pUnit)
        return true
    end

    local action, fx, fy = DecideAction(pUnit, tgt, pred, mode)

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
        AdvanceTowardTarget(pUnit, tgt)

    else -- fortify
        DoFortify(pUnit)
    end

    return true
end

-- ---------------------------------------------------------------------------
--  Main pass over all eligible units of the local player.
-- ---------------------------------------------------------------------------

local function RunAutoBattlePass()
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
    -- Snapshot units first, since operations can mutate the collection.
    local unitList = {}
    local skipped = 0
    for _, u in pUnits:Members() do
        if IsEligibleUnit(u) then
            if CanStillAct(u) then
                table.insert(unitList, { unit = u, priority = GetExecutionPriority(u) })
            else
                skipped = skipped + 1  -- already used by the player this turn
            end
        end
    end

    -- Tactical execution order: melee (1) -> ranged (2) -> siege (3) ->
    -- support (4). Stable sort by priority so melee open the fight and take
    -- tiles before ranged fire into softened targets, siege bombard, and
    -- support reposition last.
    table.sort(unitList, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        -- Tie-break by unit ID for deterministic ordering within a bucket.
        return a.unit:GetID() < b.unit:GetID()
    end)

    for _, entry in ipairs(unitList) do
        local pUnit = entry.unit
        local ok = Try("ProcessUnit", function() return ProcessUnit(pUnit, selfPlayerId, m_mode) end)
        if ok then processed = processed + 1 end
    end

    Log(("pass complete: acted on %d unit(s), skipped %d already-used, mode=%d")
        :format(processed, skipped, m_mode))
    return processed
end

-- ---------------------------------------------------------------------------
--  Public API (this file is include()d by UI/AutoBattle.lua into the SAME Lua
--  VM, so the panel calls these globals directly -- no LuaEvents bridge, which
--  would only be needed to cross between separate Lua states).
-- ---------------------------------------------------------------------------

-- Set enabled/mode from the panel.
function AutoBattle_SetConfig(enabled, mode)
    m_isEnabled = enabled and true or false
    if mode ~= nil then m_mode = mode end
    Log(("config set: enabled=%s mode=%d"):format(tostring(m_isEnabled), m_mode))
end

-- Run one pass now. Returns the number of units acted on so the panel can
-- update its status line from the return value.
function AutoBattle_RunPass()
    return RunAutoBattlePass()
end

-- Auto-run at the start of the local player's turn when enabled.
local function OnLocalPlayerTurnBegin()
    if not m_isEnabled then return end
    RunAutoBattlePass()
end

-- Fire pending ranged shots once a move-to-firing-plot completes. The engine
-- reports (playerID, unitID, ...) for this event across builds; we only act on
-- our local player's units that we registered a pending shot for.
local function OnUnitMoveComplete(playerID, unitID)
    if next(m_pendingShots) == nil then return end
    local shot = m_pendingShots[unitID]
    if shot == nil then return end
    -- Clear first so a failed/again event can't double-fire.
    m_pendingShots[unitID] = nil

    if playerID ~= Game.GetLocalPlayer() then return end
    local pPlayer = Players[playerID]
    if pPlayer == nil then return end
    local pUnits = pPlayer:GetUnits()
    if pUnits == nil then return end
    local pUnit = pUnits:FindID(unitID)
    if pUnit == nil or pUnit:IsDead() then return end

    -- Only fire if the target is now actually in range from the new position.
    local dist = PlotDistance(pUnit:GetX(), pUnit:GetY(), shot.x, shot.y)
    local range = pUnit:GetRange() or 1
    if dist >= 1 and dist <= range then
        DoAttackAt(pUnit, shot.x, shot.y)
    else
        Log(("pending shot skipped: unit %d out of range after move (dist=%d range=%d)")
            :format(unitID, dist, range))
    end
end

-- Clear any stale pending shots at the start of each turn.
local function ClearPendingShots()
    m_pendingShots = {}
end

-- Register engine event hooks (available in the InGame UI context).
if Events ~= nil and Events.LocalPlayerTurnBegin ~= nil then
    Events.LocalPlayerTurnBegin.Add(ClearPendingShots)
    Events.LocalPlayerTurnBegin.Add(OnLocalPlayerTurnBegin)
    Log("hooked LocalPlayerTurnBegin.")
else
    Log("WARNING: Events.LocalPlayerTurnBegin unavailable; only Run Now will work.")
end

if Events ~= nil and Events.UnitMoveComplete ~= nil then
    Events.UnitMoveComplete.Add(OnUnitMoveComplete)
    Log("hooked UnitMoveComplete (ranged move-then-fire).")
else
    Log("WARNING: Events.UnitMoveComplete unavailable; ranged units will move but not auto-fire the same turn.")
end

Log("AutoBattle logic loaded OK.")
