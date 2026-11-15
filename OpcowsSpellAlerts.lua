-- Opcow's Spell Alerts: a spell's icon pops up, with a sound, when one of your alerts is true:
--   usable: the spell can be cast now, ex: Riposte after a parry
--   combo: the spell is usable and the target has at least N combo points, ex: Eviscerate at 5
--   debuff: your debuff has fallen off the target you're fighting, ex: Rupture
--
-- Forever blocks the combat log and makes auras secret in combat, so each alert reads what it can.
-- A debuff is read directly when that works, else through the Cooldown Manager when it tracks
-- the debuff, else timed from your cast. /osa probe prints which reads work.

local OSA = {}
_G.OpcowsSpellAlerts = OSA

-- icon size when the size option is 0
local SIZE = 48
-- between icons
local GAP = 6
-- how often active timers and cooldowns are checked, in seconds
local TICK = 0.1
-- the same alert's sound doesn't play again sooner than this
local SOUND_GAP = 1.5
-- a cooldown this short or shorter is the global cooldown, which doesn't stop an alert
local GCD = 1.5
-- an alert shown only for a while fades in over this many seconds, and out over a third of its
-- time, at most this many
local FADE_IN = 0.3
local FADE_OUT = 1
-- sounds by name. The kit's SOUNDKIT name is used when it exists, else the number.
local SOUNDS = {
    { name = "ping", kit = "MAP_PING", id = 3175 },
    { name = "raid", kit = "RAID_WARNING", id = 8959 },
    { name = "ready", kit = "READY_CHECK", id = 8960 },
    { name = "alarm", kit = "ALARM_CLOCK_WARNING_3", id = 12889 },
}
-- what an alert does while the spell waits on energy, rage or mana: show it, dim it or hide it
local POWER_MODES = { "show", "dim", "hide" }
-- the alpha of a dimmed icon
local DIM = 0.45
-- the conditions an alert can be hidden by, as in Buff Reminder. Each alert's conds[key] is
-- 0 = ignored, 1 = hide the icon while true, 2 = hide the icon while false.
local CONDITIONS = { "dead", "instance", "party", "raid", "resting", "taxi", "combat", "mounted",
    "target", "enemy", "friendly", "fireTotem", "earthTotem", "waterTotem", "airTotem" }
local DEFAULT_CONDS = { dead = 1, taxi = 1, mounted = 1 }
-- the totem conditions: [key] = { totem slot, element as spell descriptions name it }
local TOTEMS = {
    fireTotem = { FIRE_TOTEM_SLOT or 1, "fire" }, earthTotem = { EARTH_TOTEM_SLOT or 2, "earth" },
    waterTotem = { WATER_TOTEM_SLOT or 3, "water" }, airTotem = { AIR_TOTEM_SLOT or 4, "air" },
}
-- set below, the default for a totem condition from the spell's description, nil when unknown
local TotemDefault

local issecretvalue = issecretvalue or function() return false end

-- an alert's conditions, filled in with the defaults where missing or invalid
local function Conds(a)
    if type(a.conds) ~= "table" then a.conds = {} end
    for _, k in ipairs(CONDITIONS) do
        local c = a.conds[k]
        if c ~= 0 and c ~= 1 and c ~= 2 then
            if TOTEMS[k] then
                -- left unset until the description can be read
                a.conds[k] = TotemDefault and TotemDefault(a, k) or nil
            else
                a.conds[k] = DEFAULT_CONDS[k] or 0
            end
        end
    end
    return a.conds
end

local function DB()
    OpcowsSpellAlertsDB = OpcowsSpellAlertsDB or {}
    local db = OpcowsSpellAlertsDB
    db.alerts = db.alerts or {}
    -- each alert's id names its place in the icon sets, so it stays when the list is reordered
    if type(db.nextId) ~= "number" then db.nextId = 1 end
    local ids = {}
    for _, a in ipairs(db.alerts) do
        if type(a.id) == "number" and not ids[a.id] then
            ids[a.id] = true
            db.nextId = math.max(db.nextId, a.id + 1)
        else
            a.id = nil
        end
    end
    for _, a in ipairs(db.alerts) do
        Conds(a)
        -- 0.7 and before saved when the sound last played
        a.soundAt = nil
        if not a.id then
            a.id, db.nextId = db.nextId, db.nextId + 1
        end
        -- its own icon size, nil = the default
        if type(a.size) ~= "number" or a.size < 10 or a.size > 200 then a.size = nil end
    end
    -- [lower case spell name] = { [combo points at the cast] = seconds }, debuff lengths read from
    -- the aura when it could be read
    db.learned = db.learned or {}
    if type(db.size) ~= "number" or db.size < 0 then db.size = 0 end
    -- the minimap button: angle around the minimap, hidden
    if type(db.minimap) ~= "table" then db.minimap = {} end
    return db
end

local function Print(text)
    print("|cff33ff99Spell Alerts:|r " .. text)
end

local function Debug(text)
    if DB().debug then print("|cff999999Spell Alerts: " .. text .. "|r") end
end

local function Num(v)
    if type(v) == "number" and not issecretvalue(v) then return v end
    return nil
end

-- a readable boolean, or nil when it's secret or not a boolean. 1/0 count as true/false.
local function Bool(v)
    if issecretvalue(v) then return nil end
    if type(v) == "boolean" then return v end
    if v == 1 then return true end
    if v == 0 or v == nil then return false end
    return nil
end

local function Str(v)
    if type(v) == "string" and not issecretvalue(v) then return v end
    return nil
end

-- what a value is, for the probe
local function Show(v)
    if issecretvalue(v) then return "secret" end
    return tostring(v)
end

-- spellbook --------------------------------------------------------------------------------------

local function SpellName(id)
    if not (C_Spell and C_Spell.GetSpellName) then return nil end
    local ok, n = pcall(C_Spell.GetSpellName, id)
    return ok and Str(n) or nil
end

local function SpellIcon(id)
    if not (C_Spell and C_Spell.GetSpellTexture) then return nil end
    local ok, icon = pcall(C_Spell.GetSpellTexture, id)
    if ok and not issecretvalue(icon) then return icon end
    return nil
end

-- [lower case name] = { name = name as written, id = highest rank's id } for every spell in your
-- spellbook. Cleared when the spellbook changes.
local book

local function Book()
    if book then return book end
    book = {}
    if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines) then return book end
    local ok, err = pcall(function()
        local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
        local future = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.FutureSpell
        for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
            if info then
                for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                    local item = C_SpellBook.GetSpellBookItemInfo(i, bank)
                    local id, n = item and Num(item.spellID), item and Str(item.name)
                    if id and n and not (future and item.itemType == future) then
                        local key = n:lower()
                        -- later items are higher ranks; keep the highest id seen as a tiebreak
                        local e = book[key]
                        if not e or id > e.id then book[key] = { name = n, id = id } end
                    end
                end
            end
        end
    end)
    if not ok then Debug("reading the spellbook failed: " .. tostring(err)) end
    return book
end

-- an alert's spell id (your highest rank), or nil when it isn't in your spellbook
local function AlertSpell(a)
    local e = Book()[a.spell:lower()]
    return e and e.id or nil
end

-- spells such as Fire Nova that need a totem of the element down: "your Fire totem" in the
-- description of a spell that isn't itself a totem. Hide those while the totem isn't down.
TotemDefault = function(a, k)
    if not (C_Spell and C_Spell.GetSpellDescription) then return 0 end
    local id = AlertSpell(a)
    if not id then return nil end
    local ok, d = pcall(C_Spell.GetSpellDescription, id)
    d = ok and Str(d)
    if not d or d == "" then return nil end
    if a.spell:lower():find("totem") then return 0 end
    return d:lower():find(TOTEMS[k][2] .. " totem") and 2 or 0
end

local function KeyOf(spellID)
    local n = Num(spellID) and SpellName(spellID)
    return n and n:lower() or nil
end

-- game state -------------------------------------------------------------------------------------

local function ComboPoints()
    if GetComboPoints then
        local ok, n = pcall(GetComboPoints, "player", "target")
        if ok then return n end
    end
    if UnitPower and Enum and Enum.PowerType and Enum.PowerType.ComboPoints then
        local ok, n = pcall(UnitPower, "player", Enum.PowerType.ComboPoints)
        if ok then return n end
    end
    return nil
end

-- true when you have a living target you can attack
local function Attackable()
    if not Bool(UnitExists("target")) then return false end
    local ok, can = pcall(UnitCanAttack, "player", "target")
    if not ok or Bool(can) ~= true then return false end
    local dok, dead = pcall(UnitIsDead, "target")
    return not (dok and Bool(dead) == true)
end

local function TargetGUID()
    local ok, g = pcall(UnitGUID, "target")
    return ok and Str(g) or nil
end

local function InCombat()
    return InCombatLockdown() or Bool(UnitAffectingCombat("player")) == true
end

-- [condition] = true or false right now, for the conditions. A read the game hides keeps the
-- last value.
local status = {}

local function Flag(key, fn, ...)
    if not fn then return end
    local ok, v = pcall(fn, ...)
    if ok and not issecretvalue(v) then status[key] = v and true or false end
end

local function UpdateStatus()
    Flag("dead", UnitIsDeadOrGhost, "player")
    Flag("party", IsInGroup)
    Flag("raid", IsInRaid)
    Flag("resting", IsResting)
    Flag("taxi", UnitOnTaxi, "player")
    Flag("mounted", IsMounted)
    status.combat = InCombat() and true or false
    -- the target: any, a living one you can attack, a friendly one
    local exists = Bool(UnitExists("target"))
    if exists ~= nil then
        status.target = exists
        status.enemy = exists and Attackable() or false
        if not exists then status.friendly = false else Flag("friendly", UnitIsFriend, "player", "target") end
    end
    if IsInInstance then
        local ok, _, kind = pcall(IsInInstance)
        if ok and not issecretvalue(kind) then status.instance = kind == "party" end
    end
    if GetTotemInfo then
        for k, t in pairs(TOTEMS) do
            local ok, have, name = pcall(GetTotemInfo, t[1])
            if ok and not issecretvalue(have) and not issecretvalue(name) then
                status[k] = (have and name ~= nil and name ~= "") and true or false
            end
        end
    end
end

-- true when one of the alert's conditions hides it
local function Suppressed(a)
    local conds = Conds(a)
    for _, k in ipairs(CONDITIONS) do
        local v, c = status[k], conds[k]
        if (v and c == 1) or (not v and c == 2) then return true end
    end
    return false
end

-- the spell's usability and whether only power is missing, either may be secret
local function RawUsable(id)
    if C_Spell and C_Spell.IsSpellUsable then
        local ok, u, noPower = pcall(C_Spell.IsSpellUsable, id)
        if ok then return u, noPower end
    end
    if IsUsableSpell then
        local ok, u, noPower = pcall(IsUsableSpell, id)
        if ok then return u, noPower end
    end
    return nil
end

-- whether the spell could be cast but for energy, rage or mana: true, false, or nil with the
-- game's secret boolean as the third value. The second value is true when only power is missing,
-- ex: Riposte after a parry, or 5 combo points with 20 energy.
local function Usable(id)
    local u, noPower = RawUsable(id)
    if Bool(noPower) == true then return true, true end
    if issecretvalue(u) then return nil, false, u end
    return Bool(u) == true, false
end

-- an alert whose criterion is met, by its power setting: shown, shown dimmed or hidden while the
-- spell waits on power
local function PowerRule(a, short)
    if not short then return true end
    local mode = a.power or "dim"
    if mode == "hide" then return false end
    if mode == "dim" then return true, nil, true end
    return true
end

-- your energy, rage or mana, or nil when the game hides it
local function PlayerPower()
    local ok, p = pcall(UnitPower, "player")
    return ok and Num(p) or nil
end

-- false when the alert wants at least so much power and you have less, ex: an energy dump at 90.
-- When the game hides your power the minimum is ignored.
local function EnoughPower(a)
    local need = a.atPower
    if not need or need <= 0 then return true end
    local p = PlayerPower()
    return p == nil or p >= need
end

-- false when a usable or debuff alert wants at least so many combo points on the target and there
-- are fewer. When the game hides combo points the minimum is ignored.
local function EnoughCP(a)
    if not a.cp or a.cp <= 0 then return true end
    local cp = Num(ComboPoints())
    return cp == nil or cp >= a.cp
end

local function RawCooldown(id)
    if C_Spell and C_Spell.GetSpellCooldown then
        local ok, info = pcall(C_Spell.GetSpellCooldown, id)
        if ok and type(info) == "table" then return info.startTime, info.duration end
        if ok then return info end
    end
    if GetSpellCooldown then
        local ok, start, dur = pcall(GetSpellCooldown, id)
        if ok then return start, dur end
    end
    return nil
end

-- [lower case name] = time its cooldown ends, from your casts, for when the game's is secret
local cooldownUntil = {}
-- [lower case name] = true while Blizzard's spell alert glow is on
local glowing = {}

-- the spell's base cooldown in seconds, for tracking it ourselves
local function BaseCooldown(id)
    if not GetSpellBaseCooldown then return nil end
    local ok, ms = pcall(GetSpellBaseCooldown, id)
    ms = ok and Num(ms)
    if ms and ms > GCD * 1000 then return ms / 1000 end
    return nil
end

-- [spell id] = the GCD flag the game gave at SPELL_UPDATE_COOLDOWN, the only time it's sure of it
local gcdFlag = {}
-- [lower case name] = true while the game last said the spell was on its own cooldown, for moments
-- it won't say (a GCD in combat)
local knownOnCooldown = {}
-- [lower case name] = when the spell was first seen on cooldown, for its end when the game hides it
local onSince = {}

-- a readable true or false, nil for anything else
local function Flag(v)
    if not issecretvalue(v) and type(v) == "boolean" then return v end
    return nil
end

local function CooldownInfo(id)
    if not (C_Spell and C_Spell.GetSpellCooldown) then return nil end
    local ok, info = pcall(C_Spell.GetSpellCooldown, id)
    if ok and type(info) == "table" then return info end
    return nil
end

-- the GCD flags, read while SPELL_UPDATE_COOLDOWN is handled
local function UpdateGCDFlags()
    for _, a in ipairs(DB().alerts) do
        local id = AlertSpell(a)
        local info = id and CooldownInfo(id)
        if id then gcdFlag[id] = info and Flag(info.isOnGCD) end
    end
end

-- whether the spell is on its own cooldown, not just the GCD, from the flags the game keeps public
-- in combat too: true, false, or nil when it won't say. Each spell has its own flags, so a cooldown
-- it shares with another spell (the shocks) counts.
local function OnCooldownFlag(id, key)
    local info = CooldownInfo(id)
    if not info then return nil end
    local enabled, active = Flag(info.isEnabled), Flag(info.isActive)
    local on
    if enabled == false then
        on = true
    elseif active == false then
        on = false
    elseif active == true then
        -- the cooldown without the GCD: zero means only the GCD is running
        if C_Spell.GetSpellCooldownDuration then
            local ok, d = pcall(C_Spell.GetSpellCooldownDuration, id, true)
            if ok and d and d.IsZero then
                local ok2, zero = pcall(d.IsZero, d)
                zero = ok2 and Flag(zero)
                if zero ~= nil then on = not zero end
            end
        end
        if on == nil and gcdFlag[id] ~= nil then on = not gcdFlag[id] end
        if on == nil and knownOnCooldown[key] then on = true end
    end
    if on ~= nil then knownOnCooldown[key] = on or nil end
    return on
end

-- true when the game says the spell's base cooldown is no longer than the GCD
local function NoOwnCooldown(id)
    if not GetSpellBaseCooldown then return false end
    local ok, ms = pcall(GetSpellBaseCooldown, id)
    ms = ok and Num(ms)
    return ms ~= nil and ms <= GCD * 1000
end

-- the spell whose cooldown is the global cooldown
local GCD_SPELL = 61304

-- true when a readable cooldown is only the global cooldown: the game flags it, or it's the same
-- as the GCD spell's
local function IsGCD(id, start, dur)
    local info = CooldownInfo(id)
    if info and Flag(info.isOnGCD) == true then return true end
    local gs, gd = RawCooldown(GCD_SPELL)
    gs, gd = Num(gs), Num(gd)
    return gs ~= nil and gd ~= nil and gd > 0 and math.abs(gs - start) < 0.05 and math.abs(gd - dur) < 0.05
end

-- when you last cast a spell with a cooldown of its own (not a wand shot), see OnCast
local cooldownCastAt

-- true when such a cast came within half a second of the time
local function CooldownCastNear(t)
    return cooldownCastAt ~= nil and math.abs(cooldownCastAt - t) < 0.5
end

-- when the spell's cooldown ends, false when it's off cooldown, nil when unknown
local function CooldownEnds(a, id)
    -- a spell with no cooldown of its own can only be waiting on the GCD, ex: one started by a wand
    -- shot, which the game's flags don't always call the GCD
    if NoOwnCooldown(id) then return false end
    local now = GetTime()
    local key = a.spell:lower()
    local start, dur = RawCooldown(id)
    start, dur = Num(start), Num(dur)
    if start and dur then
        if start == 0 or dur <= GCD or start + dur <= now then return false end
        -- only the GCD, though longer than 1.5 sec, ex: started by a wand shot
        if IsGCD(id, start, dur) then return false end
        return start + dur
    end
    -- from your own cast of it: false once it's over
    local untilAt = cooldownUntil[key]
    local cast = untilAt and now < untilAt and untilAt
    local on = OnCooldownFlag(id, key)
    if on == false then
        onSince[key] = nil
        return false
    end
    if on == true then
        onSince[key] = onSince[key] or now
        if cast then return cast end
        -- A lockout the game doesn't call the GCD, ex: ~1.1 sec after each wand shot. Until it's
        -- run longer than a GCD it's taken for one, unless you just cast a spell with a cooldown of
        -- its own, which may share it (the shocks).
        if now - onSince[key] < GCD and not CooldownCastNear(onSince[key]) then return false end
        -- put on cooldown by another spell: guess its end from its own base cooldown
        local base = BaseCooldown(id)
        if base and onSince[key] + base > now then return onSince[key] + base end
        return math.huge
    end
    if untilAt then return cast or false end
    return nil
end

-- [alert] = time its cooldown ends or its debuff falls off, for alerts shown early with a
-- countdown, see EarlyOk and DebuffEarly
local early = {}

-- false when the spell is on cooldown, unless the alert shows early and the cooldown ends within
-- that many seconds. Then the icon shows with a countdown.
local function EarlyOk(a, id)
    local ends = CooldownEnds(a, id)
    if not ends then return true end
    if (a.early or 0) > 0 and ends - GetTime() <= a.early then
        early[a] = ends
        return true
    end
    return false
end

-- debuffs ----------------------------------------------------------------------------------------

-- your debuff on the target: true when it's surely there, with its expiry time when readable,
-- nil when unknown. A missing aura isn't believed in combat: reads there can come back empty.
local function ReadDebuff(a)
    local name = a.spell
    local aura
    if C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName then
        local ok, d = pcall(C_UnitAuras.GetAuraDataBySpellName, "target", name, "HARMFUL|PLAYER")
        if ok and not issecretvalue(d) then aura = d end
    end
    if aura == nil and AuraUtil and AuraUtil.FindAuraByName then
        local ok, d = pcall(function() return { AuraUtil.FindAuraByName(name, "target", "HARMFUL|PLAYER") } end)
        if ok and d[1] ~= nil and not issecretvalue(d[1]) then
            aura = { name = d[1], duration = d[5], expirationTime = d[6] }
        end
    end
    if type(aura) ~= "table" then return nil end
    return true, Num(aura.expirationTime), Num(aura.duration)
end

local function CDMOn()
    if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo) then return false end
    if C_CVar and C_CVar.GetCVarBool then
        local ok, on = pcall(C_CVar.GetCVarBool, "cooldownViewerEnabled")
        if ok and on == false then return false end
    end
    return true
end

local VIEWERS = { "BuffIconCooldownViewer", "BuffBarCooldownViewer", "EssentialCooldownViewer",
    "UtilityCooldownViewer" }

-- calls fn(frame, lower case spell name) for each Cooldown Manager frame
local function EachCDMFrame(fn)
    if not CDMOn() then return end
    for _, vname in ipairs(VIEWERS) do
        local viewer = _G[vname]
        local pool = viewer and viewer.itemFramePool
        if pool and pool.EnumerateActive then
            pcall(function()
                for f in pool:EnumerateActive() do
                    local cid = Num(f.cooldownID)
                    local info = cid and C_CooldownViewer.GetCooldownViewerCooldownInfo(cid)
                    local seen = {}
                    local function try(id)
                        local key = KeyOf(id)
                        if key and not seen[key] then
                            seen[key] = true
                            fn(f, key, vname)
                        end
                    end
                    if type(info) == "table" then
                        try(info.spellID); try(info.overrideSpellID); try(info.linkedSpellID)
                        if type(info.linkedSpellIDs) == "table" then
                            for _, id in ipairs(info.linkedSpellIDs) do try(id) end
                        end
                    end
                    try(f.auraSpellID)
                end
            end)
        end
    end
end

-- whether a Cooldown Manager aura frame shows the debuff up: true, false, or nil when no frame
-- says. Only the aura viewers count, the others show cooldowns.
local function CDMActive(a)
    local key, result = a.spell:lower(), nil
    EachCDMFrame(function(f, k, vname)
        if k ~= key or not vname:find("^Buff") then return end
        local active = f.isActive
        if not issecretvalue(active) and type(active) == "boolean" then
            result = result or active
        end
    end)
    return result
end

-- the debuff's length from its description, ex: "over 18 sec", or per combo point,
-- ex: "1 point: 40 damage over 8 secs"
local function DescDuration(id, cp)
    if not (C_Spell and C_Spell.GetSpellDescription) then return nil end
    local ok, d = pcall(C_Spell.GetSpellDescription, id)
    d = ok and Str(d)
    if not d or d == "" then return nil end
    local per = {}
    for n, s in d:gmatch("(%d) points?:.-(%d+)%s*sec") do per[tonumber(n)] = tonumber(s) end
    if next(per) then return per[cp or 0] or per[1] end
    return tonumber(d:match("(%d+)%s*sec"))
end

-- how long the debuff lasts when cast with cp combo points
local function DebuffDuration(a, id, cp)
    if a.duration and a.duration > 0 then return a.duration end
    local learned = DB().learned[a.spell:lower()]
    if learned and learned[cp or 0] then return learned[cp or 0] end
    local d = DescDuration(id, cp)
    if d then return d end
    -- a length learned at other combo points, when they all agree, ex: Garrote
    if learned then
        local one
        for _, s in pairs(learned) do
            if one and one ~= s then return nil end
            one = s
        end
        return one
    end
    return nil
end

-- [lower case name] = { [target guid or "?"] = { at, cp, dur, expires, seenUp, cdmUp } }, your
-- casts of debuff alerts this fight
local casts = {}
-- [lower case name] = combo points when the spell was sent, before the finisher spends them
local sentCP = {}

local function CastRecord(a, create)
    local key = a.spell:lower()
    local guid = TargetGUID() or "?"
    casts[key] = casts[key] or {}
    local rec = casts[key][guid]
    if not rec and create then
        rec = {}
        casts[key][guid] = rec
    end
    return rec
end

-- whether the spell was clicked and is waiting to go off, ex: Raptor Strike or Heroic Strike on
-- the next swing, which the action bar shows lit. true, false, or nil with the game's secret
-- boolean as the second value.
local function Queued(id)
    local secret
    local function Check(fn, ...)
        if not fn then return false end
        local ok, v = pcall(fn, ...)
        if not ok or v == nil then return false end
        if issecretvalue(v) then
            secret = secret or v
            return false
        end
        return v and true or false
    end
    if Check(C_Spell and C_Spell.IsCurrentSpell, id) or Check(IsCurrentSpell, id) then return true end
    -- the action bar's own read, from any button the spell is on
    if C_ActionBar and C_ActionBar.FindSpellActionButtons and IsCurrentAction then
        local ok, slots = pcall(C_ActionBar.FindSpellActionButtons, id)
        if ok and type(slots) == "table" then
            for _, slot in ipairs(slots) do
                if Check(IsCurrentAction, slot) then return true end
            end
        end
    end
    if secret ~= nil then return nil, secret end
    return false
end

-- alerts -----------------------------------------------------------------------------------------

-- an alert's state: true, false, or nil with a secret boolean when only the game knows. A third
-- value, true, dims the icon.
local function UsableState(a, id)
    -- out of a fight, a spell that's always usable would always show, unless the alert asks for any time
    if not a.anytime and not (InCombat() or Attackable()) then return false end
    if not EnoughPower(a) or not EnoughCP(a) then return false end
    local u, short, secret = Usable(id)
    if u == nil then
        if glowing[a.spell:lower()] then return true end
        -- the game's usable doesn't count cooldowns, so a spell on one would still show
        if not EarlyOk(a, id) then return false end
        return nil, secret
    end
    if not u then return glowing[a.spell:lower()] or false end
    if not EarlyOk(a, id) then return false end
    return PowerRule(a, short)
end

local function ComboState(a, id)
    -- no target needed: the target conditions can still ask for one
    if not a.anytime and not Attackable() then return false end
    local cp = Num(ComboPoints())
    if not cp or cp < (a.cp or 0) then return false end
    if not EnoughPower(a) then return false end
    local u, short = Usable(id)
    if u == false or not EarlyOk(a, id) then return false end
    return PowerRule(a, short)
end

-- a debuff that's still up shows early, with a countdown, when it falls off within the alert's
-- early seconds
local function DebuffEarly(a, ends)
    local left = ends and ends - GetTime()
    if not left or left <= 0 or left > (a.early or 0) or not EnoughCP(a) then return false end
    early[a] = ends
    return true
end

local function DebuffState(a, id)
    if not InCombat() or not Attackable() then return false end
    local rec = CastRecord(a, false)
    local ends = rec and (rec.expires or (rec.dur and rec.at + rec.dur))
    local up, expires, duration = ReadDebuff(a)
    if up then
        if rec then
            rec.seenUp = true
            if expires then rec.expires = expires end
            if duration and duration > 0 then
                local learned = DB().learned
                local key = a.spell:lower()
                learned[key] = learned[key] or {}
                learned[key][rec.cp or 0] = duration
            end
        end
        return DebuffEarly(a, expires or ends)
    end
    if not rec then return false end
    local cdm = CDMActive(a)
    if cdm == true then
        rec.cdmUp = true
        return DebuffEarly(a, ends)
    end
    -- the manager may lag a cast, so its "gone" counts only once it showed the debuff up
    if cdm == false and rec.cdmUp then return EnoughCP(a) end
    if not ends then return false end
    if GetTime() < ends then return DebuffEarly(a, ends) end
    return EnoughCP(a)
end

local function State(a)
    early[a] = nil
    if a.off or Suppressed(a) then return false end
    local id = AlertSpell(a)
    if not id then return false end
    if a.kind == "combo" then return ComboState(a, id) end
    if a.kind == "debuff" then return DebuffState(a, id) end
    return UsableState(a, id)
end

local function SoundId(name)
    for _, s in ipairs(SOUNDS) do
        if s.name == name then return SOUNDKIT and SOUNDKIT[s.kit] or s.id end
    end
    return nil
end

-- [alert] = when its sound last played
local soundAt = {}

-- force plays it even if it just played, ex: picking a sound in the window
local function PlayAlertSound(a, force)
    local name = a.sound or "ping"
    if name == "off" then return end
    local now = GetTime()
    if not force and soundAt[a] and now - soundAt[a] < SOUND_GAP then return end
    soundAt[a] = now
    local id = SoundId(name)
    if id then pcall(PlaySound, id, "Master") end
end

-- the alert frame --------------------------------------------------------------------------------

local holder
local icons = {}
-- [alert] = whether it was ready at the last readable state, for playing the sound only when it
-- turns ready. An icon shown early isn't ready yet.
local wasOn = {}
-- [alert] = when it turned ready, for alerts shown only for a while
local readyAt = {}
-- [alert] = true while it shows early, so a "show for" alert going on to ready doesn't fade in again
local wasEarly = {}
-- show every alert's icon for a few seconds, /osa test
local testUntil = 0

-- the default icon size, alerts can have their own
local function Size()
    local s = DB().size
    return s > 0 and s or SIZE
end

-- icon placement, as in Buff Reminder ------------------------------------------------------------
-- The icons are placed in sets. Each set is a grid with one alert per cell, drawn from its anchor.
-- Unlocked, every icon shows so it can be placed: dragging moves the whole set, Shift-drag pulls
-- one icon out, like taking a button off an action bar, and a set dropped touching another snaps
-- onto its grid. Dropped into a row or column it pushes the rest along. A row or column closes up
-- around the icons that aren't showing, other shapes keep the gaps.
-- db.bars = { { left, top = its top left from the screen centre, cells = { { key, c, r, ha, va } } } },
-- ha / va line an icon smaller than its column or row up to the left or top (-1) or the right or
-- bottom (1), nil centres it.
local anchors = {}      -- [set index] = frame covering the set, what's dragged
local dragging          -- the set being dragged
local alertOf = {}      -- [key] = alert, filled by PlaceableKeys

local function AlertKey(a)
    return "a" .. a.id
end

-- the default icon's size with its spacing
local function Pitch()
    return Size() + GAP
end

local function KeySize(key)
    local a = alertOf[key]
    return a and a.size or Size()
end

local function KeyPitch(key)
    return KeySize(key) + GAP
end

-- every alert's key, as a set and in the alerts' order
local function PlaceableKeys()
    wipe(alertOf)
    local keys, order = {}, {}
    for _, a in ipairs(DB().alerts) do
        local k = AlertKey(a)
        alertOf[k] = a
        keys[k] = true
        table.insert(order, k)
    end
    return keys, order
end

-- columns and rows a set spans
local function Span(bar)
    local w, h = 0, 0
    for _, cell in ipairs(bar.cells) do
        w, h = math.max(w, cell.c + 1), math.max(h, cell.r + 1)
    end
    return w, h
end

-- "row", "column", "single" or nil for any other shape
local function Shape(bar)
    local w, h = Span(bar)
    if w <= 1 and h <= 1 then return "single" end
    if h == 1 and #bar.cells == w then return "row" end
    if w == 1 and #bar.cells == h then return "column" end
end

-- where each column and row starts and how big it is, and the size of the whole set
local function Geometry(bar)
    local w, h = Span(bar)
    local g = { cx = {}, cw = {}, ry = {}, rh = {} }
    for _, cell in ipairs(bar.cells) do
        local p = KeyPitch(cell.key)
        g.cw[cell.c] = math.max(g.cw[cell.c] or 0, p)
        g.rh[cell.r] = math.max(g.rh[cell.r] or 0, p)
    end
    local x, y = 0, 0
    for c = 0, w - 1 do
        g.cw[c] = g.cw[c] or Pitch()
        g.cx[c], x = x, x + g.cw[c]
    end
    for r = 0, h - 1 do
        g.rh[r] = g.rh[r] or Pitch()
        g.ry[r], y = y, y + g.rh[r]
    end
    g.w, g.h = math.max(x, Pitch()), math.max(y, Pitch())
    return g
end

-- an icon's centre from the screen centre, with every icon of its set showing
local function CellCenter(bar, g, cell)
    local p = KeyPitch(cell.key)
    local cw, rh = g.cw[cell.c], g.rh[cell.r]
    return bar.left + g.cx[cell.c] + cw / 2 + (cell.ha or 0) * (cw - p) / 2,
        bar.top - g.ry[cell.r] - rh / 2 - (cell.va or 0) * (rh - p) / 2
end

local function TopLeftCell(bar)
    local best
    for _, cell in ipairs(bar.cells) do
        if not best or cell.r < best.r or (cell.r == best.r and cell.c < best.c) then best = cell end
    end
    return best
end

-- remember where one of a set's icons is, so Normalize can keep it there
local function Pin(bar, cell)
    cell = cell or TopLeftCell(bar)
    if not cell then return end
    local x, y = CellCenter(bar, Geometry(bar), cell)
    return { cell = cell, x = x, y = y }
end

-- move the top left cell back to 0, 0, keeping the pinned icon where it was
local function Normalize(bar, pin)
    if #bar.cells == 0 then return end
    local c0, r0 = math.huge, math.huge
    for _, cell in ipairs(bar.cells) do
        c0, r0 = math.min(c0, cell.c), math.min(r0, cell.r)
    end
    for _, cell in ipairs(bar.cells) do
        cell.c, cell.r = cell.c - c0, cell.r - r0
    end
    if pin then
        local x, y = CellCenter(bar, Geometry(bar), pin.cell)
        bar.left, bar.top = bar.left + pin.x - x, bar.top + pin.y - y
    end
end

local function Occupied(bar)
    local used = {}
    for _, cell in ipairs(bar.cells) do used[cell.c .. "," .. cell.r] = true end
    return used
end

-- a free cell for a new icon: the end of a row or column, else the first gap, else a new row
local function FreeCell(bar)
    local w, h = Span(bar)
    local shape = Shape(bar)
    if #bar.cells == 0 then return 0, 0 end
    if shape == "row" or shape == "single" then return w, 0 end
    if shape == "column" then return 0, h end
    local used = Occupied(bar)
    for r = 0, h - 1 do
        for c = 0, w - 1 do
            if not used[c .. "," .. r] then return c, r end
        end
    end
    return 0, h
end

-- saved sets, with anything broken dropped, nil when there are none
local function CheckBars(old)
    if type(old) ~= "table" then return nil end
    local bars = {}
    for _, b in ipairs(old) do
        if type(b) == "table" and type(b.left) == "number" and type(b.top) == "number" and type(b.cells) == "table" then
            local bar, used = { left = b.left, top = b.top, cells = {} }, {}
            for _, cell in ipairs(b.cells) do
                if type(cell) == "table" and type(cell.key) == "string" and type(cell.c) == "number"
                    and type(cell.r) == "number" then
                    local c, r = math.floor(cell.c), math.floor(cell.r)
                    if not used[c .. "," .. r] then
                        used[c .. "," .. r] = true
                        local new = { key = cell.key, c = c, r = r }
                        if cell.ha == -1 or cell.ha == 1 then new.ha = cell.ha end
                        if cell.va == -1 or cell.va == 1 then new.va = cell.va end
                        table.insert(bar.cells, new)
                    end
                end
            end
            Normalize(bar)
            table.insert(bars, bar)
        end
    end
    return #bars > 0 and bars or nil
end

-- drop removed alerts and empty sets, new alerts join the first set, true when anything changed
local function SyncBars()
    local db = DB()
    if type(db.bars) ~= "table" or #db.bars == 0 then
        -- an empty set is centred on its position when icons join it
        db.bars = { { left = 0, top = 140, cells = {} } }
    end
    local bars, changed = db.bars, false
    local keys, order = PlaceableKeys()
    for i = #bars, 1, -1 do
        local b = bars[i]
        local gone = {}
        for j = #b.cells, 1, -1 do
            local k = b.cells[j].key
            -- also drops a key that's placed twice
            if keys[k] then
                keys[k] = nil
            else
                gone[j] = true
            end
        end
        if next(gone) then
            changed = true
            local shape = Shape(b)
            local keep
            for j, cell in ipairs(b.cells) do
                if not gone[j] and (not keep or cell.r < keep.r or (cell.r == keep.r and cell.c < keep.c)) then
                    keep = cell
                end
            end
            local pin = keep and Pin(b, keep)
            for j = #b.cells, 1, -1 do
                if gone[j] then table.remove(b.cells, j) end
            end
            -- a row or column closes up
            if shape == "row" or shape == "column" then
                table.sort(b.cells, function(p, q) return p.c + p.r < q.c + q.r end)
                for n, cell in ipairs(b.cells) do
                    if shape == "row" then cell.c = n - 1 else cell.r = n - 1 end
                end
            end
            Normalize(b, pin)
        end
        if #b.cells == 0 and #bars > 1 then table.remove(bars, i) end
    end
    local first = bars[1]
    local empty, added = #first.cells == 0, false
    for _, k in ipairs(order) do
        if keys[k] then
            local c, r = FreeCell(first)
            -- lined up like the nearest icon in its row and in its column
            local inRow, inCol
            for _, cell in ipairs(first.cells) do
                if cell.r == r and (not inRow or math.abs(cell.c - c) < math.abs(inRow.c - c)) then inRow = cell end
                if cell.c == c and (not inCol or math.abs(cell.r - r) < math.abs(inCol.r - r)) then inCol = cell end
            end
            table.insert(first.cells, { key = k, c = c, r = r, va = inRow and inRow.va, ha = inCol and inCol.ha })
            changed, added = true, true
        end
    end
    -- a new set starts centred on its position, like the old single row
    if empty and added then
        local g = Geometry(first)
        first.left, first.top = first.left - g.w / 2, first.top + g.h / 2
    end
    return changed
end

local function ApplyLayout()
    local db = DB()
    SyncBars()
    for i, bar in ipairs(db.bars) do
        local a = anchors[i]
        if not a then
            a = CreateFrame("Frame", nil, holder)
            a:SetMovable(true)
            a:SetClampedToScreen(true)
            anchors[i] = a
        end
        -- covers every cell, what's clamped to the screen while dragging
        local g = Geometry(bar)
        a:SetSize(g.w, g.h)
        a:ClearAllPoints()
        a:SetPoint("CENTER", UIParent, "CENTER", bar.left + g.w / 2, bar.top - g.h / 2)
        a:Show()
    end
    for i = #db.bars + 1, #anchors do anchors[i]:Hide() end
end

local function BarIndex(bar)
    for i, b in ipairs(DB().bars) do
        if b == bar then return i end
    end
end

-- where each showing icon of a set goes, as offsets from its anchor's centre
local function PlaceIcons(bar, showing)
    local g = Geometry(bar)
    local shape = Shape(bar)
    local out = {}
    if shape == "row" or shape == "column" then
        local list, total = {}, 0
        for _, cell in ipairs(bar.cells) do
            if showing[cell.key] then
                table.insert(list, cell)
                total = total + KeyPitch(cell.key)
            end
        end
        table.sort(list, function(p, q) return p.c + p.r < q.c + q.r end)
        local pos = -total / 2
        for _, cell in ipairs(list) do
            local p = KeyPitch(cell.key)
            local d = pos + p / 2
            pos = pos + p
            if shape == "column" then
                table.insert(out, { key = cell.key, x = (cell.ha or 0) * (g.w - p) / 2, y = -d })
            else
                table.insert(out, { key = cell.key, x = d, y = -(cell.va or 0) * (g.h - p) / 2 })
            end
        end
    else
        local ox, oy = bar.left + g.w / 2, bar.top - g.h / 2
        for _, cell in ipairs(bar.cells) do
            if showing[cell.key] then
                local x, y = CellCenter(bar, g, cell)
                table.insert(out, { key = cell.key, x = x - ox, y = y - oy })
            end
        end
    end
    return out
end

-- does set d fit on t's grid moved by oc columns and or_ rows, touching it without overlapping
local function Fits(t, d, oc, or_)
    local used = Occupied(t)
    local touches = false
    for _, cell in ipairs(d.cells) do
        local c, r = cell.c + oc, cell.r + or_
        if used[c .. "," .. r] then return false end
        if used[(c - 1) .. "," .. r] or used[(c + 1) .. "," .. r]
            or used[c .. "," .. (r - 1)] or used[c .. "," .. (r + 1)] then
            touches = true
        end
    end
    return touches
end

-- ways to line up icons of different sizes, false keeps what they had
local ALIGNS = { false, { 0, 0 }, { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 }, { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } }

local function SetAlign(cell, ha, va)
    cell.ha = ha ~= 0 and ha or nil
    cell.va = va ~= 0 and va or nil
end

-- t with d put in: kind "grid" moves d by a columns and b rows, "row" or "column" pushes it in at
-- a. align lines up d and the icons sharing its rows and columns. t's top left icon stays still.
-- Returns the new set and d's cells in it.
local function Merge(t, d, kind, a, b, align)
    local pin = Pin(t)
    local m = { left = t.left, top = t.top, cells = {} }
    local k = #d.cells
    local ref
    for _, cell in ipairs(t.cells) do
        local n = { key = cell.key, c = cell.c, r = cell.r, ha = cell.ha, va = cell.va }
        if kind == "row" and n.c >= a then n.c = n.c + k end
        if kind == "column" and n.r >= a then n.r = n.r + k end
        if cell == pin.cell then ref = n end
        table.insert(m.cells, n)
    end
    local sorted = {}
    for _, cell in ipairs(d.cells) do table.insert(sorted, cell) end
    table.sort(sorted, function(p, q) return p.c + p.r < q.c + q.r end)
    local added, cols, rows, mine = {}, {}, {}, {}
    for i, cell in ipairs(sorted) do
        local n = { key = cell.key, ha = cell.ha, va = cell.va }
        if kind == "grid" then
            n.c, n.r = cell.c + a, cell.r + b
        elseif kind == "row" then
            n.c, n.r = a + i - 1, 0
        else
            n.c, n.r = 0, a + i - 1
        end
        cols[n.c], rows[n.r] = true, true
        added[cell], mine[n] = n, true
        table.insert(m.cells, n)
    end
    if align then
        for _, n in ipairs(m.cells) do
            if mine[n] then
                SetAlign(n, align[1], align[2])
            else
                -- only the alignment across the line d joined
                SetAlign(n, cols[n.c] and align[1] or (n.ha or 0), rows[n.r] and align[2] or (n.va or 0))
            end
        end
    end
    Normalize(m, { cell = ref, x = pin.x, y = pin.y })
    return m, added
end

-- snap a dropped set onto the set, place and alignment that puts its icons nearest where they were
-- dropped, if that's within most of an icon
local function SnapBar(d)
    local bars = DB().bars
    local dg = Geometry(d)
    local drop = {}
    for _, cell in ipairs(d.cells) do drop[cell] = { CellCenter(d, dg, cell) } end
    local limit = 0.75 * KeyPitch(TopLeftCell(d).key)
    local dShape = Shape(d)
    local dw, dh = Span(d)
    local best, bestDist
    local function Try(t, kind, a, b)
        for _, align in ipairs(ALIGNS) do
            local m, added = Merge(t, d, kind, a, b, align)
            local mg = Geometry(m)
            local sum = 0
            for cell, n in pairs(added) do
                local x, y = CellCenter(m, mg, n)
                sum = sum + (x - drop[cell][1]) ^ 2 + (y - drop[cell][2]) ^ 2
            end
            local dist = math.sqrt(sum / #d.cells)
            if dist < limit and (not bestDist or dist < bestDist - 0.01) then
                best, bestDist = { t = t, m = m }, dist
            end
        end
    end
    for _, t in ipairs(bars) do
        if t ~= d and #t.cells > 0 then
            local tShape = Shape(t)
            local tw, th = Span(t)
            -- pushed in like a button onto an action bar
            if (tShape == "row" or tShape == "single") and (dShape == "row" or dShape == "single") then
                for at = 0, tw do Try(t, "row", at) end
            end
            if (tShape == "column" or tShape == "single") and (dShape == "column" or dShape == "single") then
                for at = 0, th do Try(t, "column", at) end
            end
            for oc = -dw, tw do
                for or_ = -dh, th do
                    if Fits(t, d, oc, or_) then Try(t, "grid", oc, or_) end
                end
            end
        end
    end
    if not best then return false end
    local t = best.t
    t.left, t.top, t.cells = best.m.left, best.m.top, best.m.cells
    table.remove(bars, BarIndex(d))
    return true
end

local function IconDragStart(f)
    local db = DB()
    if not db.unlocked or dragging or not f.bar or not BarIndex(f.bar) then return end
    GameTooltip:Hide()
    local bar = f.bar
    if IsShiftKeyDown() and #bar.cells > 1 then
        local idx
        for j, cell in ipairs(bar.cells) do
            if cell.key == f.key then idx = j end
        end
        if idx then
            local cell = bar.cells[idx]
            local x, y = CellCenter(bar, Geometry(bar), cell)
            local shape = Shape(bar)
            table.remove(bar.cells, idx)
            local pin = Pin(bar)
            -- a row or column closes up behind it, other shapes keep the gap
            if shape == "row" or shape == "column" then
                local along = shape == "row" and "c" or "r"
                for _, other in ipairs(bar.cells) do
                    if other[along] > cell[along] then other[along] = other[along] - 1 end
                end
            end
            Normalize(bar, pin)
            local half = KeyPitch(f.key) / 2
            bar = { left = x - half, top = y + half, cells = { { key = f.key, c = 0, r = 0 } } }
            table.insert(db.bars, bar)
            OSA.Update()
        end
    end
    dragging = bar
    anchors[BarIndex(bar)]:StartMoving()
end

function OSA.IconDragStop()
    local bar = dragging
    if not bar then return end
    dragging = nil
    local i = BarIndex(bar)
    if not i then return end
    local a = anchors[i]
    a:StopMovingOrSizing()
    local ax, ay = a:GetCenter()
    local ux, uy = UIParent:GetCenter()
    if ax and ux then
        local g = Geometry(bar)
        bar.left, bar.top = ax - ux - g.w / 2, ay - uy + g.h / 2
    end
    SnapBar(bar)
    ApplyLayout()
    OSA.Update()
end

-- unlocked, how to place it
local function IconTooltip(f)
    local a = alertOf[f.key]
    if not (a and DB().unlocked) then return end
    GameTooltip:SetOwner(f, "ANCHOR_TOP")
    GameTooltip:SetText(a.spell)
    GameTooltip:AddLine("Drag to move it with the icons it's snapped to.", 1, 1, 1)
    GameTooltip:AddLine("Shift-drag to pull it away on its own.", 1, 1, 1)
    GameTooltip:AddLine("Drop it touching other icons, on any side, to snap to them.", 1, 1, 1)
    GameTooltip:AddLine("Its size is set in the options window, /osa.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

-- how visible an icon shown for len seconds is t seconds after it turned ready, 0 to 1
local function FlashAlpha(len, t)
    local out = math.min(FADE_OUT, len / 3)
    if t < 0 or t >= len then return 0 end
    if t < FADE_IN then return t / FADE_IN end
    if t > len - out then return (len - t) / out end
    return 1
end

-- the action bar button's icon frame and the mask that rounds the icon's corners to fit it
local ICON_FRAME, ICON_MASK = "UI-HUD-ActionBar-IconFrame", "UI-HUD-ActionBar-IconFrame-Mask"

local function HasAtlas(name)
    return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil or false
end

local function MakeIcon(i)
    local f = CreateFrame("Frame", nil, holder)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    -- the action bar button's thin dark frame with rounded corners, the icon cut to fit inside it.
    -- Without that art: a thin black edge.
    local mask
    if HasAtlas(ICON_FRAME) then
        f.tex:SetAllPoints()
        f.edge = f:CreateTexture(nil, "OVERLAY", nil, 2)
        f.edge:SetAtlas(ICON_FRAME)
        f.edge:SetAllPoints()
        if HasAtlas(ICON_MASK) and f.tex.AddMaskTexture and f.CreateMaskTexture then
            mask = f:CreateMaskTexture()
            mask:SetAtlas(ICON_MASK)
            mask:SetAllPoints(f.tex)
            f.tex:AddMaskTexture(mask)
        end
    else
        f.edge = f:CreateTexture(nil, "BACKGROUND")
        f.edge:SetAllPoints()
        f.edge:SetColorTexture(0, 0, 0, 1)
        f.tex:SetPoint("TOPLEFT", 1, -1)
        f.tex:SetPoint("BOTTOMRIGHT", -1, 1)
    end
    f.count = f:CreateFontString(nil, "OVERLAY", "NumberFontNormalLarge")
    f.count:SetPoint("BOTTOMRIGHT", -3, 3)
    -- shown early: a shade over the icon and the seconds left on the cooldown
    f.shade = f:CreateTexture(nil, "OVERLAY")
    f.shade:SetAllPoints(f.tex)
    f.shade:SetColorTexture(0, 0, 0, 0.55)
    f.timer = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.timer:SetPoint("CENTER")
    f.timer:SetTextColor(1, 1, 1)
    -- clicked and waiting for the next swing: lit like the action bar's button
    f.queued = f:CreateTexture(nil, "OVERLAY", nil, 1)
    f.queued:SetAllPoints(f.tex)
    f.queued:SetTexture("Interface\\Buttons\\CheckButtonHilight")
    f.queued:SetBlendMode("ADD")
    f.queued:Hide()
    -- the shade and the light take the icon's rounded corners too
    if mask then
        f.shade:AddMaskTexture(mask)
        f.queued:AddMaskTexture(mask)
    end
    -- takes the mouse only while unlocked, to be dragged
    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) IconDragStart(self) end)
    f:SetScript("OnDragStop", function() OSA.IconDragStop() end)
    f:SetScript("OnEnter", function(self) IconTooltip(self) end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f:Hide()
    icons[i] = f
    return f
end

local function MakeHolder()
    -- the parent of everything, the icons are placed by their sets' anchors
    holder = CreateFrame("Frame", "OpcowsSpellAlertsFrame", UIParent)
    holder:SetSize(1, 1)
    holder:SetPoint("CENTER")
    holder:EnableMouse(false)
    local db = DB()
    db.bars = CheckBars(db.bars)
    -- 0.11 and before: one row centred on a point. An empty set is centred on its position when
    -- the icons join it, so they start where they were.
    local pos = db.pos
    if type(pos) == "table" and type(pos.x) == "number" and type(pos.y) == "number" and not db.bars then
        local x, y = pos.x, pos.y
        if pos.point ~= "CENTER" or pos.relPoint ~= "CENTER" then
            -- anchored some other way: where its centre was
            local probe = CreateFrame("Frame", nil, UIParent)
            probe:SetSize(Size(), Size())
            probe:SetPoint(pos.point or "CENTER", UIParent, pos.relPoint or "CENTER", x, y)
            local px, py = probe:GetCenter()
            local ux, uy = UIParent:GetCenter()
            if px and ux then x, y = px - ux, py - uy end
            probe:Hide()
        end
        db.bars = { { left = x, top = y, cells = {} } }
    end
    db.pos = nil
    ApplyLayout()
end

-- [alert] = its last state as text, for the debug trace
local tracedState = {}
-- the most lines the trace keeps, the oldest go first
local TRACE_MAX = 1000

-- debug: when an alert's state changes, print what decided it, so a hidden icon can be explained
local function TraceState(a, on)
    local text = on == nil and "secret" or tostring(on)
    if tracedState[a] == text then return end
    tracedState[a] = text
    local id = AlertSpell(a)
    local parts = { ("%s -> %s"):format(a.spell, on == nil and "only the game knows (secret usable)"
        or on and "shown" or "hidden") }
    if a.off then table.insert(parts, "turned off") end
    if Suppressed(a) then
        for _, k in ipairs(CONDITIONS) do
            local v, c = status[k], Conds(a)[k]
            if (v and c == 1) or (not v and c == 2) then table.insert(parts, "hidden by condition " .. k) end
        end
    end
    if id then
        local u, noPower = RawUsable(id)
        local info = CooldownInfo(id) or {}
        local okB, base = pcall(GetSpellBaseCooldown or error, id)
        local gInfo = CooldownInfo(GCD_SPELL) or {}
        local start, dur = RawCooldown(id)
        local ends = CooldownEnds(a, id)
        table.insert(parts, ("usable %s, no power %s, glow %s"):format(Show(u), Show(noPower),
            tostring(glowing[a.spell:lower()] or false)))
        table.insert(parts, ("cooldown %s/%s, active %s, enabled %s, on GCD %s (cached %s), base %s, GCD active %s, we say %s")
            :format(Show(start), Show(dur), Show(info.isActive), Show(info.isEnabled), Show(info.isOnGCD),
                tostring(gcdFlag[id]), okB and Show(base) or "?", Show(gInfo.isActive),
                ends == false and "ready" or ends == nil and "unknown" or ends == math.huge and "on cooldown"
                    or ("%.1fs left"):format(ends - GetTime())))
    end
    table.insert(parts, ("combat %s, enemy target %s, combo points %s, power %s, enough power %s, no target needed %s")
        :format(tostring(InCombat()), tostring(Attackable()), Show(ComboPoints()), Show(PlayerPower()),
            tostring(EnoughPower(a)), tostring(a.anytime or false)))
    -- kept in the saved variables, not chat, as there's too much to read there. The game writes it
    -- to WTF\...\SavedVariables\OpcowsSpellAlerts.lua on /reload or logout.
    local db = DB()
    if type(db.trace) ~= "table" then db.trace = {} end
    table.insert(db.trace, ("%.1f %s"):format(GetTime(), table.concat(parts, "; ")))
    while #db.trace > TRACE_MAX do table.remove(db.trace, 1) end
end

function OSA.Update()
    if not holder then return end
    local db = DB()
    local preview = db.unlocked or GetTime() < testUntil
    local now = GetTime()
    UpdateStatus()
    -- [key] = what its icon shows, for the alerts whose icon is up
    local showing = {}
    for _, a in ipairs(db.alerts) do
        local on, secret, dim = State(a)
        if db.debug and not preview then TraceState(a, on) end
        if preview then on, secret, dim = true, nil, nil end
        -- the sound plays when the alert is ready, not when it shows early
        local ready = on == true and not early[a]
        if on ~= nil and not preview then
            if ready and not wasOn[a] then
                PlayAlertSound(a)
                -- coming from the countdown the icon is already showing, so it doesn't fade in
                readyAt[a] = wasEarly[a] and now - FADE_IN or now
            end
            if not ready then readyAt[a] = nil end
            wasOn[a] = ready
            wasEarly[a] = on and early[a] and true or nil
        end
        -- shown only for a while: hidden once that's over, until the alert turns off and on again
        local flash = not preview and ready and a.flash and readyAt[a]
        if flash and now - flash >= a.flash then on = false end
        -- clicked and waiting for the next swing: it shows, lit, even if it'd be hidden, so the
        -- click is seen to have taken. No sound, it's not a new alert.
        local queued, queuedSecret
        local id = not preview and not a.off and AlertSpell(a)
        if id then queued, queuedSecret = Queued(id) end
        if queued and on ~= true and not Suppressed(a) then
            on, secret, dim, flash = true, nil, nil, nil
        end
        if on ~= false then
            showing[AlertKey(a)] = { a = a, on = on, secret = secret, dim = dim, flash = flash,
                queued = queued, queuedSecret = queuedSecret }
        end
    end
    if dragging and not (db.unlocked and IsMouseButtonDown and IsMouseButtonDown("LeftButton")) then
        -- locked mid-drag, or a drag whose icon went away never gets its OnDragStop
        OSA.IconDragStop()
    end
    -- sizes may have changed, but a set being dragged is left where the mouse has it
    if not dragging or SyncBars() then ApplyLayout() end
    local shown = 0
    for bi, bar in ipairs(db.bars) do
        for _, p in ipairs(PlaceIcons(bar, showing)) do
            local s = showing[p.key]
            local a, on, secret, dim, flash = s.a, s.on, s.secret, s.dim, s.flash
            shown = shown + 1
            local f = icons[shown] or MakeIcon(shown)
            f.key, f.bar = p.key, bar
            local id = AlertSpell(a)
            local size = KeySize(p.key)
            f:SetSize(size, size)
            f:ClearAllPoints()
            f:SetPoint("CENTER", anchors[bi], "CENTER", p.x, p.y)
            f:EnableMouse(db.unlocked and true or false)
            f.tex:SetTexture(id and SpellIcon(id) or 134400)
            f.queued:SetShown(s.queued and true or false)
            if s.queuedSecret ~= nil and f.queued.SetAlphaFromBoolean
                and pcall(f.queued.SetAlphaFromBoolean, f.queued, s.queuedSecret, 1, 0) then
                f.queued:Show()
            else
                f.queued:SetAlpha(1)
            end
            local cp = (a.kind == "combo" or a.cp) and Num(ComboPoints())
            f.count:SetText(cp and tostring(cp) or "")
            local left = not preview and early[a] and early[a] - GetTime()
            f.shade:SetShown(left and true or false)
            f.timer:SetText(left and (left < 3 and ("%.1f"):format(left) or ("%d"):format(math.ceil(left))) or "")
            local alpha = db.unlocked and 0.6 or dim and DIM or 1
            -- the fade is set every frame, see OnUpdate
            f.flash = flash and { at = flash, len = a.flash, alpha = alpha } or nil
            f:SetAlpha(flash and alpha * FlashAlpha(a.flash, now - flash) or alpha)
            f.tex:SetDesaturated(dim and true or false)
            if on == nil then
                -- only the game knows: let it set the alpha, and play no sound
                if not (f.SetAlphaFromBoolean and pcall(f.SetAlphaFromBoolean, f, secret, 1, 0)) then f:SetAlpha(1) end
            end
            f:Show()
        end
    end
    for i = shown + 1, #icons do
        icons[i]:Hide()
        icons[i].flash = nil
        icons[i].key, icons[i].bar = nil, nil
    end
end

-- events -----------------------------------------------------------------------------------------

-- [event] = { count, last }, what's been seen, for the probe
local seen = {}

local function Saw(event, ...)
    local s = seen[event] or { count = 0 }
    seen[event] = s
    s.count = s.count + 1
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = Show((select(i, ...))) end
    s.last = table.concat(parts, ", ")
end

local function OnCast(spellID)
    local key = KeyOf(spellID)
    if not key then return end
    -- a spell with a cooldown of its own, for telling a shared cooldown from a GCD. Not the wand,
    -- whose shot may have a base cooldown, its speed.
    local auto = false
    if IsAutoRepeatSpell then
        local ok, v = pcall(IsAutoRepeatSpell, SpellName(spellID) or "")
        auto = ok and Bool(v) == true
    end
    local id = Num(spellID)
    if not auto and key ~= "shoot" and id and BaseCooldown(id) then cooldownCastAt = GetTime() end
    for _, a in ipairs(DB().alerts) do
        if a.spell:lower() == key then
            local id = AlertSpell(a) or spellID
            local base = BaseCooldown(id)
            if base then cooldownUntil[key] = GetTime() + base end
            if a.kind == "debuff" then
                local rec = CastRecord(a, true)
                local cp = sentCP[key]
                rec.at, rec.cp = GetTime(), cp
                rec.dur = DebuffDuration(a, id, cp)
                rec.expires, rec.seenUp, rec.cdmUp = nil, nil, nil
                Debug(("%s cast, %s combo points, lasts %s"):format(a.spell, tostring(cp), tostring(rec.dur)))
            end
        end
    end
end

local frame = CreateFrame("Frame")
local elapsed = 0

local function Register(event, unit)
    if unit then
        pcall(frame.RegisterUnitEvent, frame, event, unit)
    else
        pcall(frame.RegisterEvent, frame, event)
    end
end

frame:SetScript("OnEvent", function(_, event, ...)
    Saw(event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= "OpcowsSpellAlerts" then return end
        DB()
        MakeHolder()
        return
    elseif event == "PLAYER_LOGIN" then
        if OSA.UpdateMinimap then OSA.UpdateMinimap() end
    elseif event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_TAB" then
        book = nil
    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" or event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        local key = KeyOf(...)
        if key then glowing[key] = event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" or nil end
    elseif event == "UNIT_SPELLCAST_SENT" then
        local _, _, _, spellID = ...
        local key = KeyOf(spellID)
        if key then sentCP[key] = Num(ComboPoints()) end
    elseif event == "SPELL_UPDATE_COOLDOWN" then
        UpdateGCDFlags()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, _, spellID = ...
        OnCast(spellID)
    elseif event == "PLAYER_TARGET_CHANGED" then
        -- casts on a target whose guid couldn't be read belong to the old target
        for _, byTarget in pairs(casts) do byTarget["?"] = nil end
    elseif event == "PLAYER_REGEN_ENABLED" then
        wipe(casts)
        wipe(glowing)
    end
    OSA.Update()
end)

frame:SetScript("OnUpdate", function(_, dt)
    -- fading icons change every frame, the rest every tick
    local now = GetTime()
    for _, f in ipairs(icons) do
        local fl = f.flash
        if fl then f:SetAlpha(fl.alpha * FlashAlpha(fl.len, now - fl.at)) end
    end
    elapsed = elapsed + dt
    if elapsed < TICK or not holder then return end
    elapsed = 0
    if #DB().alerts > 0 or DB().unlocked then OSA.Update() end
end)

Register("ADDON_LOADED")
Register("PLAYER_LOGIN")
Register("PLAYER_ENTERING_WORLD")
Register("SPELLS_CHANGED")
Register("LEARNED_SPELL_IN_TAB")
Register("PLAYER_TARGET_CHANGED")
Register("PLAYER_REGEN_DISABLED")
Register("PLAYER_REGEN_ENABLED")
Register("SPELL_UPDATE_USABLE")
Register("SPELL_UPDATE_COOLDOWN")
Register("ACTIONBAR_UPDATE_USABLE")
Register("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
Register("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
Register("UNIT_POWER_FREQUENT", "player")
Register("UNIT_AURA", "target")
Register("PLAYER_TOTEM_UPDATE")
-- a next-swing spell clicked or gone off, so the icon lights or unlights at once
Register("CURRENT_SPELL_CAST_CHANGED")
Register("ACTIONBAR_UPDATE_STATE")
Register("UNIT_SPELLCAST_SENT", "player")
Register("UNIT_SPELLCAST_SUCCEEDED", "player")

-- probe ------------------------------------------------------------------------------------------

local PROBED_EVENTS = { "SPELL_UPDATE_USABLE", "ACTIONBAR_UPDATE_USABLE", "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW",
    "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_POWER_FREQUENT", "UNIT_AURA",
    "CURRENT_SPELL_CAST_CHANGED", "ACTIONBAR_UPDATE_STATE" }

local function ProbeSpell(name)
    local e = Book()[name:lower()]
    if not e then
        Print(("probe: %s isn't in your spellbook."):format(name))
        return
    end
    local a = { spell = e.name }
    local start, dur = RawCooldown(e.id)
    Print(("%s (spell %d): usable %s, cooldown start %s length %s, base cooldown %s, glow %s"):format(
        e.name, e.id, Show(RawUsable(e.id)) .. ", no power " .. Show(select(2, RawUsable(e.id))), Show(start), Show(dur), tostring(BaseCooldown(e.id)),
        tostring(glowing[e.name:lower()] or false)))
    local info = CooldownInfo(e.id) or {}
    local zero = "none"
    local okD, d = pcall(C_Spell.GetSpellCooldownDuration or error, e.id, true)
    if okD and d and d.IsZero then
        local okZ, z = pcall(d.IsZero, d)
        zero = okZ and Show(z) or "error"
    end
    local ends = CooldownEnds(a, e.id)
    Print(("  cooldown flags: active %s, enabled %s, on GCD %s (at last update %s), no-GCD zero %s; we say %s"):format(
        Show(info.isActive), Show(info.isEnabled), Show(info.isOnGCD), tostring(gcdFlag[e.id]), zero,
        ends == false and "ready" or ends == nil and "unknown" or ends == math.huge and "on cooldown, end unknown"
            or ("on cooldown, %.1fs left"):format(ends - GetTime())))
    local gs, gd = RawCooldown(GCD_SPELL)
    local wandOk, wand = false, nil
    if IsAutoRepeatSpell then wandOk, wand = pcall(IsAutoRepeatSpell, "Shoot") end
    local gInfo = CooldownInfo(GCD_SPELL) or {}
    Print(("  global cooldown: start %s length %s, active %s; wand shooting %s; own cooldown %s"):format(
        Show(gs), Show(gd), Show(gInfo.isActive), wandOk and Show(wand) or "unknown",
        NoOwnCooldown(e.id) and "no" or "yes or unknown"))
    local queued, queuedSecret = Queued(e.id)
    Print(("  waiting for the next swing: %s"):format(queuedSecret ~= nil and "secret" or tostring(queued)))
    local up, expires, duration = ReadDebuff(a)
    Print(("  on target: %s, expires %s, length %s, description says %s sec"):format(
        up and "yes" or "unknown", tostring(expires), tostring(duration), tostring(DescDuration(e.id, Num(ComboPoints())))))
    local frames = 0
    EachCDMFrame(function(f, k, vname)
        if k == e.name:lower() then
            frames = frames + 1
            Print(("  cooldown manager %s: active %s, aura %s"):format(vname, Show(f.isActive), Show(f.auraInstanceID)))
        end
    end)
    if frames == 0 then Print("  cooldown manager: no frame for it" .. (CDMOn() and "" or " (manager off or missing)")) end
end

function OSA.Probe(name)
    local cpOk, cp = pcall(GetComboPoints or function() return "missing" end, "player", "target")
    local powerType = Enum and Enum.PowerType and Enum.PowerType.ComboPoints
    local pw = powerType and select(2, pcall(UnitPower, "player", powerType)) or "missing"
    Print(("probe, %s: combo points %s, power %s, your energy/rage/mana %s, target %s, attackable %s, guid %s"):format(
        InCombatLockdown() and "in combat" or "out of combat", cpOk and Show(cp) or "error", Show(pw),
        Show(select(2, pcall(UnitPower, "player"))),
        Show(UnitName("target")), tostring(Attackable()), Show(select(2, pcall(UnitGUID, "target")))))
    for _, ev in ipairs(PROBED_EVENTS) do
        local s = seen[ev]
        Print(("  %s: %s"):format(ev, s and (s.count .. " seen, last: " .. s.last) or "not seen"))
    end
    if name and name ~= "" then
        ProbeSpell(name)
    else
        for _, a in ipairs(DB().alerts) do ProbeSpell(a.spell) end
        if #DB().alerts == 0 then Print("  /osa probe <spell> to probe a spell.") end
    end
end

-- slash commands ---------------------------------------------------------------------------------

local function Describe(i, a)
    local text = ("%d. %s, %s"):format(i, a.spell, a.kind)
    if a.kind == "combo" then text = text .. " at " .. (a.cp or 0) .. " points" end
    if a.kind ~= "combo" and a.cp then text = text .. ", with " .. a.cp .. "+ combo points" end
    if a.kind == "debuff" then
        local id = AlertSpell(a)
        local d = a.duration or (id and DebuffDuration(a, id, 5))
        text = text .. (a.duration and (", lasts " .. a.duration .. " sec (set)")
            or d and (", lasts about " .. d .. " sec") or ", length unknown: /osa duration " .. i .. " <sec>")
        if a.early then text = text .. ", shows " .. a.early .. " sec before it falls off" end
    end
    if a.kind == "usable" then
        text = text .. (a.anytime and ", no target needed" or ", in combat or with an enemy target")
    elseif a.kind == "combo" then
        text = text .. (a.anytime and ", no target needed" or ", with an enemy target")
    end
    if a.kind ~= "debuff" then
        if a.atPower then text = text .. ", at " .. a.atPower .. "+ energy" end
        if a.early then text = text .. ", shows " .. a.early .. " sec before its cooldown ends" end
        text = text .. ", short of energy: " .. (a.power or "dim")
    end
    if a.flash then text = text .. ", fades out after " .. a.flash .. " sec" end
    if a.size then text = text .. ", icon size " .. a.size end
    text = text .. ", sound " .. (a.sound or "ping")
    local hides = {}
    for _, k in ipairs(CONDITIONS) do
        local c = Conds(a)[k]
        if c and c ~= 0 then table.insert(hides, (c == 2 and "not " or "") .. k) end
    end
    if #hides > 0 then text = text .. ", hidden while " .. table.concat(hides, ", ") end
    if a.off then text = text .. " (off)" end
    if not AlertSpell(a) then text = text .. " (not in your spellbook)" end
    return text
end

local HELP = {
    "/osa - open the options window",
    "/osa add <spell> - alert when it's usable, ex: /osa add Riposte",
    "/osa add <spell> combo <n> - when it's usable with n combo points, ex: /osa add Eviscerate combo 5",
    "/osa add <spell> debuff [sec] - when your debuff falls off the target, ex: /osa add Rupture debuff",
    "/osa list - your alerts",
    "/osa remove <n> - remove alert n",
    "/osa toggle <n> - turn alert n off or on",
    "/osa cp <n> <points|off> - the combo points alert n waits for, off or 0 = any",
    "/osa duration <n> <sec|auto> - set how long a debuff lasts, auto reads it",
    "/osa sound <n> <ping|raid|ready|alarm|off> - an alert's sound",
    "/osa power <n> show|dim|hide - while the spell waits on energy, rage or mana",
    "/osa energy <n> <amount|off> - only alert with at least this much energy, rage or mana, ex: /osa energy 3 90",
    "/osa early <n> <sec|off> - show alert n with a countdown this many seconds before its cooldown ends, "
        .. "or before its debuff falls off",
    "/osa flash <n> <sec|off> - show alert n for only this many seconds when it comes on, fading in and out",
    "/osa anytime <n> on|off - no target needed: a usable alert shows out of combat with no target, ex: "
        .. "Sprint, a combo point alert without an enemy target. The target, enemy and friendly conditions "
        .. "can still ask for one",
    "/osa hide <n> <condition> off|true|false - hide alert n while the condition is true or false, "
        .. "ex: /osa hide 1 combat false. Conditions: " .. table.concat(CONDITIONS, ", "),
    "/osa size <size> - every icon's size, 0 = " .. SIZE,
    "/osa size <n> <size|off> - alert n's own icon size, off = the size above",
    "/osa lock - lock or unlock the icons. Unlocked, drag an icon to move its set, Shift-drag to pull "
        .. "it out on its own, drop it touching other icons to snap to them",
    "/osa reset - put every icon back in one row",
    "/osa test - show every icon for 3 seconds",
    "/osa probe [spell] - print what the game lets us read, in and out of combat",
    "/osa minimap - show or hide the minimap button",
    "/osa debug - debug messages",
}

local function Alert(n)
    return DB().alerts[tonumber(n) or 0]
end

SLASH_OPCOWSSPELLALERTS1 = "/osa"
SlashCmdList.OPCOWSSPELLALERTS = function(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    local db = DB()
    if cmd == "add" and rest ~= "" then
        local name, kind, arg = rest:match("^(.-)%s+(combo)%s*(%d*)$")
        if not name then name, kind, arg = rest:match("^(.-)%s+(debuff)%s*(%d*)$") end
        if not name then name, kind = rest:match("^(.-)%s+(usable)$") end
        name, kind = name or rest, kind or "usable"
        local e = Book()[name:lower()]
        if not e then
            Print(("%s isn't in your spellbook."):format(name))
            return
        end
        local a = { spell = e.name, kind = kind }
        if kind == "combo" then a.cp = math.min(5, tonumber(arg) or 0) end
        if kind == "debuff" then a.duration = tonumber(arg) end
        table.insert(db.alerts, a)
        Print("added " .. Describe(#db.alerts, a))
    elseif cmd == "list" then
        if #db.alerts == 0 then Print("no alerts yet, /osa add <spell> to add one.") end
        for i, a in ipairs(db.alerts) do Print(Describe(i, a)) end
    elseif cmd == "remove" and Alert(rest) then
        table.remove(db.alerts, tonumber(rest))
        Print("removed.")
    elseif cmd == "toggle" and Alert(rest) then
        local a = Alert(rest)
        a.off = not a.off or nil
        Print(Describe(tonumber(rest), a))
    elseif cmd == "cp" then
        local n, points = rest:match("^(%d+)%s+(%S+)$")
        local a = Alert(n)
        points = points and (points:lower() == "off" and 0 or tonumber(points))
        if not (a and points) then Print("/osa cp <n> <points|off>, n is the alert's number in /osa list.") return end
        points = math.min(5, points)
        if a.kind == "combo" then a.cp = points else a.cp = points > 0 and points or nil end
        Print(Describe(tonumber(n), a))
    elseif cmd == "duration" then
        local n, value = rest:match("^(%d+)%s+(%S+)$")
        local a = Alert(n)
        if not (a and a.kind == "debuff") then Print("/osa duration <n> <sec|auto>, n is a debuff alert's number in /osa list.") return end
        a.duration = tonumber(value)
        Print(Describe(tonumber(n), a))
    elseif cmd == "power" then
        local n, mode = rest:match("^(%d+)%s+(%a+)$")
        local a = Alert(n)
        mode = mode and mode:lower()
        if not (a and (mode == "show" or mode == "dim" or mode == "hide")) then
            Print("/osa power <n> show|dim|hide")
            return
        end
        a.power = mode
        Print(Describe(tonumber(n), a))
    elseif cmd == "early" then
        local n, value = rest:match("^(%d+)%s+(%S+)$")
        local a = Alert(n)
        local sec = value and (value:lower() == "off" and 0 or tonumber(value))
        if not (a and sec) then
            Print("/osa early <n> <sec|off>, n is the alert's number in /osa list.")
            return
        end
        a.early = sec > 0 and sec or nil
        Print(Describe(tonumber(n), a))
    elseif cmd == "flash" then
        local n, value = rest:match("^(%d+)%s+(%S+)$")
        local a = Alert(n)
        local sec = value and (value:lower() == "off" and 0 or tonumber(value))
        if not (a and sec) then
            Print("/osa flash <n> <sec|off>, n is the alert's number in /osa list.")
            return
        end
        a.flash = sec > 0 and math.max(1, sec) or nil
        Print(Describe(tonumber(n), a))
    elseif cmd == "anytime" then
        local n, value = rest:match("^(%d+)%s+(%a+)$")
        local a = Alert(n)
        value = value and value:lower()
        if not (a and a.kind ~= "debuff" and (value == "on" or value == "off")) then
            Print("/osa anytime <n> on|off, n is a usable or combo point alert's number in /osa list.")
            return
        end
        a.anytime = value == "on" or nil
        Print(Describe(tonumber(n), a))
    elseif cmd == "hide" then
        local n, key, mode = rest:match("^(%d+)%s+(%a+)%s+(%a+)$")
        local a = Alert(n)
        local value = ({ off = 0, ["true"] = 1, ["false"] = 2 })[(mode or ""):lower()]
        local name = key and key:lower()
        key = nil
        for _, k in ipairs(CONDITIONS) do if k:lower() == name then key = k end end
        if not (a and value and key) then
            Print("/osa hide <n> <condition> off|true|false, conditions: " .. table.concat(CONDITIONS, ", "))
            return
        end
        Conds(a)[key] = value
        Print(Describe(tonumber(n), a))
    elseif cmd == "energy" then
        local n, value = rest:match("^(%d+)%s+(%S+)$")
        local a = Alert(n)
        if not (a and a.kind ~= "debuff" and (tonumber(value) or value == "off")) then
            Print("/osa energy <n> <amount|off>, n is a usable or combo alert's number in /osa list.")
            return
        end
        a.atPower = tonumber(value) and tonumber(value) > 0 and tonumber(value) or nil
        Print(Describe(tonumber(n), a))
    elseif cmd == "sound" then
        local n, name = rest:match("^(%d+)%s+(%S+)$")
        local a = Alert(n)
        name = name and name:lower()
        if not a or not (name == "off" or SoundId(name)) then Print("/osa sound <n> <ping|raid|ready|alarm|off>") return end
        a.sound = name
        PlayAlertSound(a, true)
        Print(Describe(tonumber(n), a))
    elseif cmd == "size" and tonumber(rest) then
        db.size = math.max(0, math.min(200, tonumber(rest)))
        Print("icon size " .. Size())
    elseif cmd == "size" then
        local n, value = rest:match("^(%d+)%s+(%S+)$")
        local a = Alert(n)
        local px = value and (value:lower() == "off" and 0 or tonumber(value))
        if not (a and px) then
            Print("/osa size <size> for every icon, or /osa size <n> <size|off> for alert n's own.")
            return
        end
        a.size = px > 0 and math.max(10, math.min(200, px)) or nil
        Print(Describe(tonumber(n), a))
    elseif cmd == "lock" or cmd == "unlock" then
        db.unlocked = not db.unlocked or nil
        Print(db.unlocked and "unlocked: drag an icon to move its set, Shift-drag to pull it out on its own."
            or "locked.")
    elseif cmd == "reset" then
        db.bars = nil
        Print("the icons are back in one row.")
    elseif cmd == "test" then
        OSA.Test()
    elseif cmd == "probe" then
        OSA.Probe(rest)
    elseif cmd == "debug" then
        db.debug = not db.debug or nil
        if db.debug then
            -- a fresh trace, starting with every alert's state
            db.trace = {}
            wipe(tracedState)
            Print("debug on. Alert changes are logged to the saved variables, written on /reload.")
        else
            Print(("debug off, %d lines logged. /reload to write them to the file."):format(
                type(db.trace) == "table" and #db.trace or 0))
        end
    elseif cmd == "minimap" then
        db.minimap.hide = not db.minimap.hide or nil
        if OSA.UpdateMinimap then OSA.UpdateMinimap() end
    elseif cmd == "" and OSA.ToggleConfig then
        OSA.ToggleConfig()
    else
        for _, line in ipairs(HELP) do Print(line) end
    end
    OSA.Changed()
end

-- for the options window
function OSA.Changed()
    OSA.Update()
    if OSA.RefreshConfig then OSA.RefreshConfig() end
end

function OSA.Test()
    testUntil = GetTime() + 3
    if DB().alerts[1] then PlayAlertSound(DB().alerts[1], true) end
end

OSA.DB = DB
OSA.Print = Print
OSA.Book = Book
OSA.SpellName = SpellName
OSA.SpellIcon = SpellIcon
OSA.AlertSpell = AlertSpell
OSA.DebuffDuration = DebuffDuration
OSA.SOUNDS = SOUNDS
OSA.SoundId = SoundId
OSA.PlayAlertSound = PlayAlertSound
OSA.SIZE = SIZE
OSA.POWER_MODES = POWER_MODES
OSA.CONDITIONS = CONDITIONS
OSA.Conds = Conds
