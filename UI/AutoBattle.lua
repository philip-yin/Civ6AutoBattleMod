-- ===========================================================================
--  Auto Battle - UI panel (InGame UI context)
--
--  Draws the control panel. The auto-battle brain lives in AutoBattleLogic.lua,
--  which we include() into this SAME Lua VM, so we call its functions directly:
--
--      AutoBattle_SetConfig(enabled, mode)   -- push panel state to the brain
--      AutoBattle_RunPass() -> count         -- run one pass, returns units acted on
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

local m_enabled = false
local m_mode    = MODE_BALANCED

-- ---------------------------------------------------------------------------
--  Push current config to the brain.
-- ---------------------------------------------------------------------------
local function PushConfig()
    AutoBattle_SetConfig(m_enabled, m_mode)
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
local function OnEnableToggled()
    m_enabled = Controls.EnableCheck:IsSelected()
    PushConfig()
end

local function OnRunNow()
    -- Make sure the brain has the latest config, run one pass, show the result.
    PushConfig()
    local count = AutoBattle_RunPass() or 0
    if count > 0 then
        Controls.StatusLabel:LocalizeAndSetText("LOC_AUTOBATTLE_STATUS_RAN", count)
    else
        Controls.StatusLabel:LocalizeAndSetText("LOC_AUTOBATTLE_STATUS_IDLE")
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
    Controls.EnableCheck:RegisterCallback(Mouse.eLClick, OnEnableToggled)
    Controls.ModeAggressive:RegisterCallback(Mouse.eLClick, function() SetMode(MODE_AGGRESSIVE) end)
    Controls.ModeBalanced:RegisterCallback(Mouse.eLClick, function() SetMode(MODE_BALANCED) end)
    Controls.ModePassive:RegisterCallback(Mouse.eLClick, function() SetMode(MODE_PASSIVE) end)
    Controls.RunNowButton:RegisterCallback(Mouse.eLClick, OnRunNow)

    -- Sound feedback (optional, standard UI click sounds)
    Controls.RunNowButton:RegisterCallback(Mouse.eMouseEnter, function()
        UI.PlaySound("Main_Menu_Mouse_Over")
    end)

    -- Initialize visuals + push default config.
    Controls.EnableCheck:SetSelected(m_enabled)
    RefreshModeButtons()
    PushConfig()

    -- Fallback: also un-hide directly, in case the init handler timing differs
    -- across builds (harmless if OnInit also fires).
    ContextPtr:SetHide(false)

    print("[AutoBattle-UI] Panel initialized.")
end

Initialize()
