-- (Token Bucket Algorithm)
-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local module = {}
module.__index = module

function module.new(refillRate:number, capacity:number, initialTokens:number?)
	local self = setmetatable({}, module)
	self.refillRate = refillRate
	self.capacity = capacity
	self.tokens = initialTokens or capacity
	self.lastRefillTime = os.clock()
	return self
end

function module:_refill()
	local now = os.clock()
	local elapsed = now - self.lastRefillTime
	local tokensToAdd = elapsed * self.refillRate
	self.tokens = math.min(self.capacity, self.tokens + tokensToAdd)
	self.lastRefillTime = now
end

function module:consume(amount:number?):boolean
	local tokensNeeded = amount or 1
	assert(tokensNeeded > 0, "Token amount must be greater than 0")
	self:_refill()
	if self.tokens >= tokensNeeded then
		self.tokens -= tokensNeeded
		return true
	end
	return false
end

function module:getAvailableTokens():number
	self:_refill()
	return self.tokens
end

function module:getTimeUntilAvailable(amount:number?):number
	local tokensNeeded = amount or 1
	self:_refill()
	local deficit = tokensNeeded - self.tokens
	if deficit <= 0 then
		return 0
	end
	return deficit / self.refillRate
end

function module:reset()
	self.tokens = self.capacity
	self.lastRefillTime = os.clock()
end

function module:setRefillRate(newRate:number)
	assert(newRate > 0, "Refill rate must be greater than 0")
	self:_refill() -- Refill with old rate first
	self.refillRate = newRate
end

function module:setCapacity(newCapacity:number)
	assert(newCapacity > 0, "Capacity must be greater than 0")
	self.capacity = newCapacity
	self.tokens = math.min(self.tokens, newCapacity)
end

function module:getInfo():{refillRate:number, capacity:number, tokens:number, lastRefillTime:number}
	self:_refill()
	return {
		refillRate = self.refillRate,
		capacity = self.capacity,
		tokens = self.tokens,
		lastRefillTime = self.lastRefillTime
	}
end

return module
