-- ===========================================================================
--  Offline logic tests for AutoBattleLogic.lua (run with: lua run_tests.lua)
--
--  Each test: reset mocks -> build scenario -> load logic fresh -> drive via
--  public API -> assert on captured operations (M.issuedOps).
-- ===========================================================================

package.path = package.path .. ";" .. (arg[0]:match("(.*/)") or "./") .. "?.lua"
local M = require("mock_engine")

local LOGIC_PATH = (arg[0]:match("(.*/)") or "./") .. "../UI/AutoBattleLogic.lua"

local MODE_AGGRESSIVE, MODE_BALANCED, MODE_PASSIVE = 1, 2, 3

-- Silence the logic file's print() noise during tests; keep test output clean.
local realPrint = print
local function quiet() print = function() end end
local function loud() print = realPrint end

local passed, failed = 0, 0
local function check(name, cond, detail)
    loud()
    if cond then
        passed = passed + 1
        realPrint(("  PASS  %s"):format(name))
    else
        failed = failed + 1
        realPrint(("  FAIL  %s%s"):format(name, detail and ("  -> " .. detail) or ""))
    end
    quiet()
end

-- Load the logic file fresh into the current global env (mocks already installed).
local function loadLogic()
    quiet()
    local chunk, err = loadfile(LOGIC_PATH)
    if not chunk then loud(); error("loadfile failed: " .. tostring(err)) end
    chunk()
    -- Leave print() silenced; check() restores it for its own output.
end

-- Find issued ops for a given unit id.
local function opsFor(unitId)
    local r = {}
    for _, o in ipairs(M.issuedOps) do if o.unit == unitId then table.insert(r, o) end end
    return r
end
local function firstOp(unitId) return opsFor(unitId)[1] end

-- Common scenario helper: one of our units vs one enemy unit, at war, visible.
-- ourSpec/enemySpec are unit specs; combat is a makeCombatResult(...) or nil.
local function scenario(ourSpec, enemySpec, combat, mode)
    M.reset()
    M.localPlayerId = 0
    ourSpec.id = ourSpec.id or 100
    enemySpec.id = enemySpec.id or 200
    M.players[0] = M.makePlayer{ id = 0, units = { ourSpec } }
    M.players[1] = M.makePlayer{ id = 1, units = { enemySpec } }
    M.warMatrix["0:1"] = true
    M.warMatrix["1:0"] = true
    if combat then M.combatResults[ourSpec.id .. ":" .. enemySpec.id] = combat end
    M.install()
    loadLogic()
    AutoBattle_SetConfig(true, mode or MODE_BALANCED)
    AutoBattle_RunPass()
end

realPrint("=== AutoBattle logic tests ===")
quiet()  -- silence engine log noise; check() restores print for its own output

-- -------------------------------------------------------------------------
-- 1. Aggressive: adjacent melee, safe attack -> attacks
-- -------------------------------------------------------------------------
scenario(
    { x=5, y=5, combat=50 },                       -- our melee
    { x=6, y=5, combat=30 },                        -- adjacent enemy
    M.makeCombatResult(0, 0, 40, 10),               -- we deal 40, take 10; both survive
    MODE_AGGRESSIVE)
do
    local op = firstOp(100)
    check("Aggressive melee attacks adjacent enemy (safe)",
        op and op.op == "MOVE_TO" and op.x == 6 and op.y == 5,
        op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 2. Aggressive: attack that would KILL our unit and NOT kill enemy -> fortify (suicide guard)
-- -------------------------------------------------------------------------
scenario(
    { x=5, y=5, combat=10 },
    { x=6, y=5, combat=90 },
    M.makeCombatResult(0, 0, 5, 100),               -- enemy survives (5 dmg), we die (100 dmg)
    MODE_AGGRESSIVE)
do
    local op = firstOp(100)
    check("Aggressive avoids suicide -> fortify",
        op and op.op == "FORTIFY", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 3. In-Between: below 50% HP, non-lethal attack -> fortify
-- -------------------------------------------------------------------------
scenario(
    { x=5, y=5, combat=50, damage=60 },             -- 40% HP
    { x=6, y=5, combat=30 },
    M.makeCombatResult(60, 0, 40, 10),              -- non-lethal to enemy
    MODE_BALANCED)
do
    local op = firstOp(100)
    check("In-Between <50% HP non-lethal -> fortify",
        op and op.op == "FORTIFY", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 4. In-Between: below 50% HP but attack KILLS -> attack
-- -------------------------------------------------------------------------
scenario(
    { x=5, y=5, combat=50, damage=60 },             -- 40% HP
    { x=6, y=5, combat=30 },
    M.makeCombatResult(60, 0, 100, 10),             -- lethal to enemy
    MODE_BALANCED)
do
    local op = firstOp(100)
    check("In-Between <50% HP but lethal -> attack",
        op and op.op == "MOVE_TO", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 5. Passive melee: attack costs HP, not lethal -> fortify (never trades)
-- -------------------------------------------------------------------------
scenario(
    { x=5, y=5, combat=50 },
    { x=6, y=5, combat=40 },
    M.makeCombatResult(0, 0, 30, 20),               -- we take 20 (cost), not lethal
    MODE_PASSIVE)
do
    local op = firstOp(100)
    check("Passive melee non-lethal w/ retaliation -> fortify",
        op and op.op == "FORTIFY", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 6. Passive ranged: no retaliation -> attack
-- -------------------------------------------------------------------------
scenario(
    { x=5, y=5, ranged=50, range=2 },
    { x=7, y=5, combat=40 },                         -- 2 tiles away, in range
    M.makeCombatResult(0, 0, 30, 0),                 -- no damage taken
    MODE_PASSIVE)
do
    local op = firstOp(100)
    check("Passive ranged no-retaliation -> attack",
        op and op.op == "RANGE_ATTACK", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 7. Passive: never advances (enemy out of range)
-- -------------------------------------------------------------------------
scenario(
    { x=5, y=5, combat=50 },
    { x=10, y=5, combat=40 },                        -- far away
    nil,
    MODE_PASSIVE)
do
    local op = firstOp(100)
    check("Passive never advances -> fortify",
        op and op.op == "FORTIFY", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 8. Religious unit ignores military enemy (no valid target -> fortify)
-- -------------------------------------------------------------------------
scenario(
    { x=5, y=5, religious=50 },                      -- our apostle
    { x=6, y=5, combat=40 },                          -- enemy WARRIOR (not religious)
    nil,
    MODE_AGGRESSIVE)
do
    local op = firstOp(100)
    check("Religious unit ignores military target -> fortify",
        op and op.op == "FORTIFY", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 9. Military unit CAN target enemy religious unit
-- -------------------------------------------------------------------------
scenario(
    { x=5, y=5, combat=50 },                         -- our warrior
    { x=6, y=5, religious=40 },                        -- enemy apostle
    M.makeCombatResult(0, 0, 40, 0),
    MODE_AGGRESSIVE)
do
    local op = firstOp(100)
    check("Military unit can attack enemy religious unit",
        op and op.op == "MOVE_TO", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 10. Target priority: kill-first beats higher-damage non-kill
-- -------------------------------------------------------------------------
do
    M.reset()
    M.localPlayerId = 0
    M.players[0] = M.makePlayer{ id=0, units={ { id=100, x=5, y=5, ranged=50, range=3 } } }
    M.players[1] = M.makePlayer{ id=1, units={
        { id=200, x=6, y=5, combat=40, damage=95 },   -- killable (low HP)
        { id=201, x=7, y=5, combat=40 },               -- full HP, higher raw damage
    } }
    M.warMatrix["0:1"]=true; M.warMatrix["1:0"]=true
    M.combatResults["100:200"] = M.makeCombatResult(0, 95, 30, 0)  -- kills 200 (95+30>=100... wait 125>=100 yes)
    M.combatResults["100:201"] = M.makeCombatResult(0, 0, 60, 0)   -- 60 dmg but not a kill
    M.install(); loadLogic()
    AutoBattle_SetConfig(true, MODE_AGGRESSIVE)
    AutoBattle_RunPass()
    local op = firstOp(100)
    check("Kill-first: targets killable enemy over higher-damage one",
        op and op.op == "RANGE_ATTACK" and op.x == 6 and op.y == 5,
        op and (op.op .. " @" .. tostring(op.x) .. "," .. tostring(op.y)) or "no op")
end

-- -------------------------------------------------------------------------
-- 11. Distance tie-breaker: equal damage, closer enemy chosen
-- -------------------------------------------------------------------------
do
    M.reset()
    M.localPlayerId = 0
    M.players[0] = M.makePlayer{ id=0, units={ { id=100, x=5, y=5, ranged=50, range=5 } } }
    M.players[1] = M.makePlayer{ id=1, units={
        { id=200, x=8, y=5, combat=40 },   -- 3 away
        { id=201, x=7, y=5, combat=40 },   -- 2 away (closer)
    } }
    M.warMatrix["0:1"]=true; M.warMatrix["1:0"]=true
    M.combatResults["100:200"] = M.makeCombatResult(0, 0, 30, 0)  -- equal damage
    M.combatResults["100:201"] = M.makeCombatResult(0, 0, 30, 0)  -- equal damage
    M.install(); loadLogic()
    AutoBattle_SetConfig(true, MODE_AGGRESSIVE)
    AutoBattle_RunPass()
    local op = firstOp(100)
    check("Distance tie-break: attacks closer of equal-damage targets",
        op and op.x == 7 and op.y == 5,
        op and (tostring(op.x) .. "," .. tostring(op.y)) or "no op")
end

-- -------------------------------------------------------------------------
-- 12. Skip already-used unit (no moves, no attacks)
-- -------------------------------------------------------------------------
scenario(
    { x=5, y=5, combat=50, moves=0, attacks=0 },
    { x=6, y=5, combat=30 },
    M.makeCombatResult(0, 0, 40, 10),
    MODE_AGGRESSIVE)
do
    check("Exhausted unit is skipped (no ops issued)",
        #opsFor(100) == 0, tostring(#opsFor(100)) .. " ops")
end

-- -------------------------------------------------------------------------
-- 13. Game core busy -> whole pass deferred (no ops)
-- -------------------------------------------------------------------------
do
    M.reset()
    M.localPlayerId = 0
    M.players[0] = M.makePlayer{ id=0, units={ { id=100, x=5, y=5, combat=50 } } }
    M.players[1] = M.makePlayer{ id=1, units={ { id=200, x=6, y=5, combat=30 } } }
    M.warMatrix["0:1"]=true; M.warMatrix["1:0"]=true
    M.combatResults["100:200"] = M.makeCombatResult(0,0,40,10)
    M.gameCoreBusy = true
    M.install(); loadLogic()
    AutoBattle_SetConfig(true, MODE_AGGRESSIVE)
    local n = AutoBattle_RunPass()
    check("Busy core defers pass (0 ops, returns 0)", #M.issuedOps == 0 and n == 0,
        tostring(#M.issuedOps) .. " ops, n=" .. tostring(n))
end

-- -------------------------------------------------------------------------
-- 14. Not at war -> no target -> fortify
-- -------------------------------------------------------------------------
do
    M.reset()
    M.localPlayerId = 0
    M.players[0] = M.makePlayer{ id=0, units={ { id=100, x=5, y=5, combat=50 } } }
    M.players[1] = M.makePlayer{ id=1, units={ { id=200, x=6, y=5, combat=30 } } }
    -- no war set
    M.install(); loadLogic()
    AutoBattle_SetConfig(true, MODE_AGGRESSIVE)
    AutoBattle_RunPass()
    local op = firstOp(100)
    check("Not at war -> no target -> fortify",
        op and op.op == "FORTIFY", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 15. Fogged enemy is ignored (visible=false) -> fortify
-- -------------------------------------------------------------------------
do
    M.reset()
    M.localPlayerId = 0
    M.players[0] = M.makePlayer{ id=0, units={ { id=100, x=5, y=5, combat=50 } } }
    M.players[1] = M.makePlayer{ id=1, units={ { id=200, x=6, y=5, combat=30 } } }
    M.warMatrix["0:1"]=true; M.warMatrix["1:0"]=true
    M.visibleDefault = false   -- everything fogged
    M.install(); loadLogic()
    AutoBattle_SetConfig(true, MODE_AGGRESSIVE)
    AutoBattle_RunPass()
    local op = firstOp(100)
    check("Fogged enemy ignored -> fortify",
        op and op.op == "FORTIFY", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 16. Melee attack carries the ATTACK move-modifier (the #1 fix)
-- -------------------------------------------------------------------------
scenario(
    { x=5, y=5, combat=50 },
    { x=6, y=5, combat=30 },
    M.makeCombatResult(0, 0, 40, 10),
    MODE_AGGRESSIVE)
do
    local op = firstOp(100)
    check("Melee attack sets PARAM_MODIFIERS = ATTACK",
        op and op.op == "MOVE_TO" and op.mod == UnitOperationMoveModifiers.ATTACK,
        op and ("mod=" .. tostring(op.mod)) or "no op")
end

-- -------------------------------------------------------------------------
-- 17. CanStartOperation=false -> op is skipped (no phantom orders)
-- -------------------------------------------------------------------------
do
    M.reset()
    M.localPlayerId = 0
    M.players[0] = M.makePlayer{ id=0, units={ { id=100, x=5, y=5, combat=50 } } }
    M.players[1] = M.makePlayer{ id=1, units={ { id=200, x=6, y=5, combat=30 } } }
    M.warMatrix["0:1"]=true; M.warMatrix["1:0"]=true
    M.combatResults["100:200"] = M.makeCombatResult(0,0,40,10)
    M.disallowOps["100:MOVE_TO"] = true   -- engine forbids the attack-move
    M.install(); loadLogic()
    AutoBattle_SetConfig(true, MODE_AGGRESSIVE)
    AutoBattle_RunPass()
    check("Disallowed MOVE_TO is not issued",
        #opsFor(100) == 0, tostring(#opsFor(100)) .. " ops")
end

realPrint(("=== %d passed, %d failed ==="):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
