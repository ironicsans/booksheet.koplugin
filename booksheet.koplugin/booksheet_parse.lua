--[[--
Turns raw feeds into Booksheet content. No KOReader dependencies, so it can be
tested on its own.
]]

local Parse = {}

local ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
    rsquo = "’", lsquo = "‘", rdquo = "”", ldquo = "“", mdash = "—", ndash = "–",
    hellip = "…", eacute = "é", egrave = "è", aacute = "á", iacute = "í",
    oacute = "ó", uacute = "ú", ntilde = "ñ", ccedil = "ç", uuml = "ü", ouml = "ö",
}

local function utf8Char(cp)
    if not cp or cp < 0 or cp > 0x10FFFF then return "" end
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
    end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 4096),
            0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    return string.char(0xF0 + math.floor(cp / 262144),
        0x80 + math.floor(cp / 4096) % 64,
        0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

function Parse.decode(text)
    if not text then return "" end
    text = text:gsub("&#[xX](%x+);", function(hex) return utf8Char(tonumber(hex, 16)) end)
    text = text:gsub("&#(%d+);", function(num) return utf8Char(tonumber(num)) end)
    text = text:gsub("&(%a+);", function(name) return ENTITIES[name] end)
    return text
end

local function trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function xmlText(raw)
    if not raw then return "" end
    local parts, found = {}, false
    for inner in raw:gmatch("<!%[CDATA%[(.-)%]%]>") do
        found = true
        parts[#parts + 1] = inner
    end
    if found then return table.concat(parts) end
    return Parse.decode(raw)
end

--- Plain, readable text from article HTML. Paragraphs are separated by a blank line.
function Parse.stripHtml(html)
    if not html or html == "" then return "" end
    local text = html
    for _, tag in ipairs({ "script", "style", "figure", "iframe", "aside" }) do
        text = text:gsub("<" .. tag .. "[ >].-</" .. tag .. ">", " ")
    end
    text = text:gsub("<!%-%-.-%-%->", " ")
    text = text:gsub("<br%s*/?>", "\n")
    text = text:gsub("<li[^>]*>", "\n• ")
    for _, tag in ipairs({ "p", "div", "h%d", "ul", "ol", "blockquote", "section" }) do
        text = text:gsub("</" .. tag .. ">", "\n\n")
    end
    text = text:gsub("<[^>]+>", "")
    text = Parse.decode(text)

    local paragraphs = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = trim((line:gsub("[ \t\r]+", " ")))
        local is_boilerplate = line:find("appeared first on", 1, true) and line:find("^The post ")
        if line ~= "" and not is_boilerplate then
            paragraphs[#paragraphs + 1] = line
        end
    end
    return table.concat(paragraphs, "\n\n")
end

function Parse.wordCount(text)
    local _, count = (text or ""):gsub("%S+", "")
    return count
end

--- Shortens at a word boundary.
function Parse.excerpt(text, max_bytes)
    text = trim((text or ""):gsub("%s+", " "))
    if #text <= max_bytes then return text end
    local cut = text:sub(1, max_bytes)
    cut = cut:gsub("%s+%S*$", "")
    return cut .. "…"
end

local MONTHS = { jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6,
    jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12 }

local function utcEpoch(y, m, d, hh, mi, ss)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + hh * 3600 + mi * 60 + ss
end

local function zoneOffset(zone)
    if not zone then return 0 end
    local sign, hh, mi = zone:match("([%+%-])(%d%d):?(%d%d)")
    if sign then
        local offset = tonumber(hh) * 3600 + tonumber(mi) * 60
        return sign == "-" and -offset or offset
    end
    local named = { EST = -5, EDT = -4, CST = -6, CDT = -5, MST = -7, MDT = -6, PST = -8, PDT = -7 }
    return (named[zone:match("%a+") or ""] or 0) * 3600
end

--- Parses RSS (RFC 822) and Atom/iTunes (ISO 8601) dates into a UTC epoch.
function Parse.date(text)
    if not text then return nil end
    local y, m, d, hh, mi, ss, zone = text:match("(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)")
    if y then
        return utcEpoch(tonumber(y), tonumber(m), tonumber(d), tonumber(hh), tonumber(mi), tonumber(ss))
            - zoneOffset(zone)
    end
    local day, month, year, h, min, sec, z = text:match("(%d+)%s+(%a+)%s+(%d%d%d%d)%s+(%d+):(%d+):?(%d*)%s*(.*)")
    if day then
        local month_num = MONTHS[month:sub(1, 3):lower()]
        if not month_num then return nil end
        return utcEpoch(tonumber(year), month_num, tonumber(day), tonumber(h), tonumber(min), tonumber(sec) or 0)
            - zoneOffset(z)
    end
    return nil
end

local function field(block, name)
    return block:match("<" .. name .. "[^>]*>(.-)</" .. name .. ">")
end

--- Parses an RSS or Atom feed into a list of articles.
function Parse.feed(xml, limit)
    local out = {}
    if not xml then return out end
    local tag = xml:find("<item[ >]") and "item" or "entry"
    for block in xml:gmatch("<" .. tag .. "[ >].-</" .. tag .. ">") do
        local title = trim(Parse.decode(xmlText(field(block, "title"))))
        local link = trim(xmlText(field(block, "link")))
        if link == "" then
            link = block:match('<link[^>]-rel="alternate"[^>]-href="([^"]+)"')
                or block:match('<link[^>]-href="([^"]+)"') or ""
        end
        local html = xmlText(field(block, "content:encoded") or field(block, "content"))
        local summary = Parse.stripHtml(xmlText(field(block, "description") or field(block, "summary")))
        local body = Parse.stripHtml(html)
        local date = Parse.date(field(block, "pubDate") or field(block, "published")
            or field(block, "updated") or field(block, "dc:date"))
        if title ~= "" and link ~= "" then
            out[#out + 1] = {
                title = title,
                link = Parse.decode(link),
                summary = Parse.excerpt(summary ~= "" and summary or body, 420),
                body = Parse.wordCount(body) >= 150 and body or nil,
                date = date,
            }
            if limit and #out >= limit then break end
        end
    end
    return out
end

--- Reads decoded Apple chart JSON into a clean list of books.
function Parse.chart(decoded)
    local out = {}
    local feed = decoded and decoded.feed
    local entries = feed and feed.entry
    if not entries then return out end
    if entries["im:name"] then entries = { entries } end
    for _, entry in ipairs(entries) do
        local title = entry["im:name"] and entry["im:name"].label
        local author = entry["im:artist"] and entry["im:artist"].label
        if title and title ~= "" then
            local images = entry["im:image"]
            local cover = images and images[#images] and images[#images].label
            if cover then cover = cover:gsub("/%d+x%d+%a*%.%a+$", "/170x170bb.jpg") end
            local id_field = entry.id or {}
            local attrs = id_field.attributes or {}
            local release = entry["im:releaseDate"] and entry["im:releaseDate"].label
            out[#out + 1] = {
                id = tostring(attrs["im:id"] or title),
                title = title,
                author = author or "",
                cover = cover,
                link = id_field.label,
                release = Parse.date(release),
                summary = Parse.excerpt(Parse.stripHtml(entry.summary and entry.summary.label or ""), 420),
            }
        end
    end
    return out
end

--- Extracts the book from a headline like: Book Review: ‘Long Wave,’ by Daisy Johnson
function Parse.reviewedBook(headline)
    local title, author = headline:match("^Book Review: ‘(.-),?’,? by (.+)$")
    if title then return title, author end
    return nil
end

local DAY = 86400
local MAX_NEWS = 20
local MAX_NEWS_AGE = DAY * 7
local DROPPED = { "video:", "sponsored" }

--- Every enabled source as one reverse-chronological feed, like an RSS reader.
-- Keeps the newest 20 stories from the past 7 days, without videos or sponsored posts.
-- Stories with no date come last.
function Parse.latestNews(articles, now)
    local pool, seen = {}, {}
    for index, article in ipairs(articles) do
        local lower = article.title:lower()
        local dropped = false
        for _, word in ipairs(DROPPED) do
            if lower:find(word, 1, true) then dropped = true end
        end
        local recent = not article.date or now - article.date <= MAX_NEWS_AGE
        if recent and not dropped and not seen[article.link] then
            seen[article.link] = true
            pool[#pool + 1] = { article = article, index = index }
        end
    end
    table.sort(pool, function(a, b)
        local a_date, b_date = a.article.date or 0, b.article.date or 0
        if a_date ~= b_date then return a_date > b_date end
        return a.index < b.index
    end)
    local out = {}
    for i = 1, math.min(MAX_NEWS, #pool) do
        local item = pool[i].article
        out[i] = { title = item.title, link = item.link, summary = item.summary, body = item.body,
            domain = item.domain, source = item.source, date = item.date }
    end
    return out
end

--- New releases from a chart: released in the past three weeks, newest first.
function Parse.justOut(books, now, count)
    local recent = {}
    for _, book in ipairs(books) do
        if book.release and book.release <= now + DAY and now - book.release <= DAY * 21 then
            recent[#recent + 1] = book
        end
    end
    table.sort(recent, function(a, b)
        if a.release ~= b.release then return a.release > b.release end
        return a.title < b.title
    end)
    local out = {}
    for i = 1, math.min(count, #recent) do out[i] = recent[i] end
    return out
end

return Parse
