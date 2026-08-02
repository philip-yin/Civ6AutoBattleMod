# Auto Battle — Civ6 Mod

Adds an in-game panel that makes your **military and religious units** fight and
reposition automatically, with three behavior modes.

## Modes

| | Aggressive | In-Between | Passive |
|---|---|---|---|
| **Attack** | Always attack unless the preview says the unit would die | Fortify if < 50% HP, unless the attack kills | Only attack if it costs no HP, unless the attack kills (melee rarely attacks) |
| **Fallback** | Fortify + heal | Fortify | Fortify |
| **Move** | Advance to minimize distance to closest enemy | Only units > 50% HP advance | Never advance toward enemies |
| **Ranged** | Attack in range; else move+attack; else advance | If move+attack possible, move to **max range** then fire | Fire only (no advance) |

The "hold" action is unit-appropriate: military units **Fortify** (defensive bonus
+ heal), but religious/civilian units can't fortify, so they **Sleep** (heal in
place) or **Skip Turn** instead.

**Target priority (all modes):** among **all currently-visible** enemies (any
enemy on a tile your civ can see — no distance limit; fogged enemies are
ignored), kill a target if possible; otherwise hit the target you deal the most
damage to. **Distance breaks ties** — a closer enemy is preferred when two
targets are otherwise equal. Priority order: **kill > damage > distance**.

**Execution order within a pass (one round per Run Now):** ranged (archers,
crossbows) + air → siege (catapult, trebuchet, bombard) → melee/cavalry/religious
→ support (medics, rams, towers). Ranged/siege fire **first** — in place, or
repositioning only to an **empty** tile (never swapping places with a friendly);
then melee attack an adjacent enemy or **step one tile** toward the target (in
Aggressive/Balanced), so ranged fire ahead of the closing line. Support
repositions last. Ties within a bucket are ordered by unit ID for determinism.
Each Run Now is one such round; click again for the next.

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
  They never auto-advance or rebase (`DEPLOY` is a strategic choice left to you),
  so an air unit only attacks a target already within its operational range.

**Religious units:**

- **Missionaries / Gurus** (spread-only, no combat) get dedicated behavior in all
  modes: move to the nearest **unconverted** city — **our own cities first**, then
  foreign/neutral — and **Spread Religion** when adjacent. If no unconverted city
  is visible, they **explore** toward the nearest unrevealed tile (fog edge).
  "Unconverted" = the city's majority religion isn't the one we founded.

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
  it **explores** to save the charge for you to spend manually. Apostle attacks
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

- A small **Auto Battle** panel appears at the top-right of the in-game HUD.
- Tick **Enable Auto Battle** to run automatically at the start of each of your
  turns.
- Pick a mode: **Aggressive / In-Between / Passive** (highlighted = active).
- **Run Now** executes one pass immediately, regardless of the Enable toggle.

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
[AutoBattle] hooked LocalPlayerTurnBegin.
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
- `game core busy; deferring pass.` — a pass was skipped because the engine was
  busy. Rare; if you see it at turn start, that turn's auto-run was skipped.
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
  tie-breaker) over all visible enemies. It doesn't do multi-turn strategic
  planning, and it will send units to advance toward any visible enemy — a
  rear-line unit may march toward a distant foe rather than hold position.
- Ranged **move-then-attack** is event-driven: the unit moves to its firing plot
  this pass and fires on arrival (via `UnitMoveComplete`). If that event name
  differs on your patch, the unit still moves but won't fire until the next pass
  (the log will say so).
- Religious combat uses the same target/decision pipeline; if the combat
  predictor doesn't model religious strength on your build, the fallback
  heuristic handles it (watch the log).
- No custom art/icons yet — panel uses stock UI styles.
```
