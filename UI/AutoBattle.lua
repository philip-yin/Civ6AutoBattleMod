-- ===========================================================================
--  Auto Battle - UI panel (InGame UI context)
--
--  Draws the control panel. The auto-battle brain lives in AutoBattleLogic.lua,
--  which we include() into this SAME Lua VM, so we call its functions directly:
--
--      AutoBattle_SetConfig(mode)             -- push selected mode to the brain
--      AutoBattle_RunMelee() -> count         -- run melee/cav/religious pass
--      AutoBattle_RunRanged() -> count        -- run ranged/siege/air pass
--
--  (Both files run in the InGame UI context, where CombatManager / UnitManager /
--  PlayersVisibility are bound. No LuaEvents bridge is needed because there is
--  no separate Lua state to cross.)
-- ===========================================================================

include("AutoBattleLogic")

print("[AutoBattle-UI] Panel loading...")

local MODE_AGGRESSIVE = 1
local MODE_BALANCED   = 2
local MODE_PASSIVE    = 3

local m_mode = MODE_BALANCED

-- ---------------------------------------------------------------------------
--  Push current config (just the mode) to the brain. The mod is Run-Now-only:
--  there is no auto-run at turn start, so no enable flag.
-- ---------------------------------------------------------------------------
local function PushConfig()
    AutoBattle_SetConfig(m_mode)
end

-- ---------------------------------------------------------------------------
--  Visual feedback for the selected mode (highlight the active button).
-- ---------------------------------------------------------------------------
local function RefreshModeButtons()
    -- SetSelected gives a pressed/highlighted look on GridButton.
    Controls.ModeAggressive:SetSelected(m_mode == MODE_AGGRESSIVE)
    Controls.ModeBalanced:SetSelected(m_mode == MODE_BALANCED)
    Controls.ModePassive:SetSelected(m_mode == MODE_PASSIVE)
end

local function SetMode(mode)
    m_mode = mode
    RefreshModeButtons()
    PushConfig()
end

-- ---------------------------------------------------------------------------
--  Handlers
-- ---------------------------------------------------------------------------
-- Hard-wrap: insert a line break every 20 characters, regardless of word
-- boundaries. Requested for the debug diag text, which can otherwise run past
-- the panel's WrapWidth as one long unbroken line (e.g. long "excluded: ..."
-- breakdowns) since it's plain text, not word-wrapped loc content.
-- IMPORTANT: Civ6's text rendering uses the literal markup tag "[NEWLINE]" for
-- line breaks in SetText -- a raw "\n" byte is not recognized as whitespace by
-- the font/glyph pipeline and renders as a garbage placeholder glyph instead.
local function HardWrap(s, chunkSize)
    local parts = {}
    for i = 1, #s, chunkSize do
        table.insert(parts, s:sub(i, i + chunkSize - 1))
    end
    return table.concat(parts, "[NEWLINE]")
end

-- Update the status line from a pass result (units acted on). Since this build
-- doesn't write Lua.log, we also append the brain's per-pass outcome breakdown
-- (fired / moved / refused / no target / held) so a failure is diagnosable
-- in-game, right on the panel, with no log file.
local function ShowResult(count)
    local diag = ""
    if AutoBattle_LastDiag ~= nil then diag = AutoBattle_LastDiag() or "" end

    if diag ~= "" then
        -- Show the raw breakdown, hard-wrapped every 20 characters.
        Controls.StatusLabel:SetText(HardWrap(diag, 20))
    elseif (count or 0) > 0 then
        Controls.StatusLabel:LocalizeAndSetText("LOC_AUTOBATTLE_STATUS_RAN", count)
    else
        Controls.StatusLabel:LocalizeAndSetText("LOC_AUTOBATTLE_STATUS_IDLE")
    end
end

-- "Run Now": melee/cav/religious units, per the selected Melee Mode.
local function OnRunMelee()
    PushConfig()   -- push current mode to the brain
    ShowResult(AutoBattle_RunMelee() or 0)
end

-- "Run Ranged": ranged/siege/air units. Fixed shoot-or-wait behavior (no mode).
local function OnRunRanged()
    ShowResult(AutoBattle_RunRanged() or 0)
end

-- ---------------------------------------------------------------------------
--  Minimize / expand: collapse the body to just the title bar. State is kept in
--  m_minimized; the title bar (and its toggle button) stay visible either way.
-- ---------------------------------------------------------------------------
local m_minimized = false

local function RefreshMinimizeState()
    -- The panel is bottom-anchored (docked above End Turn) with the title bar at
    -- its TOP, so to keep the title bar fixed when minimizing we DON'T resize the
    -- root (resizing a bottom-anchored control moves its top edge). We just hide
    -- the body; the title bar holds its position. No leftover click-catcher: the
    -- root/body are plain Containers (no ConsumeMouse), so the only click targets
    -- are the buttons/backgrounds inside BodyContainer, which are hidden too.
    Controls.BodyContainer:SetHide(m_minimized)
end

local function OnToggleMinimize()
    m_minimized = not m_minimized
    RefreshMinimizeState()
    UI.PlaySound("Main_Menu_Mouse_Over")
end

-- ---------------------------------------------------------------------------
--  Auto-hide under fullscreen popups. The base game broadcasts *_Shown/*_Closed
--  LuaEvents when big screens open (diplomacy, fullscreen map, natural wonder,
--  etc.). We hide the whole context while any are up and restore afterward, so
--  the panel never sits on top of a popup. A counter handles overlapping popups.
-- ---------------------------------------------------------------------------
local m_popupDepth = 0

local function OnPopupShown()
    m_popupDepth = m_popupDepth + 1
    ContextPtr:SetHide(true)
end

local function OnPopupClosed()
    m_popupDepth = m_popupDepth - 1
    if m_popupDepth < 0 then m_popupDepth = 0 end
    if m_popupDepth == 0 then
        ContextPtr:SetHide(false)
    end
end

-- ---------------------------------------------------------------------------
--  Init
--
--  CRITICAL: panels added via <AddUserInterfaces> are loaded HIDDEN by the base
--  game (InGame.lua LoadNewContext with isHidden=true) and are never un-hidden
--  automatically. So the panel MUST show itself, via ContextPtr:SetHide(false)
--  in the init handler -- otherwise it loads but stays invisible.
-- ---------------------------------------------------------------------------

-- Fires when the context is attached to the HUD.
local function OnInit(isReload)
    ContextPtr:SetHide(false)   -- REQUIRED: mod contexts load hidden
    print("[AutoBattle-UI] Panel shown (OnInit).")
end

local function Initialize()
    -- Show the panel once the context is attached.
    ContextPtr:SetInitHandler(OnInit)

    -- Button wiring
    Controls.ModeAggressive:RegisterCallback(Mouse.eLClick, function() SetMode(MODE_AGGRESSIVE) end)
    Controls.ModeBalanced:RegisterCallback(Mouse.eLClick, function() SetMode(MODE_BALANCED) end)
    Controls.ModePassive:RegisterCallback(Mouse.eLClick, function() SetMode(MODE_PASSIVE) end)
    Controls.RunNowButton:RegisterCallback(Mouse.eLClick, OnRunMelee)
    Controls.RunRangedButton:RegisterCallback(Mouse.eLClick, OnRunRanged)
    Controls.MinimizeButton:RegisterCallback(Mouse.eLClick, OnToggleMinimize)

    -- Sound feedback (optional, standard UI click sounds)
    Controls.RunNowButton:RegisterCallback(Mouse.eMouseEnter, function()
        UI.PlaySound("Main_Menu_Mouse_Over")
    end)
    Controls.RunRangedButton:RegisterCallback(Mouse.eMouseEnter, function()
        UI.PlaySound("Main_Menu_Mouse_Over")
    end)

    -- Auto-hide under fullscreen popups. Guard each hook (event may be absent on
    -- some builds); harmless if a given popup type never fires.
    if LuaEvents ~= nil then
        local shown = {
            LuaEvents.DiplomacyActionView_Show, LuaEvents.FullscreenMap_Shown,
            LuaEvents.NaturalWonderPopup_Shown, LuaEvents.ProjectBuiltPopup_Shown,
            LuaEvents.EndGameMenu_Shown,
        }
        local closed = {
            LuaEvents.DiplomacyActionView_Hide, LuaEvents.FullscreenMap_Closed,
            LuaEvents.NaturalWonderPopup_Closed, LuaEvents.ProjectBuiltPopup_Closed,
            LuaEvents.EndGameMenu_Closed,
        }
        for _, ev in ipairs(shown)  do if ev ~= nil then ev.Add(OnPopupShown)  end end
        for _, ev in ipairs(closed) do if ev ~= nil then ev.Add(OnPopupClosed) end end
    end

    -- Initialize visuals + push default config.
    RefreshModeButtons()
    RefreshMinimizeState()
    PushConfig()

    -- Fallback: also un-hide directly, in case the init handler timing differs
    -- across builds (harmless if OnInit also fires).
    ContextPtr:SetHide(false)

    print("[AutoBattle-UI] Panel initialized.")
end

Initialize()
