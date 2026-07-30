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

**Target priority (all modes):** among **all currently-visible** enemies (any
enemy on a tile your civ can see — no distance limit; fogged enemies are
ignored), kill a target if possible; otherwise hit the target you deal the most
damage to. **Distance breaks ties** — a closer enemy is preferred when two
targets are otherwise equal. Priority order: **kill > damage > distance**.

**Execution order within a pass:** melee/cavalry/religious → ranged (archers,
crossbows) → siege (catapult, trebuchet, bombard) → support (medics, rams,
towers). Melee open the fight and take tiles, ranged fire into softened targets,
siege bombard (especially cities), support reposition last. Ties within a bucket
are ordered by unit ID for determinism.

## Install (macOS)

1. Quit Civilization VI if it's running.
2. Copy the whole `Civ6AutoBattleMod` folder into your Mods directory:

   ```
   ~/Library/Application Support/Sid Meier's Civilization VI/Mods/
   ```

   You can do it from Terminal:

   ```sh
   cp -R "/Users/jyin1/Desktop/VI/Civ6AutoBattleMod" \
     "$HOME/Library/Application Support/Sid Meier's Civilization VI/Mods/"
   ```

3. Launch Civ VI → **Additional Content** (main menu) → **Mods** → enable
   **Auto Battle** → **Back** (it will reload) → start or load a game.

> The mod declares dependencies on the two expansions (Rise & Fall, Gathering
> Storm). If you don't own them, open `Civ6AutoBattleMod.modinfo` and delete the
> two `<Mod .../>` lines inside `<Dependencies>`.

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

**Enable logging** — in
`~/Library/Application Support/Sid Meier's Civilization VI/AppOptions.txt`
set:

```
EnableTuner 1
```

**Log file location:**

```
~/Library/Application Support/Sid Meier's Civilization VI/Logs/Lua.log
```

Search it for `[AutoBattle]` (gameplay) and `[AutoBattle-UI]` (panel). Key lines
to look for:

- `combat predictor = ...` — tells you which prediction API resolved. If you see
  `no combat predictor found ... strength heuristic fallback`, attacks still work
  but use an approximation; send me that line and I'll wire the correct call.
- `call failed (RangeAttack): ...` / `call failed (MoveTo): ...` — an operation
  name mismatch for your patch. Paste these to me and I'll fix the constant.
- `hooked UnitMoveComplete` — confirms ranged move-then-fire is active. If you
  see the warning instead, ranged units will reposition but not auto-fire the
  same turn on your patch.
- `call failed (IsVisible): ...` — the visibility API differs on your patch; the
  mod falls back to targeting all enemies regardless of fog. Paste it and I'll
  fix the query.

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
