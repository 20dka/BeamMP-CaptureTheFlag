--[[
 SJSON Parser for Lua 5.1

 Copyright (c) 2013-2018 BeamNG GmbH.
 All Rights Reserved.

 Permission is hereby granted, free of charge, to any person
 obtaining a copy of this software to deal in the Software without
 restriction, including without limitation the rights to use,
 copy, modify, merge, publish, distribute, sublicense, and/or
 sell copies of the Software, and to permit persons to whom the
 Software is furnished to do so, subject to the following conditions:

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR
 ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

 It decodes SJON format:
  https://github.com/Autodesk/sjson

 Usage:

 -- Lua script:
 local t = Json.Decode(json)

 Notes:
 1) Encodable Lua types: string, number, boolean, table, nil
 2) All control chars are encoded to \uXXXX format eg "\021" encodes to "\u0015"
 3) All Json \uXXXX chars are decoded to chars (0-255 byte range only)
 4) Json single line // and /* */ block comments are discarded during decoding
 5) Numerically indexed Lua arrays are encoded to Json Lists eg [1,2,3]
 6) Lua dictionary tables are converted to Json objects eg {"one":1,"two":2}
 7) Json nulls are decoded to Lua nil and treated by Lua in the normal way

--]]

local M = {}

if not pcall(require, "table.new") then
  table.new = function() return {} end
end

local byte, sub, tconcat, tablenew = string.byte, string.sub, table.concat, table.new

local escapes = {
  [116] = '\t',
  [110] = '\n',
  [102] = '\f',
  [114] = '\r',
  [98] = '\b',
  [34] = '"',
  [92] = '\\',
  [10] = '\n', -- needed for lua escape support
  [57] = '\t',
  [48] = '\r',
}

local peekTable = tablenew(256,0)

local function jsonError(msg, s, i)
  local curlen = 0
  local n = 1
  for w in s:gmatch("([^\n]*)") do
    curlen = curlen + #w
    if curlen >= i then
      error(string.format("%s near line %d, '%s'",msg, n, w:match'^%s*(.*%S)' or ''))
    end
    if w == '' then
      n = n + 1
      curlen = curlen + 1
    end
  end
end

local function readNumber(s, si)
  -- Read Number
  local i = si
  local c = byte(s, i)
  local coef = 1

  if c == 45 then -- -
    coef = -1
    i = i + 1
  elseif c == 43 then i = i + 1 end -- +

  local r = 0
  c = byte(s, i)
  while (c >= 48 and c <= 57) do -- \d
    i = i + 1
    r = r * 10 + (c - 48)
    c = byte(s, i)
  end
  if c == 46 then -- .
    i = i + 1
    c = byte(s, i)
    local f = 0
    local scale = 0.1
    while (c >= 48 and c <= 57) do -- \d
      i = i + 1
      f = f + (c - 48) * scale
      c = byte(s, i)
      scale = scale * 0.1
    end
    r = r + f
  elseif c == 73 then -- I
    local infend = i + 7
    if r == 0 and i <= si + 1 and byte(s, i - 1) ~= 48 and sub(s, i, infend) == "Infinity" then
      return coef * math.huge, infend
    else
      jsonError(string.format("Invalid number: '%s'", sub(s, si, infend)), s, si)
    end
  elseif c == 35 then -- #
    local infend = si + 6
    if sub(s, si, infend) == "1#INF00" then
      return math.huge, infend
    else
      jsonError(string.format("Invalid number: '%s'", sub(s, si, infend)), s, si)
    end
  end
  if c == 101 or c == 69 then -- e E
    i = i + 1
    c = byte(s, i)
    while (c >= 45 and c <= 57) or c == 43 do -- \d-+
      i = i + 1
      c = byte(s, i)
    end
    r = tonumber(sub(s, si, i - 1))
    if r == nil then
      jsonError(string.format("Invalid number: '%s'", sub(s, si, i-1)), s, si)
    end
  else
    r = coef * r
  end
  return r, i - 1
end

local function error_input(s, si)
  jsonError('Invalid input', s, si)
end

local function SkipWhiteSpace(s, si)
  local i = si + 1

::restart::
  local p = byte(s, i)
  while (p ~= nil and p <= 32) or p == 44 do -- matches space tab newline or comma
    i = i + 1
    p = byte(s, i)
  end

  if p == 47 then -- / -- read comment
    i = i + 1
    p = byte(s, i)
    if p == 47 then -- / -- single line comment "//"
      repeat
        i = i + 1
        p = byte(s, i)
      until p == 10 or p == 13 or p == nil
      i = i + 1
    elseif p == 42 then -- * -- block comment "/*  xxxxxxx */"
      while true do
        i = i + 1
        p = byte(s, i)
        if (p == 42 and byte(s, i+1) == 47) or p == nil then -- */
          break
        elseif p == 47 and byte(s, i+1) == 42 then -- /*
          jsonError("'/*' inside another '/*' comment is not permitted", s, i)
        end
      end
      i = i + 2
    else
      jsonError('Invalid comment', s, i)
    end
    goto restart
  end

  return p, i
end

local function readString(s, si)
  -- parse string
  -- fast path
  local i = si + 1
  local si1 = i -- "
  local ch = byte(s, i)
  while ch ~= 34 and ch ~= 92 and ch ~= nil do  -- " \
    i = i + 1
    ch = byte(s, i)
  end

  if ch == 34 then -- "
    return sub(s, si1, i - 1), i
  end

  -- slow path for strings with escape chars
  if ch ~= 92 then -- \
    jsonError("String not having an end-quote", s, si)
    return nil, si1
  end

  local result = tablenew(si1 - i, 0)
  local resultidx = 1
  i = si1
  ch = byte(s, i)
  while ch ~= 34 do -- "
    ch = s:match('^[^"\\]*', i)
    i = i + (ch and ch:len() or 0)
    result[resultidx] = ch
    resultidx = resultidx + 1
    ch = byte(s, i)
    if ch == 92 then -- \
      local ch1 = escapes[byte(s, i+1)]
      if ch1 then
        result[resultidx] = ch1
        resultidx = resultidx + 1
        i = i + 1
      else
        result[resultidx] = '\\'
        resultidx = resultidx + 1
      end
      i = i + 1 -- "
    end
  end

  return tconcat(result), i
end

local function readKey(s, si, c)
  local key
  local i = si
  if c == 34 then -- '"'
    key, i = readString(s, i)
  else
    if c == nil then
      jsonError(string.format("Expected dictionary key"), s, si)
    end
    local ch = byte(s, i)
    while (ch >= 97 and ch <= 122) or (ch >= 65 and ch <= 90) or (ch >= 48 and ch <= 57) or ch == 95 do -- [a z] [A Z] or [0 9] or _
      i = i + 1
      ch = byte(s, i)
    end

    i = i - 1
    key = sub(s, si, i)
  end
  if i < si then
    jsonError(string.format("Expected dictionary key"), s, i)
  end
  local delim
  delim, i = SkipWhiteSpace(s, i)
  if delim ~= 58 and delim ~= 61 then -- : =
    jsonError(string.format("Expected dictionary separator ':' or '=' instead of: '%s'", string.char(delim)), s, i)
  end
  return key, i
end

local function decode(s)
  if s == nil then return nil end
  local c, si = SkipWhiteSpace(s, 0)
  local result
  if c == 123 or c == 91 then
      result, si = peekTable[c](s, si)
  else
    result = {}
    local key
    while c do
      key, si = readKey(s, si, c)
      c, si = SkipWhiteSpace(s, si)
      result[key], si = peekTable[c](s, si)
      c, si = SkipWhiteSpace(s, si)
    end
  end
  return result
end

-- build dispatch table
do
  for i = 0, 255 do
    peekTable[i] = error_input
  end

  peekTable[73] = function(s, si) -- I
    if byte(s, si+1) == 110 and byte(s, si+2) == 102 and byte(s, si+3) == 105 and
       byte(s, si+4) == 110 and byte(s, si+5) == 105 and byte(s, si+6) == 116 and byte(s, si+7) == 121 then -- nfinity
      return math.huge, si + 7
    else
      jsonError('Error reading value: true', s, si)
    end
  end
  peekTable[123] = function(s, si) -- {
      -- parse object
      local key
      local result = tablenew(0, 3)
      local c, i = SkipWhiteSpace(s, si)
      while c ~= 125 do -- }
        key, i = readKey(s, i, c)
        c, i = SkipWhiteSpace(s, i)
        result[key], i = peekTable[c](s, i)
        c, i = SkipWhiteSpace(s, i)
      end
      return result, i
    end
  peekTable[116] = function(s, si) -- t
      if byte(s, si+1) == 114 and byte(s, si+2) == 117 and byte(s, si+3) == 101 then -- rue
        return true, si + 3
      else
        jsonError('Error reading value: true', s, si)
      end
    end
  peekTable[110] = function(s, si) -- n
      if byte(s, si+1) == 117 and byte(s, si+2) == 108 and byte(s, si+3) == 108 then -- ull
        return nil, si + 3
      else
        jsonError('Error reading value: null', s, si)
      end
    end
  peekTable[102] = function(s, si) -- f
      if byte(s, si+1) == 97 and byte(s, si+2) == 108 and byte(s, si+3) == 115 and byte(s, si+4) == 101 then -- alse
        return false, si + 4
      else
        jsonError('Error reading value: false', s, si)
      end
    end
  peekTable[91] = function(s, si) -- [
      -- Read Array
      local result = tablenew(4, 0)
      local tidx = 1
      local c, i = SkipWhiteSpace(s, si)
      while c ~= 93 do -- ]
        result[tidx], i = peekTable[c](s, i)
        tidx = tidx + 1
        c, i = SkipWhiteSpace(s, i)
      end
      return result, i
    end
  peekTable[48] = readNumber -- 0
  peekTable[49] = readNumber -- 1
  peekTable[50] = readNumber -- 2
  peekTable[51] = readNumber -- 3
  peekTable[52] = readNumber -- 4
  peekTable[53] = readNumber -- 5
  peekTable[54] = readNumber -- 6
  peekTable[55] = readNumber -- 7
  peekTable[56] = readNumber -- 8
  peekTable[57] = readNumber -- 9
  peekTable[43] = readNumber -- +
  peekTable[45] = readNumber -- -
  peekTable[34] = readString  -- "
end


--== Json ==--
local serTmp = {}
local seridx = 0
local function jsonEncode_rec(v)
  local vtype = type(v)

  seridx = seridx + 1
  if vtype == 'string' then
    serTmp[seridx] = string.format('%q', v)
  elseif vtype == 'number' then
    if v * 0 ~= 0 then -- inf,nan
      serTmp[seridx] = v > 0 and '-9e999' or '-9e999'
    else
      serTmp[seridx] = v
    end
  elseif vtype == 'table' then  --tables
    local kk1, vv1 = next(v)
    if kk1 == 1 and next(v, #v) == nil then
      local vcount = #v
      serTmp[seridx] = '['
      if vcount >= 1 then
        jsonEncode_rec(vv1)
        for i = 2, vcount do
          seridx = seridx + 1; serTmp[seridx] = ','
          jsonEncode_rec(v[i])
        end
      end
      seridx = seridx + 1; serTmp[seridx] = ']'
    else
      if kk1 ~= nil then
        local prefixFormat = '{%q:'
        for kk, vv in pairs(v) do
          serTmp[seridx] = string.format(prefixFormat, kk)
          jsonEncode_rec(vv)
          prefixFormat = ',%q:'
          seridx = seridx + 1
        end
        serTmp[seridx] = '}'
      else
        serTmp[seridx] = '{}'
      end
    end
  elseif vtype == 'boolean' then
    serTmp[seridx] = tostring(v)
  elseif vtype == 'cdata' and ffi.offsetof(v, 'w') ~= nil then  -- vec3
    serTmp[seridx] = string.format('{"x":%.9g,"y":%.9g,"z":%.9g}', v.x, v.y, v.z)
  else
    serTmp[seridx] = "null"
  end
end

function jsonEncode(v)
  seridx = 0
  jsonEncode_rec(v)
  local res = table.concat(serTmp)

  local count = #serTmp
  for i=0, count do serTmp[i]=nil end
  --table.clear(serTmp)
  return res
end


-- public interface
M.encode = jsonEncode
M.decode = decode
return M
