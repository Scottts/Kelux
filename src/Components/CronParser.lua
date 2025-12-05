-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local CronParser = {}
CronParser.__index = CronParser

local MONTH_NAMES = {
	jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6,
	jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12
}

local WEEKDAY_NAMES = {
	sun = 0, mon = 1, tue = 2, wed = 3, thu = 4, fri = 5, sat = 6
}

local SPECIAL_EXPRESSIONS = {
	["@yearly"] = "0 0 0 1 1 *",
	["@annually"] = "0 0 0 1 1 *",
	["@monthly"] = "0 0 0 1 * *",
	["@weekly"] = "0 0 0 * * 0",
	["@daily"] = "0 0 0 * * *",
	["@midnight"] = "0 0 0 * * *",
	["@hourly"] = "0 0 * * * *"
}

local FIELD_CONSTRAINTS = {
	second = {min = 0, max = 59},
	minute = {min = 0, max = 59},
	hour = {min = 0, max = 23},
	day = {min = 1, max = 31},
	month = {min = 1, max = 12},
	weekday = {min = 0, max = 6}
}

local DAYS_IN_MONTH = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

local function isLeapYear(year)
	return (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
end

local function getDaysInMonth(month, year)
	if month == 2 and isLeapYear(year) then
		return 29
	end
	return DAYS_IN_MONTH[month]
end

local function parseNamedValue(value, names)
	local lower = string.lower(value)
	return names[lower] or tonumber(value)
end

local function parseField(field, fieldType)
	if field == "*" then
		return nil 
	end
	local constraint = FIELD_CONSTRAINTS[fieldType]
	local values = {}
	for segment in string.gmatch(field, "[^,]+") do
		segment = string.gsub(segment, "^%s*(.-)%s*$", "%1") 
		local base, step = string.match(segment, "^(.+)/(%d+)$")
		step = tonumber(step) or 1
		if base then
			segment = base
		end
		local rangeStart, rangeEnd = string.match(segment, "^(.+)-(.+)$")
		if rangeStart and rangeEnd then
			rangeStart = parseNamedValue(rangeStart, fieldType == "month" and MONTH_NAMES or 
				fieldType == "weekday" and WEEKDAY_NAMES or {})
			rangeEnd = parseNamedValue(rangeEnd, fieldType == "month" and MONTH_NAMES or 
				fieldType == "weekday" and WEEKDAY_NAMES or {})
			if not rangeStart or not rangeEnd then
				error("Invalid range in cron field: "..segment)
			end
			for i = rangeStart, rangeEnd, step do
				if i >= constraint.min and i <= constraint.max then
					values[i] = true
				end
			end
		elseif segment == "*" then
			for i = constraint.min, constraint.max, step do
				values[i] = true
			end
		else
			local value = parseNamedValue(segment, fieldType == "month" and MONTH_NAMES or 
				fieldType == "weekday" and WEEKDAY_NAMES or {})
			if not value then
				error("Invalid value in cron field: "..segment)
			end
			if value >= constraint.min and value <= constraint.max then
				if step > 1 then

					for i = value, constraint.max, step do
						values[i] = true
					end
				else
					values[value] = true
				end
			end
		end
	end
	return next(values) and values or nil
end

local function matchesField(value, field)
	return field == nil or field[value] == true
end

local function detectCronFormat(cronExpression)
	local fieldCount = 0
	for field in string.gmatch(cronExpression, "%S+") do
		fieldCount = fieldCount + 1
	end
	return fieldCount
end

function CronParser.new(cronExpression)
	local self = setmetatable({}, CronParser)
	if SPECIAL_EXPRESSIONS[cronExpression] then
		cronExpression = SPECIAL_EXPRESSIONS[cronExpression]
	end
	local fieldCount = detectCronFormat(cronExpression)
	local fields = {}
	local fieldNames
	if fieldCount == 5 then
		fieldNames = {"minute", "hour", "day", "month", "weekday"}
		self.hasSeconds = false
	elseif fieldCount == 6 then
		fieldNames = {"second", "minute", "hour", "day", "month", "weekday"}
		self.hasSeconds = true
	else
		error("Invalid cron expression: expected 5 or 6 fields, got " .. fieldCount)
	end
	local i = 1
	for field in string.gmatch(cronExpression, "%S+") do
		if i > #fieldNames then
			error("Too many fields in cron expression")
		end
		fields[fieldNames[i]] = parseField(field, fieldNames[i])
		i = i + 1
	end
	if i <= #fieldNames then
		error("Not enough fields in cron expression")
	end
	self.fields = fields
	self.expression = cronExpression
	return self
end

function CronParser:shouldRun(dateTime)
	if not dateTime then
		dateTime = os.date("*t")
	end
	local matches = true
	if self.hasSeconds then
		matches = matches and matchesField(dateTime.sec, self.fields.second)
	end
	matches = matches and matchesField(dateTime.min, self.fields.minute) and
		matchesField(dateTime.hour, self.fields.hour) and
		matchesField(dateTime.day, self.fields.day) and
		matchesField(dateTime.month, self.fields.month) and
		matchesField(dateTime.wday - 1, self.fields.weekday)
	return matches
end

function CronParser:getNextRun(fromTime)
	local currentTime = math.floor(fromTime)
	local maxIterations = 60 * 60 * 24 * 365
	for i = 1, maxIterations do
		currentTime = currentTime + 1
		local dateTable = os.date("!*t", currentTime)
		if self:shouldRun(dateTable) then
			return currentTime
		end
	end
	return nil
end

function CronParser:getNextRuns(count, fromTime)
	if not count then count = 5 end
	if not fromTime then fromTime = os.time() end
	local runs = {}
	local currentTime = fromTime
	for i = 1, count do
		currentTime = self:getNextRun(currentTime)
		table.insert(runs, currentTime)
	end
	return runs
end

function CronParser:matches(dateTime)
	return self:shouldRun(dateTime)
end

function CronParser:getExpression()
	return self.expression
end

function CronParser:describe()
	local description = "Cron: "..self.expression.."\n"
	local function describeField(field, fieldType, name)
		if not field then
			description = description..name..": any\n"
		else
			local values = {}
			for value in pairs(field) do
				table.insert(values, tostring(value))
			end
			table.sort(values, function(a, b) return tonumber(a) < tonumber(b) end)
			description = description..name..": "..table.concat(values, ", ").."\n"
		end
	end
	if self.hasSeconds then
		describeField(self.fields.second, "second", "Seconds")
	end
	describeField(self.fields.minute, "minute", "Minutes")
	describeField(self.fields.hour, "hour", "Hours")
	describeField(self.fields.day, "day", "Days")
	describeField(self.fields.month, "month", "Months")
	describeField(self.fields.weekday, "weekday", "Weekdays")
	return description
end

function CronParser.isValidExpression(cronExpression)
	local success, result = pcall(function()
		CronParser.new(cronExpression)
	end)
	return success
end

function CronParser.parseExpression(cronExpression)
	return CronParser.new(cronExpression)
end

return CronParser
