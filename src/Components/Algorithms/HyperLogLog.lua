-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local module = {}
module.__index = module

local ALPHA = {
	[4] = 0.673,
	[5] = 0.697,
	[6] = 0.709,
	[7] = 0.715,
	[8] = 0.7182,
}

local function hash32(str:string):number
	local h = 2166136261
	for i = 1, #str do
		h = bit32.bxor(h, string.byte(str, i))
		h = bit32.band(h * 16777619, 0xFFFFFFFF)
	end
	return h
end

local function leadingZeroCount(value:number, skipBits:number):number
	local mask = bit32.lshift(1, 31 - skipBits)
	local count = 1
	for i = skipBits, 31 do
		if bit32.band(value, mask) ~= 0 then
			return count
		end
		count = count + 1
		mask = bit32.rshift(mask, 1)
	end
	return count
end

function module.new(precision:number?)
	precision = precision or 12
	assert(precision >= 4 and precision <= 16, "Precision must be between 4 and 16")
	local m = bit32.lshift(1, precision)
	local registers = table.create(m, 0)
	local self = setmetatable({
		precision = precision,
		m = m,
		registers = registers,
		alphaMM = (ALPHA[precision] or (0.7213 / (1 + 1.079 / m))) * m * m,
	}, module)
	return self
end

function module:add(value:any)
	local str = tostring(value)
	local h = hash32(str)
	local idx = bit32.rshift(h, 32 - self.precision) + 1
	local leadingZeros = leadingZeroCount(bit32.lshift(h, self.precision), self.precision)
	if leadingZeros > self.registers[idx] then
		self.registers[idx] = leadingZeros
	end
end

function module:count():number
	local sum = 0
	for i = 1, self.m do
		sum = sum + 2 ^ (-self.registers[i])
	end
	local estimate = self.alphaMM / sum
	if estimate <= 2.5 * self.m then
		local zeros = 0
		for i = 1, self.m do
			if self.registers[i] == 0 then
				zeros = zeros + 1
			end
		end
		if zeros ~= 0 then
			estimate = self.m * math.log(self.m / zeros)
		end
	elseif estimate > (1/30) * 2^32 then
		estimate = -2^32 * math.log(1 - estimate / 2^32)
	end
	return math.floor(estimate + 0.5)
end

function module:merge(other:typeof(module))
	assert(self.precision == other.precision, "Cannot merge HyperLogLogs with different precisions")
	for i = 1, self.m do
		if other.registers[i] > self.registers[i] then
			self.registers[i] = other.registers[i]
		end
	end
end

function module:clear()
	for i = 1, self.m do
		self.registers[i] = 0
	end
end

function module:getMemoryUsage():number
	return self.m * 1
end

function module:getStandardError():number
	return 1.04 / math.sqrt(self.m)
end

return module
