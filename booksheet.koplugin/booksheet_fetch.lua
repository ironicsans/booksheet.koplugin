--[[--
Small network helpers with short timeouts and a size limit.
]]

local http = require("socket.http")
local logger = require("logger")
local socket = require("socket")
local socketutil = require("socketutil")

local Fetch = {}

local MAX_BYTES = 3 * 1024 * 1024
local BLOCK_TIMEOUT = 8
local TOTAL_TIMEOUT = 20

local function limitedSink(parts)
    local size = 0
    return function(chunk, err)
        if chunk then
            size = size + #chunk
            if size > MAX_BYTES then return nil, "response too large" end
            parts[#parts + 1] = chunk
        end
        return 1, err
    end
end

--- Returns the response body, or nil on any failure.
function Fetch.get(url)
    local parts = {}
    socketutil:set_timeout(BLOCK_TIMEOUT, TOTAL_TIMEOUT)
    local ok, code = pcall(function()
        return socket.skip(1, http.request{
            url = url,
            method = "GET",
            sink = limitedSink(parts),
        })
    end)
    socketutil:reset_timeout()
    if not ok or code ~= 200 then
        logger.warn("Booksheet: fetch failed", url, code)
        return nil
    end
    return table.concat(parts)
end

--- Downloads to a file, replacing it only after a complete download.
function Fetch.toFile(url, path)
    local body = Fetch.get(url)
    if not body or #body == 0 then return false end
    local tmp = path .. ".tmp"
    local file = io.open(tmp, "wb")
    if not file then return false end
    file:write(body)
    file:close()
    return os.rename(tmp, path) and true or false
end

return Fetch
