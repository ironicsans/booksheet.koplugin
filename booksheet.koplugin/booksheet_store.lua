--[[--
Saved settings, the last edition, the Want to read list and cached covers.
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local Store = {}

local DEFAULTS = {
    sections = { "scifi", "biography", "just_out", "reviewed" },
    covers = true,
    text_size = "medium",
    sources = { nyt = true, npr = true, lithub = true, bookriot = true },
    store = "bookshop",
    libby_key = "",
    update_mode = "open",
    want = {},
}

local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deepCopy(v) end
    return out
end

function Store:init()
    if self.settings then return end
    self.dir = DataStorage:getDataDir() .. "/cache/booksheet"
    self.cover_dir = self.dir .. "/covers"
    util.makePath(self.cover_dir)
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/booksheet.lua")
    self.edition_file = LuaSettings:open(self.dir .. "/edition.lua")
end

function Store:get(key)
    local value = self.settings:readSetting(key)
    if value == nil then
        value = deepCopy(DEFAULTS[key])
        self.settings:saveSetting(key, value)
    end
    return value
end

function Store:set(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function Store:getEdition()
    return self.edition_file:readSetting("edition")
end

function Store:setEdition(edition)
    self.edition_file:saveSetting("edition", edition)
    self.edition_file:flush()
end

--- The same book can appear on a list and under reviews with different ids.
local function sameBook(a, b)
    if a.id == b.id then return true end
    return a.title and b.title and a.title:lower() == b.title:lower()
        and (a.author or ""):lower() == (b.author or ""):lower()
end

function Store:isWanted(book)
    for _, entry in ipairs(self:get("want")) do
        if sameBook(entry, book) then return true end
    end
    return false
end

--- Adds or removes a book. Returns true when the book is now saved.
function Store:toggleWant(book)
    local want = self:get("want")
    for i, entry in ipairs(want) do
        if sameBook(entry, book) then
            table.remove(want, i)
            self:set("want", want)
            return false
        end
    end
    table.insert(want, 1, { id = book.id, title = book.title, author = book.author,
        link = book.link, summary = book.summary, meta = book.meta, kind = "book",
        review_link = book.review_link, review_domain = book.review_domain,
        saved_at = book.saved_at or os.time() })
    self:set("want", want)
    return true
end

function Store:coverPath(book)
    if not book or not book.id then return nil end
    local name = tostring(book.id):gsub("[^%w]", "_")
    return ("%s/%s.jpg"):format(self.cover_dir, name)
end

function Store:hasCover(book)
    local path = self:coverPath(book)
    if path and lfs.attributes(path, "mode") == "file" and (lfs.attributes(path, "size") or 0) > 0 then
        return path
    end
end

--- Deletes covers no longer used by the page or the Want to read list.
function Store:pruneCovers(keep_books)
    local keep = {}
    for _, book in ipairs(keep_books) do
        local path = self:coverPath(book)
        if path then keep[path] = true end
    end
    for _, book in ipairs(self:get("want")) do
        local path = self:coverPath(book)
        if path then keep[path] = true end
    end
    for name in lfs.dir(self.cover_dir) do
        if name:match("%.jpg$") then
            local path = self.cover_dir .. "/" .. name
            if not keep[path] then os.remove(path) end
        end
    end
end

return Store
