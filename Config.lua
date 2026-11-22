-- Options window, minimap button and addon compartment entry. Built on first use. Nothing here is
-- protected, so it all works in combat.

local OSA = OpcowsSpellAlerts
local ROW_HEIGHT = 20
local WIDTH = 420
local ICON = "Interface\\Icons\\Ability_Warrior_Challange"
-- the kinds in the order the "Alert when" button cycles through them
local KINDS = { "usable", "combo", "debuff", "aura" }
local POWER_TEXT = { show = "Show it", dim = "Dim it", hide = "Hide it" }
local KIND_TEXT = { usable = "It's usable", combo = "Combo points reach", debuff = "My debuff falls off",
    aura = "A debuff is on the target" }
local COND_LABELS = {
    dead = "Dead", instance = "Instance", party = "Party", raid = "Raid",
    resting = "Resting", taxi = "Taxi", combat = "Combat", mounted = "Mounted",
    target = "Target", enemy = "Enemy", friendly = "Friendly",
    fireTotem = "Fire totem", earthTotem = "Earth totem", waterTotem = "Water totem", airTotem = "Air totem",
}
local COND_DESC = {
    dead = "dead", instance = "in a dungeon", party = "in a party", raid = "in a raid",
    resting = "resting", taxi = "on a flight path", combat = "in combat", mounted = "mounted",
    target = "you have a target", enemy = "your target is a living enemy you can attack",
    friendly = "your target is friendly",
    fireTotem = "a Fire totem is down", earthTotem = "an Earth totem is down",
    waterTotem = "a Water totem is down", airTotem = "an Air totem is down",
}

local config
local minimapButton

local issecretvalue = issecretvalue or function() return false end

local function Trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end

-- widget helpers ---------------------------------------------------------------------------------

local function Label(parent, text, font)
    local fs = parent:CreateFontString(nil, "ARTWORK", font or "GameFontNormal")
    fs:SetText(text)
    fs:SetJustifyH("LEFT")
    return fs
end

local function Button(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

-- text can be a function of the widget, for tooltips that describe the current state
local function Tooltip(widget, title, text)
    widget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title)
        local t = type(text) == "function" and text(self) or text
        if t then GameTooltip:AddLine(t, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function EditBox(parent, width)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(width, 20)
    e:SetAutoFocus(false)
    return e
end

local function Check(parent, text, onClick)
    local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    c:SetSize(24, 24)
    c.label = Label(c, text, "GameFontHighlightSmall")
    c.label:SetPoint("LEFT", c, "RIGHT", 0, 1)
    c:SetHitRectInsets(0, -100, 0, 0)
    c:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    return c
end

local function Box(parent, bg)
    local b = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    b:SetBackdrop({
        bgFile = bg or "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    if not bg then b:SetBackdropColor(0, 0, 0, 0.5) end
    b:SetBackdropBorderColor(0.6, 0.6, 0.6)
    return b
end

-- a number box: get() gives the value shown, set(n) saves a typed one
local function NumberBox(parent, width, get, set)
    local box = EditBox(parent, width)
    box:SetNumeric(true)
    box:SetMaxLetters(3)
    local function Save(self)
        local n = tonumber(self:GetText())
        if n then set(n) end
        OSA.Changed()
    end
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEditFocusLost", Save)
    box:SetScript("OnEscapePressed", function(self)
        self:SetScript("OnEditFocusLost", nil)
        self:ClearFocus()
        self:SetScript("OnEditFocusLost", Save)
        OSA.Changed()
    end)
    box.get = get
    return box
end

-- shows a number box's value, unless it's being typed in
local function ShowNumber(box)
    if not box:HasFocus() then box:SetText(tostring(box.get() or 0)) end
end

-- a button whose left-click picks the next choice and right-click the one before
local function Cycle(parent, width, onStep)
    local b = Button(parent, "", width, nil)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", function(_, button) onStep(button == "RightButton" and -1 or 1) end)
    return b
end

local function Step(list, current, dir)
    local at = 1
    for i, v in ipairs(list) do
        if v == current then at = i end
    end
    return list[(at - 1 + dir) % #list + 1]
end

-- scrolling list of rows with an icon, text and an optional remove button. onDrop, if given, runs
-- when something is dropped on the list from the cursor.
local function ScrollList(parent, width, height, onDrop)
    local box = Box(parent)
    box:SetSize(width, height)
    local sf = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 4, -4)
    sf:SetPoint("BOTTOMRIGHT", -26, 4)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(width - 30, 1)
    sf:SetScrollChild(child)
    box.rows = {}

    local function Droppable(f)
        if not onDrop then return end
        f:EnableMouse(true)
        f:SetScript("OnReceiveDrag", function() onDrop() end)
        f:HookScript("OnMouseUp", function() if GetCursorInfo() then onDrop() end end)
    end
    Droppable(box)
    Droppable(sf)

    local function NewRow(i)
        local row = CreateFrame("Button", nil, child)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        row:SetPoint("RIGHT", child, "RIGHT")
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(1, 0.82, 0, 0.25)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", 2, 0)
        row.remove = CreateFrame("Button", nil, row, "UIPanelCloseButton")
        row.remove:SetSize(20, 20)
        row.remove:SetPoint("RIGHT", 0, 0)
        row.remove:SetScript("OnClick", function() row.item.onRemove() end)
        Tooltip(row.remove, "Remove", "Remove this alert.")
        row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
        row.text:SetPoint("RIGHT", row.remove, "LEFT", -2, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row:SetScript("OnClick", function(self)
            if GetCursorInfo() and onDrop then
                onDrop()
            elseif self.item.onClick then
                self.item.onClick()
            end
        end)
        if onDrop then row:SetScript("OnReceiveDrag", function() onDrop() end) end
        row:SetScript("OnEnter", function(self)
            if not self.item.spell then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetSpellByID(self.item.spell)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        box.rows[i] = row
        return row
    end

    -- items = { { text, icon, selected, onClick, onRemove, spell }, ... }
    function box:SetItems(items)
        for i, item in ipairs(items) do
            local row = self.rows[i] or NewRow(i)
            row.item = item
            row.icon:SetTexture(item.icon)
            row.icon:SetDesaturated(item.dim and true or false)
            row.text:SetText(item.text)
            row.sel:SetShown(item.selected and true or false)
            row.remove:SetShown(item.onRemove ~= nil)
            row:Show()
        end
        for i = #items + 1, #self.rows do
            self.rows[i]:Hide()
        end
        child:SetHeight(math.max(1, #items * ROW_HEIGHT))
    end

    return box
end

-- searchable popup list beside the window
local function Picker(parent, title, width, height)
    local p = Box(parent, "Interface\\DialogFrame\\UI-DialogBox-Background")
    p:SetSize(width, height)
    p:SetFrameStrata("DIALOG")
    p:EnableMouse(true)
    p:SetClampedToScreen(true)
    p:Hide()
    p.title = Label(p, title)
    p.title:SetPoint("TOPLEFT", 10, -9)
    local close = CreateFrame("Button", nil, p, "UIPanelCloseButton")
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() p:Hide() end)
    local searchLabel = Label(p, "Search:", "GameFontHighlightSmall")
    searchLabel:SetPoint("TOPLEFT", 12, -34)
    p.search = EditBox(p, width - 76)
    p.search:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
    p.search:SetScript("OnTextChanged", function() p:Update() end)
    p.search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    p.search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    p.list = ScrollList(p, width - 16, height - 62)
    p.list:SetPoint("TOPLEFT", 8, -54)

    function p:Update()
        if not self.rows then return end
        local filter = Trim(self.search:GetText()):lower()
        local items = {}
        for _, row in ipairs(self.rows) do
            if filter == "" or row.name:lower():find(filter, 1, true) then table.insert(items, row) end
        end
        self.list:SetItems(items)
    end

    function p:Open(source)
        self.rows = source()
        self.search:SetText("")
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", parent, "TOPRIGHT", 2, 0)
        self:Show()
        self:Update()
    end

    return p
end

-- the selected alert's looks, a panel beside the window: each look is an effect and its conditions,
-- joined by and/or. alert() gives the alert or nil.
local function LooksPanel(parent, alert)
    local MAX, MAX_CONDS, MAX_TOTAL = OSA.MAX_LOOKS, OSA.MAX_CONDS, 12
    local LINE, TOP = 26, 78
    local p = Box(parent, "Interface\\DialogFrame\\UI-DialogBox-Background")
    -- the height is set in Refresh
    p:SetSize(330, TOP + 100)
    p:SetFrameStrata("DIALOG")
    p:EnableMouse(true)
    p:SetClampedToScreen(true)
    p:Hide()
    p.title = Label(p, "Look")
    p.title:SetPoint("TOPLEFT", 10, -9)
    local close = CreateFrame("Button", nil, p, "UIPanelCloseButton")
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() p:Hide() end)
    local help = Label(p, "Change the icon while it shows. Each look's effect shows while its conditions hold. "
        .. "\"and\" goes before \"or\": a and b or c is (a and b) or c.", "GameFontHighlightSmall")
    help:SetPoint("TOPLEFT", 12, -32)
    help:SetPoint("RIGHT", p, "RIGHT", -12, 0)
    help:SetWordWrap(true)

    local CYCLE_HINT = "\n\nClick for the next one, right-click for the one before."
    local function Total(a)
        local n = 0
        for _, look in ipairs(a.looks or {}) do n = n + #look.conds end
        return n
    end

    -- pooled lines: a look's header, and its conditions under it
    local heads, rows = {}, {}
    local function Head(i)
        if heads[i] then return heads[i] end
        local h = {}
        h.fx = Cycle(p, 70, function(dir)
            if not h.look then return end
            h.look.fx = Step(OSA.LOOK_FXS, h.look.fx, dir)
            OSA.Changed()
        end)
        Tooltip(h.fx, "Effect", "Dim: a dark shade over the icon.\nGlow: the action bar's gold glow.\nGrey: the "
            .. "icon without colour.\nRed, Green, Blue: the icon tinted that colour." .. CYCLE_HINT)
        h.when = Label(p, "when:", "GameFontHighlightSmall")
        h.when:SetPoint("LEFT", h.fx, "RIGHT", 6, 0)
        h.add = Button(p, "+ Condition", 96, function()
            local a = alert()
            if not (a and h.look) or #h.look.conds >= MAX_CONDS or Total(a) >= MAX_TOTAL then return end
            table.insert(h.look.conds, { what = "cp", op = ">=", n = 5, join = "and" })
            OSA.Changed()
        end)
        h.add:SetPoint("LEFT", h.when, "RIGHT", 8, 0)
        Tooltip(h.add, "Add a condition", ("Add a condition to this look, up to %d."):format(MAX_CONDS))
        h.remove = CreateFrame("Button", nil, p, "UIPanelCloseButton")
        h.remove:SetSize(22, 22)
        h.remove:SetPoint("LEFT", h.add, "RIGHT", 2, 0)
        h.remove:SetScript("OnClick", function()
            local a = alert()
            if not (a and a.looks and h.look) then return end
            for k, look in ipairs(a.looks) do
                if look == h.look then table.remove(a.looks, k) break end
            end
            if #a.looks == 0 then a.looks = nil end
            OSA.Changed()
        end)
        Tooltip(h.remove, "Remove", "Remove this look and its conditions.")
        h.all = { h.fx, h.when, h.add, h.remove }
        heads[i] = h
        return h
    end
    local function Row(i)
        if rows[i] then return rows[i] end
        local r = {}
        local function Change(key, list)
            return function(dir)
                if not r.cond then return end
                r.cond[key] = Step(list, r.cond[key], dir)
                OSA.Changed()
            end
        end
        r.join = Cycle(p, 40, Change("join", { "and", "or" }))
        Tooltip(r.join, "And / or", "And: this and the condition above must both hold.\nOr: either side "
            .. "may hold. \"and\" goes first, so a and b or c and d is (a and b) or (c and d)." .. CYCLE_HINT)
        r.what = Cycle(p, 104, Change("what", OSA.LOOK_WHATS))
        r.what:SetPoint("LEFT", r.join, "RIGHT", 2, 0)
        Tooltip(r.what, "What it watches", "Your energy (or rage or mana, whichever you have), your target's "
            .. "health in percent, or your combo points." .. CYCLE_HINT)
        r.op = Cycle(p, 40, Change("op", OSA.LOOK_OPS))
        r.op:SetPoint("LEFT", r.what, "RIGHT", 2, 0)
        Tooltip(r.op, "Compare", "Less than, at most, equal to, at least, or more than the number. Energy "
            .. "and combo points are whole numbers, so < 30 means 29 or less. Target health = 30 means "
            .. "29.5% to 30.5%." .. CYCLE_HINT)
        r.n = NumberBox(p, 40, function()
            return r.cond and r.cond.n
        end, function(n)
            if r.cond then r.cond.n = n end
        end)
        r.n:SetMaxLetters(5)
        r.n:SetPoint("LEFT", r.op, "RIGHT", 8, 0)
        r.remove = CreateFrame("Button", nil, p, "UIPanelCloseButton")
        r.remove:SetSize(22, 22)
        r.remove:SetPoint("LEFT", r.n, "RIGHT", 2, 0)
        r.remove:SetScript("OnClick", function()
            local a = alert()
            if not (a and a.looks and r.look and r.cond) then return end
            for k, c in ipairs(r.look.conds) do
                if c == r.cond then table.remove(r.look.conds, k) break end
            end
            -- a look with no conditions goes too
            if #r.look.conds == 0 then
                for k, look in ipairs(a.looks) do
                    if look == r.look then table.remove(a.looks, k) break end
                end
                if #a.looks == 0 then a.looks = nil end
            end
            OSA.Changed()
        end)
        Tooltip(r.remove, "Remove", "Remove this condition.")
        r.all = { r.join, r.what, r.op, r.n, r.remove }
        rows[i] = r
        return r
    end

    local add = Button(p, "Add a look", 100, function()
        local a = alert()
        if not a then return end
        a.looks = a.looks or {}
        if #a.looks >= MAX or Total(a) >= MAX_TOTAL then return end
        -- a start that reads sensibly, then change it
        table.insert(a.looks, { fx = "dim", conds = { { what = "power", op = ">", n = 80, join = "and" } } })
        OSA.Changed()
    end)
    local note = Label(p, "In combat the game hides your energy and the target's health from addons, and checks "
        .. "them itself. Then energy \"and\" target health can't be checked together, and an \"or\" can draw "
        .. "the effect twice, so a glow is brighter or a dim darker.", "GameFontDisableSmall")
    note:SetPoint("BOTTOMLEFT", 12, 10)
    note:SetPoint("RIGHT", p, "RIGHT", -12, 0)
    note:SetWordWrap(true)

    function p:Refresh()
        local a = alert()
        if not a then self:Hide() return end
        self.title:SetText("Look of " .. a.spell)
        local looks = a.looks or {}
        local total = Total(a)
        local y, nh, nr = -TOP, 0, 0
        for _, look in ipairs(looks) do
            nh = nh + 1
            local h = Head(nh)
            h.look = look
            h.fx:ClearAllPoints()
            h.fx:SetPoint("TOPLEFT", 10, y)
            h.fx:SetText(OSA.LOOK_FX_NAMES[look.fx])
            h.add:SetEnabled(#look.conds < MAX_CONDS and total < MAX_TOTAL)
            for _, w in ipairs(h.all) do w:Show() end
            y = y - LINE
            for k, c in ipairs(look.conds) do
                nr = nr + 1
                local r = Row(nr)
                r.look, r.cond = look, c
                r.join:ClearAllPoints()
                r.join:SetPoint("TOPLEFT", 26, y)
                r.join:SetText(c.join or "and")
                for _, w in ipairs(r.all) do w:Show() end
                -- the first condition has nothing above it to join to
                r.join:SetShown(k > 1)
                r.what:SetText(OSA.LOOK_WHAT_NAMES[c.what])
                r.op:SetText(c.op)
                ShowNumber(r.n)
                y = y - LINE
            end
        end
        for i = nh + 1, #heads do
            heads[i].look = nil
            for _, w in ipairs(heads[i].all) do w:Hide() end
        end
        for i = nr + 1, #rows do
            rows[i].look, rows[i].cond = nil, nil
            for _, w in ipairs(rows[i].all) do w:Hide() end
        end
        add:ClearAllPoints()
        add:SetPoint("TOPLEFT", 10, y - 4)
        add:SetEnabled(#looks < MAX and total < MAX_TOTAL)
        -- room for the Add a look button, then the note under it, however many lines it wraps to
        local noteHeight = math.max(note:GetStringHeight() or 0, 40)
        self:SetHeight(TOP + (nh + nr) * LINE + 4 + 22 + 12 + noteHeight + 10)
    end

    function p:Open()
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", parent, "TOPRIGHT", 2, 0)
        self:Show()
        self:Refresh()
    end

    return p
end

-- your spells that can be cast, one row per name, sorted
local function SpellRows(onPick)
    local byName, rows = {}, {}
    if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines) then return rows end
    pcall(function()
        local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
        local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
        for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
            if info then
                for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                    local item = C_SpellBook.GetSpellBookItemInfo(i, bank)
                    local id, n = item and item.spellID, item and item.name
                    if type(id) == "number" and not issecretvalue(id) and type(n) == "string"
                        and not issecretvalue(n) and not item.isPassive
                        and (spellType == nil or item.itemType == spellType) then
                        local r = byName[n]
                        if r then
                            if id > r.spell then r.spell = id end
                        else
                            r = { name = n, text = n, icon = item.iconID, spell = id }
                            r.onClick = function() onPick(n) end
                            byName[n] = r
                            table.insert(rows, r)
                        end
                    end
                end
            end
        end
    end)
    table.sort(rows, function(a, b) return a.name < b.name end)
    return rows
end

-- the window -------------------------------------------------------------------------------------

-- the selected alert's index
local selected

local function Selected()
    return selected and OSA.DB().alerts[selected]
end

local function Add(name)
    local e = OSA.Book()[name:lower()]
    if not e then return end
    local alerts = OSA.DB().alerts
    table.insert(alerts, { spell = e.name, kind = "usable" })
    selected = #alerts
    OSA.Changed()
end

-- a spell dropped on the list from the spellbook or an action bar
local function Drop()
    local kind, _, _, id = GetCursorInfo()
    if kind ~= "spell" then return end
    ClearCursor()
    local name = type(id) == "number" and OSA.SpellName(id)
    if name then Add(name) end
end

-- what the alert does, in a few words
local function Summary(a)
    local early = (a.early and (", %d sec early"):format(a.early) or "")
        .. (a.flash and (", shown %d sec"):format(a.flash) or "")
        .. (a.looks and (", %d look%s"):format(#a.looks, #a.looks > 1 and "s" or "") or "")
    local at = (a.atPower and (", %d+ energy"):format(a.atPower) or "") .. early
    if a.kind == "combo" then
        return ("at %d combo points"):format(a.cp or 0) .. (a.anytime and ", no target needed" or "") .. at
    end
    local cp = (a.cp or 0) > 0 and (", %d+ combo points"):format(a.cp) or ""
    -- the debuffs a usable or combo alert waits for
    if a.need and (a.kind == "usable" or a.kind == "combo") then
        at = at .. ", with " .. table.concat(a.need, " or ")
    end
    if a.kind == "aura" then
        return "on the target" .. (a.anyone and ", anyone's" or "") .. cp
            .. (a.flash and (", shown %d sec"):format(a.flash) or "")
    end
    if a.kind == "debuff" then
        local id = OSA.AlertSpell(a)
        local d = a.duration or (id and OSA.DebuffDuration(a, id, 5))
        return (d and ("debuff falls off (%s sec)"):format(d) or "debuff falls off (length unknown)") .. cp .. early
    end
    return "usable" .. (a.anytime and ", no target needed" or "") .. cp .. at
end

-- the debuff length the alert uses when its box is 0
local function AutoDuration(a)
    local id = OSA.AlertSpell(a)
    local saved = a.duration
    a.duration = nil
    local d = id and OSA.DebuffDuration(a, id, 5)
    a.duration = saved
    return d
end

local function CreateConfig()
    local f = CreateFrame("Frame", "OpcowsSpellAlertsConfig", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(WIDTH, 876)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    table.insert(UISpecialFrames, "OpcowsSpellAlertsConfig")

    local title = f.TitleText
    if not title then
        title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetPoint("TOP", 0, -5)
    end
    title:SetText("Opcow's Spell Alerts")

    local help = Label(f, "A spell's icon pops up with a sound when it's usable, when a finisher has enough "
        .. "combo points, when your debuff falls off the target, or while a debuff is on it.", "GameFontHighlightSmall")
    help:SetPoint("TOPLEFT", 16, -32)
    help:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    help:SetWordWrap(true)

    local picker = Picker(f, "Add a spell", 260, 380)
    local addSpell = Button(f, "Add spell...", 120, function()
        if picker:IsShown() then picker:Hide() return end
        if f.looks then f.looks:Hide() end
        picker:Open(function()
            return SpellRows(function(name)
                Add(name)
                picker:Hide()
            end)
        end)
    end)
    addSpell:SetPoint("TOPLEFT", 14, -66)
    -- a debuff that isn't a spell of yours, ex: Frostbite, which procs from Frost spells
    StaticPopupDialogs.OPCOWS_SPELL_ALERTS_DEBUFF = {
        text = "The debuff's name or spell id, ex: Frostbite.\nIts icon shows while it's on your target.",
        button1 = ACCEPT or "Accept",
        button2 = CANCEL or "Cancel",
        hasEditBox = true,
        maxLetters = 60,
        OnAccept = function(self)
            local box = self.editBox or self.EditBox or (self.GetEditBox and self:GetEditBox())
            local a, err = OSA.AddAura(box and box:GetText() or "")
            if a then
                selected = #OSA.DB().alerts
            else
                OSA.Print(err)
            end
            OSA.Changed()
        end,
        EditBoxOnEnterPressed = function(self)
            local popup = self:GetParent()
            local accept = popup.button1 or (popup.GetButton1 and popup:GetButton1())
            if accept then accept:Click() end
        end,
        EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    local addDebuff = Button(f, "Debuff by name...", 130, function()
        StaticPopup_Show("OPCOWS_SPELL_ALERTS_DEBUFF")
    end)
    addDebuff:SetPoint("LEFT", addSpell, "RIGHT", 4, 0)
    Tooltip(addDebuff, "Debuff by name", "Alert while a debuff is on your target, even one that isn't in "
        .. "your spellbook, ex: Frostbite, which procs at random from Frost spells. Type its name or "
        .. "spell id.\n\nThe first time, its spell ids are looked up out of combat, which takes a few seconds.")
    local dropHint = Label(f, "or drag a spell in", "GameFontDisableSmall")
    dropHint:SetPoint("LEFT", addDebuff, "RIGHT", 8, 0)

    local list = ScrollList(f, WIDTH - 28, 170, Drop)
    list:SetPoint("TOPLEFT", 14, -92)

    -- the selected alert -------------------------------------------------------------------------
    local edit = Box(f)
    edit:SetSize(WIDTH - 28, 466)
    edit:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -8)

    local none = Label(edit, "Select an alert in the list to change it.", "GameFontDisableSmall")
    none:SetPoint("CENTER")

    local icon = edit:CreateTexture(nil, "ARTWORK")
    icon:SetSize(28, 28)
    icon:SetPoint("TOPLEFT", 10, -10)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local name = Label(edit, "", "GameFontNormalLarge")
    name:SetPoint("LEFT", icon, "RIGHT", 8, 0)

    local on = Check(edit, "On", function(v)
        local a = Selected()
        if a then a.off = not v or nil end
        OSA.Changed()
    end)
    on:SetPoint("TOPRIGHT", -40, -12)
    Tooltip(on, "On", "Turn this alert off to keep it without it showing.")

    local whenLabel = Label(edit, "Alert when:", "GameFontHighlightSmall")
    whenLabel:SetPoint("TOPLEFT", 12, -50)
    local when = Cycle(edit, 170, function(dir)
        local a = Selected()
        if not a then return end
        a.kind = Step(KINDS, a.kind, dir)
        if a.kind == "combo" then
            a.cp = a.cp or 0
        elseif a.cp and a.cp <= 0 then
            a.cp = nil
        end
        OSA.Changed()
    end)
    when:SetPoint("LEFT", whenLabel, "RIGHT", 8, 0)
    Tooltip(when, "Alert when", "Click for the next choice, right-click for the one before.\n\n"
        .. "|cffffd100It's usable:|r the spell can be cast and is off cooldown, ex: Riposte after a parry.\n"
        .. "|cffffd100Combo points reach:|r the spell is usable and your target has at least that many "
        .. "combo points, ex: Eviscerate at 5.\n"
        .. "|cffffd100My debuff falls off:|r your debuff on the target you're fighting has run out, "
        .. "ex: Rupture. It's timed from your cast when the game hides auras in combat, so it may "
        .. "not notice a debuff removed early.\n"
        .. "|cffffd100A debuff is on the target:|r the icon shows while the debuff is on your target, "
        .. "ex: Frostbite, which procs at random. In combat the game's own debuff button shows it. "
        .. "Add debuffs that aren't your spells with \"Debuff by name...\".")

    local cpLabel = Label(edit, "Combo points at least:", "GameFontHighlightSmall")
    cpLabel:SetPoint("TOPLEFT", whenLabel, "BOTTOMLEFT", 0, -22)
    local cp = NumberBox(edit, 30, function()
        local a = Selected()
        return a and (a.cp or 0)
    end, function(n)
        local a = Selected()
        if not a then return end
        n = math.max(0, math.min(5, n))
        if a.kind == "combo" then a.cp = n else a.cp = n > 0 and n or nil end
    end)
    cp:SetMaxLetters(1)
    cp:SetPoint("LEFT", cpLabel, "RIGHT", 8, 0)
    local cpHint = Label(edit, "", "GameFontDisableSmall")
    cpHint:SetPoint("LEFT", cp, "RIGHT", 6, 0)
    Tooltip(cp, "Combo points", "The icon only shows once your target has at least this many combo points, "
        .. "1 to 5, ex: Rupture fell off but you have 4. The sound plays when you reach them.\n\n"
        .. "0 = any.")

    local lastsLabel = Label(edit, "Lasts:", "GameFontHighlightSmall")
    lastsLabel:SetPoint("LEFT", when, "RIGHT", 10, 0)
    local lasts = NumberBox(edit, 34, function() return Selected() and Selected().duration or 0 end, function(n)
        local a = Selected()
        if a then a.duration = n > 0 and n or nil end
    end)
    lasts:SetPoint("LEFT", lastsLabel, "RIGHT", 8, 0)
    local lastsHint = Label(edit, "", "GameFontDisableSmall")
    lastsHint:SetPoint("LEFT", lasts, "RIGHT", 6, 0)
    Tooltip(lasts, "Debuff length", "How many seconds the debuff lasts, used when the game hides auras in "
        .. "combat. 0 reads it from the spell's tooltip, or from the debuff itself when it can.")

    -- usable and combo point alerts: by default they wait for a fight or an enemy target, or a
    -- spell that's always usable would always show
    local anytime = Check(edit, "No target needed", function(v)
        local a = Selected()
        if a then a.anytime = v or nil end
        OSA.Changed()
    end)
    anytime:SetPoint("LEFT", when, "RIGHT", 8, 0)
    Tooltip(anytime, "No target needed", function()
        local a = Selected()
        local unchecked = a and a.kind == "combo"
            and "Unchecked, it only shows while you target a living enemy."
            or "Unchecked, it only shows in combat or while you target a living enemy, so spells that "
                .. "are almost always usable don't sit on screen."
        return "Show the icon whenever the spell is ready, with or without a target, ex: Sprint coming "
            .. "off cooldown while you travel.\n\n" .. unchecked .. "\n\nTo ask for a certain target, "
            .. "use the Target, Enemy and Friendly conditions below, ex: Not Friendly for a heal "
            .. "on your target."
    end)

    -- aura alerts, in the same spot: yours only, or anyone's
    local anyone = Check(edit, "Anyone's", function(v)
        local a = Selected()
        if a then a.anyone = v or nil end
        OSA.Changed()
    end)
    anyone:SetPoint("LEFT", when, "RIGHT", 8, 0)
    Tooltip(anyone, "Anyone's", "Count the debuff whoever put it on the target, ex: another mage's "
        .. "Frostbite or a warrior's Sunder Armor.\n\nUnchecked, only yours.")

    -- usable and combo alerts: only while one of these debuffs is on the target, ex: Ice Lance
    -- while Frostbite or Frost Nova is on it
    local needLabel = Label(edit, "Only while on target:", "GameFontHighlightSmall")
    needLabel:SetPoint("TOPLEFT", cpLabel, "BOTTOMLEFT", 0, -22)
    local need = EditBox(edit, 160)
    need:SetPoint("LEFT", needLabel, "RIGHT", 10, 0)
    need:SetMaxLetters(200)
    local function SaveNeed(self)
        local a = Selected()
        if a then OSA.SetNeed(a, self:GetText()) end
        OSA.Changed()
    end
    need:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    need:SetScript("OnEditFocusLost", SaveNeed)
    need:SetScript("OnEscapePressed", function(self)
        self:SetScript("OnEditFocusLost", nil)
        self:ClearFocus()
        self:SetScript("OnEditFocusLost", SaveNeed)
        OSA.Changed()
    end)
    Tooltip(need, "Only while on the target", "Debuff names, split by commas. The icon only shows while one "
        .. "of them is on your target, ex: Frostbite, Frost Nova on Ice Lance, so one icon says when to "
        .. "cast it. Spell ids work too. Empty = no debuff needed.\n\nIn combat the game hides auras from "
        .. "addons, so the icon is put inside the game's own debuff button, which shows only while one "
        .. "is on. Then there may be no sound.")
    local needAnyone = Check(edit, "Anyone's", function(v)
        local a = Selected()
        if a then a.anyone = v or nil end
        OSA.Changed()
    end)
    needAnyone:SetPoint("LEFT", need, "RIGHT", 6, 0)
    needAnyone:SetHitRectInsets(0, -50, 0, 0)
    Tooltip(needAnyone, "Anyone's", "Count the debuffs whoever put them on the target, ex: another "
        .. "mage's Frost Nova.\n\nUnchecked, only yours.")

    -- the conditions, as in Buff Reminder: each check cycles off, hide while true, hide while false
    local condTitle = Label(edit, "Hide the icon while:", "GameFontHighlightSmall")
    condTitle:SetPoint("TOPLEFT", needLabel, "BOTTOMLEFT", 0, -16)
    local condHint = Label(edit, "click to cycle: off, while true, |cffff4040while false|r", "GameFontDisableSmall")
    condHint:SetPoint("LEFT", condTitle, "RIGHT", 8, 0)
    local condChecks = {}
    for i, key in ipairs(OSA.CONDITIONS) do
        local c = Check(edit, COND_LABELS[key], function() end)
        c:SetPoint("TOPLEFT", condTitle, "BOTTOMLEFT", ((i - 1) % 4) * 96 - 4, -2 - math.floor((i - 1) / 4) * 22)
        c:SetHitRectInsets(0, -60, 0, 0)
        function c:SetState(s)
            self.state = s
            self:SetChecked(s ~= 0)
            local red = s == 2
            local tex = self:GetCheckedTexture()
            if tex then tex:SetVertexColor(1, red and 0.2 or 1, red and 0.2 or 1) end
            self.label:SetText(red and ("|cffff4040Not|r " .. COND_LABELS[key]) or COND_LABELS[key])
        end
        c:SetScript("OnClick", function()
            local a = Selected()
            if not a then return end
            local conds = OSA.Conds(a)
            conds[key] = ((conds[key] or 0) + 1) % 3
            OSA.Changed()
        end)
        Tooltip(c, COND_LABELS[key], function(self)
            local s = self.state
            local text = s == 0 and "Ignored."
                or ("Hide the icon while " .. (s == 2 and "not " or "") .. COND_DESC[key] .. ".")
            return text .. "\n|cff808080Click to change.|r"
        end)
        condChecks[key] = c
    end

    local soundLabel = Label(edit, "Sound:", "GameFontHighlightSmall")
    soundLabel:SetPoint("TOPLEFT", condTitle, "BOTTOMLEFT", 0, -104)
    local soundNames = { "off" }
    for _, s in ipairs(OSA.SOUNDS) do table.insert(soundNames, s.name) end
    local sound = Cycle(edit, 100, function(dir)
        local a = Selected()
        if not a then return end
        a.sound = Step(soundNames, a.sound or "ping", dir)
        OSA.PlayAlertSound(a, true)
        OSA.Changed()
    end)
    sound:SetPoint("LEFT", soundLabel, "RIGHT", 8, 0)
    Tooltip(sound, "Sound", "Played once each time the alert is ready: the spell is off cooldown, the "
        .. "debuff has fallen off, or the debuff is on the target. Not when the icon shows early. Click "
        .. "for the next sound, right-click for the one before.\n\nA debuff on the target may show in "
        .. "combat with no sound, if the game hides it from addons.")
    local play = Button(edit, "Play", 60, function()
        local a = Selected()
        if a then OSA.PlayAlertSound(a, true) end
    end)
    play:SetPoint("LEFT", sound, "RIGHT", 4, 0)

    local flashLabel = Label(edit, "Show for:", "GameFontHighlightSmall")
    flashLabel:SetPoint("LEFT", play, "RIGHT", 14, 0)
    local flashBox = NumberBox(edit, 34, function() return Selected() and Selected().flash or 0 end, function(n)
        local a = Selected()
        if a then a.flash = n > 0 and math.max(1, n) or nil end
    end)
    flashBox:SetPoint("LEFT", flashLabel, "RIGHT", 8, 0)
    local flashHint = Label(edit, "sec", "GameFontDisableSmall")
    flashHint:SetPoint("LEFT", flashBox, "RIGHT", 6, 0)
    Tooltip(flashBox, "Show for", "When the alert is ready, the icon fades in, shows for this many seconds "
        .. "and fades out, ex: Sprint coming off cooldown. It shows again the next time the alert comes on.\n\n"
        .. "0 = it stays while the alert is on.")

    local powerLabel = Label(edit, "Short of energy:", "GameFontHighlightSmall")
    powerLabel:SetPoint("TOPLEFT", soundLabel, "BOTTOMLEFT", 0, -22)
    local power = Cycle(edit, 100, function(dir)
        local a = Selected()
        if not a then return end
        a.power = Step(OSA.POWER_MODES, a.power or "dim", dir)
        OSA.Changed()
    end)
    power:SetPoint("LEFT", powerLabel, "RIGHT", 8, 0)
    Tooltip(power, "Short of energy", "What the icon does once the alert's criterion is met but the spell "
        .. "still needs more energy, rage or mana, ex: 5 combo points with 20 energy.\n\n"
        .. "|cffffd100Show it:|r the icon shows as usual.\n"
        .. "|cffffd100Dim it:|r the icon shows dimmed and grey until you can cast it.\n"
        .. "|cffffd100Hide it:|r the icon waits until you have the energy, and the sound plays then.\n\n"
        .. "Click for the next choice, right-click for the one before.")

    local atLabel = Label(edit, "Only with at least:", "GameFontHighlightSmall")
    atLabel:SetPoint("TOPLEFT", powerLabel, "BOTTOMLEFT", 0, -22)
    local atPower = NumberBox(edit, 34, function() return Selected() and Selected().atPower or 0 end, function(n)
        local a = Selected()
        if a then a.atPower = n > 0 and n or nil end
    end)
    atPower:SetPoint("LEFT", atLabel, "RIGHT", 8, 0)
    local atHint = Label(edit, "energy, rage or mana, 0 = any", "GameFontDisableSmall")
    atHint:SetPoint("LEFT", atPower, "RIGHT", 6, 0)
    Tooltip(atPower, "Minimum energy", "The icon only shows once you have at least this much energy, rage "
        .. "or mana, ex: 90 for a spell you use to dump energy before it caps. The sound plays when you "
        .. "reach it.\n\n0 = no minimum.")

    -- placed under the energy rows, or under the sound for a debuff alert, which has none
    local earlyLabel = Label(edit, "Show early:", "GameFontHighlightSmall")
    local earlyBox = NumberBox(edit, 34, function() return Selected() and Selected().early or 0 end, function(n)
        local a = Selected()
        if a then a.early = n > 0 and n or nil end
    end)
    earlyBox:SetPoint("LEFT", earlyLabel, "RIGHT", 8, 0)
    local earlyHint = Label(edit, "", "GameFontDisableSmall")
    earlyHint:SetPoint("LEFT", earlyBox, "RIGHT", 6, 0)
    Tooltip(earlyBox, "Show early", function()
        local a = Selected()
        if a and a.kind == "debuff" then
            return "Show the icon this many seconds before your debuff falls off, shaded, with a countdown. "
                .. "The sound plays when it falls off.\n\nThe countdown needs the debuff's length, so a debuff "
                .. "only the Cooldown Manager follows can't show early unless its length is known.\n\n"
                .. "0 = only once it's fallen off."
        end
        return "Show the icon this many seconds before the spell comes off cooldown, shaded, with a "
            .. "countdown. The sound plays when it's ready.\n\n0 = only once it's off cooldown."
    end)

    local up = Button(edit, "Move up", 80, function()
        local alerts = OSA.DB().alerts
        if not selected or selected <= 1 then return end
        alerts[selected], alerts[selected - 1] = alerts[selected - 1], alerts[selected]
        selected = selected - 1
        OSA.Changed()
    end)
    up:SetPoint("BOTTOMLEFT", 10, 10)
    local down = Button(edit, "Move down", 90, function()
        local alerts = OSA.DB().alerts
        if not selected or selected >= #alerts then return end
        alerts[selected], alerts[selected + 1] = alerts[selected + 1], alerts[selected]
        selected = selected + 1
        OSA.Changed()
    end)
    down:SetPoint("LEFT", up, "RIGHT", 4, 0)
    Tooltip(down, "List order", "Moves it in this list. Where the icons show is set by dragging them while "
        .. "they're unlocked.")
    Tooltip(up, "List order", "Moves it in this list. Where the icons show is set by dragging them while "
        .. "they're unlocked.")

    local iconSizeLabel = Label(edit, "Size:", "GameFontHighlightSmall")
    iconSizeLabel:SetPoint("LEFT", down, "RIGHT", 12, 0)
    local iconSize = NumberBox(edit, 34, function() return Selected() and Selected().size or 0 end, function(n)
        local a = Selected()
        if a then a.size = n > 0 and math.max(10, math.min(200, n)) or nil end
    end)
    iconSize:SetPoint("LEFT", iconSizeLabel, "RIGHT", 6, 0)
    local iconBy = Label(edit, "x", "GameFontHighlightSmall")
    iconBy:SetPoint("LEFT", iconSize, "RIGHT", 4, 0)
    local iconHeight = NumberBox(edit, 34, function() return Selected() and Selected().height or 0 end, function(n)
        local a = Selected()
        if a then a.height = n > 0 and math.max(10, math.min(200, n)) or nil end
    end)
    iconHeight:SetPoint("LEFT", iconBy, "RIGHT", 4, 0)
    local iconSizeHint = Label(edit, "0 = default", "GameFontDisableSmall")
    iconSizeHint:SetPoint("LEFT", iconHeight, "RIGHT", 6, 0)
    Tooltip(iconSize, "Icon width", "This alert's own icon size, its width if it has a height too, 10 to 200. "
        .. "Icons of different sizes snapped together line up by their centres, or by an edge if you drop "
        .. "them that way.\n\n0 = the icon size under Options.")
    Tooltip(iconHeight, "Icon height", "This alert's own icon height, 10 to 200, for an icon wider than it's "
        .. "high, or higher than it's wide. The picture keeps its shape: its top and bottom, or its sides, are "
        .. "cut off, as Plater does.\n\n0 = square, as high as it's wide.")

    -- the set the icon's in goes on the target's nameplate
    local plate = Check(edit, "On the target's nameplate", function(v)
        local a = Selected()
        if a then OSA.SetPlate(a, v) end
    end)
    plate:SetPoint("BOTTOMLEFT", up, "TOPLEFT", -2, 30)
    plate:SetHitRectInsets(0, -140, 0, 0)
    local plateSide = Cycle(edit, 80, function(dir)
        local a = Selected()
        if not a then return end
        OSA.SetPlateSide(a, Step(OSA.PLATE_SIDES, OSA.PlateSideOf(a), dir))
        OSA.Changed()
    end)
    plateSide:SetPoint("LEFT", plate, "RIGHT", 150, 0)
    Tooltip(plateSide, "Side of the nameplate", "Where on the nameplate the icons go: above it, or to its "
        .. "left or right. Changing it puts them back against the plate's edge, then drag them while "
        .. "unlocked to move them from there.\n\nClick for the next side, right-click for the one before.")
    Tooltip(plate, "On the target's nameplate", "The icon, and the icons snapped to it, sit on your "
        .. "target's nameplate, above it or to its side. Unlock the icons and drag them to place them on the plate. "
        .. "While the target has no nameplate showing, they go where they were, which you place by "
        .. "dragging them then.\n\nNameplates must be on in the game's settings (V). Shift-drag an icon "
        .. "out of its set first to put only that one on the nameplate.")

    -- the icon's border
    local borderLabel = Label(edit, "Border:", "GameFontHighlightSmall")
    borderLabel:SetPoint("BOTTOMLEFT", up, "TOPLEFT", 2, 12)
    local border = Cycle(edit, 100, function(dir)
        local a = Selected()
        if not a then return end
        local b = Step(OSA.BORDERS, a.border or "thin", dir)
        a.border = b ~= "thin" and b or nil
        OSA.Changed()
    end)
    border:SetPoint("LEFT", borderLabel, "RIGHT", 8, 0)
    Tooltip(border, "Border", "The icon's border: a thin black edge (the default), the action bar's thin dark "
        .. "frame with rounded corners, a thick black edge, or none.\n\nClick for the next one, right-click for "
        .. "the one before.")

    -- rules that change the icon's look with your energy, the target's health or combo points
    local looks = LooksPanel(f, Selected)
    f.looks = looks
    local lookButton = Button(edit, "Look...", 90, function()
        if looks:IsShown() then looks:Hide() return end
        picker:Hide()
        looks:Open()
    end)
    lookButton:SetPoint("LEFT", border, "RIGHT", 12, 0)
    Tooltip(lookButton, "Look", function()
        local a = Selected()
        local text = "Dim the icon, make it glow, grey it or tint it while your energy, the target's health or "
            .. "your combo points compare to numbers, joined by and/or. Not on an alert that needs a debuff "
            .. "while the game's aura button draws it in combat."
        if a and a.looks then
            local parts = {}
            for _, look in ipairs(a.looks) do table.insert(parts, OSA.DescribeLook(look)) end
            text = text .. "\n\n" .. table.concat(parts, "\n")
        end
        return text
    end)

    local editWidgets = { lookButton, borderLabel, border,plate, plateSide, iconBy, iconHeight, icon, name, on, whenLabel, when, cpLabel, cp, cpHint, condTitle, condHint, soundLabel, sound,
        play, flashLabel, flashBox, flashHint, earlyLabel, earlyBox, earlyHint, up, down, iconSizeLabel, iconSize,
        iconSizeHint }
    -- shown only for alerts that need the spell castable
    local powerWidgets = { powerLabel, power, atLabel, atPower, atHint }

    -- options ------------------------------------------------------------------------------------
    local optionsLabel = Label(f, "Options")
    optionsLabel:SetPoint("TOPLEFT", edit, "BOTTOMLEFT", 2, -12)

    local unlock = Button(f, "Unlock icons", 120, function()
        local db = OSA.DB()
        db.unlocked = not db.unlocked or nil
        OSA.Changed()
    end)
    unlock:SetPoint("TOPLEFT", optionsLabel, "BOTTOMLEFT", -2, -8)
    Tooltip(unlock, "Move the icons", "Unlocked, every alert's icon shows so it can be placed.\n\n"
        .. "Drag an icon to move it with the icons it's snapped to.\n"
        .. "Shift-drag to pull it away on its own.\n"
        .. "Drop it touching other icons, on any side, to snap to them.\n\n"
        .. "Lock them again when you're done. /osa reset puts them all back in one row.")

    local test = Button(f, "Test", 70, function() OSA.Test() end)
    test:SetPoint("LEFT", unlock, "RIGHT", 4, 0)
    Tooltip(test, "Test", "Show every alert's icon for 3 seconds, with the first one's sound.")

    local sizeLabel = Label(f, "Icon size:", "GameFontHighlightSmall")
    sizeLabel:SetPoint("LEFT", test, "RIGHT", 14, 0)
    local size = NumberBox(f, 34, function() return OSA.DB().size end, function(n)
        OSA.DB().size = math.min(200, n)
    end)
    size:SetPoint("LEFT", sizeLabel, "RIGHT", 8, 0)
    local sizeHint = Label(f, "0 = " .. OSA.SIZE, "GameFontDisableSmall")
    sizeHint:SetPoint("LEFT", size, "RIGHT", 6, 0)
    Tooltip(size, "Icon size", "The size of every icon that doesn't have its own. 0 = " .. OSA.SIZE .. ".")

    local minimap = Check(f, "Minimap button", function(v)
        OSA.DB().minimap.hide = not v or nil
        OSA.UpdateMinimap()
    end)
    minimap:SetPoint("TOPLEFT", unlock, "BOTTOMLEFT", 0, -8)
    local whole = Check(f, "Whole seconds", function(v)
        OSA.DB().wholeSeconds = v or nil
    end)
    whole:SetPoint("LEFT", minimap, "LEFT", 130, 0)
    Tooltip(whole, "Whole seconds", "The countdown on an icon shown early counts in whole seconds all the "
        .. "way down. Off, it shows tenths of a second under 3 seconds, ex: 2.4.")
    local debug = Check(f, "Debug messages", function(v)
        OSA.DB().debug = v or nil
    end)
    debug:SetPoint("LEFT", minimap, "LEFT", 265, 0)

    local probeHint = Label(f, "Alert not firing? Type /osa probe <spell> in and out of combat.", "GameFontDisableSmall")
    probeHint:SetPoint("BOTTOMLEFT", 16, 12)

    function f:Refresh()
        local db = OSA.DB()
        local alerts = db.alerts
        if selected and not alerts[selected] then selected = nil end
        local items = {}
        for i, a in ipairs(alerts) do
            local id = OSA.AlertSpell(a)
            local aura = a.kind == "aura"
            local text = a.spell .. "  |cff999999" .. Summary(a) .. "|r"
            if (aura or a.need) and OSA.Searching(a) then
                text = text .. "  |cffffd100looking up its spell ids|r"
            elseif not id and not aura then
                text = text .. "  |cffff6060not in your spellbook|r"
            end
            if a.off then text = "|cff808080" .. a.spell .. "  " .. Summary(a) .. " (off)|r" end
            local listIcon = aura and OSA.AuraIcon(a) or id and OSA.SpellIcon(id) or 134400
            table.insert(items, {
                text = text, icon = listIcon, spell = id, dim = a.off,
                selected = i == selected,
                onClick = function()
                    selected = i
                    f:Refresh()
                end,
                onRemove = function()
                    table.remove(alerts, i)
                    if selected == i then selected = nil elseif selected and selected > i then selected = selected - 1 end
                    OSA.Changed()
                end,
            })
        end
        list:SetItems(items)

        local a = Selected()
        none:SetShown(a == nil)
        for _, w in ipairs(editWidgets) do w:SetShown(a ~= nil) end
        for key, c in pairs(condChecks) do
            c:SetShown(a ~= nil)
            if a then c:SetState(OSA.Conds(a)[key] or 0) end
        end
        lastsLabel:SetShown(a ~= nil and a.kind == "debuff")
        lasts:SetShown(a ~= nil and a.kind == "debuff")
        lastsHint:SetShown(a ~= nil and a.kind == "debuff")
        local castable = a ~= nil and a.kind ~= "debuff" and a.kind ~= "aura"
        needLabel:SetShown(castable)
        need:SetShown(castable)
        needAnyone:SetShown(castable)
        -- the conditions move up into the row when it's hidden
        condTitle:ClearAllPoints()
        condTitle:SetPoint("TOPLEFT", castable and needLabel or cpLabel, "BOTTOMLEFT", 0, -16)
        if a then
            if not need:HasFocus() then need:SetText(a.need and table.concat(a.need, ", ") or "") end
            needAnyone:SetChecked(a.anyone and true or false)
        end
        anytime:SetShown(castable)
        anyone:SetShown(a ~= nil and a.kind == "aura")
        -- an on-the-target alert's icon is the game's aura button, which the rules can't draw on
        lookButton:SetShown(a ~= nil and a.kind ~= "aura")
        if a and a.kind == "aura" then looks:Hide() end
        for _, w in ipairs(powerWidgets) do w:SetShown(castable) end
        -- an aura alert has no cooldown or length to show early by
        if a and a.kind == "aura" then
            earlyLabel:Hide()
            earlyBox:Hide()
            earlyHint:Hide()
        end
        if a then
            local id = OSA.AlertSpell(a)
            icon:SetTexture(a.kind == "aura" and OSA.AuraIcon(a) or id and OSA.SpellIcon(id) or 134400)
            name:SetText(a.spell)
            on:SetChecked(not a.off)
            anytime:SetChecked(a.anytime and true or false)
            anyone:SetChecked(a.anyone and true or false)
            when:SetText(KIND_TEXT[a.kind] or a.kind)
            sound:SetText(a.sound or "ping")
            power:SetText(POWER_TEXT[a.power or "dim"])
            ShowNumber(cp)
            cpHint:SetText("on your target, 0 = any")
            ShowNumber(atPower)
            ShowNumber(earlyBox)
            ShowNumber(flashBox)
            earlyLabel:ClearAllPoints()
            earlyLabel:SetPoint("TOPLEFT", castable and atLabel or soundLabel, "BOTTOMLEFT", 0, -22)
            earlyHint:SetText(a.kind == "debuff" and "sec before it falls off, 0 = off"
                or "sec before its cooldown ends, 0 = off")
            ShowNumber(lasts)
            ShowNumber(iconSize)
            plate:SetChecked(OSA.OnPlate(a) and true or false)
            plateSide:SetText(({ top = "Above", left = "Left", right = "Right" })[OSA.PlateSideOf(a)])
            plateSide:SetEnabled(OSA.OnPlate(a) and true or false)
            border:SetText(OSA.BORDER_NAMES[a.border or "thin"])
            lookButton:SetText(a.looks and ("Look (%d)..."):format(#a.looks) or "Look...")
            ShowNumber(iconHeight)
            iconSizeHint:SetText("0 = " .. (db.size > 0 and db.size or OSA.SIZE))
            local auto = a.kind == "debuff" and AutoDuration(a)
            lastsHint:SetText(a.duration and "sec" or (auto and ("sec, 0 = auto (" .. auto .. ")") or "sec, 0 = auto"))
            up:SetEnabled(selected > 1)
            down:SetEnabled(selected < #alerts)
        end

        unlock:SetText(db.unlocked and "Lock icons" or "Unlock icons")
        ShowNumber(size)
        minimap:SetChecked(not db.minimap.hide)
        debug:SetChecked(db.debug and true or false)
        whole:SetChecked(db.wholeSeconds and true or false)
        if looks:IsShown() then looks:Refresh() end
    end

    f:SetScript("OnShow", function(self) self:Refresh() end)
    return f
end

function OSA.RefreshConfig()
    if config and config:IsShown() then config:Refresh() end
end

function OSA.ToggleConfig()
    config = config or CreateConfig()
    config:SetShown(not config:IsShown())
end

-- addon compartment (the addons button by the minimap) -------------------------------------------

-- Shift-click unlocks or locks the icons, as in Buff Reminder
function OSA.ToggleLocked()
    local db = OSA.DB()
    db.unlocked = not db.unlocked or nil
    OSA.Print(db.unlocked and "Icons unlocked. Drag an icon to move its set, Shift-drag to pull it out on its own."
        or "Icons locked.")
    OSA.Changed()
end

function OpcowsSpellAlerts_OnAddonCompartmentClick()
    if IsShiftKeyDown() then
        OSA.ToggleLocked()
    else
        OSA.ToggleConfig()
    end
end

function OpcowsSpellAlerts_OnAddonCompartmentEnter(_, button)
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:SetText("Opcow's Spell Alerts")
    GameTooltip:AddLine("Click: options", 1, 1, 1)
    GameTooltip:AddLine(OSA.DB().unlocked and "Shift-click: lock the icons" or "Shift-click: unlock the icons", 1, 1, 1)
    GameTooltip:AddLine(#OSA.DB().alerts .. " alerts", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

function OpcowsSpellAlerts_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end

-- minimap button, drag to move it around the minimap ---------------------------------------------

local function PlaceMinimapButton()
    local angle = math.rad(OSA.DB().minimap.angle or 200)
    -- on the edge of the minimap, whatever size it is
    local w, h = Minimap:GetWidth() / 2 + 5, Minimap:GetHeight() / 2 + 5
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * w, math.sin(angle) * h)
end

local function CreateMinimapButton()
    local b = CreateFrame("Button", "OpcowsSpellAlertsMinimapButton", Minimap)
    -- same layout as LibDBIcon so it matches other addons' buttons
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("AnyUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(24, 24)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("CENTER")
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetTexture(ICON)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon:SetPoint("CENTER")
    -- round it off, or the square icon's corners show outside the border
    if b.CreateMaskTexture then
        local mask = b:CreateMaskTexture()
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(icon)
        icon:AddMaskTexture(mask)
    end
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(50, 50)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    b:SetScript("OnClick", function() OpcowsSpellAlerts_OnAddonCompartmentClick() end)
    b:SetScript("OnEnter", function(self) OpcowsSpellAlerts_OnAddonCompartmentEnter(nil, self) end)
    b:SetScript("OnLeave", OpcowsSpellAlerts_OnAddonCompartmentLeave)
    b:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            OSA.DB().minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            PlaceMinimapButton()
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    return b
end

function OSA.UpdateMinimap()
    if not Minimap then return end
    local hide = OSA.DB().minimap.hide
    if hide and not minimapButton then return end
    minimapButton = minimapButton or CreateMinimapButton()
    PlaceMinimapButton()
    minimapButton:SetShown(not hide)
end
