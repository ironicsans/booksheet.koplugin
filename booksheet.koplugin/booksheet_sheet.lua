--[[--
The Booksheet page: masthead, four sections on shared rows, Book news
and a status footer. Each section and Book news pages independently.
]]

local Catalog = require("booksheet_catalog")
local Store = require("booksheet_store")
local UI = require("booksheet_ui")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Geom = require("ui/geometry")
local Screen = Device.screen

local NEWS_PER_VIEW = 3
local MAX_NEWS = 20

local Sheet = UI.Page:extend{
    name = "booksheet_sheet",
    plugin = nil,
    edition = nil,
    status = nil,
}

function Sheet:init()
    self:initInput()
    self.status = self.status or { state = "idle" }
    self:rebuild()
end

local function longDate(epoch)
    return os.date("%A, %B ", epoch) .. tonumber(os.date("%d", epoch)) .. os.date(", %Y", epoch)
end

local function clock(epoch)
    local text = os.date("%I:%M %p", epoch)
    return (text:gsub("^0", ""))
end

local function updatedLabel(epoch)
    if not epoch then return "Not updated yet" end
    if os.date("%Y%j", epoch) == os.date("%Y%j") then
        return "Updated " .. clock(epoch)
    end
    return "Updated " .. os.date("%A", epoch)
end

function Sheet:_layout(scale, per_section, extra)
    local W = Screen:getWidth()
    local margin = UI.px(15)
    local content_w = W - margin * 2
    local gutter = UI.px(16)
    local col_w = math.floor((content_w - gutter) / 2)
    local right_x = margin + col_w + gutter
    local pad = UI.px(2) + extra
    local fonts = {
        masthead = UI.face("serif_bold", 28 * scale),
        date = UI.face("sans", 13 * scale),
        heading = UI.face("sans_bold", 14 * scale),
        item = UI.face("serif", 15.5 * scale),
        sub = UI.face("serif", 13 * scale),
        news = UI.face("serif", 15.5 * scale),
        domain = UI.face("sans", 12 * scale),
        nav = UI.face("sans", 12.5 * scale),
        number_w = UI.px(23 * scale),
    }

    local canvas, hits = UI.canvas(), {}
    local edition = self.edition or {}
    local y = UI.px(8)

    -- Masthead
    local title = UI.text("The Booksheet", fonts.masthead, content_w - UI.px(60))
    canvas:place(title, math.floor((W - title:getSize().w) / 2), y)
    local close = UI.text("×", UI.face("sans", 28), UI.px(36))
    local close_size = close:getSize()
    canvas:place(close, W - margin - close_size.w, y)
    hits[#hits + 1] = { x = W - UI.px(56), y = 0, w = UI.px(56), h = UI.px(50), action = "close" }
    y = y + title:getSize().h
    local date = UI.text(longDate(edition.updated_at or os.time()), fonts.date, content_w, UI.MUTED)
    canvas:place(date, math.floor((W - date:getSize().w) / 2), y)
    y = y + date:getSize().h + UI.px(4)
    canvas:hline(margin, y, content_w, UI.px(1), UI.BLACK)
    canvas:hline(margin, y + UI.px(3), content_w, UI.px(1), UI.BLACK)
    y = y + UI.px(9)

    -- Every row has room for a two-line title, so paging never moves anything.
    local head_probe = UI.text("Book news", fonts.heading, content_w)
    local title_probe = UI.box("Ag\nAg", fonts.item, col_w)
    local sub_probe = UI.text("Ag", fonts.sub, col_w)
    local line_probe = UI.text("Ag", fonts.news, content_w)
    local head_h = head_probe:getSize().h
    local row_h = title_probe:getSize().h + sub_probe:getSize().h + pad * 2
    local news_row_h = line_probe:getSize().h + pad * 2 + UI.px(1)
    head_probe:free(true)
    title_probe:free(true)
    sub_probe:free(true)
    line_probe:free(true)

    local slots = Store:get("sections")
    local data = edition.section_data or {}
    local show_covers = Store:get("covers")
    local cover_w = UI.px(44)
    local panels = {}
    for block = 0, 1 do
        for side = 1, 2 do
            local section = Catalog.find(Catalog.sections, slots[block * 2 + side]) or Catalog.sections[1]
            local entry = data[section.id]
            panels[#panels + 1] = {
                kind = "section", key = section.id, heading = section.heading,
                items = entry and entry.items or {}, is_list = section.genre ~= nil,
                show_cover = section.genre ~= nil and show_covers,
                x = side == 1 and margin or right_x, y = y, w = col_w,
                head_h = head_h, row_h = row_h, per_view = per_section, pad = pad,
                fonts = fonts, cover_w = cover_w, cover_h = math.floor(cover_w * 1.5), cover_gap = UI.px(6),
                nav_gap = UI.px(12),
            }
        end
        y = y + head_h + UI.px(5) + row_h * per_section + UI.px(8)
    end
    local news = {
        kind = "news", key = "news", heading = "Book news", items = self:_stories(),
        x = margin, y = y, w = content_w, head_h = head_h, row_h = news_row_h,
        per_view = NEWS_PER_VIEW, pad = pad, fonts = fonts, nav_gap = UI.px(20),
    }
    panels[#panels + 1] = news
    y = y + head_h + UI.px(4) + news_row_h * NEWS_PER_VIEW
    self._next_panels, self._next_news = panels, news

    return canvas, hits, y, per_section * 2 + NEWS_PER_VIEW
end

--- All enabled sources, newest first.
function Sheet:_stories()
    local edition = self.edition or {}
    local all, stories = {}, {}
    if edition.lead then all[1] = edition.lead end
    for _, story in ipairs(edition.news or {}) do all[#all + 1] = story end
    table.sort(all, function(a, b)
        local a_date, b_date = a.date or 0, b.date or 0
        if a_date ~= b_date then return a_date > b_date end
        return a.title < b.title
    end)
    for i = 1, math.min(MAX_NEWS, #all) do stories[i] = all[i] end
    return stories
end

--- Draws a heading with More and Back. Returns the navigation hit areas.
function Sheet:_placeHeading(canvas, panel, view, views)
    local fonts, nav_hits = panel.fonts, {}
    local y, head_h = panel.y, panel.head_h
    local right = panel.x + panel.w
    local heading_w = panel.w
    if views > 1 then
        -- More keeps its spot, and Back sits at a fixed distance from it.
        local more = UI.text("More ›", fonts.nav, UI.px(90))
        local back = UI.text("‹ Back", fonts.nav, UI.px(90))
        local more_size, back_size = more:getSize(), back:getSize()
        local gap = panel.nav_gap
        local more_x = right - more_size.w
        local back_x = more_x - gap - back_size.w
        heading_w = back_x - panel.x - UI.px(6)
        local hit_h = math.max(head_h, UI.px(46))
        local hit_y = y + math.floor((head_h - hit_h) / 2)
        local half = math.floor(gap / 2)
        if view < views then
            canvas:place(more, more_x, y + head_h - more_size.h)
            nav_hits[#nav_hits + 1] = { x = more_x - half, y = hit_y,
                w = more_size.w + half + UI.px(7), h = hit_h, action = "more", panel = panel }
        else
            more:free(true)
        end
        if view > 1 then
            canvas:place(back, back_x, y + head_h - back_size.h)
            nav_hits[#nav_hits + 1] = { x = back_x - UI.px(10), y = hit_y,
                w = back_size.w + UI.px(10) + half, h = hit_h, action = "back", panel = panel }
        else
            back:free(true)
        end
    end
    canvas:place(UI.text(panel.heading, fonts.heading, heading_w), panel.x, y)
    return nav_hits
end

function Sheet:_buildSection(panel, canvas, view)
    local fonts, item_hits = panel.fonts, {}
    local y = panel.y + panel.head_h + UI.px(1)
    canvas:hline(panel.x, y, panel.w, UI.px(1.5), UI.BLACK)
    y = y + UI.px(4)
    local has_cover = panel.show_cover and view == 1 and panel.items[1] ~= nil
    local text_w = has_cover and (panel.w - panel.cover_w - panel.cover_gap) or panel.w
    local body_y = y
    if #panel.items == 0 then
        canvas:place(UI.text("Waiting for update", fonts.sub, text_w, UI.MUTED), panel.x, y + panel.pad)
    end
    for i = 1, panel.per_view do
        local index = (view - 1) * panel.per_view + i
        local item = panel.items[index]
        if item then
            local title = UI.box(item.title, fonts.item, text_w - fonts.number_w, 2)
            local sub = UI.text(item.sub or item.author or "", fonts.sub, text_w - fonts.number_w, UI.MUTED)
            local mark = UI.text(panel.is_list and tostring(index) or "•", fonts.item, fonts.number_w)
            local text_h = title:getSize().h + sub:getSize().h
            local top = y + math.floor((panel.row_h - text_h) / 2)
            canvas:place(mark, panel.x, top)
            canvas:place(title, panel.x + fonts.number_w, top)
            canvas:place(sub, panel.x + fonts.number_w, top + title:getSize().h)
            item_hits[#item_hits + 1] = { x = panel.x, y = y, w = text_w, h = panel.row_h, item = item }
            canvas:hline(panel.x, y + panel.row_h - 1, text_w, 1, UI.RULE)
        end
        y = y + panel.row_h
    end
    if has_cover then
        local cover_x = panel.x + text_w + panel.cover_gap
        canvas:cover(Store:hasCover(panel.items[1]), cover_x, body_y + panel.pad, panel.cover_w, panel.cover_h)
        item_hits[#item_hits + 1] = { x = panel.x + text_w, y = body_y, w = panel.cover_w + panel.cover_gap,
            h = panel.cover_h + panel.pad, item = panel.items[1] }
    end
    return item_hits, y
end

function Sheet:_buildNewsRows(panel, canvas, view)
    local fonts, item_hits = panel.fonts, {}
    local y = panel.y + panel.head_h + UI.px(1)
    canvas:hline(panel.x, y, panel.w, UI.px(1.5), UI.BLACK)
    y = y + UI.px(3)
    for i = 1, panel.per_view do
        local item = panel.items[(view - 1) * panel.per_view + i]
        if item then
            item.kind = "news"
            local domain = UI.text(item.domain or "", fonts.domain, math.floor(panel.w * 0.34), UI.MUTED)
            local domain_size = domain:getSize()
            local line = UI.text(item.title, fonts.news, panel.w - domain_size.w - UI.px(10))
            local line_h = line:getSize().h
            canvas:place(line, panel.x, y + panel.pad)
            canvas:place(domain, panel.x + panel.w - domain_size.w,
                y + panel.pad + math.floor((line_h - domain_size.h) / 2))
            item_hits[#item_hits + 1] = { x = panel.x, y = y, w = panel.w, h = panel.row_h, item = item }
            canvas:hline(panel.x, y + panel.row_h - 1, panel.w, 1, UI.RULE)
        end
        y = y + panel.row_h
    end
    return item_hits, y
end

function Sheet:_buildPanel(panel)
    if panel.canvas then panel.canvas:free() end
    self.views = self.views or {}
    local views = math.max(1, math.ceil(#panel.items / panel.per_view))
    local view = math.max(1, math.min(self.views[panel.key] or 1, views))
    self.views[panel.key] = view
    local canvas = UI.canvas()
    panel.nav_hits = self:_placeHeading(canvas, panel, view, views)
    local item_hits, bottom
    if panel.kind == "news" then
        item_hits, bottom = self:_buildNewsRows(panel, canvas, view)
    else
        item_hits, bottom = self:_buildSection(panel, canvas, view)
    end
    panel.item_hits = item_hits
    panel.hits = {}
    for _, hit in ipairs(panel.nav_hits) do panel.hits[#panel.hits + 1] = hit end
    for _, hit in ipairs(item_hits) do panel.hits[#panel.hits + 1] = hit end
    panel.canvas = canvas
    panel.rect = Geom:new{ x = panel.x, y = panel.y, w = panel.w, h = bottom - panel.y }
end

function Sheet:_turn(panel, delta)
    self.views[panel.key] = (self.views[panel.key] or 1) + delta
    self:_buildPanel(panel)
    UIManager:setDirty(self, function() return "ui", panel.rect end)
end

function Sheet:_freePanels()
    for _, panel in ipairs(self.panels or {}) do
        if panel.canvas then panel.canvas:free() end
    end
    self.panels = nil
end

function Sheet:_footerHeight()
    return UI.px(36)
end

function Sheet:_buildFooter()
    if self.footer then self.footer:free() end
    local W, H = Screen:getWidth(), Screen:getHeight()
    local margin = UI.px(15)
    local fh = self:_footerHeight()
    local footer_y = H - fh
    local canvas = UI.canvas()
    local face = UI.face("sans", 13)
    local strong = UI.face("sans_bold", 13)
    local mid_y = footer_y + math.floor(fh / 2)
    local hits = {}

    local status = self.status or { state = "idle" }
    local update_w
    do
        local text
        if status.state == "offline" then
            local when = self.edition and self.edition.updated_at
            if when then
                local is_today = os.date("%Y%j", when) == os.date("%Y%j")
                text = "Offline · from " .. (is_today and clock(when) or os.date("%A", when))
            else
                text = "Offline"
            end
        else
            text = updatedLabel(self.edition and self.edition.updated_at)
        end
        local label = UI.text(text, status.state == "offline" and strong or face, math.floor(W * 0.42),
            status.state == "offline" and UI.BLACK or UI.MUTED)
        canvas:place(label, margin, mid_y - math.floor(label:getSize().h / 2))
        update_w = margin + label:getSize().w + UI.px(14)
    end

    local count = #Store:get("want")
    local want = UI.text("Want to read: " .. count, face, math.floor(W * 0.3), UI.MUTED)
    local want_size = want:getSize()
    local want_x = math.floor((W - want_size.w) / 2) + UI.px(14)
    canvas:place(want, want_x, mid_y - math.floor(want_size.h / 2))
    hits[#hits + 1] = { x = want_x - UI.px(8), y = footer_y, w = want_size.w + UI.px(16), h = fh, action = "want" }

    local settings = UI.text("Settings", face, UI.px(90))
    local settings_size = settings:getSize()
    local settings_x = W - margin - settings_size.w
    canvas:place(settings, settings_x, mid_y - math.floor(settings_size.h / 2))
    hits[#hits + 1] = { x = settings_x - UI.px(14), y = footer_y, w = W - settings_x + UI.px(14), h = fh, action = "settings" }

    if update_w then
        hits[#hits + 1] = { x = 0, y = footer_y, w = update_w, h = fh, action = "update" }
    end

    self.footer = canvas
    self.footer_hits = hits
    self.footer_rect = Geom:new{ x = 0, y = footer_y, w = W, h = fh }
end

function Sheet:rebuild()
    if self.canvas then self.canvas:free() end
    self:_freePanels()
    local size = Catalog.find(Catalog.text_sizes, Store:get("text_size")) or Catalog.text_sizes[2]
    local limit = Screen:getHeight() - self:_footerHeight()
    -- Use the largest type that fits, so the page fills any screen size.
    -- Readability wins: below full size, show two books per section instead.
    local attempts = { { 1, 3 }, { 0.96, 3 }, { 1, 2 }, { 0.94, 2 }, { 0.88, 2 } }
    local canvas, hits
    for index, attempt in ipairs(attempts) do
        local scale = size.scale * attempt[1]
        local c, h, used, rows = self:_layout(scale, attempt[2], 0)
        if used <= limit or index == #attempts then
            local spare = limit - used
            if spare > rows and rows > 0 then
                c:free()
                local extra = math.min(math.floor(spare / (rows * 2 + 2)), UI.px(13))
                c, h = self:_layout(scale, attempt[2], extra)
            end
            canvas, hits = c, h
            break
        end
        c:free()
    end
    self.canvas, self.hits = canvas, hits
    self.panels, self.news_panel = self._next_panels, self._next_news
    for _, panel in ipairs(self.panels) do self:_buildPanel(panel) end
    self:_buildFooter()
end

function Sheet:paintTo(bb, x, y)
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, UI.WHITE)
    self.canvas:paint(bb, x, y)
    for _, panel in ipairs(self.panels) do panel.canvas:paint(bb, x, y) end
    self.footer:paint(bb, x, y)
    if self.banner then
        local r = self.banner_rect
        bb:paintRect(x + r.x, y + r.y, r.w, r.h, UI.WHITE)
        self.banner:paint(bb, x, y)
    end
end

function Sheet:onShow()
    UIManager:setDirty(self, "full")
    return true
end

function Sheet:_buildBanner()
    if self.banner then self.banner:free() end
    self.banner, self.banner_rect = nil, nil
    local status = self.status or {}
    if status.state ~= "updating" then return end
    local W, H = Screen:getWidth(), Screen:getHeight()
    local bw, bh = UI.px(230), UI.px(90)
    local bx, by = math.floor((W - bw) / 2), math.floor((H - bh) / 2)
    local canvas = UI.canvas()
    canvas:box(bx, by, bw, bh, UI.px(3), UI.BLACK)
    local label = UI.text("Updating", UI.face("serif_bold", 20), bw - UI.px(20))
    local size = label:getSize()
    local seg_w, seg_h, gap = UI.px(24), UI.px(8), UI.px(4)
    local bar_w = seg_w * 5 + gap * 4
    local top = by + math.floor((bh - size.h - UI.px(7) - seg_h) / 2)
    canvas:place(label, bx + math.floor((bw - size.w) / 2), top)
    local bar_x, bar_y = bx + math.floor((bw - bar_w) / 2), top + size.h + UI.px(7)
    local filled = math.floor(5 * (status.fraction or 0) + 0.0001)
    for i = 1, 5 do
        local sx = bar_x + (i - 1) * (seg_w + gap)
        if i <= filled then
            canvas:rect(sx, bar_y, seg_w, seg_h, UI.BLACK)
        else
            canvas:box(sx, bar_y, seg_w, seg_h, 1, UI.BLACK)
        end
    end
    self.banner = canvas
    self.banner_rect = Geom:new{ x = bx, y = by, w = bw, h = bh }
end

function Sheet:setStatus(status)
    local was_updating = self.status and self.status.state == "updating"
    self.status = status
    self:_buildFooter()
    self:_buildBanner()
    if self.banner_rect and was_updating then
        UIManager:setDirty(self, function() return "ui", self.banner_rect end)
    else
        UIManager:setDirty(self, "ui")
    end
end

function Sheet:setEdition(edition)
    self.edition = edition
    self.views = {}
    self.status = { state = "idle" }
    self:rebuild()
    self:_buildBanner()
    UIManager:setDirty(self, "full")
end

function Sheet:redraw()
    self:rebuild()
    UIManager:setDirty(self, "ui")
end

function Sheet:onTap(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    local entry = UI.hit(self.footer_hits, x, y)
    -- More and Back have generous touch areas, so they are checked before rows.
    for _, panel in ipairs(self.panels) do entry = entry or UI.hit(panel.nav_hits, x, y) end
    for _, panel in ipairs(self.panels) do entry = entry or UI.hit(panel.item_hits, x, y) end
    entry = entry or UI.hit(self.hits, x, y)
    if not entry then return true end
    -- While updating, only the close button works.
    if self.banner and entry.action ~= "close" then return true end
    if entry.action == "close" then
        self:onClose()
    elseif entry.action == "settings" then
        self.plugin:openSettings()
    elseif entry.action == "want" then
        self.plugin:openWantList()
    elseif entry.action == "update" then
        self.plugin:update(true)
    elseif entry.action == "more" then
        self:_turn(entry.panel, 1)
    elseif entry.action == "back" then
        self:_turn(entry.panel, -1)
    elseif entry.item then
        self.plugin:openCard(entry.item)
    end
    return true
end

function Sheet:onClose()
    UIManager:close(self, "full")
    return true
end

function Sheet:onCloseWidget()
    if self.canvas then self.canvas:free() end
    self:_freePanels()
    if self.footer then self.footer:free() end
    if self.banner then self.banner:free() end
    if self.plugin then self.plugin:onSheetClosed(self) end
end

return Sheet
