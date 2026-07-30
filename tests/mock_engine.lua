-- ===========================================================================
--  Mock Civ6 engine for offline testing of AutoBattleLogic.lua
--
--  Defines fake versions of every engine global the logic file touches, so the
--  real logic can be load()ed and driven without the game. Scenarios configure
--  units/players/combat outcomes; issued operations are captured for asserting.
--
--  Usage (see run_tests.lua):
--     local M = require("mock_engine")
--     M.reset()
--     ... build a scenario ...
--     dofile(".../AutoBattleLogic.lua")   -- installs globals into _G
--     AutoBattle_SetConfig(true, 1)
--     AutoBattle_RunPass()
--     ... assert on M.issuedOps ...
-- ===========================================================================

local M = {}

-- Captured operations: { {unit=id, op="FORTIFY"|"MOVE_TO"|"RANGE_ATTACK", x=, y=}, ... }
M.issuedOps = {}
-- Registered event handlers: name -> { fn, fn, ... }
M.eventHandlers = {}

-- Scenario state
M.gameCoreBusy = false
M.localPlayerId = 0
M.players = {}       -- id -> mockPlayer
M.warMatrix = {}     -- "a:b" -> true
M.visible = {}       -- "x,y" -> true (default: everything visible unless set)
M.visibleDefault = true
M.combatResults = {} -- "attackerId:defenderId" -> result table
M.disallowOps = {}   -- "unitId:opType" -> true  (CanStartOperation returns false)
M.unitInfo = {}      -- unitType string -> { FormationClass=, PromotionClass= }
M.reachablePlots = {}-- unitId -> { plotIndex, ... }
M.plots = {}         -- plotIndex -> {x=, y=}

-- ---------------------------------------------------------------------------
--  Enum tables (values don't matter, only identity/keys)
-- ---------------------------------------------------------------------------
UnitOperationTypes = {
    FORTIFY = "FORTIFY", MOVE_TO = "MOVE_TO", RANGE_ATTACK = "RANGE_ATTACK",
    PARAM_X = "PARAM_X", PARAM_Y = "PARAM_Y", PARAM_MODIFIERS = "PARAM_MODIFIERS",
}
UnitOperationMoveModifiers = { NONE = 0, ATTACK = 1, MOVE_IGNORE_UNEXPLORED_DESTINATION = 2 }
CombatTypes = { MELEE=1, RANGED=2, BOMBARD=3, RELIGIOUS=4, AIR=5, NONE=0 }
CombatResultParameters = {
    ATTACKER="ATTACKER", DEFENDER="DEFENDER",
    DAMAGE_TO="DAMAGE_TO", FINAL_DAMAGE_TO="FINAL_DAMAGE_TO",
    MAX_HIT_POINTS="MAX_HIT_POINTS",
}

-- ---------------------------------------------------------------------------
--  Mock unit factory
-- ---------------------------------------------------------------------------
-- spec: { id, x, y, combat, ranged, range, religious, damage, unitType,
--         moves, attacks, dead }
function M.makeUnit(spec)
    local u = {}
    local s = spec
    u._spec = s
    function u:GetID() return s.id end
    function u:GetComponentID() return { player = s.owner or 0, id = s.id } end
    function u:GetX() return s.x end
    function u:GetY() return s.y end
    function u:GetCombat() return s.combat or 0 end
    function u:GetRangedCombat() return s.ranged or 0 end
    function u:GetRange() return s.range or 0 end
    function u:GetReligiousStrength() return s.religious or 0 end
    function u:GetDamage() return s.damage or 0 end
    function u:GetMovesRemaining() return s.moves == nil and 2 or s.moves end
    function u:GetAttacksRemaining() return s.attacks == nil and 1 or s.attacks end
    function u:GetUnitType() return s.unitType or "UNIT_WARRIOR" end
    function u:IsDead() return s.dead == true end
    function u:IsDelayedDeath() return false end
    function u:GetDefenseStrength() return s.defense or 20 end
    return u
end

-- Mock unit collection
local function makeUnitCollection(units)
    local c = {}
    function c:Members()
        local i = 0
        return function()
            i = i + 1
            if units[i] then return i, units[i] end
        end
    end
    function c:FindID(id)
        for _, u in ipairs(units) do if u:GetID() == id then return u end end
        return nil
    end
    return c
end

local function makeCityCollection(cities)
    local c = {}
    function c:Members()
        local i = 0
        return function() i = i + 1; if cities[i] then return i, cities[i] end end
    end
    return c
end

-- Mock player factory
-- spec: { id, units={unitSpec...}, cities={citySpec...} }
function M.makePlayer(spec)
    local p = {}
    local units = {}
    for _, us in ipairs(spec.units or {}) do
        us.owner = spec.id
        table.insert(units, M.makeUnit(us))
    end
    local cities = {}
    for _, cs in ipairs(spec.cities or {}) do
        local city = {}
        function city:GetX() return cs.x end
        function city:GetY() return cs.y end
        function city:GetComponentID() return { player = spec.id, id = cs.id } end
        function city:GetDefenseStrength() return cs.defense or 30 end
        table.insert(cities, city)
    end
    function p:GetID() return spec.id end
    function p:GetUnits() return makeUnitCollection(units) end
    function p:GetCities() return makeCityCollection(cities) end
    function p:GetDiplomacy()
        return {
            IsAtWarWith = function(_, otherId)
                return M.warMatrix[spec.id .. ":" .. otherId] == true
            end
        }
    end
    p._units = units
    return p
end

-- ---------------------------------------------------------------------------
--  Install engine globals
-- ---------------------------------------------------------------------------
function M.install()
    Players = setmetatable({}, { __index = function(_, id) return M.players[id] end })

    Game = {
        GetLocalPlayer = function() return M.localPlayerId end,
        GetPlayers = function()
            local list = {}
            for _, p in pairs(M.players) do table.insert(list, p) end
            -- Deterministic order by id
            table.sort(list, function(a, b) return a:GetID() < b:GetID() end)
            return list
        end,
    }

    Map = {
        GetPlotDistance = function(x1, y1, x2, y2)
            -- Hex-ish distance is fine to approximate with Chebyshev for tests.
            return math.max(math.abs(x1 - x2), math.abs(y1 - y2))
        end,
        GetPlotByIndex = function(idx)
            local p = M.plots[idx]
            if p == nil then return nil end
            return { GetX = function() return p.x end, GetY = function() return p.y end }
        end,
    }

    PlayersVisibility = setmetatable({}, { __index = function()
        return { IsVisible = function(_, x, y)
            local key = x .. "," .. y
            if M.visible[key] ~= nil then return M.visible[key] end
            return M.visibleDefault
        end }
    end })

    GameInfo = { Units = setmetatable({}, { __index = function(_, ut)
        return M.unitInfo[ut] or { FormationClass = "FORMATION_CLASS_LAND_COMBAT",
                                   PromotionClass = "PROMOTION_CLASS_MELEE",
                                   UnitType = ut }
    end }) }

    UI = {
        IsGameCoreBusy = function() return M.gameCoreBusy end,
        PlaySound = function() end,
    }

    UnitManager = {
        -- Returns true unless a scenario disallows this (unitId, op) pair.
        CanStartOperation = function(unit, op, _, _)
            local key = unit:GetID() .. ":" .. op
            if M.disallowOps[key] then return false end
            return true
        end,
        RequestOperation = function(unit, op, params)
            local rec = { unit = unit:GetID(), op = op }
            if params then
                rec.x = params[UnitOperationTypes.PARAM_X]
                rec.y = params[UnitOperationTypes.PARAM_Y]
                rec.mod = params[UnitOperationTypes.PARAM_MODIFIERS]
            end
            table.insert(M.issuedOps, rec)
        end,
        GetReachableMovement = function(unit)
            return M.reachablePlots[unit:GetID()] or {}
        end,
    }

    CombatManager = {
        SimulateAttackVersus = function(attackerCID, defenderCID, _)
            local key = attackerCID.id .. ":" .. defenderCID.id
            return M.combatResults[key]
        end,
    }

    Events = setmetatable({}, { __index = function(_, name)
        M.eventHandlers[name] = M.eventHandlers[name] or {}
        return { Add = function(fn) table.insert(M.eventHandlers[name], fn) end }
    end })
end

-- Helper to build a CombatResultParameters-shaped result.
-- dealt = damage we do to defender; taken = damage defender does to us.
-- Cumulative damage after attack = current + this hit.
function M.makeCombatResult(attackerCurDmg, defenderCurDmg, dealtToDefender, dealtToAttacker)
    local P = CombatResultParameters
    return {
        [P.ATTACKER] = {
            [P.MAX_HIT_POINTS] = 100,
            [P.DAMAGE_TO] = dealtToAttacker,
            [P.FINAL_DAMAGE_TO] = attackerCurDmg + dealtToAttacker,
        },
        [P.DEFENDER] = {
            [P.MAX_HIT_POINTS] = 100,
            [P.DAMAGE_TO] = dealtToDefender,
            [P.FINAL_DAMAGE_TO] = defenderCurDmg + dealtToDefender,
        },
    }
end

function M.reset()
    M.issuedOps = {}
    M.eventHandlers = {}
    M.gameCoreBusy = false
    M.localPlayerId = 0
    M.players = {}
    M.warMatrix = {}
    M.visible = {}
    M.visibleDefault = true
    M.combatResults = {}
    M.disallowOps = {}
    M.unitInfo = {}
    M.reachablePlots = {}
    M.plots = {}
end

return M
