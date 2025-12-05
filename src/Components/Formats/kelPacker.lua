--!optimize 2
--[[
	KELP/kelPack
	v2.5 [6/3/25 11:55 PM UTC+9]
	About:
		This is a MessagePack implementation for LuaU, Roblox's restricted Lua environment.
		It is used to compress data being sent to and from the server, to reduce the packet size.
		Still slower than C++ even if this is made to be as optimized as possible.
	Written by Kel (@GudEveningBois)
]]
local kelPack = {}

-- Buffer aliases
local buf_create = buffer.create
local buf_tostring = buffer.tostring
local buf_copy = buffer.copy
local buf_w8 = buffer.writeu8
local buf_w16 = buffer.writeu16
local buf_w32 = buffer.writeu32
local buf_wf64 = buffer.writef64
local buf_wstr = buffer.writestring
local buf_r8 = buffer.readu8
local buf_r16 = buffer.readu16
local buf_r32 = buffer.readu32
local buf_rf64 = buffer.readf64
local buf_rstr = buffer.readstring
local buf_wi8 = buffer.writei8
local buf_wi16 = buffer.writei16
local buf_wi32 = buffer.writei32
local buf_ri8 = buffer.readi8
local buf_ri16 = buffer.readi16
local buf_ri32 = buffer.readi32
local buf_fromstr = buffer.fromstring 
local m_max = math.max
local t_type = type

-- Constants
local INITIAL_CAP = 4096
local EXTRA_CAP = 64
local FIXPOS_MAX = 0x7F         
local FIXNEG_BASE = 0xE0        
local NIL_MARK = 0xC0           
local FALSE_MARK = 0xC2         
local TRUE_MARK = 0xC3          
local UINT8_MARK = 0xCC        
local UINT16_MARK = 0xCD        
local UINT32_MARK = 0xCE        
local FLOAT64_MARK = 0xCB       
local STR_FIX_BASE = 0xA0       
local STR8_MARK = 0xD9          
local STR16_MARK = 0xDA         
local ARRAY_FIX_BASE = 0x90     
local ARRAY16_MARK = 0xDC       
local MAP_FIX_BASE = 0x80       
local MAP16_MARK = 0xDE         
local INT8_MARK = 0xD0          
local INT16_MARK = 0xD1         
local INT32_MARK = 0xD2         

local STR_FIX_MAX = STR_FIX_BASE + 31     
local ARRAY_FIX_MAX = ARRAY_FIX_BASE + 15 
local MAP_FIX_MAX = MAP_FIX_BASE + 15   

-- Inlined unpacking functions for hot path optimization
local function readAnyRecursive(b, p)
	local tag = buf_r8(b, p) 
	p = p + 1 
	if tag <= FIXPOS_MAX then 
		return tag, p 
	end
	if tag == NIL_MARK then 
		return nil, p 
	end
	if tag == FALSE_MARK then 
		return false, p 
	elseif tag == TRUE_MARK then 
		return true, p 
	end
	if tag >= FIXNEG_BASE then
		return tag - 0x100, p 
	end
	if tag >= STR_FIX_BASE and tag <= STR_FIX_MAX then 
		local len = tag - STR_FIX_BASE 
		return buf_rstr(b, p, len), p + len 
	end
	if tag >= ARRAY_FIX_BASE and tag <= ARRAY_FIX_MAX then 
		local count = tag - ARRAY_FIX_BASE 
		local res = {} 
		local current_p = p 
		for i = 1, count do 
			local v, next_p = readAnyRecursive(b, current_p) 
			res[i] = v 
			current_p = next_p 
		end
		return res, current_p 
	end
	if tag >= MAP_FIX_BASE and tag <= MAP_FIX_MAX then 
		local count = tag - MAP_FIX_BASE 
		local res = {} 
		local current_p = p 
		for i = 1, count do 
			local k, p1 = readAnyRecursive(b, current_p) 
			local v, p2 = readAnyRecursive(b, p1) 
			if k ~= nil then res[k] = v end
			current_p = p2 
		end
		return res, current_p 
	end
	if tag == UINT8_MARK then 
		return buf_r8(b, p), p + 1 
	elseif tag == UINT16_MARK then 
		return buf_r16(b, p), p + 2 
	elseif tag == UINT32_MARK then 
		return buf_r32(b, p), p + 4 
	elseif tag == INT8_MARK then 
		return buf_ri8(b, p), p + 1 
	elseif tag == INT16_MARK then 
		return buf_ri16(b, p), p + 2 
	elseif tag == INT32_MARK then 
		return buf_ri32(b, p), p + 4 
	elseif tag == FLOAT64_MARK then 
		return buf_rf64(b, p), p + 8 
	end
	if tag == STR8_MARK then 
		local len = buf_r8(b, p) 
		return buf_rstr(b, p + 1, len), p + 1 + len 
	elseif tag == STR16_MARK then 
		local len = buf_r16(b, p) 
		return buf_rstr(b, p + 2, len), p + 2 + len
	end
	if tag == ARRAY16_MARK then 
		local count = buf_r16(b, p) 
		local res = {} 
		local current_p = p + 2 
		for i = 1, count do 
			local v, next_p = readAnyRecursive(b, current_p) 
			res[i] = v 
			current_p = next_p 
		end
		return res, current_p 
	end
	if tag == MAP16_MARK then 
		local count = buf_r16(b, p) 
		local res = {} 
		local current_p = p + 2 
		for i = 1, count do 
			local k, p1 = readAnyRecursive(b, current_p) 
			local v, p2 = readAnyRecursive(b, p1) 
			if k ~= nil then res[k] = v end 
			current_p = p2 
		end
		return res, current_p 
	end
	error("Invalid tag: " .. tag) 
end

function kelPack.pack(value)
	local buf = buf_create(INITIAL_CAP) 
	local cap, off = INITIAL_CAP, 0 
	local writeAny
	writeAny = function(x)
		local ty = t_type(x) 
		if ty == "nil" then
			if off + 1 > cap then 
				local new_cap = m_max(cap*2, off + 1 + EXTRA_CAP) 
				local new_buf = buf_create(new_cap) 
				buf_copy(new_buf, 0, buf, 0, off) 
				buf = new_buf 
				cap = new_cap 
			end
			buf_w8(buf,off,NIL_MARK) 
			off = off + 1 
		elseif ty == "boolean" then 
			if off + 1 > cap then 
				local new_cap = m_max(cap*2, off + 1 + EXTRA_CAP) 
				local new_buf = buf_create(new_cap) 
				buf_copy(new_buf, 0, buf, 0, off) 
				buf = new_buf 
				cap = new_cap 
			end
			buf_w8(buf,off, x and TRUE_MARK or FALSE_MARK) 
			off = off + 1 
		elseif ty == "number" then 
			local n = x 
			if n % 1 == 0 then
				if n >= 0 then
					if n <= FIXPOS_MAX then 
						if off + 1 > cap then
							local new_cap = m_max(cap*2, off + 1 + EXTRA_CAP) 
							local new_buf = buf_create(new_cap) 
							buf_copy(new_buf, 0, buf, 0, off) 
							buf = new_buf 
							cap = new_cap 
						end
						buf_w8(buf,off,n) 
						off = off + 1 
					elseif n <= 0xFF then 
						if off + 2 > cap then 
							local new_cap = m_max(cap*2, off + 2 + EXTRA_CAP) 
							local new_buf = buf_create(new_cap) 
							buf_copy(new_buf, 0, buf, 0, off) 
							buf = new_buf 
							cap = new_cap 
						end
						buf_w8(buf,off,UINT8_MARK) 
						buf_w8(buf,off+1,n) 
						off = off + 2 
					elseif n <= 0xFFFF then 
						if off + 3 > cap then 
							local new_cap = m_max(cap*2, off + 3 + EXTRA_CAP) 
							local new_buf = buf_create(new_cap) 
							buf_copy(new_buf, 0, buf, 0, off) 
							buf = new_buf 
							cap = new_cap 
						end
						buf_w8(buf,off,UINT16_MARK) 
						buf_w16(buf,off+1,n) 
						off = off + 3 
					elseif n <= 0xFFFFFFFF then 
						if off + 5 > cap then
							local new_cap = m_max(cap*2, off + 5 + EXTRA_CAP) 
							local new_buf = buf_create(new_cap) 
							buf_copy(new_buf, 0, buf, 0, off) 
							buf = new_buf 
							cap = new_cap 
						end
						buf_w8(buf,off,UINT32_MARK) 
						buf_w32(buf,off+1,n) 
						off = off + 5 
					else  
						if off + 9 > cap then 
							local new_cap = m_max(cap*2, off + 9 + EXTRA_CAP) 
							local new_buf = buf_create(new_cap) 
							buf_copy(new_buf, 0, buf, 0, off) 
							buf = new_buf 
							cap = new_cap 
						end
						buf_w8(buf,off,FLOAT64_MARK) 
						buf_wf64(buf,off+1,n) 
						off = off + 9 
					end
				else
					if n >= -0x20 then 
						if off + 1 > cap then 
							local new_cap = m_max(cap*2, off + 1 + EXTRA_CAP) 
							local new_buf = buf_create(new_cap) 
							buf_copy(new_buf, 0, buf, 0, off) 
							buf = new_buf 
							cap = new_cap 
						end
						buf_w8(buf,off, FIXNEG_BASE + (n+0x20)) 
						off = off + 1 
					elseif n >= -0x80 then
						if off + 2 > cap then 
							local new_cap = m_max(cap*2, off + 2 + EXTRA_CAP) 
							local new_buf = buf_create(new_cap) 
							buf_copy(new_buf, 0, buf, 0, off) 
							buf = new_buf 
							cap = new_cap 
						end
						buf_w8(buf,off,INT8_MARK) 
						buf_wi8(buf,off+1,n) 
						off = off + 2 
					elseif n >= -0x8000 then
						if off + 3 > cap then 
							local new_cap = m_max(cap*2, off + 3 + EXTRA_CAP) 
							local new_buf = buf_create(new_cap) 
							buf_copy(new_buf, 0, buf, 0, off) 
							buf = new_buf 
							cap = new_cap 
						end
						buf_w8(buf,off,INT16_MARK) 
						buf_wi16(buf,off+1,n) 
						off = off + 3 
					elseif n >= -0x80000000 then
						if off + 5 > cap then 
							local new_cap = m_max(cap*2, off + 5 + EXTRA_CAP) 
							local new_buf = buf_create(new_cap) 
							buf_copy(new_buf, 0, buf, 0, off) 
							buf = new_buf 
							cap = new_cap
						end
						buf_w8(buf,off,INT32_MARK) 
						buf_wi32(buf,off+1,n) 
						off = off + 5 
					else  
						if off + 9 > cap then 
							local new_cap = m_max(cap*2, off + 9 + EXTRA_CAP) 
							local new_buf = buf_create(new_cap) 
							buf_copy(new_buf, 0, buf, 0, off) 
							buf = new_buf 
							cap = new_cap 
						end
						buf_w8(buf,off,FLOAT64_MARK) 
						buf_wf64(buf,off+1,n) 
						off = off + 9 
					end
				end
			else
				if off + 9 > cap then 
					local new_cap = m_max(cap*2, off + 9 + EXTRA_CAP) 
					local new_buf = buf_create(new_cap) 
					buf_copy(new_buf, 0, buf, 0, off) 
					buf = new_buf 
					cap = new_cap 
				end
				buf_w8(buf,off,FLOAT64_MARK) 
				buf_wf64(buf,off+1,n) 
				off = off + 9 
			end
		elseif ty == "string" then 
			local s = x  
			local l = #s 
			if l < 32 then 
				if off + 1 + l > cap then 
					local new_cap = m_max(cap*2, off + 1 + l + EXTRA_CAP)
					local new_buf = buf_create(new_cap) 
					buf_copy(new_buf, 0, buf, 0, off) 
					buf = new_buf 
					cap = new_cap 
				end
				buf_w8(buf,off,STR_FIX_BASE+l) 
				off = off + 1 
			elseif l < 0x100 then 
				if off + 2 + l > cap then 
					local new_cap = m_max(cap*2, off + 2 + l + EXTRA_CAP) 
					local new_buf = buf_create(new_cap) 
					buf_copy(new_buf, 0, buf, 0, off) 
					buf = new_buf 
					cap = new_cap 
				end
				buf_w8(buf,off,STR8_MARK) 
				buf_w8(buf,off+1,l) 
				off = off + 2 
			else 
				if off + 3 + l > cap then 
					local new_cap = m_max(cap*2, off + 3 + l + EXTRA_CAP) 
					local new_buf = buf_create(new_cap) 
					buf_copy(new_buf, 0, buf, 0, off) 
					buf = new_buf 
					cap = new_cap 
				end
				buf_w8(buf,off,STR16_MARK) 
				buf_w16(buf,off+1,l) 
				off = off + 3 
			end
			buf_wstr(buf,off,s,l) 
			off = off + l 
		elseif ty == "table" then 
			local cnt, seq, mx = 0, true, 0
			for k in pairs(x) do 
				cnt = cnt + 1 
				if seq and t_type(k)=="number" and k>0 and k%1==0 then 
					if k > mx then mx = k end 
				else 
					seq = false 
				end
			end
			if seq and mx == cnt then
				if cnt < 16 then 
					if off + 1 > cap then 
						local new_cap = m_max(cap*2, off + 1 + EXTRA_CAP) 
						local new_buf = buf_create(new_cap) 
						buf_copy(new_buf, 0, buf, 0, off) 
						buf = new_buf 
						cap = new_cap 
					end
					buf_w8(buf,off,ARRAY_FIX_BASE+cnt) 
					off = off + 1 
				else 
					if off + 3 > cap then 
						local new_cap = m_max(cap*2, off + 3 + EXTRA_CAP) 
						local new_buf = buf_create(new_cap) 
						buf_copy(new_buf, 0, buf, 0, off) 
						buf = new_buf 
						cap = new_cap 
					end
					buf_w8(buf,off,ARRAY16_MARK) 
					buf_w16(buf,off+1,cnt) 
					off = off + 3 
				end
				for i=1,cnt do 
					writeAny(x[i])
				end
			else
				if cnt < 16 then 
					if off + 1 > cap then 
						local new_cap = m_max(cap*2, off + 1 + EXTRA_CAP) 
						local new_buf = buf_create(new_cap) 
						buf_copy(new_buf, 0, buf, 0, off) 
						buf = new_buf 
						cap = new_cap 
					end
					buf_w8(buf,off,MAP_FIX_BASE+cnt) 
					off = off + 1 
				else 
					if off + 3 > cap then 
						local new_cap = m_max(cap*2, off + 3 + EXTRA_CAP) 
						local new_buf = buf_create(new_cap) 
						buf_copy(new_buf, 0, buf, 0, off) 
						buf = new_buf 
						cap = new_cap 
					end
					buf_w8(buf,off,MAP16_MARK) 
					buf_w16(buf,off+1,cnt) 
					off = off + 3 
				end
				for k,v in pairs(x) do  
					writeAny(k)
					writeAny(v)
				end
			end
		else 
			error("Unsupported type: "..ty) 
		end
	end
	writeAny(value) 
	return buf_tostring(buf):sub(1,off) 
end

function kelPack.unpack(str)
	if not str then return nil end 
	return readAnyRecursive(buf_fromstr(str), 0)  
end

-- Specialized Packers/Unpackers for Known Table Structures

function kelPack.packKnownArray(theArray)
	local buf = buf_create(INITIAL_CAP) 
	local cap, off = INITIAL_CAP, 0 
	local cnt = #theArray

	-- Write array header directly without analysis
	if cnt < 16 then
		if off + 1 > cap then
			local new_cap = m_max(cap*2, off + 1 + EXTRA_CAP)
			local new_buf = buf_create(new_cap)
			buf_copy(new_buf, 0, buf, 0, off)
			buf = new_buf
			cap = new_cap
		end
		buf_w8(buf, off, ARRAY_FIX_BASE + cnt)
		off = off + 1
	else
		if off + 3 > cap then
			local new_cap = m_max(cap*2, off + 3 + EXTRA_CAP)
			local new_buf = buf_create(new_cap)
			buf_copy(new_buf, 0, buf, 0, off)
			buf = new_buf
			cap = new_cap
		end
		buf_w8(buf, off, ARRAY16_MARK)
		buf_w16(buf, off + 1, cnt)
		off = off + 3
	end

	-- writeAny function, specific to this packer's context
	local writeAny
	writeAny = function(x)
		local ty = t_type(x)
		if ty == "nil" then
			if off + 1 > cap then
				local new_cap = m_max(cap*2, off + 1 + EXTRA_CAP)
				local new_buf = buf_create(new_cap)
				buf_copy(new_buf, 0, buf, 0, off)
				buf = new_buf
				cap = new_cap
			end
			buf_w8(buf,off,NIL_MARK)
			off = off + 1
		elseif ty == "boolean" then
			if off + 1 > cap then
				local new_cap = m_max(cap*2, off + 1 + EXTRA_CAP)
				local new_buf = buf_create(new_cap)
				buf_copy(new_buf, 0, buf, 0, off)
				buf = new_buf
				cap = new_cap
			end
			buf_w8(buf,off, x and TRUE_MARK or FALSE_MARK)
			off = off + 1
		elseif ty == "number" then
			local n = x
			if n % 1 == 0 then
				if n >= 0 then
					if n <= FIXPOS_MAX then
						if off + 1 > cap then
							local new_cap = m_max(cap*2, off + 1 + EXTRA_CAP)
							local new_buf = buf_create(new_cap)
							buf_copy(new_buf, 0, buf, 0, off)
							buf = new_buf
							cap = new_cap
						end
						buf_w8(buf,off,n)
						off = off + 1
					elseif n <= 0xFF then
						if off + 2 > cap then
							local new_cap = m_max(cap*2, off + 2 + EXTRA_CAP)
							local new_buf = buf_create(new_cap)
							buf_copy(new_buf, 0, buf, 0, off)
							buf = new_buf
							cap = new_cap
						end
						buf_w8(buf,off,UINT8_MARK)
						buf_w8(buf,off+1,n)
						off = off + 2
					elseif n <= 0xFFFF then
						if off + 3 > cap then
							local new_cap = m_max(cap*2, off + 3 + EXTRA_CAP)
							local new_buf = buf_create(new_cap)
							buf_copy(new_buf, 0, buf, 0, off)
							buf = new_buf
							cap = new_cap
						end
						buf_w8(buf,off,UINT16_MARK)
						buf_w16(buf,off+1,n)
						off = off + 3
					elseif n <= 0xFFFFFFFF then
						if off + 5 > cap then
							local new_cap = m_max(cap*2, off + 5 + EXTRA_CAP)
							local new_buf = buf_create(new_cap)
							buf_copy(new_buf, 0, buf, 0, off)
							buf = new_buf
							cap = new_cap
						end
						buf_w8(buf,off,UINT32_MARK)
						buf_w32(buf,off+1,n)
						off = off + 5
					else 
						if off + 9 > cap then
							local new_cap = m_max(cap*2, off + 9 + EXTRA_CAP)
							local new_buf = buf_create(new_cap)
							buf_copy(new_buf, 0, buf, 0, off)
							buf = new_buf
							cap = new_cap
						end
						buf_w8(buf,off,FLOAT64_MARK)
						buf_wf64(buf,off+1,n)
						off = off + 9
					end
				else
					if n >= -0x20 then
						if off + 1 > cap then
							local new_cap = m_max(cap*2, off + 1 + EXTRA_CAP)
							local new_buf = buf_create(new_cap)
							buf_copy(new_buf, 0, buf, 0, off)
							buf = new_buf
							cap = new_cap
						end
						buf_w8(buf,off, FIXNEG_BASE + (n+0x20))
						off = off + 1
					elseif n >= -0x80 then
						if off + 2 > cap then
							local new_cap = m_max(cap*2, off + 2 + EXTRA_CAP)
							local new_buf = buf_create(new_cap)
							buf_copy(new_buf, 0, buf, 0, off)
							buf = new_buf
							cap = new_cap
						end
						buf_w8(buf,off,INT8_MARK)
						buf_wi8(buf,off+1,n)
						off = off + 2
					elseif n >= -0x8000 then
						if off + 3 > cap then
							local new_cap = m_max(cap*2, off + 3 + EXTRA_CAP)
							local new_buf = buf_create(new_cap)
							buf_copy(new_buf, 0, buf, 0, off)
							buf = new_buf
							cap = new_cap
						end
						buf_w8(buf,off,INT16_MARK)
						buf_wi16(buf,off+1,n)
						off = off + 3
					elseif n >= -0x80000000 then
						if off + 5 > cap then
							local new_cap = m_max(cap*2, off + 5 + EXTRA_CAP)
							local new_buf = buf_create(new_cap)
							buf_copy(new_buf, 0, buf, 0, off)
							buf = new_buf
							cap = new_cap
						end
						buf_w8(buf,off,INT32_MARK)
						buf_wi32(buf,off+1,n)
						off = off + 5
					else 
						if off + 9 > cap then
							local new_cap = m_max(cap*2, off + 9 + EXTRA_CAP)
							local new_buf = buf_create(new_cap)
							buf_copy(new_buf, 0, buf, 0, off)
							buf = new_buf
							cap = new_cap
						end
						buf_w8(buf,off,FLOAT64_MARK)
						buf_wf64(buf,off+1,n)
						off = off + 9
					end
				end
			else
				if off + 9 > cap then
					local new_cap = m_max(cap*2, off + 9 + EXTRA_CAP)
					local new_buf = buf_create(new_cap)
					buf_copy(new_buf, 0, buf, 0, off)
					buf = new_buf
					cap = new_cap
				end
				buf_w8(buf,off,FLOAT64_MARK)
				buf_wf64(buf,off+1,n)
				off = off + 9
			end
		elseif ty == "string" then
			local s = x 
			local l = #s
			if l < 32 then
				if off + 1 + l > cap then
					local new_cap = m_max(cap*2, off + 1 + l + EXTRA_CAP)
					local new_buf = buf_create(new_cap)
					buf_copy(new_buf, 0, buf, 0, off)
					buf = new_buf
					cap = new_cap
				end
				buf_w8(buf,off,STR_FIX_BASE+l)
				off = off + 1
			elseif l < 0x100 then
				if off + 2 + l > cap then
					local new_cap = m_max(cap*2, off + 2 + l + EXTRA_CAP)
					local new_buf = buf_create(new_cap)
					buf_copy(new_buf, 0, buf, 0, off)
					buf = new_buf
					cap = new_cap
				end
				buf_w8(buf,off,STR8_MARK)
				buf_w8(buf,off+1,l)
				off = off + 2
			else
				if off + 3 + l > cap then
					local new_cap = m_max(cap*2, off + 3 + l + EXTRA_CAP)
					local new_buf = buf_create(new_cap)
					buf_copy(new_buf, 0, buf, 0, off)
					buf = new_buf
					cap = new_cap
				end
				buf_w8(buf,off,STR16_MARK)
				buf_w16(buf,off+1,l)
				off = off + 3
			end
			buf_wstr(buf,off,s,l)
			off = off + l
		elseif ty == "table" then
			local cnt_internal, seq_internal, mx_internal = 0, true, 0
			for k_internal in pairs(x) do
				cnt_internal = cnt_internal + 1
				if seq_internal and t_type(k_internal)=="number" and k_internal>0 and k_internal%1==0 then
					if k_internal > mx_internal then mx_internal = k_internal end
				else
					seq_internal = false
				end
			end
			if seq_internal and mx_internal == cnt_internal then
				if cnt_internal < 16 then
					if off + 1 > cap then
						local new_cap = m_max(cap*2, off + 1 + EXTRA_CAP)
						local new_buf = buf_create(new_cap)
						buf_copy(new_buf, 0, buf, 0, off)
						buf = new_buf
						cap = new_cap
					end
					buf_w8(buf,off,ARRAY_FIX_BASE+cnt_internal)
					off = off + 1
				else
					if off + 3 > cap then
						local new_cap = m_max(cap*2, off + 3 + EXTRA_CAP)
						local new_buf = buf_create(new_cap)
						buf_copy(new_buf, 0, buf, 0, off)
						buf = new_buf
						cap = new_cap
					end
					buf_w8(buf,off,ARRAY16_MARK)
					buf_w16(buf,off+1,cnt_internal)
					off = off + 3
				end
				for i_internal=1,cnt_internal do 
					writeAny(x[i_internal])
				end
			else
				if cnt_internal < 16 then
					if off + 1 > cap then
						local new_cap = m_max(cap*2, off + 1 + EXTRA_CAP)
						local new_buf = buf_create(new_cap)
						buf_copy(new_buf, 0, buf, 0, off)
						buf = new_buf
						cap = new_cap
					end
					buf_w8(buf,off,MAP_FIX_BASE+cnt_internal)
					off = off + 1
				else
					if off + 3 > cap then
						local new_cap = m_max(cap*2, off + 3 + EXTRA_CAP)
						local new_buf = buf_create(new_cap)
						buf_copy(new_buf, 0, buf, 0, off)
						buf = new_buf
						cap = new_cap
					end
					buf_w8(buf,off,MAP16_MARK)
					buf_w16(buf,off+1,cnt_internal)
					off = off + 3
				end
				for k_internal,v_internal in pairs(x) do 
					writeAny(k_internal)
					writeAny(v_internal)
				end
			end
		else
			error("Unsupported type: "..ty)
		end
	end

	-- Pack array elements
	for i = 1, cnt do
		writeAny(theArray[i])
	end

	return buf_tostring(buf):sub(1, off)
end

function kelPack.unpackKnownArray(packedString)
	if not packedString then return nil end

	local b = buf_fromstr(packedString)
	local tag = buf_r8(b, 0)
	local p = 1

	-- Verify it's an array tag
	local count
	if tag >= ARRAY_FIX_BASE and tag <= ARRAY_FIX_MAX then
		count = tag - ARRAY_FIX_BASE
	elseif tag == ARRAY16_MARK then
		count = buf_r16(b, p)
		p = p + 2
	else
		error("Expected array tag, got: " .. tag)
	end

	-- Read array elements
	local res = {}
	local current_p = p
	for i = 1, count do
		local v, next_p = readAnyRecursive(b, current_p)
		res[i] = v
		current_p = next_p
	end

	return res
end

function kelPack.packKnownMap(theMap)
	local buf = buf_create(INITIAL_CAP)
	local cap, off = INITIAL_CAP, 0

	-- Count map entries
	local cnt = 0
	for _ in pairs(theMap) do
		cnt = cnt + 1
	end

	-- Write map header directly without analysis
	if cnt < 16 then
		if off + 1 > cap then
			local new_cap = m_max(cap*2, off + 1 + EXTRA_CAP)
			local new_buf = buf_create(new_cap)
			buf_copy(new_buf, 0, buf, 0, off)
			buf = new_buf
			cap = new_cap
		end
		buf_w8(buf, off, MAP_FIX_BASE + cnt)
		off = off + 1
	else
		if off + 3 > cap then
			local new_cap = m_max(cap*2, off + 3 + EXTRA_CAP)
			local new_buf = buf_create(new_cap)
			buf_copy(new_buf, 0, buf, 0, off)
			buf = new_buf
			cap = new_cap
		end
		buf_w8(buf, off, MAP16_MARK)
		buf_w16(buf, off + 1, cnt)
		off = off + 3
	end

	-- writeAny function, specific to this packer's context
	local writeAny
	writeAny = function(x)
		local ty = t_type(x)
		if ty == "nil" then
			if off + 1 > cap then
				local new_cap = m_max(cap*2, off + 1 + EXTRA_CAP)
				local new_buf = buf_create(new_cap)
				buf_copy(new_buf, 0, buf, 0, off)
				buf = new_buf
				cap = new_cap
			end
			buf_w8(buf,off,NIL_MARK)
			off = off + 1
		elseif ty == "boolean" then
			if off + 1 > cap then
				local new_cap = m_max(cap*2, off + 1 + EXTRA_CAP)
				local new_buf = buf_create(new_cap)
				buf_copy(new_buf, 0, buf, 0, off)
				buf = new_buf
				cap = new_cap
			end
			buf_w8(buf,off, x and TRUE_MARK or FALSE_MARK)
			off = off + 1
		elseif ty == "number" then
			local n = x
			if n % 1 == 0 then
				if n >= 0 then
					if n <= FIXPOS_MAX then
						if off + 1 > cap then
							local new_cap = m_max(cap*2, off + 1 + EXTRA_CAP)
							local new_buf = buf_create(new_cap)
							buf_copy(new_buf, 0, buf, 0, off)
							buf = new_buf
							cap = new_cap
						end
						buf_w8(buf,off,n)
						off = off + 1
					elseif n <= 0xFF then
						if off + 2 > cap then
							local new_cap = m_max(cap*2, off + 2 + EXTRA_CAP)
							local new_buf = buf_create(new_cap)
							buf_copy(new_buf, 0, buf, 0, off)
							buf = new_buf
							cap = new_cap
						end
						buf_w8(buf,off,UINT8_MARK)
						buf_w8(buf,off+1,n)
						off = off + 2
					elseif n <= 0xFFFF then
						if off + 3 > cap then
							local new_cap = m_max(cap*2, off + 3 + EXTRA_CAP)
							local new_buf = buf_create(new_cap)
							buf_copy(new_buf, 0, buf, 0, off)
							buf = new_buf
							cap = new_cap
						end
						buf_w8(buf,off,UINT16_MARK)
						buf_w16(buf,off+1,n)
						off = off + 3
					elseif n <= 0xFFFFFFFF then
						if off + 5 > cap then
							local new_cap = m_max(cap*2, off + 5 + EXTRA_CAP)
							local new_buf = buf_create(new_cap)
							buf_copy(new_buf, 0, buf, 0, off)
							buf = new_buf
							cap = new_cap
						end
						buf_w8(buf,off,UINT32_MARK)
						buf_w32(buf,off+1,n)
						off = off + 5
					else 
						if off + 9 > cap then
							local new_cap = m_max(cap*2, off + 9 + EXTRA_CAP)
							local new_buf = buf_create(new_cap)
							buf_copy(new_buf, 0, buf, 0, off)
							buf = new_buf
							cap = new_cap
						end
						buf_w8(buf,off,FLOAT64_MARK)
						buf_wf64(buf,off+1,n)
						off = off + 9
					end
				else
					if n >= -0x20 then
						if off + 1 > cap then
							local new_cap = m_max(cap*2, off + 1 + EXTRA_CAP)
							local new_buf = buf_create(new_cap)
							buf_copy(new_buf, 0, buf, 0, off)
							buf = new_buf
							cap = new_cap
						end
						buf_w8(buf,off, FIXNEG_BASE + (n+0x20))
						off = off + 1
					elseif n >= -0x80 then
						if off + 2 > cap then
							local new_cap = m_max(cap*2, off + 2 + EXTRA_CAP)
							local new_buf = buf_create(new_cap)
							buf_copy(new_buf, 0, buf, 0, off)
							buf = new_buf
							cap = new_cap
						end
						buf_w8(buf,off,INT8_MARK)
						buf_wi8(buf,off+1,n)
						off = off + 2
					elseif n >= -0x8000 then
						if off + 3 > cap then
							local new_cap = m_max(cap*2, off + 3 + EXTRA_CAP)
							local new_buf = buf_create(new_cap)
							buf_copy(new_buf, 0, buf, 0, off)
							buf = new_buf
							cap = new_cap
						end
						buf_w8(buf,off,INT16_MARK)
						buf_wi16(buf,off+1,n)
						off = off + 3
					elseif n >= -0x80000000 then
						if off + 5 > cap then
							local new_cap = m_max(cap*2, off + 5 + EXTRA_CAP)
							local new_buf = buf_create(new_cap)
							buf_copy(new_buf, 0, buf, 0, off)
							buf = new_buf
							cap = new_cap
						end
						buf_w8(buf,off,INT32_MARK)
						buf_wi32(buf,off+1,n)
						off = off + 5
					else 
						if off + 9 > cap then
							local new_cap = m_max(cap*2, off + 9 + EXTRA_CAP)
							local new_buf = buf_create(new_cap)
							buf_copy(new_buf, 0, buf, 0, off)
							buf = new_buf
							cap = new_cap
						end
						buf_w8(buf,off,FLOAT64_MARK)
						buf_wf64(buf,off+1,n)
						off = off + 9
					end
				end
			else
				if off + 9 > cap then
					local new_cap = m_max(cap*2, off + 9 + EXTRA_CAP)
					local new_buf = buf_create(new_cap)
					buf_copy(new_buf, 0, buf, 0, off)
					buf = new_buf
					cap = new_cap
				end
				buf_w8(buf,off,FLOAT64_MARK)
				buf_wf64(buf,off+1,n)
				off = off + 9
			end
		elseif ty == "string" then
			local s = x 
			local l = #s
			if l < 32 then
				if off + 1 + l > cap then
					local new_cap = m_max(cap*2, off + 1 + l + EXTRA_CAP)
					local new_buf = buf_create(new_cap)
					buf_copy(new_buf, 0, buf, 0, off)
					buf = new_buf
					cap = new_cap
				end
				buf_w8(buf,off,STR_FIX_BASE+l)
				off = off + 1
			elseif l < 0x100 then
				if off + 2 + l > cap then
					local new_cap = m_max(cap*2, off + 2 + l + EXTRA_CAP)
					local new_buf = buf_create(new_cap)
					buf_copy(new_buf, 0, buf, 0, off)
					buf = new_buf
					cap = new_cap
				end
				buf_w8(buf,off,STR8_MARK)
				buf_w8(buf,off+1,l)
				off = off + 2
			else
				if off + 3 + l > cap then
					local new_cap = m_max(cap*2, off + 3 + l + EXTRA_CAP)
					local new_buf = buf_create(new_cap)
					buf_copy(new_buf, 0, buf, 0, off)
					buf = new_buf
					cap = new_cap
				end
				buf_w8(buf,off,STR16_MARK)
				buf_w16(buf,off+1,l)
				off = off + 3
			end
			buf_wstr(buf,off,s,l)
			off = off + l
		elseif ty == "table" then
			local cnt_internal, seq_internal, mx_internal = 0, true, 0
			for k_internal in pairs(x) do
				cnt_internal = cnt_internal + 1
				if seq_internal and t_type(k_internal)=="number" and k_internal>0 and k_internal%1==0 then
					if k_internal > mx_internal then mx_internal = k_internal end
				else
					seq_internal = false
				end
			end
			if seq_internal and mx_internal == cnt_internal then
				if cnt_internal < 16 then
					if off + 1 > cap then
						local new_cap = m_max(cap*2, off + 1 + EXTRA_CAP)
						local new_buf = buf_create(new_cap)
						buf_copy(new_buf, 0, buf, 0, off)
						buf = new_buf
						cap = new_cap
					end
					buf_w8(buf,off,ARRAY_FIX_BASE+cnt_internal)
					off = off + 1
				else
					if off + 3 > cap then
						local new_cap = m_max(cap*2, off + 3 + EXTRA_CAP)
						local new_buf = buf_create(new_cap)
						buf_copy(new_buf, 0, buf, 0, off)
						buf = new_buf
						cap = new_cap
					end
					buf_w8(buf,off,ARRAY16_MARK)
					buf_w16(buf,off+1,cnt_internal)
					off = off + 3
				end
				for i_internal=1,cnt_internal do 
					writeAny(x[i_internal])
				end
			else
				if cnt_internal < 16 then
					if off + 1 > cap then
						local new_cap = m_max(cap*2, off + 1 + EXTRA_CAP)
						local new_buf = buf_create(new_cap)
						buf_copy(new_buf, 0, buf, 0, off)
						buf = new_buf
						cap = new_cap
					end
					buf_w8(buf,off,MAP_FIX_BASE+cnt_internal)
					off = off + 1
				else
					if off + 3 > cap then
						local new_cap = m_max(cap*2, off + 3 + EXTRA_CAP)
						local new_buf = buf_create(new_cap)
						buf_copy(new_buf, 0, buf, 0, off)
						buf = new_buf
						cap = new_cap
					end
					buf_w8(buf,off,MAP16_MARK)
					buf_w16(buf,off+1,cnt_internal)
					off = off + 3
				end
				for k_internal,v_internal in pairs(x) do 
					writeAny(k_internal)
					writeAny(v_internal)
				end
			end
		else
			error("Unsupported type: "..ty)
		end
	end

	-- Pack map key-value pairs
	for k, v in pairs(theMap) do
		writeAny(k)
		writeAny(v)
	end

	return buf_tostring(buf):sub(1, off)
end

function kelPack.unpackKnownMap(packedString)
	if not packedString then return nil end
	local b = buf_fromstr(packedString)
	local tag = buf_r8(b, 0)
	local p = 1
	-- Verify it's a map tag
	local count
	if tag >= MAP_FIX_BASE and tag <= MAP_FIX_MAX then
		count = tag - MAP_FIX_BASE
	elseif tag == MAP16_MARK then
		count = buf_r16(b, p)
		p = p + 2
	else
		error("Expected map tag, got: " .. tag)
	end
	-- Read map key-value pairs
	local res = {}
	local current_p = p
	for i = 1, count do
		local k, p1 = readAnyRecursive(b, current_p)
		local v, p2 = readAnyRecursive(b, p1)
		if k ~= nil then res[k] = v end
		current_p = p2
	end

	return res
end

return kelPack
