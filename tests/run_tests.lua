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

-- Run both passes (as a player clicking Run Now then Run Ranged would). Each
-- pass filters by unit family internally, so calling both is harmless and
-- exercises whichever pass actually owns the units in a given scenario.
local function runBothPasses()
    local n1 = AutoBattle_RunMelee() or 0
    local n2 = AutoBattle_RunRanged() or 0
    return n1 + n2
end

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
    AutoBattle_SetConfig(mode or MODE_BALANCED)
    runBothPasses()
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
-- 6b. Passive ranged: target visible but out of firing range -> HOLDS, does
--     NOT reposition to a firing tile or advance. This is the "ranged mode-
--     aware Passive" rule: fire only if no movement is required at all.
--     A reachable plot IS registered that would both (a) put the target in
--     range and (b) be picked by the advance-fallback -- proving Passive is
--     what's blocking the move, not a lack of reachable plots.
-- -------------------------------------------------------------------------
do
    M.reset()
    M.localPlayerId = 0
    M.players[0] = M.makePlayer{ id=0, units={
        { id=100, x=5, y=5, ranged=50, range=2 } } }
    M.players[1] = M.makePlayer{ id=1, units={
        { id=200, x=8, y=5, combat=40 } } }              -- dist 3: out of range 2
    M.warMatrix["0:1"]=true; M.warMatrix["1:0"]=true
    M.plots[6005] = { x=6, y=5 }                          -- dist 2 from (8,5): would be in range
    M.reachablePlots[100] = { 6005 }
    M.install(); loadLogic()
    AutoBattle_SetConfig(MODE_PASSIVE)
    runBothPasses()
    local op = firstOp(100)
    check("Passive ranged out of range holds (no reposition/advance)",
        op and op.op == "FORTIFY", op and op.op or "no op")
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
-- 7b. MAX_ENGAGE_DIST gate: even AGGRESSIVE (which normally advances toward
--     ANY visible enemy) refuses to engage/advance toward an enemy more than
--     6 hexes away -- the enemy must not even be gathered as a candidate.
-- -------------------------------------------------------------------------
scenario(
    { x=5, y=5, combat=50 },
    { x=12, y=5, combat=40 },                        -- dist 7: just beyond the gate
    nil,
    MODE_AGGRESSIVE)
do
    local op = firstOp(100)
    check("Aggressive does not engage/advance beyond MAX_ENGAGE_DIST (7 hexes)",
        op and op.op == "FORTIFY", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 7c. MAX_ENGAGE_DIST gate boundary: an enemy exactly AT the 6-hex gate is
--     still a valid candidate -- Aggressive advances toward it. A reachable
--     plot is registered (scenario() doesn't expose one) so the melee unit
--     actually has somewhere to step toward.
-- -------------------------------------------------------------------------
do
    M.reset()
    M.localPlayerId = 0
    M.players[0] = M.makePlayer{ id=0, units={ { id=100, x=5, y=5, combat=50 } } }
    M.players[1] = M.makePlayer{ id=1, units={
        { id=200, x=11, y=5, combat=40 } } }             -- dist 6: right at the gate, still valid
    M.warMatrix["0:1"]=true; M.warMatrix["1:0"]=true
    M.plots[6005] = { x=6, y=5 }
    M.reachablePlots[100] = { 6005 }
    M.install(); loadLogic()
    AutoBattle_SetConfig(MODE_AGGRESSIVE)
    runBothPasses()
    local op = firstOp(100)
    check("Aggressive still engages/advances at exactly MAX_ENGAGE_DIST (6 hexes)",
        op and op.op == "MOVE_TO", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 8. Religious spread unit with nothing to do HOLDS via SLEEP (NOT Fortify --
--    religious/civilian units can't fortify).
-- -------------------------------------------------------------------------
scenario(
    { x=5, y=5, religious=50, unitType="UNIT_MISSIONARY",
      formationClass="FORMATION_CLASS_CIVILIAN" },     -- our missionary
    { x=6, y=5, combat=40 },                            -- enemy WARRIOR (irrelevant to it)
    nil,
    MODE_AGGRESSIVE)
do
    local op = firstOp(100)
    check("Religious unit holds via SLEEP, not Fortify",
        op and op.op == "SLEEP", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 9. Military unit CAN target an enemy religious COMBATANT (e.g. Inquisitor,
--    which carries real combat strength alongside religious strength). A
--    spread-only religious civilian (0 combat/ranged) is deliberately excluded
--    -- see GatherEnemyTargets -- so this unit must have nonzero combat to be
--    a valid military target at all.
-- -------------------------------------------------------------------------
scenario(
    { x=5, y=5, combat=50 },                         -- our warrior
    { x=6, y=5, religious=40, combat=30 },             -- enemy Inquisitor (fights)
    M.makeCombatResult(0, 0, 40, 0),
    MODE_AGGRESSIVE)
do
    local op = firstOp(100)
    check("Military unit can attack enemy religious combatant",
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
    AutoBattle_SetConfig(MODE_AGGRESSIVE)
    runBothPasses()
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
    AutoBattle_SetConfig(MODE_AGGRESSIVE)
    runBothPasses()
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
    AutoBattle_SetConfig(MODE_AGGRESSIVE)
    local n = runBothPasses()
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
    AutoBattle_SetConfig(MODE_AGGRESSIVE)
    runBothPasses()
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
    AutoBattle_SetConfig(MODE_AGGRESSIVE)
    runBothPasses()
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
    AutoBattle_SetConfig(MODE_AGGRESSIVE)
    runBothPasses()
    check("Disallowed MOVE_TO is not issued",
        #opsFor(100) == 0, tostring(#opsFor(100)) .. " ops")
end

-- -------------------------------------------------------------------------
-- 18. Air unit in range -> AIR_ATTACK op (not RANGE_ATTACK / MOVE_TO)
-- -------------------------------------------------------------------------
scenario(
    { x=5, y=5, ranged=60, range=4, domain="DOMAIN_AIR", unitType="UNIT_BOMBER" },
    { x=8, y=5, combat=40 },                          -- 3 tiles, within air range 4
    M.makeCombatResult(0, 0, 50, 0),
    MODE_AGGRESSIVE)
do
    local op = firstOp(100)
    check("Air unit in range uses AIR_ATTACK",
        op and op.op == "AIR_ATTACK", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 19. Air unit with target OUT of range (but within the MAX_ENGAGE_DIST gate,
--     so it's still a gathered candidate, not filtered out entirely) ->
--     fortify (never advances/deploys). Air units are IsRangedFamily, so
--     runBothPasses() drives this through Run Ranged's ExecuteRanged too -- a
--     reachable plot is registered so AdvanceTowardTarget WOULD succeed if the
--     IsAir guard there were ever removed, making this test actually catch
--     that regression.
-- -------------------------------------------------------------------------
do
    M.reset()
    M.localPlayerId = 0
    M.players[0] = M.makePlayer{ id=0, units={
        { id=100, x=5, y=5, ranged=60, range=4, domain="DOMAIN_AIR", unitType="UNIT_BOMBER" } } }
    M.players[1] = M.makePlayer{ id=1, units={
        { id=200, x=10, y=5, combat=40 } } }             -- dist 5: beyond air range 4, within engage gate 6
    M.warMatrix["0:1"]=true; M.warMatrix["1:0"]=true
    M.plots[6005] = { x=6, y=5 }
    M.reachablePlots[100] = { 6005 }                     -- would let ground advance succeed
    M.install(); loadLogic()
    AutoBattle_SetConfig(MODE_AGGRESSIVE)
    runBothPasses()
    local op = firstOp(100)
    check("Air unit out of range -> fortify (no advance)",
        op and op.op == "FORTIFY", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 19b. Ground ranged unit with target out of movement+range, but within the
--      MAX_ENGAGE_DIST gate -> ADVANCES (full movement) instead of holding.
--      Target is dist 6 from (5,5) (right at the gate) and still dist 5 from
--      the only reachable plot (6,5) -- out of firing range 2 either way -- so
--      ExecuteRanged's step 3 (advance fallback) should fire a MOVE_TO there.
-- -------------------------------------------------------------------------
do
    M.reset()
    M.localPlayerId = 0
    M.players[0] = M.makePlayer{ id=0, units={
        { id=100, x=5, y=5, ranged=50, range=2 } } }
    M.players[1] = M.makePlayer{ id=1, units={
        { id=200, x=11, y=5, combat=40 } } }             -- dist 6: within engage gate, out of range+reach
    M.warMatrix["0:1"]=true; M.warMatrix["1:0"]=true
    M.plots[6005] = { x=6, y=5 }
    M.reachablePlots[100] = { 6005 }                     -- still nowhere near range 2 of (11,5)
    M.install(); loadLogic()
    AutoBattle_SetConfig(MODE_AGGRESSIVE)
    runBothPasses()
    local op = firstOp(100)
    check("Ranged unit out of range advances toward distant target (no hold)",
        op and op.op == "MOVE_TO" and op.x == 6 and op.y == 5,
        op and (op.op .. " @" .. tostring(op.x) .. "," .. tostring(op.y)) or "no op")
end

-- -------------------------------------------------------------------------
-- 19c. MAX_ENGAGE_DIST gate applies to Run Ranged too: a ranged unit does NOT
--      gather (let alone advance toward) an enemy beyond the 6-hex gate, even
--      though ExecuteRanged has no mode/HP gating of its own. With no targets
--      and no explore fallback (removed -- Civ6's own auto-explore covers idle
--      wandering), the unit simply holds.
-- -------------------------------------------------------------------------
do
    M.reset()
    M.localPlayerId = 0
    M.players[0] = M.makePlayer{ id=0, units={
        { id=100, x=5, y=5, ranged=50, range=2 } } }
    M.players[1] = M.makePlayer{ id=1, units={
        { id=200, x=12, y=5, combat=40 } } }             -- dist 7: just beyond the gate
    M.warMatrix["0:1"]=true; M.warMatrix["1:0"]=true
    M.plots[6005] = { x=6, y=5 }                         -- reachable, but irrelevant: no target gathered
    M.reachablePlots[100] = { 6005 }
    M.install(); loadLogic()
    AutoBattle_SetConfig(MODE_AGGRESSIVE)
    runBothPasses()
    local op = firstOp(100)
    check("Ranged unit does not engage an enemy beyond MAX_ENGAGE_DIST (7 hexes)",
        op and op.op == "FORTIFY", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 20. Naval melee ship attacks adjacent via MOVE_TO+ATTACK. Both tiles must be
--     marked water -- the cross-domain melee filter checks the TARGET's plot,
--     and the mock defaults every plot to land.
-- -------------------------------------------------------------------------
do
    M.reset()
    M.localPlayerId = 0
    M.players[0] = M.makePlayer{ id=0, units={
        { id=100, x=5, y=5, combat=45, domain="DOMAIN_SEA", unitType="UNIT_GALLEY" } } }
    M.players[1] = M.makePlayer{ id=1, units={
        { id=200, x=6, y=5, combat=30, domain="DOMAIN_SEA", unitType="UNIT_GALLEY" } } }
    M.warMatrix["0:1"]=true; M.warMatrix["1:0"]=true
    M.combatResults["100:200"] = M.makeCombatResult(0, 0, 40, 15)
    M.waterPlots["5,5"] = true
    M.waterPlots["6,5"] = true
    M.install(); loadLogic()
    AutoBattle_SetConfig(MODE_AGGRESSIVE)
    runBothPasses()
    local op = firstOp(100)
    check("Naval melee ship attacks via MOVE_TO+ATTACK",
        op and op.op == "MOVE_TO" and op.mod == UnitOperationMoveModifiers.ATTACK,
        op and (op.op .. " mod=" .. tostring(op.mod)) or "no op")
end

-- -------------------------------------------------------------------------
-- 21. Naval bombard-only ship classifies as ranged -> RANGE_ATTACK
--     (bombard=strength, ranged=0, but has range)
-- -------------------------------------------------------------------------
scenario(
    { x=5, y=5, combat=40, bombard=50, ranged=0, range=2,
      domain="DOMAIN_SEA", unitType="UNIT_FRIGATE" },
    { x=7, y=5, combat=30, domain="DOMAIN_SEA", unitType="UNIT_GALLEY", id=200 },
    M.makeCombatResult(0, 0, 45, 0),
    MODE_AGGRESSIVE)
do
    local op = firstOp(100)
    check("Naval bombard ship uses RANGE_ATTACK (bombard classified ranged)",
        op and op.op == "RANGE_ATTACK", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 22. Missionary adjacent to unconverted city -> SPREAD_RELIGION
-- -------------------------------------------------------------------------
do
    M.reset(); M.localPlayerId = 0
    M.playerReligion[0] = "REL_OURS"
    M.players[0] = M.makePlayer{ id=0,
        units = { { id=100, x=5, y=5, religious=100, unitType="UNIT_MISSIONARY",
                    formationClass="FORMATION_CLASS_CIVILIAN", promotionClass=nil } },
        cities = { { id=300, x=6, y=5, religion="REL_PAGAN" } } }  -- our unconverted city, adjacent
    M.install(); loadLogic()
    AutoBattle_SetConfig(MODE_AGGRESSIVE)
    runBothPasses()
    local op = firstOp(100)
    check("Missionary adjacent to unconverted city -> SPREAD_RELIGION",
        op and op.op == "SPREAD_RELIGION", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 23. Missionary far from unconverted city -> advances toward it
-- -------------------------------------------------------------------------
do
    M.reset(); M.localPlayerId = 0
    M.playerReligion[0] = "REL_OURS"
    M.players[0] = M.makePlayer{ id=0,
        units = { { id=100, x=5, y=5, religious=100, unitType="UNIT_MISSIONARY",
                    formationClass="FORMATION_CLASS_CIVILIAN" } },
        cities = { { id=300, x=10, y=5, religion="REL_PAGAN" } } }
    -- Reachable plots: index 6005 = (6,5) closer to the city.
    M.plots[6005] = { x=6, y=5 }
    M.reachablePlots[100] = { 6005 }
    M.install(); loadLogic()
    AutoBattle_SetConfig(MODE_AGGRESSIVE)
    runBothPasses()
    local op = firstOp(100)
    check("Missionary advances toward distant unconverted city",
        op and op.op == "MOVE_TO" and op.x == 6 and op.y == 5,
        op and (op.op .. " @" .. tostring(op.x) .. "," .. tostring(op.y)) or "no op")
end

-- -------------------------------------------------------------------------
-- 24. Missionary prioritizes OUR city over a closer foreign one
-- -------------------------------------------------------------------------
do
    M.reset(); M.localPlayerId = 0
    M.playerReligion[0] = "REL_OURS"
    M.players[0] = M.makePlayer{ id=0,
        units = { { id=100, x=5, y=5, religious=100, unitType="UNIT_MISSIONARY",
                    formationClass="FORMATION_CLASS_CIVILIAN" } },
        cities = { { id=300, x=6, y=5, religion="REL_OURS" },      -- ours, already converted (skip)
                   { id=301, x=9, y=5, religion="REL_PAGAN" } } }  -- ours, unconverted, dist 4
    M.players[1] = M.makePlayer{ id=1,
        cities = { { id=400, x=7, y=5, religion="REL_PAGAN" } } }  -- foreign, unconverted, dist 2 (closer)
    M.plots[6005]={x=6,y=5}; M.plots[8005]={x=8,y=5}
    M.reachablePlots[100] = { 6005, 8005 }
    M.install(); loadLogic()
    AutoBattle_SetConfig(MODE_AGGRESSIVE)
    runBothPasses()
    local op = firstOp(100)
    -- Should head toward OUR unconverted city (9,5) -> nearest reachable is (8,5),
    -- NOT toward the closer foreign city (7,5) -> (6,5).
    check("Missionary prefers our unconverted city over closer foreign",
        op and op.op == "MOVE_TO" and op.x == 8 and op.y == 5,
        op and (op.op .. " @" .. tostring(op.x) .. "," .. tostring(op.y)) or "no op")
end

-- -------------------------------------------------------------------------
-- 25. Missionary with no unconverted city -> holds via SLEEP (no explore --
--     Civ6's own auto-explore handles idle wandering; this mod doesn't).
-- -------------------------------------------------------------------------
do
    M.reset(); M.localPlayerId = 0
    M.playerReligion[0] = "REL_OURS"
    M.players[0] = M.makePlayer{ id=0,
        units = { { id=100, x=5, y=5, religious=100, unitType="UNIT_MISSIONARY",
                    formationClass="FORMATION_CLASS_CIVILIAN" } },
        cities = { { id=300, x=6, y=5, religion="REL_OURS" } } }  -- already ours -> no target
    M.install(); loadLogic()
    AutoBattle_SetConfig(MODE_AGGRESSIVE)
    runBothPasses()
    local op = firstOp(100)
    check("Missionary with nothing to convert holds via SLEEP",
        op and op.op == "SLEEP", op and op.op or "no op")
end

-- Helper: build an Apostle scenario. Our apostle vs optional enemy religious
-- unit + optional unconverted city.
local function apostleScenario(opts)
    M.reset(); M.localPlayerId = 0
    M.playerReligion[0] = "REL_OURS"
    local ourUnits = { { id=100, x=5, y=5, religious=110,
        unitType="UNIT_APOSTLE", promotionClass="PROMOTION_CLASS_APOSTLE",
        formationClass="FORMATION_CLASS_CIVILIAN",
        spreadCharges = opts.charges or 3 } }
    local ourCities = {}
    if opts.ownCity then table.insert(ourCities, opts.ownCity) end
    M.players[0] = M.makePlayer{ id=0, units=ourUnits, cities=ourCities }

    if opts.enemyReligious then
        M.players[1] = M.makePlayer{ id=1, units={
            { id=200, x=opts.enemyReligious.x, y=opts.enemyReligious.y, religious=100,
              unitType="UNIT_APOSTLE", promotionClass="PROMOTION_CLASS_APOSTLE",
              formationClass="FORMATION_CLASS_CIVILIAN", spreadCharges=3 } } }
        M.warMatrix["0:1"]=true; M.warMatrix["1:0"]=true
        M.combatResults["100:200"] = opts.combat or M.makeCombatResult(0,0,40,10)
    end
    if opts.reach then M.reachablePlots[100] = opts.reach end
    for idx, p in pairs(opts.plots or {}) do M.plots[idx] = p end
    if opts.fog then for k,v in pairs(opts.fog) do M.revealed[k]=v end end
    M.install(); loadLogic()
    AutoBattle_SetConfig(opts.mode)
    runBothPasses()
end

-- -------------------------------------------------------------------------
-- 26. Aggressive apostle: enemy religious unit visible -> attack
-- -------------------------------------------------------------------------
apostleScenario{ mode=MODE_AGGRESSIVE, charges=3,
    enemyReligious={x=6,y=5},                         -- adjacent enemy apostle
    ownCity={ id=300, x=9, y=5, religion="REL_PAGAN" }} -- also a spread option
do
    local op = firstOp(100)
    check("Aggressive apostle attacks when enemy religious visible",
        op and op.op == "MOVE_TO", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 27. Passive apostle: prioritizes spread even with enemy visible
-- -------------------------------------------------------------------------
apostleScenario{ mode=MODE_PASSIVE, charges=3,
    enemyReligious={x=6,y=5},
    ownCity={ id=300, x=5, y=6, religion="REL_PAGAN" }} -- adjacent unconverted city
do
    local op = firstOp(100)
    check("Passive apostle spreads even when enemy visible",
        op and op.op == "SPREAD_RELIGION", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 28. Balanced apostle: picks the CLOSER of attack vs spread (spread closer)
-- -------------------------------------------------------------------------
apostleScenario{ mode=MODE_BALANCED, charges=3,
    enemyReligious={x=10,y=5},                          -- far enemy (dist 5)
    ownCity={ id=300, x=5, y=6, religion="REL_PAGAN" }} -- adjacent city (dist 1)
do
    local op = firstOp(100)
    check("Balanced apostle picks closer target (spread)",
        op and op.op == "SPREAD_RELIGION", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 29. Last charge: never spread -> attack even in Passive
-- -------------------------------------------------------------------------
apostleScenario{ mode=MODE_PASSIVE, charges=1,
    enemyReligious={x=6,y=5},
    ownCity={ id=300, x=5, y=6, religion="REL_PAGAN" }} -- adjacent city, but last charge
do
    local op = firstOp(100)
    check("Last charge forces attack (never spread) even in Passive",
        op and op.op == "MOVE_TO", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 30. Last charge + no enemy -> holds via SLEEP (saves the charge, does not
--     spread; no explore -- Civ6's own auto-explore handles idle wandering).
-- -------------------------------------------------------------------------
apostleScenario{ mode=MODE_AGGRESSIVE, charges=1,
    ownCity={ id=300, x=5, y=6, religion="REL_PAGAN" } } -- unconverted, but last charge
do
    local op = firstOp(100)
    check("Last charge + no enemy -> holds via SLEEP (does not spread)",
        op and op.op == "SLEEP", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 31. Combat unit with no target FORTIFIES (fortify is legal for it)
-- -------------------------------------------------------------------------
scenario(
    { x=5, y=5, combat=50 },
    { x=6, y=5, combat=30 },
    nil,                                              -- no combat result -> no predictable target
    MODE_AGGRESSIVE)
do
    -- With no prediction the target is unpredictable -> holds. Combat unit -> Fortify.
    local op = firstOp(100)
    check("Combat unit holds via FORTIFY (fortify is legal)",
        op and op.op == "FORTIFY", op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 31b. Genuinely fortified unit (still ACTIVITY_HOLD, fortifyTurns>0) is
--      correctly skipped -- no ops issued at all (not even FORTIFY again).
--      The diag string now surfaces WHY, since this previously left a
--      ready-looking unit doing "nothing at all" with zero trace anywhere.
-- -------------------------------------------------------------------------
do
    M.reset(); M.localPlayerId = 0
    M.players[0] = M.makePlayer{ id=0, units={
        { id=100, x=5, y=5, combat=50, fortifyTurns=3, activityType="ACTIVITY_HOLD" } } }
    M.players[1] = M.makePlayer{ id=1, units={ { id=200, x=6, y=5, combat=30 } } }
    M.warMatrix["0:1"]=true; M.warMatrix["1:0"]=true
    M.combatResults["100:200"] = M.makeCombatResult(0,0,40,10)
    M.install(); loadLogic()
    AutoBattle_SetConfig(MODE_AGGRESSIVE)
    -- Melee-family unit: check the diag right after Run Now alone (Run Ranged,
    -- if also called, would reset m_diag/m_excluded before we can read them --
    -- matches how a real player only sees one button's diag per click anyway).
    AutoBattle_RunMelee()
    check("Genuinely fortified unit is skipped (no ops)",
        #opsFor(100) == 0, tostring(#opsFor(100)) .. " ops")
    local diag = AutoBattle_LastDiag()
    check("Fortified exclusion appears on the diag string as 'fortified'",
        diag:find("excluded: fortified 1") ~= nil, diag)
end

-- -------------------------------------------------------------------------
-- 31d. Already-used unit (0 moves, 0 attacks remaining) is skipped, and the
--      diag string reports it as "usedUp" -- distinct from "fortified"/
--      "recon"/etc, so a ready-looking unit that did nothing can be told
--      apart from one that's simply out of actions this turn.
-- -------------------------------------------------------------------------
do
    M.reset(); M.localPlayerId = 0
    M.players[0] = M.makePlayer{ id=0, units={
        { id=100, x=5, y=5, combat=50, moves=0, attacks=0 } } }
    M.players[1] = M.makePlayer{ id=1, units={ { id=200, x=6, y=5, combat=30 } } }
    M.warMatrix["0:1"]=true; M.warMatrix["1:0"]=true
    M.combatResults["100:200"] = M.makeCombatResult(0,0,40,10)
    M.install(); loadLogic()
    AutoBattle_SetConfig(MODE_AGGRESSIVE)
    AutoBattle_RunMelee()  -- see note above test 31b re: reading diag per-button
    check("Used-up unit is skipped (no ops)",
        #opsFor(100) == 0, tostring(#opsFor(100)) .. " ops")
    local diag = AutoBattle_LastDiag()
    check("Used-up exclusion appears on the diag string as 'usedUp'",
        diag:find("excluded: usedUp 1") ~= nil, diag)
end

-- -------------------------------------------------------------------------
-- 31c. Unit woken via Cancel (ACTIVITY_AWAKE) but with a STALE nonzero
--      fortifyTurns counter (GetFortifyTurns is cumulative, not a live
--      "is fortified" flag -- see IsEligibleUnit) -- must still act.
-- -------------------------------------------------------------------------
do
    M.reset(); M.localPlayerId = 0
    M.players[0] = M.makePlayer{ id=0, units={
        { id=100, x=5, y=5, combat=50, fortifyTurns=3, activityType="ACTIVITY_AWAKE" } } }
    M.players[1] = M.makePlayer{ id=1, units={ { id=200, x=6, y=5, combat=30 } } }
    M.warMatrix["0:1"]=true; M.warMatrix["1:0"]=true
    M.combatResults["100:200"] = M.makeCombatResult(0,0,40,10)
    M.install(); loadLogic()
    AutoBattle_SetConfig(MODE_AGGRESSIVE)
    runBothPasses()
    local op = firstOp(100)
    check("Woken unit with stale fortifyTurns still acts (not skipped)",
        op and op.op == "MOVE_TO" and op.x == 6 and op.y == 5,
        op and op.op or "no op")
end

-- -------------------------------------------------------------------------
-- 32. Scout (recon, Combat=10) is EXCLUDED -> no ops issued, and the exclusion
--     is now visible on the panel's diag string (previously silent/untraceable).
-- -------------------------------------------------------------------------
do
    M.reset(); M.localPlayerId = 0
    M.players[0] = M.makePlayer{ id=0, units={
        { id=100, x=5, y=5, combat=10, unitType="UNIT_SCOUT",
          promotionClass="PROMOTION_CLASS_RECON" } } }
    M.players[1] = M.makePlayer{ id=1, units={ { id=200, x=6, y=5, combat=30 } } }
    M.warMatrix["0:1"]=true; M.warMatrix["1:0"]=true
    M.combatResults["100:200"]=M.makeCombatResult(0,0,20,40)
    M.install(); loadLogic()
    AutoBattle_SetConfig(MODE_AGGRESSIVE)
    AutoBattle_RunMelee()  -- see note above test 31b re: reading diag per-button
    check("Scout (recon) is excluded from auto-battle",
        #opsFor(100) == 0, tostring(#opsFor(100)) .. " ops")
    local diag = AutoBattle_LastDiag()
    check("Scout exclusion appears on the diag string as 'recon'",
        diag:find("excluded: recon 1") ~= nil, diag)
end

-- -------------------------------------------------------------------------
-- 33. Builder (Combat=0, civilian) is EXCLUDED -> no ops issued
-- -------------------------------------------------------------------------
do
    M.reset(); M.localPlayerId = 0
    M.players[0] = M.makePlayer{ id=0, units={
        { id=100, x=5, y=5, combat=0, unitType="UNIT_BUILDER",
          formationClass="FORMATION_CLASS_CIVILIAN" } } }
    M.players[1] = M.makePlayer{ id=1, units={ { id=200, x=6, y=5, combat=30 } } }
    M.warMatrix["0:1"]=true; M.warMatrix["1:0"]=true
    M.install(); loadLogic()
    AutoBattle_SetConfig(MODE_AGGRESSIVE)
    runBothPasses()
    check("Builder (civilian) is excluded from auto-battle",
        #opsFor(100) == 0, tostring(#opsFor(100)) .. " ops")
end

-- -------------------------------------------------------------------------
-- 34. Normal warrior (combat, no recon class) is still INCLUDED
-- -------------------------------------------------------------------------
scenario(
    { x=5, y=5, combat=50, unitType="UNIT_WARRIOR" },
    { x=6, y=5, combat=30 },
    M.makeCombatResult(0, 0, 40, 10),
    MODE_AGGRESSIVE)
do
    check("Normal warrior is still included (acts)",
        #opsFor(100) > 0, tostring(#opsFor(100)) .. " ops")
end

realPrint(("=== %d passed, %d failed ==="):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
