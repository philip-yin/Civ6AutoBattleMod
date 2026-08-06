# Auto Battle — Civ6 Mod

Adds an in-game panel with two buttons — **Run Now** and **Run Ranged** — that
each execute one pass over a different family of your **military and religious
units**, fighting and repositioning them automatically. There is no auto-run: a
pass only happens when you click one of the two buttons. Both buttons share the
same **Mode** selector (Aggressive / In-Between / Passive) and the same 6-hex
engagement gate (see below) — the two families just execute the mode
differently, per their own mechanics (melee steps/attacks adjacent; ranged
fires at distance).

**Engagement gate (all modes, both buttons):** a unit will never engage or
advance toward an enemy more than **6 hexes** away. Enemies beyond that are not
even considered candidates — visibility has no distance limit otherwise, so
without this gate a unit with nothing closer would march toward literally any
visible enemy on the map. This is a hard-coded cap, not adjustable from the panel.

## Run Now (melee / cavalry / religious)

The **Mode** selector controls melee, cavalry, and religious units
(missionaries, apostles, inquisitors).

| | Aggressive | In-Between | Passive |
|---|---|---|---|
| **Attack** | Always attack unless the preview says the unit would die | Fortify if < 50% HP, unless the attack kills | Only attack if it costs no HP, unless the attack kills |
| **Fallback** | Fortify | Fortify | Fortify |
| **Move** | Advance (full movement) to minimize distance to closest enemy | Only units > 50% HP advance | Never advance toward enemies |

The "hold" action is unit-appropriate: military units **Fortify** (defensive bonus
+ heal), but religious/civilian units can't fortify, so they **Sleep** (heal in
place) or **Skip Turn** instead.

**Target priority:** among enemies within the 6-hex engagement gate that are
currently visible, Run Now always prefers the **closest reachable** target;
among targets tied on distance, it prefers a predicted kill, then max damage,
then lowest enemy HP. (Run Ranged uses a different priority — kill > damage >
distance — described below.)

**Execution order within a Run Now pass:** melee/cavalry/religious units only
(ranged/siege/air are excluded — they belong to Run Ranged), ordered by unit ID
for determinism. Each click is one round: a unit attacks an adjacent enemy or
advances toward the closest one using its **full movement** for that turn.
Click again for the next round.

## Run Ranged (ranged / siege / air)

Ranged units (archers, crossbows, siege like catapults/trebuchets/bombards, and
air units) are handled entirely separately from Run Now, but respect the same
**Mode** selector:

- **Aggressive / In-Between** (identical behavior for ranged — mode only
  changes melee's HP/retreat rules, which don't apply here):
  1. **Shoot if already in range.**
  2. Else **move to an empty firing tile** (never swapping places with a
     friendly) that would put the target in range, and fire once the move lands.
  3. Else, if no firing tile is reachable this turn, **advance** (full
     movement) toward the target — capped at the 6-hex engagement gate — to
     close the distance for a future turn.
  4. Only if none of the above is possible does the unit **hold**.
- **Passive:** fire **only if already in range** (step 1 above) — no
  repositioning, no advancing, ever. A target outside firing range this turn is
  simply held on, mirroring melee's Passive "never advance toward enemies" rule.

Target ranking is **kill > damage > distance**, computed separately for targets
already in range vs. everything else — an in-range target is always preferred
over repositioning. There is no HP/safety gate: if a shot is available, it is
taken (ranged attacks normally draw no retaliation). Air units are a further
exception on top of Passive: they only ever strike-in-range or hold in **any**
mode — they never path across tiles at all (rebasing is a strategic `DEPLOY`
choice left to you), so steps 2/3 above never apply to them.

**Which units the mod controls:** any unit with combat, ranged, or religious
strength — **except recon units** (Scout/Skirmisher/Ranger), which are excluded
so a weak Scout isn't thrown into a losing fight (leave them on your own explore
orders). Civilians (Builder, Settler, Trader, Great People, Spy, etc.) have zero
combat strength and are naturally skipped. Unknown/modded combat units are
included by default.

**Domains supported:**

- **Land** — melee, ranged, siege, cavalry, religious, support. Full support.
- **Sea** — melee ships (`MOVE_TO`+attack) and ranged/bombard ships
  (`RANGE_ATTACK`). Bombard-strength ships are correctly treated as ranged.
  (Coastal-raid auto-pillage is not automated.)
- **Air** — fighters/bombers strike in range via `AIR_ATTACK` and otherwise hold.
  They never advance or rebase (`DEPLOY` is a strategic choice left to you), so
  an air unit only attacks a target already within its operational range —
  unlike ground ranged units, an out-of-range enemy never makes an air unit
  reposition.

**Religious units:**

- **Missionaries / Gurus** (spread-only, no combat) get dedicated behavior in all
  modes: move to the nearest **unconverted** city — **our own cities first**, then
  foreign/neutral — and **Spread Religion** when adjacent. If no unconverted city
  is visible, they **hold** (Civ6's own auto-explore handles idle wandering —
  this mod doesn't duplicate it). "Unconverted" = the city's majority religion
  isn't the one we founded.

- **Apostles** can **both attack** (religious combat vs. enemy religious units)
  **and spread** religion. Which they prioritize depends on the mode:

  | Mode | Apostle priority |
  |------|------------------|
  | Aggressive | **Attack** if an enemy religious unit is visible; else spread |
  | Passive | **Spread** always; attack only if nothing to spread |
  | In-Between | Whichever target (attack or spread) is **closer** |

  **Last-charge rule (all modes):** an Apostle on its **final spread charge**
  never spreads — it prioritizes **attack** instead (using aggressive combat
  rules so the forced attack isn't cancelled), and if there's no enemy to attack
  it **holds** to save the charge for you to spend manually. Apostle attacks
  otherwise use the same suicide/HP safety gates as military units.

- **Inquisitors** carry a combat promotion class and fight via the normal combat
  pipeline (they don't get the spread-priority behavior).

## Install (macOS)

1. Quit Civilization VI if it's running.
2. Copy the whole `Civ6AutoBattleMod` folder into your Mods directory.

   The exact path depends on the build. The modern Epic/Aspyr build nests the
   folder and keeps its live data (`Mods`, `Saves`, `ModUserData`) under an
   **inner** folder of the same name:

   ```
   ~/Library/Application Support/Sid Meier's Civilization VI/Sid Meier's Civilization VI/Mods/
   ```

   Older Steam/App Store builds use the single (non-nested) path:

   ```
   ~/Library/Application Support/Sid Meier's Civilization VI/Mods/
   ```

   If unsure which is live, find the one whose `Mods`/`Saves` were modified
   recently:

   ```sh
   mdfind -name "Mods" | grep -i "Civilization VI"
   ```

   Then copy (adjust the destination to whichever Mods dir is live):

   ```sh
   cp -R "/Users/jyin1/Desktop/Personal/VI/Civ6AutoBattleMod" \
     "$HOME/Library/Application Support/Sid Meier's Civilization VI/Sid Meier's Civilization VI/Mods/"
   ```

3. Launch Civ VI → **Additional Content** (main menu) → **Mods** → enable
   **Auto Battle** → **Back** (it will reload) → start or load a game.

## Use

- A small **Auto Battle** panel is docked bottom-right, just above the End Turn
  button. Click its title bar's toggle to minimize/expand the body.
- Pick a mode: **Aggressive / In-Between / Passive** (highlighted = active;
  labeled "Melee Mode" on the panel, but it governs both buttons — see above).
- **Run Now** executes one melee/cavalry/religious pass immediately, using the
  selected mode.
- **Run Ranged** executes one ranged/siege/air pass immediately, using the same
  selected mode (see the Run Ranged section above for how each mode differs).
- There is no auto-run: nothing happens at turn start except clearing any
  pending ranged shot from last turn — every pass is a manual button click.
- The status line shows a breakdown of the last pass's outcome (e.g.
  `fired 2 | moved 1 | held 1`) so you can tell at a glance whether units
  actually acted.

## Debugging (important — first-run API check)

Civ6's Lua combat/operation API names shift slightly between game patches. This
mod is written defensively: every risky call is wrapped and logged rather than
crashing. If units don't act the way you expect, read the log.

**Which logs you get depends on the build:**

- **`Modding.log`** is written by every build and needs no flag. It records
  mod discovery, enable state, and component load (text/import/UI). This is the
  first place to look for load-time problems — a rejected text file or a mod
  that never enabled shows up here. Find the live one (the nested inner folder
  on the Aspyr/Epic build):

  ```sh
  mdfind -name "Modding.log" | grep -i "Civilization VI"
  ```

- **`Lua.log`** (the per-unit `[AutoBattle]` runtime trace below) is produced
  only when Lua logging is enabled. On older **Steam/App Store** builds, set
  `LoggingEnabled 1` in `AppOptions.txt` and it appears under `.../Logs/Lua.log`.
  The modern **Epic/Aspyr** build has no `LoggingEnabled` key in `AppOptions.txt`
  and does not write `Lua.log` to that user folder — don't chase it there. If you
  need runtime tracing on that build, search for it after a run:

  ```sh
  mdfind -name "Lua.log"
  ```

Runtime lines are prefixed `[AutoBattle]`; if you locate a `Lua.log`, filter with
`grep AutoBattle`.

### Two log levels

- **Always on** — lifecycle, warnings, errors, and a one-line summary per pass
  (`pass complete: acted on N unit(s), skipped M ...`).
- **`[AutoBattle][dbg]` per-unit tracing** — controlled by the `DEBUG` flag at the
  top of `UI/AutoBattleLogic.lua` (defaults **on** for initial testing). Set it to
  `false` once things work to quiet the log.

### What a healthy startup looks like

```
[AutoBattle] logic loading...
[AutoBattle] hooked LocalPlayerTurnBegin (clears pending shots; no auto-run).
[AutoBattle] hooked UnitMoveComplete (ranged move-then-fire).
[AutoBattle] AutoBattle logic loaded OK.
[AutoBattle] combat predictor = CombatManager.SimulateAttackVersus
```

### A per-unit decision trace (DEBUG on) reads like

```
[AutoBattle][dbg] processing u#100 UNIT_WARRIOR @(5,5) hp=100% [melee]
[AutoBattle][dbg]   2 candidate target(s) in view
[AutoBattle][dbg]   target unit @(7,5) dist=2 | pred: defRemain=-50 atkRemain=90 dmgToDef=60 dmgToUs=10
[AutoBattle][dbg]   decision: advance
[AutoBattle][dbg]     op MoveTo issued unit=100 -> (6,5)
```

That tells you, for each unit: what it is, how many targets it saw, which target
it chose with the full combat prediction (`defRemain`/`atkRemain` = predicted HP
left for defender/attacker; `<=0` means dead), the decision, and the exact
operation issued. **If a unit ever does something unexpected, this is the answer.**

### Key lines to look for (and what they mean)

- `combat predictor = CombatManager.SimulateAttackVersus` — the real combat API
  resolved (good). If instead you see `...strength heuristic fallback`, attacks
  still work but decisions use an approximation; send me that line.
- `op <name> SKIPPED (CanStartOperation=false)` — the engine refused an operation
  (e.g. can't attack from there). Expected occasionally; if a unit *never* acts,
  this is why — paste the surrounding trace.
- `op <name> FAILED` / `call failed (...)` — an API/param mismatch for your patch.
  Paste these; I'll fix the call.
- `game core busy; deferring pass.` — a Run Now/Run Ranged click was skipped
  because the engine was busy. Rare; just click the button again.
- `pending shot skipped: ... out of range after move` — a ranged unit repositioned
  but couldn't reach its target to fire. Expected sometimes; frequent = the
  firing-plot math needs a look.
- `hooked UnitMoveComplete` — confirms ranged move-then-fire is wired. The
  warning form means ranged units will move but not auto-fire the same turn.

## File layout

```
Civ6AutoBattleMod/
├── Civ6AutoBattleMod.modinfo     Manifest (what loads, when)
├── Text/AutoBattle_Text.xml      Localized strings
├── UI/AutoBattleLogic.lua        The brain (targeting, combat, movement)
├── UI/AutoBattle.xml             Panel layout
├── UI/AutoBattle.lua             Panel logic (include()s the brain)
└── README.md
```

Both Lua files load into the **same InGame UI context** (via `ImportFiles`);
`AutoBattle.lua` does `include("AutoBattleLogic")` and calls its functions
directly. The brain lives in the UI context on purpose — that is where
`CombatManager`, `UnitManager`, and `PlayersVisibility` are bound. (A separate
gameplay-script Lua state would not have those APIs, nor share globals with the
panel.)

## Known limitations / next steps

- "Optimal target" is a heuristic (kill-first, then max-damage, distance as
  tie-breaker) over enemies within the 6-hex engagement gate. It doesn't do
  multi-turn strategic planning.
- Ranged **move-then-attack** is event-driven: the unit moves to its firing plot
  this pass and fires on arrival (via `UnitMoveComplete`). If that event name
  differs on your patch, the unit still moves but won't fire until the next pass
  (the log will say so).
- When a ranged unit's target is out of movement+range entirely (no firing plot
  reachable this turn) in Aggressive/In-Between, it advances toward the target
  with full movement instead of holding — same as melee's advance, but
  ground-only: air units still only strike-in-range or hold in any mode, since
  they don't path across tiles. Passive skips this entirely (fire only, never
  reposition/advance).
- Religious combat uses the same target/decision pipeline; if the combat
  predictor doesn't model religious strength on your build, the fallback
  heuristic handles it (watch the log).
- No idle-exploration behavior: units with nothing to attack/spread simply
  hold. Civ6's own auto-explore automation handles wandering scouts/idle units
  — this mod intentionally doesn't duplicate it.
- No custom art/icons yet — panel uses stock UI styles.
