--[[--
Drawing helpers shared by the Booksheet screens: a simple positioned canvas,
text helpers, and a centered pop-up base.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

--- A shade of gray that works across KOReader versions.
local function shade(value, fallback)
    if Blitbuffer.Color8 then return Blitbuffer.Color8(value) end
    if Blitbuffer.gray then return Blitbuffer.gray((255 - value) / 255) end
    return fallback
end

local UI = {
    BLACK = Blitbuffer.COLOR_BLACK,
    WHITE = Blitbuffer.COLOR_WHITE,
    MUTED = shade(0x33, Blitbuffer.COLOR_BLACK), -- secondary text: only slightly lighter than black
    FAINT = shade(0x77, Blitbuffer.COLOR_DARK_GRAY), -- unavailable choices
    RULE = shade(0x77, Blitbuffer.COLOR_DARK_GRAY),
    FILL = Blitbuffer.COLOR_LIGHT_GRAY,
}

local FACES = {
    serif = "NotoSerif-Regular.ttf",
    serif_bold = "NotoSerif-Bold.ttf",
    sans = "NotoSans-Regular.ttf",
    sans_bold = "NotoSans-Bold.ttf",
}

function UI.px(n)
    return Screen:scaleBySize(n)
end

function UI.face(kind, size)
    return Font:getFace(FACES[kind], math.max(12, math.floor(size + 0.5)))
end

--- One line of text, cut with an ellipsis at max_width.
function UI.text(text, face, max_width, color)
    return TextWidget:new{
        text = text or "",
        face = face,
        max_width = max_width,
        fgcolor = color or UI.BLACK,
        padding = 0,
    }
end

--- Wrapped text, limited to max_lines.
function UI.box(text, face, width, max_lines, color, alignment)
    local box = TextBoxWidget:new{
        text = text or "",
        face = face,
        width = width,
        fgcolor = color or UI.BLACK,
        alignment = alignment or "left",
    }
    if max_lines then
        local line_h = box:getLineHeight()
        if box:getTextHeight() > line_h * max_lines + 1 then
            box:free(true)
            box = TextBoxWidget:new{
                text = text or "",
                face = face,
                width = width,
                height = math.ceil(line_h * max_lines),
                height_overflow_show_ellipsis = true,
                fgcolor = color or UI.BLACK,
                alignment = alignment or "left",
            }
        end
    end
    return box
end

local Canvas = {}
Canvas.__index = Canvas

function UI.canvas()
    return setmetatable({ ops = {} }, Canvas)
end

function Canvas:place(widget, x, y)
    self.ops[#self.ops + 1] = { widget = widget, x = x, y = y }
    return widget
end

function Canvas:rect(x, y, w, h, color)
    self.ops[#self.ops + 1] = { rect = true, x = x, y = y, w = w, h = h, color = color or UI.BLACK }
end

function Canvas:hline(x, y, w, thickness, color)
    self:rect(x, y, w, thickness or 1, color or UI.RULE)
end

function Canvas:box(x, y, w, h, thickness, color)
    thickness = thickness or 1
    self:rect(x, y, w, thickness, color)
    self:rect(x, y + h - thickness, w, thickness, color)
    self:rect(x, y, thickness, h, color)
    self:rect(x + w - thickness, y, thickness, h, color)
end

--- A cover fitted inside the given box, or a plain placeholder.
function Canvas:cover(path, x, y, w, h)
    if path then
        local image = ImageWidget:new{ file = path, width = w, height = h, scale_factor = 0 }
        local ok, size = pcall(image.getSize, image)
        if ok and size then
            self:place(image, x + w - size.w, y)
            self:box(x + w - size.w, y, size.w, size.h, 1, UI.MUTED)
            return size.h
        end
        pcall(image.free, image)
    end
    self:rect(x, y, w, h, UI.FILL)
    self:box(x, y, w, h, 1, UI.MUTED)
    return h
end

function Canvas:paint(bb, ox, oy)
    for _, op in ipairs(self.ops) do
        if op.rect then
            bb:paintRect(ox + op.x, oy + op.y, op.w, op.h, op.color)
        else
            op.widget:paintTo(bb, ox + op.x, oy + op.y)
        end
    end
end

function Canvas:free()
    for _, op in ipairs(self.ops) do
        if op.widget and op.widget.free then op.widget:free(true) end
    end
    self.ops = {}
end

function UI.hit(hits, x, y)
    for _, entry in ipairs(hits or {}) do
        if x >= entry.x and x < entry.x + entry.w and y >= entry.y and y < entry.y + entry.h then
            return entry
        end
    end
end

--- Base for full-screen pages.
UI.Page = InputContainer:extend{
    covers_fullscreen = true,
    stop_events_propagation = true,
}

function UI.Page:initInput()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:isTouchDevice() then
        self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = self.dimen } }
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
end

--- Base for centered pop-ups. Subclasses implement build(width) and return
-- canvas, height, hits.
UI.Popup = InputContainer:extend{
    width_ratio = 0.92,
    max_width = nil,
    stop_events_propagation = true,
}

function UI.Popup:init()
    self.screen_rect = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:isTouchDevice() then
        self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = self.screen_rect } }
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self:relayout()
end

function UI.Popup:relayout()
    if self.canvas then self.canvas:free() end
    local w = math.floor(Screen:getWidth() * self.width_ratio)
    local canvas, h, hits = self:build(w)
    self.canvas, self.hits = canvas, hits
    self.dimen = Geom:new{
        x = math.floor((Screen:getWidth() - w) / 2),
        y = math.floor((Screen:getHeight() - h) / 2),
        w = w,
        h = h,
    }
end

function UI.Popup:paintTo(bb, x, y)
    local d = self.dimen
    bb:paintRect(x + d.x, y + d.y, d.w, d.h, UI.WHITE)
    self.canvas:paint(bb, x + d.x, y + d.y)
    local border = UI.px(3)
    bb:paintRect(x + d.x, y + d.y, d.w, border, UI.BLACK)
    bb:paintRect(x + d.x, y + d.y + d.h - border, d.w, border, UI.BLACK)
    bb:paintRect(x + d.x, y + d.y, border, d.h, UI.BLACK)
    bb:paintRect(x + d.x + d.w - border, y + d.y, border, d.h, UI.BLACK)
end

function UI.Popup:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function UI.Popup:onTap(_, ges)
    local d = self.dimen
    local px, py = ges.pos.x, ges.pos.y
    if px < d.x or px >= d.x + d.w or py < d.y or py >= d.y + d.h then
        self:onClose()
        return true
    end
    local entry = UI.hit(self.hits, px - d.x, py - d.y)
    if entry and entry.action then entry.action() end
    return true
end

function UI.Popup:onClose()
    UIManager:close(self, "ui", self.dimen)
    return true
end

function UI.Popup:onCloseWidget()
    if self.canvas then self.canvas:free() end
end

function UI.Popup:refresh()
    self:relayout()
    UIManager:setDirty("all", function() return "ui", self.screen_rect end)
end

return UI
