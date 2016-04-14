-- localizations
local select = select 
local format_string = string.format 
local concat = table.concat 
local len = string.len 
local string_find = string.find 
local string_sub = string.sub 
local tonumber = tonumber 
local tostring = tostring 
local math_log = math.log
local math_ceil = math.ceil 

local spon = {}

--
-- caches
-- 
local max_stack = 128
local max_format_strings = max_stack + 32

-- string format string
local concat_format_strings = {'%s'}
for i = 2, max_format_strings do concat_format_strings[i] = concat_format_strings[i - 1] .. '%s' end

-- hex number cache
local hex_cache = {} for i = 0, 15 do hex_cache[format_string('%x', i)] = i end 


local cache_hashy = setmetatable({}, {__mode = 'kv'})
local cache_array = setmetatable({}, {__mode = 'kv'})

local function empty_cache(hashy, a)
	--for i = #hashy, 1, -1 do
	--	hashy[i] = nil
	--end
	for k,v in pairs(hashy) do
		hashy[k] = nil
	end
	return a
end




--
-- ENCODER FUNCTIONS
-- 

local encoder = {}

local log16 = math_log(16)

local function encoder_write_pointer(index)
	return format_string('#%x%x', math_ceil(math_log(index + 1) / log16), index)
end

encoder['number'] = function(value)
	if value % 1 == 0 then
		if value == 0 then return 'I0' end
		if value < 0 then
			return format_string('i%x%x', math_ceil(math_log(-value+1) / (log16)), -value)
		else
			return format_string('I%x%x', math_ceil(math_log(value+1) / (log16)), value)
		end
	else
		if value < 0 then
			return 'f' .. tostring(-value) .. ';'
		else
			return 'F' .. tostring(value) .. ';'
		end
	end
end

encoder['string'] = function(value, cache)
	if cache[value] then 
		return encoder_write_pointer(cache[value])
	end
	cache[#cache + 1] = value
	cache[value] = #cache

	local len = len(value)
	if len >= 16 * 16 then
		return format_string('T%06X%s', len, value)
	else
		return format_string('S%02X%s', len, value)
	end
end

encoder['boolean'] = function(value, cache)
	return value and 't' or 'f'
end


local function fast_concat_stack(...)
	local size = select('#', ...)
	local last = select(size, ...)
	if size == 1 then
		return ...
	elseif type(last) == 'function' then -- must never be greater than concat_format_strings count!!!
		return format_string(concat_format_strings[size-1], ...), fast_concat_stack(last())
	elseif size > max_format_strings then
		return concat {...}
	else
		return format_string(concat_format_strings[size], ...)
	end
end

local function encode_pairs(size, iterator, table, key, cache)
	if size >= max_stack then
		return function() return encode_sequential(0, iterator, table, k, cache) end
	end
	local k, v = iterator(table, key)
	if k == nil then return '}' end
	return encoder[type(k)](k, cache), encoder[type(v)](v, cache), encode_pairs(size + 2, iterator, table, k, cache)
end


local function encode_sequential(size, table, key, cache)
	if size >= max_stack then 
		return function() return encode_sequential(0, table, key, cache) end
	end

	key = key + 1
	local value = table[key]
	if value == nil then 
		return '~', encode_pairs(size + 1, pairs(table), table, key ~= 1 and key - 1 or nil, cache)
	end

	return encoder[type(value)](value, cache), encode_sequential(size + 1, table, key, cache)
end

encoder['table'] = function(value, cache)
	if cache[value] then 
		return encoder_write_pointer(value)
	end
	cache[#cache + 1] = value
	cache[value] = #cache
	return fast_concat_stack(fast_concat_stack('{', encode_sequential(1, value, 0, cache)))
end

local decoder = {}
-- a short string with a 2-digit length component
decoder['S'] = function(str, index, cache)
	local strlen = tonumber(string_sub(str, index + 1, index + 2), 16)
	local str = string_sub(str, index + 3, index + (3 - 1) + strlen)
	cache[#cache + 1] = str
	return str, index + (3) + strlen
end
-- a long string with a 6-digit length component
decoder['T'] = function(str, index, cache)
	local strlen = tonumber(string_sub(str, index + 1, index + 6), 16)
	return string_sub(str, index + 7, index + (7 - 1) + strlen), index + (7) + strlen -- figure out if alignment is off i think its right
end
-- decoder for an integer value
decoder['I'] = function(str, index, cache)
	local digitCount = hex_cache[string_sub(str, index+1, index+1)]
	if digitCount == 0 then return 0, index + 1 end
	return tonumber(string_sub(str, index + 2, index + 1 + digitCount), 16), index + (2 + digitCount)
end
-- decoder for a boolean
decoder['t'] = function(str, index) return true, index + 1 end
decoder['f'] = function(str, index) return false, index + 1 end
decoder['#'] = function(str, index, cache)
	local digitCount = hex_cache[string_sub(str, index+1, index+1)]
	return cache[tonumber(string_sub(str, index + 2, index + 1 + digitCount), 16)], index + (2 + digitCount)
end

decoder['{'] = function(str, index, cache)
	local table = {}
	cache[#cache + 1] = cache

	index = index + 1

	-- decode the array portion of the table
	local i = 1
	while true do
		local c = string_sub(str, index, index)
		if c == '~' or c == '}' or c == nil then break end
		table[i], index = decoder[c](str, index, cache)
		i = i + 1
	end

	if string_sub(str, index, index) == '~' then
		-- decode the key-value poriton of the table
		index = index + 1
		local k
		while true do
			local c = string_sub(str, index, index)
			if c == '}' or c == nil then break end
			k, index = decoder[c](str, index, cache)
			c = string_sub(str, index, index)
			table[k], index = decoder[c](str, index, cache)
		end

	end

	return table, index
end

spon.encode = function(table)
	return empty_cache(cache_hashy, encoder.table(table, cache_hashy))
end

spon.decode = function(str)
	return empty_cache(cache_array, decoder['{'](str, 1, cache_array))
end

spon.printtable = function(tbl, indent)
	if indent == nil then 
		return spon.printtable(tbl, 0)
	end
	local lpad = string.format('%'..indent..'s', '')

	for k,v in pairs(tbl) do
		print(lpad .. '- ' .. string_sub(type(k), 1, 1) .. ':' .. tostring(k) .. ' = ' .. string_sub(type(v), 1, 1) .. ':' .. tostring(v))
		if type(v) == 'table' then
			spon.printtable(v, indent + 4)
		end
	end
end

local encoded = spon.encode {
	1,2,3, 'test test test', 'test test test', 'foovarenaefnpepnf', 123, 'veanfpnap', 149343, {
		'test', 'test2', 'test3',
		y = true,
		b = false
	}
}	
print (encoded)
spon.printtable(spon.decode(encoded))
return spon