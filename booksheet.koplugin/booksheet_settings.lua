--[[--
Settings: plain rows with chevrons, and a chooser pop-up.
]]

local Catalog = require("booksheet_catalog")
local InputDialog = require("ui/widget/inputdialog")
local Store = require("booksheet_store")
local TextViewer = require("ui/widget/textviewer")
local UI = require("booksheet_ui")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Screen = Device.screen

local CHEVRON = "›"
local SLOT_NAMES = { "Top left", "Top right", "Bottom left", "Bottom right" }

--- Chooser pop-up. options: { text, note, checked, disabled, value }.
local Chooser = UI.Popup:extend{
    name = "booksheet_chooser",
    title = nil,
    columns = 1,
    get_options = nil,
    on_pick = nil,
    message = nil,
}

function Chooser:build(width)
    local canvas, hits = UI.canvas(), {}
    local pad = UI.px(14)
    local y = UI.px(10)
    local title = UI.text(self.title, UI.face("serif_bold", 20), width - pad * 2 - UI.px(40))
    canvas:place(title, pad, y)
    local close = UI.text("×", UI.face("sans", 28), UI.px(36))
    canvas:place(close, width - pad - close:getSize().w + UI.px(4), UI.px(3))
    hits[#hits + 1] = { x = width - UI.px(52), y = 0, w = UI.px(52), h = UI.px(44),
        action = function() self:onClose() end }
    y = y + title:getSize().h + UI.px(3)
    canvas:hline(pad, y, width - pad * 2, UI.px(1.5), UI.BLACK)
    y = y + UI.px(2)

    local options = self.get_options()
    local columns = self.columns
    local gap = UI.px(14)
    local col_w = math.floor((width - pad * 2 - gap * (columns - 1)) / columns)
    local row_h = UI.px(columns > 1 and 40 or 56)
    local check_w = UI.px(20)
    local col, group = 0, nil
    for _, option in ipairs(options) do
        if option.group and option.group ~= group then
            if col > 0 then y, col = y + row_h, 0 end
            y = y + UI.px(group and 18 or 8)
            group = option.group
            local head = UI.text(group, UI.face("serif_bold", 16), width - pad * 2)
            canvas:place(head, pad, y)
            y = y + head:getSize().h + UI.px(1)
            canvas:hline(pad, y, width - pad * 2, UI.px(1.5), UI.BLACK)
            y = y + UI.px(2)
        end
        local x = pad + col * (col_w + gap)
        local oy = y
        local color = option.disabled and UI.FAINT or UI.BLACK
        local face = UI.face(option.checked and "sans_bold" or "sans", 16)
        local label = UI.text(option.text, face, col_w - check_w, color)
        if option.note then
            local note = UI.text(option.note, UI.face("sans", 13), col_w - check_w, UI.MUTED)
            local total = label:getSize().h + note:getSize().h
            local top = oy + math.floor((row_h - total) / 2)
            canvas:place(label, x, top)
            canvas:place(note, x, top + label:getSize().h)
        else
            canvas:place(label, x, oy + math.floor((row_h - label:getSize().h) / 2))
        end
        if option.checked then
            local check = UI.text("✓", UI.face("sans_bold", 16), check_w)
            -- Without row lines, a far-right check would look attached to the next column.
            local check_x = columns > 1 and (x + label:getSize().w + UI.px(7)) or (x + col_w - check:getSize().w)
            canvas:place(check, check_x, oy + math.floor((row_h - check:getSize().h) / 2))
        end
        if columns == 1 then canvas:hline(x, oy + row_h - 1, col_w, 1, UI.RULE) end
        if not option.disabled then
            hits[#hits + 1] = { x = x, y = oy, w = col_w, h = row_h,
                action = function() self.on_pick(option, self) end }
        end
        col = col + 1
        if col == columns then y, col = y + row_h, 0 end
    end
    if col > 0 then y = y + row_h end
    y = y + UI.px(6)
    if self.message then
        local message = UI.box(self.message, UI.face("sans", 14), width - pad * 2)
        canvas:place(message, pad, y)
        y = y + message:getSize().h + UI.px(4)
    end
    return canvas, y + UI.px(6), hits
end

local Settings = UI.Page:extend{
    name = "booksheet_settings",
    plugin = nil,
    content_changed = false,
}

function Settings:init()
    self:initInput()
    self:rebuild()
end

local function titleOf(list, id)
    local entry = Catalog.find(list, id)
    return entry and entry.title or ""
end

function Settings:_groups()
    local slots = Store:get("sections")
    local section_rows = {}
    for i, name in ipairs(SLOT_NAMES) do
        section_rows[i] = { label = name, value = titleOf(Catalog.sections, slots[i]), chevron = true,
            action = function() self:chooseSection(i) end }
    end
    local source_count = 0
    local sources = Store:get("sources")
    for _, source in ipairs(Catalog.sources) do
        if sources[source.id] then source_count = source_count + 1 end
    end
    local want_count = #Store:get("want")
    return {
        { title = "Your sections", rows = section_rows },
        { title = "Your page", rows = {
            { label = "Book covers", value = Store:get("covers") and "On" or "Off",
              action = function() self:toggleCovers() end },
            { label = "Text size", value = titleOf(Catalog.text_sizes, Store:get("text_size")), chevron = true,
              action = function() self:chooseSimple("Text size", Catalog.text_sizes, "text_size") end },
            { label = "News sources", value = source_count .. " selected", chevron = true,
              action = function() self:chooseSources() end },
        } },
        { title = "Your books", rows = {
            { label = "Want to read", value = want_count == 1 and "1 book" or (want_count .. " books"), chevron = true,
              action = function() self.plugin:openWantList() end },
            { label = "Book QR codes open at", value = titleOf(Catalog.stores, Store:get("store")), chevron = true,
              action = function() self:chooseSimple("Book QR codes open at", Catalog.stores, "store") end },
        } },
        { title = "Updates", rows = {
            { label = "Update automatically", value = titleOf(Catalog.update_modes, Store:get("update_mode")),
              chevron = true,
              action = function() self:chooseSimple("Update automatically", Catalog.update_modes, "update_mode") end },
            { label = "Update now", action = function() self:updateNow() end },
            { label = "About and sources", chevron = true, action = function() self:showAbout() end },
        } },
    }
end

function Settings:rebuild()
    if self.canvas then self.canvas:free() end
    local W, H = Screen:getWidth(), Screen:getHeight()
    local margin = UI.px(18)
    local content_w = W - margin * 2
    local canvas, hits = UI.canvas(), {}
    local y = UI.px(10)
    local title = UI.text("Settings", UI.face("serif_bold", 24), content_w - UI.px(40))
    canvas:place(title, margin, y)
    local close = UI.text("×", UI.face("sans", 28), UI.px(36))
    canvas:place(close, W - margin - close:getSize().w, y)
    hits[#hits + 1] = { x = W - UI.px(58), y = 0, w = UI.px(58), h = UI.px(52), action = function() self:onClose() end }
    y = y + title:getSize().h + UI.px(3)
    canvas:hline(margin, y, content_w, UI.px(1), UI.BLACK)
    canvas:hline(margin, y + UI.px(3), content_w, UI.px(1), UI.BLACK)
    y = y + UI.px(8)

    local groups = self:_groups()
    local row_count = 0
    for _, group in ipairs(groups) do row_count = row_count + #group.rows end
    -- Open space above each later section keeps the groups visibly apart.
    local first_head_h, next_head_h = UI.px(32), UI.px(54)
    local heads_h = first_head_h + next_head_h * (#groups - 1)
    local row_h = math.min(UI.px(50), math.floor((H - y - heads_h - UI.px(6)) / row_count))
    local label_face, value_face = UI.face("sans", 17), UI.face("sans", 16)
    for g, group in ipairs(groups) do
        local head_h = g == 1 and first_head_h or next_head_h
        local head = UI.text(group.title, UI.face("serif_bold", 16), content_w)
        local head_y = y + head_h - head:getSize().h - UI.px(4)
        canvas:place(head, margin, head_y)
        y = y + head_h - UI.px(2)
        canvas:hline(margin, y, content_w, UI.px(1.5), UI.BLACK)
        y = y + UI.px(2)
        for r, row in ipairs(group.rows) do
            local label = UI.text(row.label, label_face, math.floor(content_w * 0.55))
            canvas:place(label, margin, y + math.floor((row_h - label:getSize().h) / 2))
            local right = margin + content_w
            if row.chevron then
                local chevron = UI.text(CHEVRON, UI.face("sans", 21), UI.px(18), UI.MUTED)
                right = right - chevron:getSize().w
                canvas:place(chevron, right, y + math.floor((row_h - chevron:getSize().h) / 2))
                right = right - UI.px(6)
            end
            if row.value then
                local value = UI.text(row.value, value_face, math.floor(content_w * 0.42), UI.MUTED)
                canvas:place(value, right - value:getSize().w, y + math.floor((row_h - value:getSize().h) / 2))
            end
            if r < #group.rows then
                canvas:hline(margin, y + row_h - 1, content_w, 1, UI.RULE)
            end
            hits[#hits + 1] = { x = margin, y = y, w = content_w, h = row_h, action = row.action }
            y = y + row_h
        end
    end
    self.canvas, self.hits = canvas, hits
end

function Settings:redraw()
    self:rebuild()
    UIManager:setDirty(self, "ui")
end

function Settings:paintTo(bb, x, y)
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, UI.WHITE)
    self.canvas:paint(bb, x, y)
end

function Settings:onShow()
    UIManager:setDirty(self, "ui")
    return true
end

function Settings:onTap(_, ges)
    local entry = UI.hit(self.hits, ges.pos.x, ges.pos.y)
    if entry and entry.action then entry.action() end
    return true
end

function Settings:toggleCovers()
    Store:set("covers", not Store:get("covers"))
    self.content_changed = true
    self:redraw()
end

function Settings:chooseSection(slot)
    local chooser = Chooser:new{
        title = SLOT_NAMES[slot],
        columns = 2,
        width_ratio = 0.92,
        get_options = function()
            local slots, options = Store:get("sections"), {}
            for _, section in ipairs(Catalog.sections) do
                local used_elsewhere = false
                for i, id in ipairs(slots) do
                    if id == section.id and i ~= slot then used_elsewhere = true end
                end
                options[#options + 1] = { text = section.title, value = section.id,
                    group = section.genre and "Bestseller lists from Apple Books" or "New and reviewed",
                    checked = slots[slot] == section.id, disabled = used_elsewhere }
            end
            return options
        end,
        on_pick = function(option, popup)
            local slots = Store:get("sections")
            slots[slot] = option.value
            Store:set("sections", slots)
            self.content_changed = true
            popup:onClose()
            self:redraw()
        end,
    }
    UIManager:show(chooser)
end

function Settings:chooseSimple(title, list, key)
    local chooser = Chooser:new{
        title = title,
        get_options = function()
            local current, options = Store:get(key), {}
            for _, entry in ipairs(list) do
                options[#options + 1] = { text = entry.title, note = entry.note, value = entry.id,
                    checked = entry.id == current }
            end
            return options
        end,
        on_pick = function(option, popup)
            if key == "store" and option.value == "libby" then
                self:askLibby(popup)
                return
            end
            Store:set(key, option.value)
            if key == "text_size" then self.content_changed = true end
            popup:onClose()
            self:redraw()
        end,
    }
    UIManager:show(chooser)
end

function Settings:saveLibby(text, popup)
    Store:set("libby_key", Catalog.libbyKey(text))
    Store:set("store", "libby")
    if popup then popup:onClose() end
    self:redraw()
end

--- Libby links are specific to one library.
function Settings:askLibby(popup)
    local dialog
    dialog = InputDialog:new{
        title = "Your Libby library",
        description = "Enter the name from your library's Libby address: libbyapp.com/library/name. Leave blank to search OverDrive instead.",
        input = Store:get("libby_key"),
        buttons = { {
            { text = "Cancel", id = "close", callback = function() UIManager:close(dialog) end },
            { text = "Save", is_enter_default = true, callback = function()
                local text = dialog:getInputText()
                UIManager:close(dialog)
                self:saveLibby(text, popup)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Settings:chooseSources()
    local chooser
    chooser = Chooser:new{
        title = "News sources",
        get_options = function()
            local sources, options = Store:get("sources"), {}
            for _, source in ipairs(Catalog.sources) do
                options[#options + 1] = { text = source.title, note = source.note, value = source.id,
                    checked = sources[source.id] == true }
            end
            return options
        end,
        on_pick = function(option, popup)
            local sources = Store:get("sources")
            local count = 0
            for _, enabled in pairs(sources) do
                if enabled then count = count + 1 end
            end
            if sources[option.value] and count == 1 then
                popup.message = "Keep at least one news source."
            else
                popup.message = nil
                sources[option.value] = (not sources[option.value]) or nil
                Store:set("sources", sources)
                self.sources_changed = true
                self:rebuild()
            end
            popup:refresh()
        end,
    }
    UIManager:show(chooser)
end

function Settings:updateNow()
    self:onClose()
    self.plugin:update(true)
end

function Settings:showAbout()
    local lines = {
        "The Booksheet is a one-page paper of book news for KOReader.",
        "",
        "Bestseller lists and Just out come from Apple Books. Reviewed this week comes from The New York Times.",
        "",
        "News comes from the sources you choose:",
    }
    for _, source in ipairs(Catalog.sources) do
        lines[#lines + 1] = "• " .. source.title .. " (" .. source.domain .. ")"
    end
    UIManager:show(TextViewer:new{ title = "About and sources", text = table.concat(lines, "\n") })
end

function Settings:onClose()
    UIManager:close(self, "full")
    return true
end

function Settings:onCloseWidget()
    if self.canvas then self.canvas:free() end
    if self.plugin then
        self.plugin:onSettingsClosed(self.content_changed, self.sources_changed)
    end
end

return Settings
