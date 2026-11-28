-- Opcow's Spell Alerts: a spell's icon pops up, with a sound, when one of your alerts is true:
--   usable: the spell can be cast now, ex: Riposte after a parry
--   combo: the spell is usable and the target has at least N combo points, ex: Eviscerate at 5
--   debuff: your debuff has fallen off the target you're fighting, ex: Rupture
--   aura: a debuff is on the target, ex: Frostbite, which procs at random
--
-- Forever blocks the combat log and makes auras secret in combat, so each alert reads what it can.
-- A debuff is read directly when that works, else through the Cooldown Manager when it tracks
-- the debuff, else timed from your cast. A debuff that's on the target is shown in combat by
-- Blizzard's own aura button. /osa probe prints which reads work.

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
    "target", "enemy", "friendly" }
local DEFAULT_CONDS = { dead = 1, taxi = 1, mounted = 1 }
-- your totems, see the totems section below
local Totem = { SLOTS = 4, PAIR = 1, slot = {} }

local issecretvalue = issecretvalue or function() return false end

-- an alert's conditions, filled in with the defaults where missing or invalid
-- an alert's looks: { fx, conds = { { what, op "<" "<=" "=" ">=" ">", n, join "and"|"or" } } }.
-- Your power is in points (energy, rage, mana), the target's health in percent. The first
-- condition's join is ignored.
local LOOK_WHAT = { power = true, health = true, cp = true }
local LOOK_OP = { ["<"] = true, ["<="] = true, ["="] = true, [">="] = true, [">"] = true }
OSA.LOOK_OPS = { "<", "<=", "=", ">=", ">" }
local LOOK_FX = { dim = true, glow = true, grey = true, red = true, green = true, blue = true }
OSA.LOOK_WHATS = { "power", "health", "cp" }
OSA.LOOK_FXS = { "dim", "glow", "grey", "red", "green", "blue" }
OSA.LOOK_WHAT_NAMES = { power = "My energy", health = "Target health", cp = "Combo points" }
OSA.LOOK_FX_NAMES = { dim = "Dim", glow = "Glow", grey = "Grey", red = "Red", green = "Green", blue = "Blue" }
OSA.MAX_LOOKS = 6
OSA.MAX_CONDS = 5

local function Conds(a)
    if type(a.conds) ~= "table" then a.conds = {} end
    for _, k in ipairs(CONDITIONS) do
        local c = a.conds[k]
        if c ~= 0 and c ~= 1 and c ~= 2 then a.conds[k] = DEFAULT_CONDS[k] or 0 end
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
        -- 0.20 and before had a check per totem element
        a.conds.fireTotem, a.conds.earthTotem, a.conds.waterTotem, a.conds.airTotem = nil, nil, nil, nil
        -- the totems one of which must be down, a list of spell names
        if type(a.totems) == "table" then
            for i = #a.totems, 1, -1 do
                if type(a.totems[i]) ~= "string" or a.totems[i] == "" then table.remove(a.totems, i) end
            end
            if #a.totems == 0 then a.totems = nil end
        else
            a.totems = nil
        end
        -- 0.7 and before saved when the sound last played
        a.soundAt = nil
        if not a.id then
            a.id, db.nextId = db.nextId, db.nextId + 1
        end
        -- its own icon size, nil = the default
        if type(a.size) ~= "number" or a.size < 10 or a.size > 200 then a.size = nil end
        -- its own icon height, nil = as wide as it is
        if type(a.height) ~= "number" or a.height < 10 or a.height > 200 then a.height = nil end
        -- its icon's border, nil = a thin black edge
        if a.border ~= "action" and a.border ~= "thick" and a.border ~= "none" then a.border = nil end
        -- hidden while the target isn't one the spell can be cast on
        if a.wrongTarget ~= true and a.wrongTarget ~= "range" then a.wrongTarget = nil end
        -- an aura alert's spell ids seen on the target, as a set
        if type(a.ids) == "table" then
            for id in pairs(a.ids) do
                if type(id) ~= "number" then a.ids[id] = nil end
            end
        else
            a.ids = nil
        end
        -- the debuff names a usable or combo alert waits for, a list of strings
        if type(a.need) == "table" then
            for i = #a.need, 1, -1 do
                if type(a.need[i]) ~= "string" or a.need[i] == "" then table.remove(a.need, i) end
            end
            if #a.need == 0 then a.need = nil end
        else
            a.need = nil
        end
        -- how the icon looks while your power, the target's health or combo points are in a range
        if type(a.looks) == "table" then
            for i = #a.looks, 1, -1 do
                local look = a.looks[i]
                -- before and/or, a look had one condition: { what, op, n, fx }
                if type(look) == "table" and look.conds == nil and look.what ~= nil then
                    look = { fx = look.fx, conds = { { what = look.what, op = look.op, n = look.n } } }
                    a.looks[i] = look
                end
                if type(look) == "table" and type(look.conds) == "table" then
                    for j = #look.conds, 1, -1 do
                        local c = look.conds[j]
                        if type(c) ~= "table" or not LOOK_WHAT[c.what] or not LOOK_OP[c.op]
                            or type(c.n) ~= "number" then
                            table.remove(look.conds, j)
                        elseif c.join ~= "or" then
                            c.join = "and"
                        end
                    end
                end
                if type(look) ~= "table" or not LOOK_FX[look.fx] or type(look.conds) ~= "table"
                    or #look.conds == 0 then
                    table.remove(a.looks, i)
                end
            end
            if #a.looks == 0 then a.looks = nil end
        else
            a.looks = nil
        end
    end
    -- spell ids by name for aura alerts, looked up once per game build: { build, names = { [lower
    -- case name] = { ids } } }
    if type(db.auraIds) ~= "table" or type(db.auraIds.names) ~= "table" then db.auraIds = { names = {} } end
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

-- the totems in your spellbook, sorted names
function Totem.Book()
    local names = {}
    for key, e in pairs(Book()) do
        if key:find("totem", 1, true) then table.insert(names, e.name) end
    end
    table.sort(names)
    return names
end

-- a spell such as Fire Nova that needs one of your totems down: the first time its description
-- can be read, the totems from your spellbook it names become its totems, ex: "your Flametongue
-- Totem". A spell that is itself a totem, or names none, gets none.
function Totem.Auto(a)
    if a.totemsChecked then return end
    if not (C_Spell and C_Spell.GetSpellDescription) then a.totemsChecked = true return end
    local id = AlertSpell(a)
    if not id then return end
    local ok, d = pcall(C_Spell.GetSpellDescription, id)
    d = ok and Str(d)
    if not d or d == "" then return end
    a.totemsChecked = true
    if a.totems or a.spell:lower():find("totem", 1, true) then return end
    d = d:lower()
    local found = {}
    for _, name in ipairs(Totem.Book()) do
        if d:find(name:lower(), 1, true) then table.insert(found, name) end
    end
    if #found > 0 then a.totems = found end
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
    Totem.ReadAll()
end

-- your totems: [slot] = the totem's name as the game gives it, nil = none. Read from GetTotemInfo
-- when it can be; when the game hides it, a totem cast and the slot that changed with it are paired.
-- the last totem cast { name, at }, and the last slot that changed unreadably { slot, at }

-- reads a slot: true when the game said what's in it
function Totem.Read(slot)
    if not GetTotemInfo then return false end
    local ok, have, name = pcall(GetTotemInfo, slot)
    if not ok then return false end
    if Bool(have) == false then Totem.slot[slot] = nil return true end
    local n = Str(name)
    if n then
        Totem.slot[slot] = n ~= "" and n or nil
        return true
    end
    return false
end

function Totem.ReadAll()
    for slot = 1, Totem.SLOTS do Totem.Read(slot) end
end

-- PLAYER_TOTEM_UPDATE: a totem went down or went away in the slot
function Totem.Changed(slot)
    slot = Num(slot)
    if not slot or Totem.Read(slot) then return end
    if Totem.cast and GetTime() - Totem.cast.at <= Totem.PAIR then
        Totem.slot[slot] = Totem.cast.name
        Totem.cast = nil
    else
        -- no cast just now: it died or ran out, unless the cast comes right after
        Totem.slot[slot] = nil
        Totem.change = { slot = slot, at = GetTime() }
    end
end

-- a spell of yours with "Totem" in its name was cast
function Totem.Cast(name)
    if Totem.change and GetTime() - Totem.change.at <= Totem.PAIR then
        Totem.slot[Totem.change.slot] = name
        Totem.change = nil
    else
        Totem.cast = { name = name, at = GetTime() }
    end
end

-- true when one of the alert's totems is down, or it needs none. Names are matched from the
-- start, so "Searing Totem" matches a "Searing Totem VII" the game may give.
function Totem.Down(a)
    Totem.Auto(a)
    if not a.totems then return true end
    for slot = 1, Totem.SLOTS do
        local down = Totem.slot[slot] and Totem.slot[slot]:lower()
        if down then
            for _, want in ipairs(a.totems) do
                want = want:lower()
                if down:sub(1, #want) == want then return true end
            end
        end
    end
    return false
end

-- a.wrongTarget: true when the target isn't one the spell can be cast on (ex: Exorcism on a beast),
-- or there's none. The game hides creature types, but its range check answers nil for a target the
-- spell can't be cast on and false when it's out of range. a.wrongTarget = "range" (can't cast) also
-- counts out of range. A hidden answer is never nil, so it shows.
function OSA.WrongTarget(a)
    if not a.wrongTarget or a.kind == "aura" then return false end
    if not UnitExists("target") then return true end
    local f = C_Spell and C_Spell.IsSpellInRange or IsSpellInRange
    if not f then return false end
    local ok, r = pcall(f, AlertSpell(a) or a.spell, "target")
    if not ok or issecretvalue(r) then return false end
    if r == nil then return true end
    -- the old IsSpellInRange answers 0 for out of range
    return a.wrongTarget == "range" and (r == false or r == 0)
end

-- true when one of the alert's conditions hides it
local function Suppressed(a)
    if not Totem.Down(a) then return true end
    if OSA.WrongTarget(a) then return true end
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

-- debuffs on the target --------------------------------------------------------------------------
-- An aura alert shows while a debuff is on the target, ex: Frostbite. The debuff needn't be a spell
-- in your spellbook. Out of combat it's read directly. In combat the game hides the target's auras
-- from addons, but Blizzard's own aura button can show them, as Buff Reminder's alerts do for your
-- buffs: each aura alert gets a CustomAuraContainer on the target with one slot, which the game
-- fills while one of the debuff's spell ids is on it. Our icon only keeps its place under it. When
-- the game lets us read whether the button is showing, that's the alert's state and the sound
-- plays. When it doesn't, the button keeps its place and shows by itself, with no sound.

-- [alert] = { holder, container, button, ids, filter, size, err }, made out of combat, see UpdateLive
local live = {}
-- how far the spell ids are searched for an aura alert's name, and how many each frame
local SCAN_MAX, SCAN_STEP = 600000, 3000
-- the search under way: { at = next id, found = { [lower case name] = { ids } } }
local scan

local function AuraFilter(a)
    return a.anyone and "HARMFUL" or "HARMFUL|PLAYER"
end

-- the debuff names an alert follows: an aura alert's own, or the ones a usable or combo alert
-- waits for ("only while on the target", a.need), nil for none
local function AuraNames(a)
    if a.kind == "aura" then return { a.spell } end
    if (a.kind == "usable" or a.kind == "combo") and type(a.need) == "table" and #a.need > 0 then return a.need end
    return nil
end

local function GameBuild()
    if not GetBuildInfo then return "?" end
    local ok, version, build = pcall(GetBuildInfo)
    return ok and (tostring(version) .. " " .. tostring(build)) or "?"
end

-- the spell ids with the name, from the search, or nil when it hasn't been searched in this build
local function ScannedIds(name)
    local cache = DB().auraIds
    if cache.build ~= GameBuild() then
        cache.build, cache.names = GameBuild(), {}
    end
    local ids = cache.names[name:lower()]
    return type(ids) == "table" and ids or nil
end

-- search every spell id for the names of aura alerts not searched yet, a few thousand a frame and
-- not in combat, true when one finished
local function ScanStep()
    if InCombat() then return false end
    if not scan then
        local found
        for _, a in ipairs(DB().alerts) do
            for _, name in ipairs(AuraNames(a) or {}) do
                if not ScannedIds(name) then
                    found = found or {}
                    found[name:lower()] = {}
                end
            end
        end
        if not found then return false end
        scan = { at = 1, found = found }
        Debug("looking up the spell ids of debuff names")
    end
    local stop = math.min(scan.at + SCAN_STEP - 1, SCAN_MAX)
    local get = C_Spell and C_Spell.GetSpellName
    if get then
        local found = scan.found
        pcall(function()
            for id = scan.at, stop do
                local n = get(id)
                if n and not issecretvalue(n) then
                    local ids = found[n:lower()]
                    if ids then table.insert(ids, id) end
                end
            end
        end)
    end
    scan.at = stop + 1
    if scan.at <= SCAN_MAX then return false end
    for name, ids in pairs(scan.found) do
        DB().auraIds.names[name] = ids
        Debug(("%s: spell ids %s"):format(name, #ids > 0 and table.concat(ids, ", ") or "none found"))
    end
    scan = nil
    return true
end

-- true while the alert's spell ids are still being looked up
local function Searching(a)
    for _, name in ipairs(AuraNames(a) or {}) do
        if not ScannedIds(name) then return true end
    end
    return false
end

-- the spell ids an aura alert follows, as a set and as a key: the search's, the ones seen on the
-- target, and the spellbook's
local function AuraIds(a)
    local set, list = {}, {}
    local function add(id)
        id = Num(id)
        if id and id > 0 and not set[id] then
            set[id] = true
            table.insert(list, id)
        end
    end
    for _, name in ipairs(AuraNames(a) or {}) do
        for _, id in ipairs(ScannedIds(name) or {}) do add(id) end
        local e = Book()[name:lower()]
        add(e and e.id)
        if C_Spell and C_Spell.GetSpellInfo then
            local ok, info = pcall(C_Spell.GetSpellInfo, name)
            add(ok and type(info) == "table" and info.spellID or nil)
        end
    end
    if a.ids then
        for id in pairs(a.ids) do add(id) end
    end
    table.sort(list)
    return set, table.concat(list, ",")
end

-- the icon for an aura alert: its spell's, else the first spell id with an icon
local function AuraIcon(a)
    local e = Book()[a.spell:lower()]
    local icon = e and SpellIcon(e.id)
    if icon then return icon end
    local _, key = AuraIds(a)
    for id in key:gmatch("%d+") do
        icon = SpellIcon(tonumber(id))
        if icon then return icon end
    end
    return nil
end

-- a debuff name as the game writes it, ex: "Frost Nova" for a typed "frost nova": the spellbook's,
-- else a found spell id's
local function GameName(name)
    local e = Book()[name:lower()]
    if e then return e.name end
    local ids = ScannedIds(name)
    return ids and ids[1] and SpellName(ids[1]) or name
end

-- whether one of the alert's debuffs is on the target, read directly: true or false, nil when the
-- game hides it. Remembers the spell ids seen.
local function ReadAura(a)
    if Bool(UnitExists("target")) ~= true then return false end
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName) then return nil end
    local unknown = false
    for _, name in ipairs(AuraNames(a) or {}) do
        local ok, d = pcall(C_UnitAuras.GetAuraDataBySpellName, "target", GameName(name), AuraFilter(a))
        if not ok or issecretvalue(d) then
            unknown = true
        elseif type(d) == "table" then
            local id = Num(d.spellId)
            if id then
                a.ids = a.ids or {}
                a.ids[id] = true
            end
            return true
        end
    end
    -- in combat the read comes back empty when the game hides it
    if unknown or InCombat() then return nil end
    return false
end

-- the alert's aura button, when it has one that works
local function Live(a)
    local l = live[a]
    return l and l.container and not l.err and l or nil
end

-- whether Blizzard's button shows the debuff: true, false, or nil with the game's secret boolean
local function LiveShown(l)
    local b = l.button
    -- made the first time the debuff shows, so until then it's unknown (the button shows by itself)
    if not b then return nil end
    local ok, v = pcall(b.IsShown, b)
    if not ok then return nil end
    if issecretvalue(v) then return nil, v end
    return v and true or false
end

local function AuraState(a)
    if not EnoughCP(a) then return false end
    local up = ReadAura(a)
    local l = Live(a)
    if l then
        local shown, secret = LiveShown(l)
        if shown ~= nil then return shown end
        if up ~= nil then return up end
        return nil, secret
    end
    return up == true
end

-- [alert] = its aura button, for the usable and combo alerts whose debuffs only the game knows
-- about this update: the icon is put inside Blizzard's button, which shows only while one is on
local gating = {}

-- whether a usable or combo alert's "only while on the target" debuffs allow it: true, false, or
-- nil when only the game knows (gating[a] is then set)
local function Gate(a)
    if not AuraNames(a) then return true end
    -- read directly when the game allows it
    local up = ReadAura(a)
    if up ~= nil then return up end
    local l = Live(a)
    -- no button to lean on, ex: the game wouldn't make one: the debuffs can't be seen, and an icon
    -- that shows whenever the spell is castable is what the list is there to stop
    if not l then return false end
    -- made the first time a debuff fills the slot, so none of them has been on since
    if not l.button then return false end
    local shown = LiveShown(l)
    if shown ~= nil then return shown end
    gating[a] = l
    return nil
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

local function SpellState(a)
    if a.kind == "aura" then return AuraState(a) end
    local id = AlertSpell(a)
    if not id then return false end
    if a.kind == "combo" then return ComboState(a, id) end
    if a.kind == "debuff" then return DebuffState(a, id) end
    return UsableState(a, id)
end

local function State(a)
    early[a] = nil
    gating[a] = nil
    if a.off or Suppressed(a) then return false end
    local on, secret, dim = SpellState(a)
    if on == false or a.kind == "aura" then return on, secret, dim end
    local gate = Gate(a)
    if gate == false then
        early[a] = nil
        return false
    end
    -- only the game knows whether a debuff is on: the icon shows inside its button, with no sound
    if gate == nil and on == true then on = nil end
    return on, secret, dim
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
-- plate = true puts the set on the target's nameplate, side = nil (above it), "left" or "right", the
-- set's edge facing the plate px, py from that side's middle. left, top is still where it goes while
-- the target has no nameplate.
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

-- an icon's width and height: its size, and its own height if it has one
local function KeyDims(key)
    local a = alertOf[key]
    local w = a and a.size or Size()
    return w, a and a.height or w
end

-- its width and height with the spacing
local function KeyPitches(key)
    local w, h = KeyDims(key)
    return w + GAP, h + GAP
end

-- texture coords for an icon w wide and h high: the icon's usual crop, cut down on its longer side
-- so the picture keeps its shape, as Plater does
local function IconCoords(w, h)
    local l, r, t, b = 0.07, 0.93, 0.07, 0.93
    if w > h then
        local cut = 0.86 * (1 - h / w) / 2
        t, b = t + cut, b - cut
    elseif h > w then
        local cut = 0.86 * (1 - w / h) / 2
        l, r = l + cut, r - cut
    end
    return l, r, t, b
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
        local pw, ph = KeyPitches(cell.key)
        g.cw[cell.c] = math.max(g.cw[cell.c] or 0, pw)
        g.rh[cell.r] = math.max(g.rh[cell.r] or 0, ph)
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
    if #bar.cells == 0 then x, y = Pitch(), Pitch() end
    g.w, g.h = x, y
    return g
end

-- an icon's centre from the screen centre, with every icon of its set showing
local function CellCenter(bar, g, cell)
    local pw, ph = KeyPitches(cell.key)
    local cw, rh = g.cw[cell.c], g.rh[cell.r]
    return bar.left + g.cx[cell.c] + cw / 2 + (cell.ha or 0) * (cw - pw) / 2,
        bar.top - g.ry[cell.r] - rh / 2 - (cell.va or 0) * (rh - ph) / 2
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
            if b.grow == true then bar.grow = true end
            if b.plate == true then
                bar.plate = true
                bar.px = type(b.px) == "number" and b.px or nil
                bar.py = type(b.py) == "number" and b.py or nil
                if b.side == "left" or b.side == "right" then bar.side = b.side end
            end
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

-- the target's nameplate, nil while it has none showing or it's one addons can't use
local function TargetPlate()
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return nil end
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, "target")
    if not ok or type(plate) ~= "table" then return nil end
    local okF, forbidden = pcall(plate.IsForbidden, plate)
    if not okF or Bool(forbidden) ~= false then return nil end
    local okV, visible = pcall(plate.IsVisible, plate)
    if not okV or Bool(visible) ~= true then return nil end
    return plate
end

-- per side: the set's point, the plate's point and the gap between them
local PLATE_SIDES = {
    top = { "BOTTOM", "TOP", 0, 4 },
    left = { "RIGHT", "LEFT", -4, 0 },
    right = { "LEFT", "RIGHT", 4, 0 },
}
OSA.PLATE_SIDES = { "top", "left", "right" }

local function PlateSide(bar)
    return PLATE_SIDES[bar.side or "top"] or PLATE_SIDES.top
end

-- the middle of the plate's side, or its top, from the screen centre in the icons' units
local function PlatePoint(plate, side)
    local function Get(m)
        local ok, v, w = pcall(plate[m], plate)
        if ok then return Num(v), Num(w) end
    end
    local cx, cy = Get("GetCenter")
    local x, y = cx, cy
    if side == "left" then x = Get("GetLeft")
    elseif side == "right" then x = Get("GetRight")
    else y = Get("GetTop") end
    local s = Get("GetEffectiveScale")
    local ux, uy = UIParent:GetCenter()
    if not (x and y and s and ux) then return nil end
    s = s / UIParent:GetEffectiveScale()
    return x * s - ux, y * s - uy
end

-- the set's own point facing the plate, from the screen centre, as placed by left, top
local function BarPoint(bar, g, side)
    if side == "left" then return bar.left + g.w, bar.top - g.h / 2 end
    if side == "right" then return bar.left, bar.top - g.h / 2 end
    return bar.left + g.w / 2, bar.top - g.h
end

local function ApplyLayout()
    local db = DB()
    SyncBars()
    local plate
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
        a.plate = nil
        if bar.plate then
            if plate == nil then plate = TargetPlate() or false end
            local ps = PlateSide(bar)
            if plate and pcall(a.SetPoint, a, ps[1], plate, ps[2], bar.px or ps[3], bar.py or ps[4]) then
                a.plate = plate
            else
                a:ClearAllPoints()
            end
        end
        if not a.plate then
            a:SetPoint("CENTER", UIParent, "CENTER", bar.left + g.w / 2, bar.top - g.h / 2)
        end
        a:Show()
    end
    for i = #db.bars + 1, #anchors do anchors[i]:Hide() end
end

-- while dragging, the sets on a nameplate get left, top where they are on screen, so pulling
-- icons out and snapping work as for any set. home keeps where they go without a nameplate.
local function Unplate()
    local ux, uy = UIParent:GetCenter()
    for i, bar in ipairs(DB().bars) do
        local a = anchors[i]
        local ok, ax, ay = false
        if a and a.plate then ok, ax, ay = pcall(a.GetCenter, a) end
        ax, ay = ok and Num(ax), ok and Num(ay)
        if ax and ay and ux then
            local g = Geometry(bar)
            bar.home = { bar.left, bar.top }
            bar.left, bar.top = ax - ux - g.w / 2, ay - uy + g.h / 2
            bar.screen = { bar.left, bar.top }
        end
    end
end

-- after a drag: a set on a nameplate keeps its new place from the plate, and its spot without one.
-- dropped is the set that was dragged.
local function Replate(dropped)
    local plate = TargetPlate()
    for _, bar in ipairs(DB().bars) do
        if bar.plate and (bar.home or bar == dropped) then
            local g = Geometry(bar)
            local moved = bar.screen and { bar.left - bar.screen[1], bar.top - bar.screen[2] }
            local x, y
            if plate then x, y = PlatePoint(plate, bar.side) end
            if x then
                local bx, by = BarPoint(bar, g, bar.side)
                bar.px = math.floor(bx - x + 0.5)
                bar.py = math.floor(by - y + 0.5)
                -- the one dragged keeps its spot without a plate, a set something snapped onto
                -- grows the same way there
                if bar.home then
                    bar.left, bar.top = bar.home[1], bar.home[2]
                    if bar ~= dropped and moved then
                        bar.left, bar.top = bar.left + moved[1], bar.top + moved[2]
                    end
                end
            elseif bar.home and bar ~= dropped then
                -- the plate went away mid-drag: it stays on the plate where it was
                bar.left, bar.top = bar.home[1] + (moved and moved[1] or 0), bar.home[2] + (moved and moved[2] or 0)
            end
        end
        bar.home, bar.screen = nil, nil
    end
end

-- the set an alert's icon is in
local function BarOf(a)
    local key = AlertKey(a)
    for _, bar in ipairs(DB().bars or {}) do
        for _, cell in ipairs(bar.cells) do
            if cell.key == key then return bar end
        end
    end
end

function OSA.OnPlate(a)
    local bar = BarOf(a)
    return bar and bar.plate or false
end

-- put the set alert a is in on the target's nameplate, or take it off
function OSA.SetPlate(a, on)
    SyncBars()
    local bar = BarOf(a)
    if not bar then return end
    bar.plate = on and true or nil
    ApplyLayout()
end

-- icons sliding to a new spot in a growing set: [key] = { bar, fx, fy (from), tx, ty (to), at }
OSA.slides = {}
OSA.SLIDE = 0.2

-- where a slide is at now, eased out, and true when it's there
function OSA.SlideAt(s, now)
    local t = math.min(1, math.max(0, (now - s.at) / OSA.SLIDE))
    t = 1 - (1 - t) * (1 - t)
    return s.fx + (s.tx - s.fx) * t, s.fy + (s.ty - s.fy) * t, t >= 1
end

-- new icons in a growing set come out from under the others: one taking a spot another icon is
-- leaving stays put under it while it slides off, one at the end slides out from under the icon
-- in the spot before it. Sets p.under (how deep: deeper further along) and p.from (where it starts).
function OSA.Reveal(places, bar)
    local function Same(x1, y1, x2, y2) return math.abs(x1 - x2) < 1 and math.abs(y1 - y2) < 1 end
    local leaving = {}
    for _, p in ipairs(places) do
        local s = OSA.slides[p.key]
        if s and s.bar == bar and not Same(s.tx, s.ty, p.x, p.y) then leaving[#leaving + 1] = s end
    end
    for _, p in ipairs(places) do
        local s = OSA.slides[p.key]
        if p.slot and not (s and s.bar == bar) then
            p.under = p.slot
            local vacated
            for _, l in ipairs(leaving) do
                if Same(l.tx, l.ty, p.x, p.y) then vacated = true end
            end
            if not vacated then
                local prev
                for _, q in ipairs(places) do
                    if q.slot and q.slot < p.slot and (not prev or q.slot > prev.slot) then prev = q end
                end
                if prev then p.from = { x = prev.x, y = prev.y } end
            end
        end
    end
end

-- icons going from a growing set, drawn under the rest for a slide: [key] = { a, bar, anchor, s, alpha, dim }
OSA.ghosts = {}

-- an icon whose slide s ended its time in the set: it stays put while another slides over it,
-- or slides back under the icon in the spot before it. Nil when there's nothing to go under.
function OSA.Going(s, placed, now)
    local x, y = OSA.SlideAt(s, now)
    local function Same(x1, y1, x2, y2) return math.abs(x1 - x2) < 1 and math.abs(y1 - y2) < 1 end
    local to, prev
    for k, o in pairs(OSA.slides) do
        if placed[k] and o.bar == s.bar then
            if Same(o.tx, o.ty, x, y) and not Same(o.fx, o.fy, x, y) then to = { x = x, y = y } end
            if o.slot and o.slot < s.slot and (not prev or o.slot > prev.slot) then prev = o end
        end
    end
    to = to or prev and { x = prev.tx, y = prev.ty }
    if not to then return nil end
    return { a = s.a, bar = s.bar, anchor = s.anchor, alpha = s.alpha, dim = s.dim,
        s = { bar = s.bar, fx = x, fy = y, tx = to.x, ty = to.y, at = now } }
end

-- put icon f at its place p in the set, sliding there from where it was when animate is set
function OSA.Slide(f, p, bar, anchor, now, animate)
    local s = OSA.slides[p.key]
    if animate and p.under and not (s and s.bar == bar) then
        -- new: under the others while they uncover it, or sliding out from under one
        local from = p.from or p
        s = { bar = bar, fx = from.x, fy = from.y, tx = p.x, ty = p.y, at = now, under = p.under }
    elseif not (animate and s and s.bar == bar) then
        s = { bar = bar, fx = p.x, fy = p.y, tx = p.x, ty = p.y, at = now - OSA.SLIDE }
    elseif s.tx ~= p.x or s.ty ~= p.y then
        -- from wherever it is, even mid-slide
        local x, y = OSA.SlideAt(s, now)
        s = { bar = bar, fx = x, fy = y, tx = p.x, ty = p.y, at = now }
    end
    OSA.slides[p.key] = s
    local x, y, done = OSA.SlideAt(s, now)
    f.slide = not done and { s = s, anchor = anchor } or nil
    f:ClearAllPoints()
    f:SetPoint("CENTER", anchor, "CENTER", x, y)
end

function OSA.Grows(a)
    local bar = BarOf(a)
    return bar and bar.grow or false
end

-- the set alert a is in grows: its showing icons fill its spots in the alerts' order
function OSA.SetGrow(a, on)
    SyncBars()
    local bar = BarOf(a)
    if not bar then return end
    bar.grow = on and true or nil
    ApplyLayout()
end

function OSA.PlateSideOf(a)
    local bar = BarOf(a)
    return bar and bar.side or "top"
end

-- which side of the plate the alert's set goes, which puts it back to the plate's edge
function OSA.SetPlateSide(a, side)
    SyncBars()
    local bar = BarOf(a)
    if not bar or not PLATE_SIDES[side] then return end
    bar.side = side ~= "top" and side or nil
    bar.px, bar.py = nil, nil
    ApplyLayout()
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
    if bar.grow then
        -- the placed icons are spots, in the alerts' order. The showing icons take them in that
        -- order, so they fill the first spots and close up when one goes.
        local rank = {}
        for i, a in ipairs(DB().alerts) do rank[AlertKey(a)] = i end
        local spots, list = {}, {}
        for _, cell in ipairs(bar.cells) do
            table.insert(spots, cell)
            if showing[cell.key] then table.insert(list, cell) end
        end
        local function Before(p, q)
            local rp, rq = rank[p.key] or math.huge, rank[q.key] or math.huge
            if rp ~= rq then return rp < rq end
            return p.r < q.r or (p.r == q.r and p.c < q.c)
        end
        table.sort(spots, Before)
        table.sort(list, Before)
        local slotOf = {}
        for i, cell in ipairs(spots) do slotOf[cell.key] = i end
        for i, cell in ipairs(list) do
            local spot = spots[i]
            -- the icon centred in the spot's column and row, lined up as the spot's icon was
            local pw, ph = KeyPitches(cell.key)
            local cw, rh = g.cw[spot.c], g.rh[spot.r]
            table.insert(out, { key = cell.key, slot = slotOf[cell.key],
                x = g.cx[spot.c] + cw / 2 + (spot.ha or 0) * (cw - pw) / 2 - g.w / 2,
                y = -g.ry[spot.r] - rh / 2 - (spot.va or 0) * (rh - ph) / 2 + g.h / 2 })
        end
    elseif shape == "row" or shape == "column" then
        local list, total = {}, 0
        for _, cell in ipairs(bar.cells) do
            if showing[cell.key] then
                table.insert(list, cell)
                local pw, ph = KeyPitches(cell.key)
                total = total + (shape == "column" and ph or pw)
            end
        end
        table.sort(list, function(p, q) return p.c + p.r < q.c + q.r end)
        local pos = -total / 2
        for _, cell in ipairs(list) do
            local pw, ph = KeyPitches(cell.key)
            local p = shape == "column" and ph or pw
            local d = pos + p / 2
            pos = pos + p
            if shape == "column" then
                table.insert(out, { key = cell.key, x = (cell.ha or 0) * (g.w - pw) / 2, y = -d })
            else
                table.insert(out, { key = cell.key, x = d, y = -(cell.va or 0) * (g.h - ph) / 2 })
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
    local limit = 0.75 * math.min(KeyPitches(TopLeftCell(d).key))
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
    Unplate()
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
            local pw, ph = KeyPitches(f.key)
            bar = { left = x - pw / 2, top = y + ph / 2, cells = { { key = f.key, c = 0, r = 0 } } }
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
    if not i then Replate() return end
    local a = anchors[i]
    a:StopMovingOrSizing()
    local ax, ay = a:GetCenter()
    local ux, uy = UIParent:GetCenter()
    ax, ay = Num(ax), Num(ay)
    if ax and ay and ux then
        local g = Geometry(bar)
        bar.left, bar.top = ax - ux - g.w / 2, ay - uy + g.h / 2
    end
    SnapBar(bar)
    Replate(bar)
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
    if f.bar and f.bar.plate then
        GameTooltip:AddLine("On your target's nameplate: drag it to place it on the plate. With no "
            .. "nameplate showing, drag it to place it for then.", 0.4, 0.8, 1, true)
    end
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

-- an icon's border: a thin black edge (the default, a.border nil), the action bar's frame, a thick
-- black edge, or none
local BORDER_LINES = { thin = 1, thick = 3 }
OSA.BORDERS = { "thin", "action", "thick", "none" }
OSA.BORDER_NAMES = { action = "Action bar", thin = "Thin black", thick = "Thick black", none = "None" }

local function BorderOf(a)
    local b = a and a.border
    if b == "thick" or b == "none" then return b end
    -- without the action bar's art: a thin black edge
    if b == "action" and HasAtlas(ICON_FRAME) then return "action" end
    return "thin"
end

-- draws s's border in style, redrawing only what changed. s = { host = the icon's frame, over = the
-- frame its edge textures go on, masked = the textures the action bar frame rounds the corners of }
local function StyleBorder(s, style)
    if s.style == style then return end
    s.style = style
    local action = style == "action"
    if action and not s.art then
        s.art = s.over:CreateTexture(nil, "OVERLAY", nil, 2)
        s.art:SetAtlas(ICON_FRAME)
        s.art:SetAllPoints(s.host)
    end
    if s.art then s.art:SetShown(action) end
    local canMask = HasAtlas(ICON_MASK) and s.host.CreateMaskTexture and s.masked[1].AddMaskTexture
    if action and canMask and not s.isMasked then
        if not s.mask then
            s.mask = s.host:CreateMaskTexture()
            s.mask:SetAtlas(ICON_MASK)
            s.mask:SetAllPoints(s.host)
        end
        for _, t in ipairs(s.masked) do t:AddMaskTexture(s.mask) end
        s.isMasked = true
    elseif not action and s.isMasked then
        for _, t in ipairs(s.masked) do t:RemoveMaskTexture(s.mask) end
        s.isMasked = false
    end
    local px = BORDER_LINES[style]
    if px and not s.lines then
        s.lines = {}
        for i = 1, 4 do
            local t = s.over:CreateTexture(nil, "OVERLAY", nil, 2)
            t:SetColorTexture(0, 0, 0, 1)
            s.lines[i] = t
        end
    end
    if s.lines then
        local top, bottom, left, right = unpack(s.lines)
        if px then
            -- lines over the icon's edges, so the icon keeps its size
            top:ClearAllPoints(); top:SetPoint("TOPLEFT", s.host); top:SetPoint("TOPRIGHT", s.host)
            top:SetHeight(px)
            bottom:ClearAllPoints(); bottom:SetPoint("BOTTOMLEFT", s.host); bottom:SetPoint("BOTTOMRIGHT", s.host)
            bottom:SetHeight(px)
            left:ClearAllPoints(); left:SetPoint("TOPLEFT", s.host); left:SetPoint("BOTTOMLEFT", s.host)
            left:SetWidth(px)
            right:ClearAllPoints(); right:SetPoint("TOPRIGHT", s.host); right:SetPoint("BOTTOMRIGHT", s.host)
            right:SetWidth(px)
        end
        for _, t in ipairs(s.lines) do t:SetShown(px and true or false) end
    end
end

-- looks ------------------------------------------------------------------------------------------
-- A look draws a layer over the icon while its conditions hold: a dark shade, a grey or coloured
-- copy of the icon, or the gold proc glow. Conditions are joined by "and" and "or", "and" binding
-- tighter. In combat the game hides your power and the target's health, so the addon can't compare
-- them itself. Instead it gives the game a curve (below 30% -> 1, from 30% on -> 0), the game looks
-- the value up and hands back the answer, secret, and that goes straight to the layer's alpha. What
-- can be read (combo points, and anything out of combat) is settled by the addon first; what's left
-- becomes one or more layers, so an "or" of hidden things can draw the effect twice.

local TINTS = { red = { 1, 0.25, 0.25 }, green = { 0.3, 1, 0.3 }, blue = { 0.35, 0.55, 1 } }
local curves = {}
-- your highest power, kept from when it could be read, to turn points into the curve's 0 to 1
local powerMax = {}

-- a step curve over 0 to 1 that's 1 inside any of segs, { {lo, hi}, ... } (lo included, hi not),
-- and 0 elsewhere
local function SegCurve(segs)
    local parts, cuts = {}, {}
    for _, s in ipairs(segs) do
        table.insert(parts, s[1] .. ":" .. s[2])
        for _, x in ipairs(s) do
            if x > 0 and x < 1 then table.insert(cuts, x) end
        end
    end
    local key = table.concat(parts, ",")
    if curves[key] ~= nil then return curves[key] or nil end
    table.sort(cuts)
    local ok, c = pcall(function()
        local c = C_CurveUtil.CreateCurve()
        c:SetType(Enum.LuaCurveType.Step)
        local function At(x)
            for _, s in ipairs(segs) do
                if x >= s[1] and x < s[2] then return 1 end
            end
            return 0
        end
        c:AddPoint(0, At(0))
        local last = 0
        for _, x in ipairs(cuts) do
            if x > last then c:AddPoint(x, At(x)) last = x end
        end
        c:AddPoint(1, At(1))
        return c
    end)
    curves[key] = ok and c or false
    return ok and c or nil
end

local function CanCurve()
    return C_CurveUtil and C_CurveUtil.CreateCurve and Enum and Enum.LuaCurveType and true or false
end

local HUGE = math.huge
-- where the rule holds, from lo up to, not including, hi. Power and combo points are whole, so
-- "< 30" is 29 or less and "= 30" is 30. Health is a percent with fractions: "< 30" is under 30%,
-- "<= 30" is 30% or less, and "= 30" rounds, 29.5% up to 30.5%.
local function Range(r)
    local n = r.n
    if r.what == "health" then
        local e = 0.001
        if r.op == "<" then return -HUGE, n end
        if r.op == "<=" then return -HUGE, n + e end
        if r.op == "=" then return n - 0.5, n + 0.5 end
        if r.op == ">=" then return n, HUGE end
        return n + e, HUGE
    end
    if r.op == "<" then return -HUGE, n - 0.5 end
    if r.op == "<=" then return -HUGE, n + 0.5 end
    if r.op == "=" then return n - 0.5, n + 0.5 end
    if r.op == ">=" then return n - 0.5, HUGE end
    return n + 0.5, HUGE
end

-- what can be read right now: combo points, your power and the target's health, each nil when hidden
local function Readings()
    local okT, pType = pcall(UnitPowerType, "player")
    pType = okT and Num(pType) or 0
    local okP, p = pcall(UnitPower, "player", pType)
    local okM, m = pcall(UnitPowerMax, "player", pType)
    m = okM and Num(m)
    if m and m > 0 then powerMax[pType] = m end
    local target = Bool(UnitExists("target")) and true or false
    local health
    if target then
        local okH, h = pcall(UnitHealth, "target")
        local okHM, hm = pcall(UnitHealthMax, "target")
        h, hm = okH and Num(h), okHM and Num(hm)
        if h and hm and hm > 0 then health = h * 100 / hm end
    end
    return { cp = Num(ComboPoints()), power = okP and Num(p) or nil, pType = pType,
        max = powerMax[pType] or 100, target = target, health = health }
end

-- a look's conditions split at each "or": { { cond, cond }, { cond } }. "and" binds tighter.
local function Terms(look)
    local terms, term = {}, nil
    for i, c in ipairs(look.conds) do
        if i == 1 or c.join == "or" then
            term = {}
            table.insert(terms, term)
        end
        table.insert(term, c)
    end
    return terms
end

-- What the game has to draw for a look. Each draw is a layer: { p = power segments, h = health
-- segments } as fractions, either or both left for the game to check because they're hidden, or
-- neither for a layer that's simply on. Returns {} when the look is off. Everything readable is
-- settled here; the hidden parts of terms that check only power (or only health) merge into one
-- draw, so "energy < 30 or energy > 80" is one layer.
function OSA.LookDraws(look, rd)
    rd = rd or Readings()
    local powerOnly, healthOnly, mixed = {}, {}, {}
    local function Frac(x, max)
        if x == -HUGE then return -1 end
        if x == HUGE then return 2 end
        return x / max
    end
    for _, term in ipairs(Terms(look)) do
        -- each kind of value must be in all of its ranges
        local rng = {}
        for _, c in ipairs(term) do
            local lo, hi = Range(c)
            local r = rng[c.what]
            if r then
                r[1], r[2] = math.max(r[1], lo), math.min(r[2], hi)
            else
                rng[c.what] = { lo, hi }
            end
        end
        local holds, p, h = true, nil, nil
        for what, r in pairs(rng) do
            if r[1] >= r[2] then
                holds = false
            elseif what == "cp" then
                -- combo points can be read; unknown counts as not met
                if not (rd.cp and rd.cp >= r[1] and rd.cp < r[2]) then holds = false end
            elseif what == "health" then
                if not rd.target then
                    holds = false
                elseif rd.health then
                    if not (rd.health >= r[1] and rd.health < r[2]) then holds = false end
                else
                    h = { Frac(r[1], 100), Frac(r[2], 100) }
                end
            elseif rd.power then
                if not (rd.power >= r[1] and rd.power < r[2]) then holds = false end
            else
                p = { Frac(r[1], rd.max), Frac(r[2], rd.max) }
            end
        end
        if holds then
            if not p and not h then return { {} } end
            if p and h then
                table.insert(mixed, { p = { p }, h = { h } })
            elseif p then
                table.insert(powerOnly, p)
            else
                table.insert(healthOnly, h)
            end
        end
    end
    local draws = {}
    if #powerOnly > 0 then table.insert(draws, { p = powerOnly }) end
    if #healthOnly > 0 then table.insert(draws, { h = healthOnly }) end
    for _, d in ipairs(mixed) do table.insert(draws, d) end
    for _, d in ipairs(draws) do d.pType = rd.pType end
    return draws
end

-- the game's answers for a draw: true, power's (1, 0 or secret, nil if not asked), health's; false
-- when it can't be asked
function OSA.DrawValues(d)
    local pv, hv
    if d.p then
        local curve = UnitPowerPercent and CanCurve() and SegCurve(d.p)
        if not curve then return false end
        local ok, v = pcall(UnitPowerPercent, "player", d.pType, false, curve)
        if not ok then return false end
        pv = v
    end
    if d.h then
        local curve = UnitHealthPercent and CanCurve() and SegCurve(d.h)
        if not curve then return false end
        local ok, v = pcall(UnitHealthPercent, "target", true, curve)
        if not ok then return false end
        hv = v
    end
    return true, pv, hv
end

-- a new layer of this effect on the icon f
local function MakeLook(f, fx)
    local t
    if fx == "glow" then
        if HasAtlas("UI-HUD-ActionBar-Proc-Loop-Flipbook") then
            t = f:CreateTexture(nil, "OVERLAY", nil, 3)
            t:SetAtlas("UI-HUD-ActionBar-Proc-Loop-Flipbook")
            -- the action bar draws it 1.4 times the button
            t.out = 0.2
            pcall(function()
                local spin = t:CreateAnimationGroup()
                spin:SetLooping("REPEAT")
                local fb = spin:CreateAnimation("FlipBook")
                fb:SetDuration(1)
                fb:SetFlipBookRows(6)
                fb:SetFlipBookColumns(5)
                fb:SetFlipBookFrames(30)
                fb:SetFlipBookFrameWidth(0)
                fb:SetFlipBookFrameHeight(0)
                spin:Play()
            end)
        else
            -- the older look: a soft gold glow past the edges
            t = f:CreateTexture(nil, "OVERLAY", nil, 3)
            t:SetTexture("Interface\\SpellActivationOverlay\\IconAlert")
            t:SetTexCoord(0.0078125, 0.5078125, 0.27734375, 0.52734375)
            t.out = 0.25
        end
    else
        -- the shade over the tints, so a dimmed red icon is dark red
        t = f:CreateTexture(nil, "ARTWORK", nil, fx == "dim" and 2 or 1)
        t:SetAllPoints(f.tex)
        if fx == "dim" then
            t:SetColorTexture(0, 0, 0, 0.6)
        else
            -- a copy of the icon, grey or tinted, over it. It's opaque, so two of them on top of
            -- each other look like one.
            t.copy = true
            t:SetDesaturated(true)
        end
        -- the action bar border's rounded corners take it too
        table.insert(f.border.masked, t)
        if f.border.isMasked and f.border.mask then t:AddMaskTexture(f.border.mask) end
    end
    t.fx = fx
    return t
end

-- sets layer t's colour and alpha from the draw's answer. A texture's alpha is its colour's alpha,
-- so the colour goes first. Only one hidden answer fits on a layer: a draw needing both your power
-- and the target's health hidden can't be shown, and stays off.
local function SetLookAlpha(t, d)
    local c = TINTS[t.fx] or { 1, 1, 1 }
    t:SetVertexColor(c[1], c[2], c[3], 1)
    local ok, pv, hv = OSA.DrawValues(d)
    if ok and d.p and d.h then ok = false end
    local alpha = 1
    if d.p then alpha = pv elseif d.h then alpha = hv end
    if ok then ok = pcall(t.SetAlpha, t, alpha) end
    if not ok then t:SetAlpha(0) end
end

-- draws the alert's looks on the icon f, or none (off is true while previewing)
local function ApplyLooks(f, a, off)
    f.looks = f.looks or {}
    local used = {}
    if not off and a.looks then
        local rd = Readings()
        for _, look in ipairs(a.looks) do
            local fx = look.fx
            for _, d in ipairs(OSA.LookDraws(look, rd)) do
                used[fx] = (used[fx] or 0) + 1
                local list = f.looks[fx] or {}
                f.looks[fx] = list
                local t = list[used[fx]]
                if not t then
                    t = MakeLook(f, fx)
                    list[used[fx]] = t
                end
                if t.copy then
                    t:SetTexture(f.tex:GetTexture())
                    t:SetTexCoord(f.tex:GetTexCoord())
                end
                if t.out then
                    local w, h = f:GetSize()
                    local ox, oy = math.floor(w * t.out + 0.5), math.floor(h * t.out + 0.5)
                    t:ClearAllPoints()
                    t:SetPoint("TOPLEFT", f, "TOPLEFT", -ox, oy)
                    t:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", ox, -oy)
                end
                t:Show()
                SetLookAlpha(t, d)
            end
        end
    end
    for fx, list in pairs(f.looks) do
        for i = (used[fx] or 0) + 1, #list do list[i]:Hide() end
    end
end

-- what a condition says, ex: "My energy > 80"
function OSA.DescribeCond(c)
    local n = c.what == "health" and (c.n .. "%") or tostring(c.n)
    return ("%s %s %s"):format(OSA.LOOK_WHAT_NAMES[c.what], c.op, n)
end

-- what a look says, ex: "Glow: Combo points = 5 and Target health >= 10%"
function OSA.DescribeLook(look)
    local parts = {}
    for i, c in ipairs(look.conds) do
        table.insert(parts, (i > 1 and ((c.join or "and") .. " ") or "") .. OSA.DescribeCond(c))
    end
    return OSA.LOOK_FX_NAMES[look.fx] .. ": " .. table.concat(parts, " ")
end

-- what the probe says about a look: on, off, or what's left for the game to check
function OSA.ProbeLook(look)
    local draws = OSA.LookDraws(look)
    if #draws == 0 then return "off" end
    local parts = {}
    for _, d in ipairs(draws) do
        if not d.p and not d.h then return "on" end
        local ok, pv, hv = OSA.DrawValues(d)
        if d.p and d.h then
            table.insert(parts, "energy and health both hidden, not drawn")
        elseif not ok then
            table.insert(parts, "can't ask the game")
        else
            table.insert(parts, d.p and ("energy " .. Show(pv)) or ("health " .. Show(hv)))
        end
    end
    return table.concat(parts, ", or ")
end

local function MakeIcon(i)
    local f = CreateFrame("Frame", nil, holder)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    f.tex:SetAllPoints()
    f.count = f:CreateFontString(nil, "OVERLAY", "NumberFontNormalLarge")
    f.count:SetPoint("BOTTOMRIGHT", -3, 3)
    -- unlocked, a growing set's icons show their spot's number
    f.slot = f:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    f.slot:SetPoint("TOPLEFT", 3, -3)
    f.slot:SetTextColor(1, 0.82, 0)
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
    -- the border, set by the alert shown in it. The shade and the light take the icon's rounded
    -- corners too.
    f.border = { host = f, over = f, masked = { f.tex, f.shade, f.queued } }
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

-- aura buttons, see "debuffs on the target" ------------------------------------------------------
local LIVE_SLOT = "debuff"

-- stack counts from 2 up, like Blizzard's, so a debuff without stacks shows no "1"
local function CountFormatter()
    if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter) then return nil end
    local ok, fm = pcall(function()
        local fm = C_StringUtil.CreateNumericRuleFormatter()
        fm:SetBreakpoints({ { threshold = 0, format = "" }, { threshold = 2, format = "%d" } })
        -- Blizzard formats inside its aura update, make sure it can't fail there
        for n = 0, 2 do
            local text = fm:FormatNumber(n)
            if type(text) ~= "string" or issecretvalue(text) or (n < 2 and text ~= "") then
                error("formatted " .. n .. " as " .. tostring(text))
            end
        end
        return fm
    end)
    return ok and fm or nil
end

-- called by Blizzard once, when it makes the slot's button: drawn like our icons, with the time left
-- as a swipe and the stacks. Frames in the button can't get scripts.
local function InitLiveButton(l, button)
    l.button = button
    local ok, err = pcall(function()
        pcall(button.EnableMouse, button, false)
        button:ClearAllPoints()
        button:SetPoint("CENTER", button:GetParent(), "CENTER", 0, 0)
        button:SetSize(l.w, l.h)
        local tex = button:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints()
        tex:SetTexCoord(IconCoords(l.w, l.h))
        l.tex = tex
        button:SetIcon(tex)
        if l.gate then
            -- a gate draws the alert's spell, ex: Ice Lance, not the debuff the game fills it with.
            -- It's drawn here, as the game won't let addons touch the button later in combat.
            tex:SetAlpha(0)
            local face = button:CreateTexture(nil, "ARTWORK", nil, 1)
            face:SetAllPoints()
            face:SetTexCoord(IconCoords(l.w, l.h))
            l.face = face
            face:SetTexture(l.icon or 134400)
            l.border = { host = button, over = button, masked = { face } }
            StyleBorder(l.border, l.style)
            return
        end
        local cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
        cd:SetAllPoints()
        cd:SetDrawEdge(false)
        -- what's wanted is the debuff, so it darkens as it runs out
        pcall(cd.SetReverse, cd, true)
        pcall(cd.SetHideCountdownNumbers, cd, true)
        button:SetDurationCooldown(cd)
        local over = CreateFrame("Frame", nil, button)
        over:SetAllPoints()
        over:SetFrameLevel(cd:GetFrameLevel() + 2)
        l.border = { host = button, over = over, masked = { tex } }
        StyleBorder(l.border, l.style)
        local count = over:CreateFontString(nil, "OVERLAY", "NumberFontNormalLarge")
        count:SetPoint("BOTTOMRIGHT", -3, 3)
        local fm = CountFormatter()
        button:SetApplicationCount(count, fm and { formatter = fm } or nil)
    end)
    if not ok then Debug("styling the debuff button failed: " .. tostring(err)) end
end

-- a holder with a container on the target, whose one slot the game fills while one of the ids is on
-- it. The holder is ours, so it can be moved and faded in combat.
local function MakeLive(a, ids, key)
    local w = a.size or Size()
    local l = { filter = AuraFilter(a), w = w, h = a.height or w, gate = a.kind ~= "aura" or nil,
        style = BorderOf(a) }
    if l.gate then
        local id = AlertSpell(a)
        l.icon = id and SpellIcon(id) or nil
    end
    l.holder = CreateFrame("Frame", nil, UIParent)
    l.holder:SetSize(l.w, l.h)
    l.holder:SetPoint("CENTER")
    l.holder:SetFrameLevel(holder:GetFrameLevel() + 20)
    l.holder:SetAlpha(0)
    local ok, err = pcall(function()
        local c = CreateFrame("AuraContainer", nil, l.holder, "CustomAuraContainerTemplate")
        c:SetPoint("CENTER")
        c:SetSize(l.w, l.h)
        c:SetUnit("target")
        pcall(c.EnableMouse, c, false)
        l.container = c
        c:AddAuraSlot(LIVE_SLOT, l.filter, {
            candidateFilters = { includeSpellIDs = ids },
            initializeFrame = function(button) InitLiveButton(l, button) end,
        })
        -- as Click Cast's containers do
        pcall(c.SetEnabled, c, true)
    end)
    if ok then
        l.ids = key
    else
        l.err = tostring(err)
        Debug(("%s: Blizzard's aura button can't be made, %s"):format(a.spell, l.err))
    end
    return l
end

-- make, refilter and resize the aura alerts' buttons, out of combat only: the game refuses changes
-- to them in combat and while auras are hidden
local function UpdateLive()
    if InCombatLockdown() or (C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret()) then
        return
    end
    local keep = {}
    for _, a in ipairs(DB().alerts) do
        if AuraNames(a) then
            keep[a] = true
            local l = live[a]
            if l and (l.filter ~= AuraFilter(a) or (l.gate and true or false) ~= (a.kind ~= "aura")) then
                -- mine or anyone's is the slot's own filter, so it takes a new container
                l.holder:Hide()
                l, live[a] = nil, nil
            end
            local ids, key = AuraIds(a)
            if not l and key ~= "" then
                live[a] = MakeLive(a, ids, key)
            elseif l and l.container and not l.err then
                if key ~= "" and key ~= l.ids and pcall(l.container.SetAuraSlotCandidateFilters, l.container,
                    LIVE_SLOT, { includeSpellIDs = ids }) then
                    l.ids = key
                end
                local w = a.size or Size()
                local h = a.height or w
                if w ~= l.w or h ~= l.h then
                    l.w, l.h = w, h
                    pcall(l.holder.SetSize, l.holder, w, h)
                    pcall(l.container.SetSize, l.container, w, h)
                    if l.button then pcall(l.button.SetSize, l.button, w, h) end
                    for _, t in ipairs({ l.tex or false, l.face or false }) do
                        if t then pcall(t.SetTexCoord, t, IconCoords(w, h)) end
                    end
                end
                l.style = BorderOf(a)
                if l.border then pcall(StyleBorder, l.border, l.style) end
                -- at login the spellbook can still be empty, so the gate's spell icon is read again
                -- until it's found, else the button keeps the question mark
                if l.gate then
                    local id = AlertSpell(a)
                    local icon = id and SpellIcon(id) or nil
                    if icon and icon ~= l.icon then
                        l.icon = icon
                        if l.face then pcall(l.face.SetTexture, l.face, icon) end
                    end
                end
            end
        end
    end
    for a, l in pairs(live) do
        if not keep[a] then
            if l.holder then l.holder:Hide() end
            live[a] = nil
        end
    end
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
    UpdateLive()
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
        local id = not preview and not a.off and a.kind ~= "aura" and AlertSpell(a)
        if id then queued, queuedSecret = Queued(id) end
        if queued and on ~= true and not Suppressed(a) then
            on, secret, dim, flash = true, nil, nil, nil
        end
        if on ~= false then
            showing[AlertKey(a)] = { a = a, on = on, secret = secret, dim = dim, flash = flash,
                queued = queued, queuedSecret = queuedSecret,
                -- Blizzard's button is the icon, ours only keeps its place under it
                live = not preview and a.kind == "aura" and Live(a) or nil,
                -- our icon goes inside Blizzard's button, which shows only while a debuff is on
                gate = not preview and gating[a] or nil }
        end
    end
    if dragging and not (db.unlocked and IsMouseButtonDown and IsMouseButtonDown("LeftButton")) then
        -- locked mid-drag, or a drag whose icon went away never gets its OnDragStop
        OSA.IconDragStop()
    end
    -- sizes may have changed, but a set being dragged is left where the mouse has it
    if not dragging or SyncBars() then ApplyLayout() end
    local shown = 0
    -- [alert] = true for the aura buttons placed this time, the rest are faded out
    local liveShown = {}
    -- the keys placed this time: an icon that went away pops back in at its spot, without a slide
    local placedKeys = {}
    for bi, bar in ipairs(db.bars) do
        local places = PlaceIcons(bar, showing)
        local animate = bar.grow and not db.unlocked and not dragging
        if animate then OSA.Reveal(places, bar) end
        for _, p in ipairs(places) do
            local s = showing[p.key]
            local a, on, secret, dim, flash = s.a, s.on, s.secret, s.dim, s.flash
            shown = shown + 1
            local f = icons[shown] or MakeIcon(shown)
            f.key, f.bar = p.key, bar
            local id = AlertSpell(a)
            local w, h = KeyDims(p.key)
            f:SetSize(w, h)
            f.tex:SetTexCoord(IconCoords(w, h))
            StyleBorder(f.border, BorderOf(a))
            -- in a growing set, an icon whose spot changed slides there
            OSA.Slide(f, p, bar, anchors[bi], now, animate)
            placedKeys[p.key] = true
            -- a new icon is drawn under the ones uncovering it until it's out
            local sl = OSA.slides[p.key]
            -- what a going icon needs to be drawn while it's covered
            sl.a, sl.anchor, sl.slot, sl.dim = a, anchors[bi], p.slot, dim and true or false
            local under = sl and sl.under and now - sl.at < OSA.SLIDE and sl.under
            f:SetFrameLevel(holder:GetFrameLevel() + (under and math.max(1, 9 - under) or 10))
            f:EnableMouse(db.unlocked and true or false)
            f.tex:SetTexture(a.kind == "aura" and AuraIcon(a) or id and SpellIcon(id) or 134400)
            f.queued:SetShown(s.queued and true or false)
            if s.queuedSecret ~= nil and f.queued.SetAlphaFromBoolean
                and pcall(f.queued.SetAlphaFromBoolean, f.queued, s.queuedSecret, 1, 0) then
                f.queued:Show()
            else
                f.queued:SetAlpha(1)
            end
            -- the combo points, on combo alerts and alerts that want some (a 0 left from a combo
            -- alert doesn't count)
            local cp = (a.kind == "combo" or (a.cp or 0) > 0) and Num(ComboPoints())
            f.count:SetText(cp and tostring(cp) or "")
            f.slot:SetText(db.unlocked and p.slot and tostring(p.slot) or "")
            local left = not preview and early[a] and early[a] - GetTime()
            f.shade:SetShown(left and true or false)
            -- tenths under 3 seconds, unless the Whole seconds option is on
            f.timer:SetText(left and (left < 3 and not db.wholeSeconds and ("%.1f"):format(left)
                or ("%d"):format(math.ceil(left))) or "")
            local alpha = db.unlocked and 0.6 or dim and DIM or 1
            -- the fade is set every frame, see OnUpdate
            f.flash = flash and { at = flash, len = a.flash, alpha = alpha } or nil
            f:SetAlpha(flash and alpha * FlashAlpha(a.flash, now - flash) or alpha)
            f.tex:SetDesaturated(dim and true or false)
            ApplyLooks(f, a, preview)
            if on == nil and secret ~= nil then
                -- only the game knows: let it set the alpha, and play no sound
                if not (f.SetAlphaFromBoolean and pcall(f.SetAlphaFromBoolean, f, secret, 1, 0)) then f:SetAlpha(1) end
            end
            f.live = nil
            -- unlocked, our icon shows so it can be dragged
            local l = not db.unlocked and (s.live or s.gate)
            if l then
                -- Blizzard's button shows the debuff, or for a gate the alert's spell while a
                -- debuff is on, over our icon, which only keeps its place. A fade is on the
                -- button's holder.
                f:SetAlpha(0)
                f.live = l.holder
                l.holder:ClearAllPoints()
                l.holder:SetPoint("CENTER", f, "CENTER")
                local full = l.gate and (dim and DIM or 1) or 1
                l.holder:SetAlpha(flash and full * FlashAlpha(a.flash, now - flash) or full)
                if f.flash then f.flash.alpha = full end
                -- a gate also needs the spell castable, which only the game may know
                if l.gate and on == nil and secret ~= nil and not (l.holder.SetAlphaFromBoolean
                    and pcall(l.holder.SetAlphaFromBoolean, l.holder, secret, full, 0)) then
                    l.holder:SetAlpha(full)
                end
                liveShown[a] = true
            end
            -- a Blizzard button, or an icon the game shows or hides, isn't drawn going
            sl.alpha = not l and on ~= nil and (flash and alpha * FlashAlpha(a.flash, now - flash) or alpha) or nil
            f:Show()
        end
    end
    -- icons that went from a growing set: covered by the one sliding into their spot, or sliding
    -- back under the one before them, then gone
    for k, s in pairs(OSA.slides) do
        if not placedKeys[k] then
            OSA.slides[k] = nil
            if s.alpha and s.slot and s.bar.grow and not db.unlocked and not dragging and not preview then
                OSA.ghosts[k] = OSA.Going(s, placedKeys, now)
            end
        end
    end
    for k, gh in pairs(OSA.ghosts) do
        if placedKeys[k] or now - gh.s.at >= OSA.SLIDE or not gh.bar.grow or db.unlocked or preview then
            OSA.ghosts[k] = nil
        else
            shown = shown + 1
            local f = icons[shown] or MakeIcon(shown)
            local a = gh.a
            local id = AlertSpell(a)
            local w, h = KeyDims(k)
            f.key, f.bar, f.flash, f.live = nil, nil, nil, nil
            f:SetSize(w, h)
            f.tex:SetTexCoord(IconCoords(w, h))
            StyleBorder(f.border, BorderOf(a))
            f.tex:SetTexture(a.kind == "aura" and AuraIcon(a) or id and SpellIcon(id) or 134400)
            f.tex:SetDesaturated(gh.dim)
            f.queued:Hide()
            f.shade:Hide()
            f.count:SetText("")
            f.slot:SetText("")
            f.timer:SetText("")
            ApplyLooks(f, a, true)
            f:EnableMouse(false)
            f:SetAlpha(gh.alpha)
            local x, y, done = OSA.SlideAt(gh.s, now)
            f:ClearAllPoints()
            f:SetPoint("CENTER", gh.anchor, "CENTER", x, y)
            f.slide = not done and { s = gh.s, anchor = gh.anchor } or nil
            f:SetFrameLevel(holder:GetFrameLevel() + 1)
            f:Show()
        end
    end
    for i = shown + 1, #icons do
        icons[i]:Hide()
        icons[i].flash = nil
        icons[i].slide = nil
        icons[i].live = nil
        icons[i].key, icons[i].bar = nil, nil
        if icons[i]:GetParent() ~= holder then pcall(icons[i].SetParent, icons[i], holder) end
    end
    for a, l in pairs(live) do
        if not liveShown[a] and l.holder then l.holder:SetAlpha(0) end
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
        local n = Num(spellID) and SpellName(spellID)
        if n and n:lower():find("totem", 1, true) then Totem.Cast(n) end
    elseif event == "PLAYER_TOTEM_UPDATE" then
        Totem.Changed(...)
    elseif event == "PLAYER_ENTERING_WORLD" then
        Totem.ReadAll()
    elseif event == "PLAYER_TARGET_CHANGED" then
        -- casts on a target whose guid couldn't be read belong to the old target
        for _, byTarget in pairs(casts) do byTarget["?"] = nil end
        -- the aura buttons follow the new target (they may already)
        if not InCombatLockdown() then
            for a, l in pairs(live) do
                if l.container and not l.err then
                    local ok, err = pcall(l.container.SetUnit, l.container, "target")
                    if not ok then Debug(("%s: aura button target: %s"):format(a.spell, tostring(err))) end
                end
            end
        end
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
        if fl then (f.live or f):SetAlpha(fl.alpha * FlashAlpha(fl.len, now - fl.at)) end
        local sl = f.slide
        if sl and f:IsShown() then
            local x, y, done = OSA.SlideAt(sl.s, now)
            f:ClearAllPoints()
            f:SetPoint("CENTER", sl.anchor, "CENTER", x, y)
            if done then f.slide = nil end
        end
    end
    elapsed = elapsed + dt
    if elapsed < TICK or not holder then return end
    elapsed = 0
    -- an aura alert's name being looked up
    if ScanStep() then OSA.Changed() end
    if #DB().alerts > 0 or DB().unlocked then OSA.Update() end
end)

Register("ADDON_LOADED")
Register("PLAYER_LOGIN")
Register("PLAYER_ENTERING_WORLD")
Register("SPELLS_CHANGED")
Register("LEARNED_SPELL_IN_TAB")
Register("PLAYER_TARGET_CHANGED")
-- sets on the target's nameplate move to it, or off it, at once
Register("NAME_PLATE_UNIT_ADDED")
Register("NAME_PLATE_UNIT_REMOVED")
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

local function ProbeAura(a)
    local _, key = AuraIds(a)
    Print(("%s (%s on the target, %s): spell ids %s%s"):format(a.spell,
        table.concat(AuraNames(a), " or "), a.anyone and "anyone's" or "yours",
        key ~= "" and key or "none yet", Searching(a) and ", still looking them up" or ""))
    local l = live[a]
    local button = "none"
    if l and l.button then
        local ok, v = pcall(l.button.IsShown, l.button)
        button = not ok and ("made, the game won't say if it's shown (" .. tostring(v) .. ")") or issecretvalue(v) and "made, shown is secret (no sound in combat)"
            or ("made, shown " .. tostring(v))
    end
    Print(("  aura button: %s; button %s"):format(
        not l and "not made" or l.err and ("failed: " .. tostring(l.err)) or "made", button))
    local up = ReadAura(a)
    local on
    if a.kind == "aura" then on = AuraState(a) else on = Gate(a) end
    Print(("  read directly: %s; we say %s"):format(up == nil and "unknown" or tostring(up),
        on == nil and "unknown, the button shows by itself" or tostring(on)))
end

function OSA.Probe(name)
    local cpOk, cp = pcall(GetComboPoints or function() return "missing" end, "player", "target")
    local powerType = Enum and Enum.PowerType and Enum.PowerType.ComboPoints
    local pw = powerType and select(2, pcall(UnitPower, "player", powerType)) or "missing"
    Print(("probe, %s: combo points %s, power %s, your energy/rage/mana %s, target health %s, target %s, attackable %s, guid %s"):format(
        InCombatLockdown() and "in combat" or "out of combat", cpOk and Show(cp) or "error", Show(pw),
        Show(select(2, pcall(UnitPower, "player"))), Show(select(2, pcall(UnitHealth, "target"))),
        Show(UnitName("target")), tostring(Attackable()), Show(select(2, pcall(UnitGUID, "target")))))
    for _, ev in ipairs(PROBED_EVENTS) do
        local s = seen[ev]
        Print(("  %s: %s"):format(ev, s and (s.count .. " seen, last: " .. s.last) or "not seen"))
    end
    -- the totems: what the game says per slot, and what we think is down
    local slots = {}
    for slot = 1, Totem.SLOTS do
        local text = "no GetTotemInfo"
        if GetTotemInfo then
            local ok, have, tname = pcall(GetTotemInfo, slot)
            text = ok and ("have " .. Show(have) .. ", name " .. Show(tname)) or "error"
        end
        table.insert(slots, ("%d: %s, we say %s"):format(slot, text, Totem.slot[slot] or "none"))
    end
    Print("  totems " .. table.concat(slots, "; "))
    local function aura(n)
        for _, a in ipairs(DB().alerts) do
            if a.kind == "aura" and a.spell:lower() == n:lower() then return a end
        end
    end
    local function needs(n)
        for _, a in ipairs(DB().alerts) do
            if a.kind ~= "aura" and AuraNames(a) and a.spell:lower() == n:lower() then ProbeAura(a) end
        end
    end
    if name and name ~= "" then
        if aura(name) then ProbeAura(aura(name)) else ProbeSpell(name) needs(name) end
    else
        for _, a in ipairs(DB().alerts) do
            if a.kind == "aura" then ProbeAura(a) else ProbeSpell(a.spell) end
            if a.kind ~= "aura" and AuraNames(a) then ProbeAura(a) end
        end
        -- what each look gives: on, off, or secret when only the game knows
        for _, a in ipairs(DB().alerts) do
            for _, look in ipairs(a.looks or {}) do
                Print(("  %s look, %s: %s"):format(a.spell, OSA.DescribeLook(look), OSA.ProbeLook(look)))
            end
        end
        if #DB().alerts == 0 then Print("  /osa probe <spell> to probe a spell.") end
    end
end

-- slash commands ---------------------------------------------------------------------------------

local function Describe(i, a)
    local text = ("%d. %s, %s"):format(i, a.spell, a.kind == "aura" and "on the target" or a.kind)
    if a.kind == "aura" then
        text = text .. (a.anyone and ", anyone's" or ", yours")
        if Searching(a) then text = text .. ", looking up its spell ids" end
    end
    if a.kind == "combo" then text = text .. " at " .. (a.cp or 0) .. " points" end
    if a.kind ~= "combo" and (a.cp or 0) > 0 then text = text .. ", with " .. a.cp .. "+ combo points" end
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
    if a.kind ~= "aura" and AuraNames(a) then
        text = text .. ", only while " .. table.concat(a.need, " or ") .. " is on the target"
            .. (a.anyone and " (anyone's)" or "") .. (Searching(a) and ", looking up spell ids" or "")
    end
    if a.totems then text = text .. ", only while " .. table.concat(a.totems, " or ") .. " is down" end
    if a.wrongTarget and a.kind ~= "aura" then
        text = text .. (a.wrongTarget == "range" and ", only while it can be cast on the target (in range)"
            or ", only on a target it can be cast on")
    end
    if a.kind ~= "debuff" and a.kind ~= "aura" then
        if a.atPower then text = text .. ", at " .. a.atPower .. "+ energy" end
        if a.early then text = text .. ", shows " .. a.early .. " sec before its cooldown ends" end
        text = text .. ", short of energy: " .. (a.power or "dim")
    end
    if a.flash then text = text .. ", fades out after " .. a.flash .. " sec" end
    if a.looks then
        local parts = {}
        for _, look in ipairs(a.looks) do table.insert(parts, OSA.DescribeLook(look)) end
        text = text .. ", looks: " .. table.concat(parts, "; ")
    end
    if a.size then text = text .. ", icon size " .. a.size end
    if a.height then text = text .. ", icon height " .. a.height end
    if a.border then text = text .. ", border " .. OSA.BORDER_NAMES[a.border]:lower() end
    text = text .. ", sound " .. (a.sound or "ping")
    local hides = {}
    for _, k in ipairs(CONDITIONS) do
        local c = Conds(a)[k]
        if c and c ~= 0 then table.insert(hides, (c == 2 and "not " or "") .. k) end
    end
    if #hides > 0 then text = text .. ", hidden while " .. table.concat(hides, ", ") end
    if a.off then text = text .. " (off)" end
    if a.kind ~= "aura" and not AlertSpell(a) then text = text .. " (not in your spellbook)" end
    return text
end

local HELP = {
    "/osa - open the options window",
    "/osa add <spell> - alert when it's usable, ex: /osa add Riposte",
    "/osa add <spell> combo <n> - when it's usable with n combo points, ex: /osa add Eviscerate combo 5",
    "/osa add <spell> debuff [sec] - when your debuff falls off the target, ex: /osa add Rupture debuff",
    "/osa add <debuff> on - while the debuff is on the target, any name or spell id, ex: /osa add Frostbite on",
    "/osa need <n> <debuff, debuff...|off> - usable or combo alert n shows only while one of these "
        .. "debuffs is on the target, ex: /osa need 1 Frostbite, Frost Nova",
    "/osa totem <n> <totem, totem...|off> - alert n shows only while one of these totems of yours is "
        .. "down, ex: /osa totem 1 Flametongue Totem",
    "/osa wrongtarget <n> on|range|off - alert n hides while the target isn't one its spell can be cast "
        .. "on, ex: Exorcism on anything but undead and demons; range also hides it out of range",
    "/osa anyone <n> on|off - count anyone's debuff, not only yours, for an on-the-target alert or one "
        .. "that needs debuffs",
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
    "/osa look <n> add <dim|glow|grey|red|green|blue> <energy|health|cp> <<|<=|=|>=|>> <number> "
        .. "[and|or ...] - change alert n's look while your energy (rage, mana), the target's health % or "
        .. "combo points compare to numbers. \"and\" binds tighter than \"or\", ex: "
        .. "/osa look 1 add glow cp = 5 and health >= 10",
    "/osa look <n> remove <look>|clear - remove one of alert n's looks, or all of them",
    "/osa anytime <n> on|off - no target needed: a usable alert shows out of combat with no target, ex: "
        .. "Sprint, a combo point alert without an enemy target. The target, enemy and friendly conditions "
        .. "can still ask for one",
    "/osa hide <n> <condition> off|true|false - hide alert n while the condition is true or false, "
        .. "ex: /osa hide 1 combat false. Conditions: " .. table.concat(CONDITIONS, ", "),
    "/osa size <size> - every icon's size, 0 = " .. SIZE,
    "/osa size <n> <size|off> - alert n's own icon size, off = the size above",
    "/osa plate <n> on|off|above|left|right - put alert n's icon, and the icons snapped to it, on your target's nameplate",
    "/osa grow <n> on|off - alert n's set fills its spots in the list's order, so showing icons close up",
    "/osa height <n> <size|off> - alert n's own icon height, the picture is cropped to fit, off = square",
    "/osa border <n> action|thin|thick|none - alert n's icon border: the action bar's frame, a thin or thick black edge, or none",
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

-- sets the debuffs a usable or combo alert waits for from a list, ex: "Frostbite, Frost Nova"; spell
-- ids give their names, and "" clears it
function OSA.SetNeed(a, text)
    local names, seen = {}, {}
    for part in (text or ""):gmatch("[^,;]+") do
        local name = part:match("^%s*(.-)%s*$")
        local id = tonumber(name)
        if id then
            local ok, n = pcall(C_Spell.GetSpellName, id)
            name = ok and type(n) == "string" and not issecretvalue(n) and n or ""
        end
        local e = name ~= "" and Book()[name:lower()]
        name = e and e.name or name
        -- the game's spelling, when it knows the name
        if not e and name ~= "" and C_Spell and C_Spell.GetSpellInfo then
            local ok, info = pcall(C_Spell.GetSpellInfo, name)
            if ok and type(info) == "table" and type(info.name) == "string" and not issecretvalue(info.name) then
                name = info.name
            end
        end
        if name ~= "" and not seen[name:lower()] then
            seen[name:lower()] = true
            table.insert(names, name)
        end
    end
    a.need = #names > 0 and names or nil
    -- ids seen are for the old names
    a.ids = nil
end

-- sets the totems one of which must be down, a list of names, ex: "Flametongue Totem"; your
-- spellbook's spelling is used when it has the totem, and an empty list clears it
function OSA.SetTotems(a, list)
    local names, seen = {}, {}
    for _, name in ipairs(list or {}) do
        name = name:match("^%s*(.-)%s*$")
        local e = name ~= "" and Book()[name:lower()]
        name = e and e.name or name
        if name ~= "" and not seen[name:lower()] then
            seen[name:lower()] = true
            table.insert(names, name)
        end
    end
    a.totems = #names > 0 and names or nil
    -- chosen by hand, so the description isn't read for them
    a.totemsChecked = true
end

-- adds or removes one totem
function OSA.ToggleTotem(a, name)
    local list, found = {}, false
    for _, n in ipairs(a.totems or {}) do
        if n:lower() == name:lower() then found = true else table.insert(list, n) end
    end
    if not found then table.insert(list, name) end
    OSA.SetTotems(a, list)
end

-- adds an alert for while a debuff is on the target: any name, ex: Frostbite, which isn't in the
-- spellbook, or a spell id, which gives its name. The alert, or nil and why not.
function OSA.AddAura(text)
    local name = strtrim and strtrim(text or "") or (text or ""):match("^%s*(.-)%s*$")
    if name == "" then return nil, "no debuff name given." end
    local id = tonumber(name)
    if id then
        local ok, n = pcall(C_Spell.GetSpellName, id)
        if not (ok and type(n) == "string" and not issecretvalue(n)) then
            return nil, ("no spell %d."):format(id)
        end
        name = n
    end
    local e = Book()[name:lower()]
    local a = { spell = e and e.name or name, kind = "aura", ids = id and { [id] = true } or nil }
    table.insert(DB().alerts, a)
    return a
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
        if not name then
            name, kind = rest:match("^(.-)%s+(on)$")
            if not name then name, kind = rest:match("^(.-)%s+(aura)$") end
            if name then
                local a, err = OSA.AddAura(name)
                Print(a and ("added " .. Describe(#db.alerts, a)) or err)
                OSA.Changed()
                return
            end
        end
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
    elseif cmd == "look" then
        local n, args = rest:match("^(%d+)%s+(.+)$")
        local a = Alert(n)
        local words = {}
        for w in (args or ""):lower():gmatch("%S+") do table.insert(words, w) end
        local whats = { energy = "power", power = "power", rage = "power", mana = "power", health = "health", cp = "cp",
            combo = "cp" }
        local ops = { above = ">", below = "<", at = "=", ["=="] = "=", ["=>"] = ">=", ["=<"] = "<=" }
        for _, op in ipairs(OSA.LOOK_OPS) do ops[op] = op end
        local fxs = { gray = "grey" }
        for _, fx in ipairs(OSA.LOOK_FXS) do fxs[fx] = fx end
        -- add <fx> <what> <op> <n> [and|or <what> <op> <n>]...
        local look
        if words[1] == "add" and fxs[words[2]] then
            look = { fx = fxs[words[2]], conds = {} }
            local i = 3
            while look do
                local join = "and"
                if #look.conds > 0 then
                    join = words[i]
                    i = i + 1
                end
                local what, op, num = whats[words[i] or ""], ops[words[i + 1] or ""], tonumber(words[i + 2] or "")
                if (join == "and" or join == "or") and what and op and num then
                    table.insert(look.conds, { what = what, op = op, n = num, join = join })
                    i = i + 3
                    if not words[i] then break end
                else
                    look = nil
                end
            end
        end
        if a and look then
            a.looks = a.looks or {}
            if #a.looks >= OSA.MAX_LOOKS then
                Print(("an alert can have up to %d looks."):format(OSA.MAX_LOOKS))
                return
            end
            if #look.conds > OSA.MAX_CONDS then
                Print(("a look can have up to %d conditions."):format(OSA.MAX_CONDS))
                return
            end
            table.insert(a.looks, look)
        elseif a and words[1] == "clear" then
            a.looks = nil
        elseif a and words[1] == "remove" and a.looks and a.looks[tonumber(words[2]) or 0] then
            table.remove(a.looks, tonumber(words[2]))
            if #a.looks == 0 then a.looks = nil end
        else
            Print("/osa look <n> add <dim|glow|grey|red|green|blue> <energy|health|cp> <<|<=|=|>=|>> <number> "
                .. "[and|or <energy|health|cp> <op> <number>]..., or /osa look <n> remove <look> or clear. "
                .. "n is the alert's number in /osa list.")
            return
        end
        Print(Describe(tonumber(n), a))
    elseif cmd == "anytime" then
        local n, value = rest:match("^(%d+)%s+(%a+)$")
        local a = Alert(n)
        value = value and value:lower()
        if not (a and a.kind ~= "debuff" and a.kind ~= "aura" and (value == "on" or value == "off")) then
            Print("/osa anytime <n> on|off, n is a usable or combo point alert's number in /osa list.")
            return
        end
        a.anytime = value == "on" or nil
        Print(Describe(tonumber(n), a))
    elseif cmd == "wrongtarget" then
        local n, value = rest:match("^(%d+)%s+(%a+)$")
        local a = Alert(n)
        value = value and value:lower()
        if not (a and a.kind ~= "aura" and (value == "on" or value == "range" or value == "off")) then
            Print("/osa wrongtarget <n> on|range|off: hide the icon while the target isn't one the spell can "
                .. "be cast on (ex: Exorcism on a beast); range also while it's out of range. n is the "
                .. "alert's number in /osa list.")
            return
        end
        a.wrongTarget = value == "range" and "range" or value == "on" or nil
        Print(Describe(tonumber(n), a))
    elseif cmd == "anyone" then
        local n, value = rest:match("^(%d+)%s+(%a+)$")
        local a = Alert(n)
        value = value and value:lower()
        if not (a and AuraNames(a) and (value == "on" or value == "off")) then
            Print("/osa anyone <n> on|off, n is the number in /osa list of an on-the-target alert or one that needs debuffs.")
            return
        end
        a.anyone = value == "on" or nil
        Print(Describe(tonumber(n), a))
    elseif cmd == "need" then
        local n, value = rest:match("^(%d+)%s+(.+)$")
        local a = Alert(n)
        if not (a and (a.kind == "usable" or a.kind == "combo") and value) then
            Print("/osa need <n> <debuff, debuff...|off>, n is a usable or combo alert's number in /osa list.")
            return
        end
        OSA.SetNeed(a, value:lower() == "off" and "" or value)
        Print(Describe(tonumber(n), a))
    elseif cmd == "totem" or cmd == "totems" then
        local n, value = rest:match("^(%d+)%s+(.+)$")
        local a = Alert(n)
        if not (a and value) then
            Print("/osa totem <n> <totem, totem...|off>, n is the alert's number in /osa list.")
            return
        end
        local list = {}
        if value:lower() ~= "off" then
            for part in value:gmatch("[^,;]+") do table.insert(list, part) end
        end
        OSA.SetTotems(a, list)
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
        if not (a and a.kind ~= "debuff" and a.kind ~= "aura" and (tonumber(value) or value == "off")) then
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
    elseif cmd == "height" then
        local n, value = rest:match("^(%d+)%s+(%S+)$")
        local a = Alert(n)
        local px = value and (value:lower() == "off" and 0 or tonumber(value))
        if not (a and px) then
            Print("/osa height <n> <size|off>, n is the alert's number in /osa list.")
            return
        end
        a.height = px > 0 and math.max(10, math.min(200, px)) or nil
        Print(Describe(tonumber(n), a))
    elseif cmd == "border" then
        local n, value = rest:match("^(%d+)%s+(%a+)$")
        local a = Alert(n)
        value = value and value:lower()
        if not (a and OSA.BORDER_NAMES[value or ""]) then
            Print("/osa border <n> action|thin|thick|none, n is the alert's number in /osa list.")
            return
        end
        a.border = value ~= "thin" and value or nil
        Print(Describe(tonumber(n), a))
    elseif cmd == "plate" then
        local n, value = rest:match("^(%d+)%s+(%a+)$")
        local a = Alert(n)
        value = value and value:lower()
        local side = ({ above = "top", top = "top", left = "left", right = "right" })[value or ""]
        if not (a and (value == "on" or value == "off" or side)) then
            Print("/osa plate <n> on|off|above|left|right, n is the alert's number in /osa list. Its whole set moves.")
            return
        end
        if side then OSA.SetPlateSide(a, side) end
        OSA.SetPlate(a, value ~= "off")
        local where = ({ top = "above", left = "left of", right = "right of" })[OSA.PlateSideOf(a)]
        Print(a.spell .. (value ~= "off" and ("'s set is " .. where .. " your target's nameplate, or where it "
            .. "was while the target has none.") or "'s set is back in its own spot."))
    elseif cmd == "grow" then
        local n, value = rest:match("^(%d+)%s+(%a+)$")
        local a = Alert(n)
        value = value and value:lower()
        if not (a and (value == "on" or value == "off")) then
            Print("/osa grow <n> on|off: alert n's set fills its spots in the list's order, so the showing "
                .. "icons close up. n is the alert's number in /osa list.")
            return
        end
        OSA.SetGrow(a, value == "on")
        Print(a.spell .. (value == "on" and "'s set grows: its icons take its first free spots, in the list's order."
            or "'s set keeps each icon in its own spot."))
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
OSA.BookTotems = Totem.Book
OSA.Totem = Totem
OSA.AuraIcon = AuraIcon
OSA.Searching = Searching
