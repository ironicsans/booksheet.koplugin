--[[--
The card that opens over the page when a book or headline is tapped.
]]

local Catalog = require("booksheet_catalog")
local Store = require("booksheet_store")
local TextViewer = require("ui/widget/textviewer")
local UI = require("booksheet_ui")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Screen = Device.screen

--- A QR code as large as the screen allows, with a close button.
local QRPopup = UI.Popup:extend{
    name = "booksheet_qr",
    title = nil,
    text = nil,
}

local QR_INCHES = 1.6 -- about 4 cm: easy to scan without taking over the screen

local function qrSide()
    return math.min(math.floor(Screen:getDPI() * QR_INCHES), math.floor(Screen:getWidth() * 0.7))
end

function QRPopup:init()
    local W = Screen:getWidth()
    self.width_ratio = math.max(0.62, (qrSide() + UI.px(28)) / W)
    UI.Popup.init(self)
end

function QRPopup:build(width)
    local canvas, hits = UI.canvas(), {}
    local pad = UI.px(14)
    local title = UI.box(self.title, UI.face("serif_bold", 18), width - pad * 2 - UI.px(40), 2)
    canvas:place(title, pad, pad)
    local close = UI.text("×", UI.face("sans", 28), UI.px(36))
    canvas:place(close, width - pad - close:getSize().w + UI.px(4), UI.px(3))
    hits[#hits + 1] = { x = width - UI.px(60), y = 0, w = UI.px(60), h = UI.px(56),
        action = function() self:onClose() end }
    local y = pad + math.max(title:getSize().h, UI.px(28)) + UI.px(12)
    local side = qrSide()
    local ok, qr = pcall(function()
        return require("ui/widget/qrwidget"):new{ text = self.text, width = side, height = side }
    end)
    if ok and qr and qr.image then
        local size = qr:getSize()
        canvas:place(qr, math.floor((width - size.w) / 2), y + math.floor((side - size.h) / 2))
        y = y + side
    else
        local link = UI.box(self.text, UI.face("sans", 15), width - pad * 2)
        canvas:place(link, pad, y)
        y = y + link:getSize().h
    end
    return canvas, y + pad, hits
end

local Card = UI.Popup:extend{
    name = "booksheet_card",
    item = nil,
    plugin = nil,
    from_list = false,
}

function Card:openOnPhone(to_review)
    local item = self.item
    local url, title, note
    if to_review then
        url = item.review_link or Catalog.reviewSearchUrl(item)
        title = "Scan to open the review at " .. (item.review_domain or "nytimes.com")
    elseif item.kind == "news" then
        url, title = item.link, "Scan to open at " .. (item.domain or "the article")
    else
        local store
        url, store = Catalog.storeUrl(Store:get("store"), item, Store:get("libby_key"))
        title = "Scan to open at " .. store.title
        if store.referral ~= "" then note = true end
    end
    if note then title = title .. " · Booksheet may earn a commission" end
    self:onClose()
    UIManager:show(QRPopup:new{ title = title, text = url })
end

function Card:readArticle()
    local item = self.item
    self:onClose()
    UIManager:show(TextViewer:new{
        title = item.title,
        text = item.body .. "\n\nFrom " .. (item.domain or "the publisher"),
    })
end

function Card:toggleWant()
    Store:toggleWant(self.item)
    self.plugin:onWantChanged()
    self:refresh()
end

--- "nytimes.com · November 23, 2026" for articles.
local function newsLine(item)
    if not item.date then return item.domain end
    local date = os.date("%B ", item.date) .. tonumber(os.date("%d", item.date)) .. os.date(", %Y", item.date)
    return item.domain and (item.domain .. " · " .. date) or date
end

--- On the Want to read list, chart positions would be out of date.
local function savedLine(item)
    if not item.saved_at then return nil end
    return "Saved " .. os.date("%B ", item.saved_at) .. tonumber(os.date("%d", item.saved_at))
        .. os.date(", %Y", item.saved_at)
end

function Card:actions()
    local item = self.item
    if item.kind == "news" then
        local list = {}
        if item.body then
            list[#list + 1] = { "Read article", function() self:readArticle() end }
        end
        list[#list + 1] = { "QR Code to Article", function() self:openOnPhone() end }
        return list
    end
    local list = {
        { Store:isWanted(item) and "Remove from list" or "Want to read", function() self:toggleWant() end },
        { "QR Code to Book", function() self:openOnPhone() end },
    }
    if item.review_link or tostring(item.id):find("^review:") then
        list[#list + 1] = { "QR Code to Review", function() self:openOnPhone(true) end }
    end
    return list
end

function Card:build(width)
    local item = self.item
    local canvas, hits = UI.canvas(), {}
    local pad = UI.px(14)
    local is_book = item.kind ~= "news"
    local cover_path = is_book and Store:hasCover(item) or nil
    local cover_w = cover_path and UI.px(76) or 0
    local cover_h = cover_path and math.floor(cover_w * 1.5) or 0
    local text_x = pad + (cover_path and cover_w + UI.px(12) or 0)
    local close_room = UI.px(36)
    local text_w = width - text_x - pad - close_room

    local y = pad
    local title = UI.box(item.title, UI.face("serif_bold", 21), text_w, 4)
    canvas:place(title, text_x, y)
    y = y + title:getSize().h + UI.px(3)
    if is_book and item.author and item.author ~= "" then
        local author = UI.box(item.author, UI.face("serif", 17), width - text_x - pad, 2, UI.MUTED)
        canvas:place(author, text_x, y)
        y = y + author:getSize().h + UI.px(1)
    end
    local meta
    if not is_book then
        meta = newsLine(item)
    elseif self.from_list then
        meta = savedLine(item)
    else
        meta = item.meta or item.domain
    end
    if meta then
        local line = UI.box(meta, UI.face("sans", 15), width - text_x - pad, 2, UI.MUTED)
        canvas:place(line, text_x, y)
        y = y + line:getSize().h
    end
    if cover_path then
        canvas:cover(cover_path, pad, pad, cover_w, cover_h)
        y = math.max(y, pad + cover_h)
    end
    y = y + UI.px(10)

    if item.summary and item.summary ~= "" then
        local summary = UI.box(item.summary, UI.face("serif", 17), width - pad * 2, 9)
        canvas:place(summary, pad, y)
        y = y + summary:getSize().h + UI.px(10)
    end

    local close = UI.text("×", UI.face("sans", 28), UI.px(36))
    canvas:place(close, width - pad - close:getSize().w + UI.px(4), UI.px(3))
    hits[#hits + 1] = { x = width - UI.px(60), y = 0, w = UI.px(60), h = UI.px(56),
        action = function() self:onClose() end }

    local actions = self:actions()
    local button_h = UI.px(56)
    canvas:hline(0, y, width, 1, UI.BLACK)
    local cell_w = math.floor(width / #actions)
    for i, action in ipairs(actions) do
        local x = (i - 1) * cell_w
        local face = UI.face("sans", #actions > 2 and 15 or 16)
        local label = UI.text(action[1], face, cell_w - UI.px(6))
        local size = label:getSize()
        canvas:place(label, x + math.floor((cell_w - size.w) / 2), y + math.floor((button_h - size.h) / 2))
        if i > 1 then canvas:rect(x, y, 1, button_h, UI.BLACK) end
        hits[#hits + 1] = { x = x, y = y, w = cell_w, h = button_h, action = action[2] }
    end
    return canvas, y + button_h, hits
end

return Card
