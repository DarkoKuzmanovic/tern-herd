--!strict
-- Host-only metadata ledger. Requiring this module shares transitions and read
-- state between consoles; it never executes commands or stores terminal content.
local common = require("./common")
local M = {}

export type Terminal = common.Term

export type Event = {
	id: number,
	at: number,
	address: string,
	name: string?,
	from: string?,
	status: string,
	exit_code: number?,
	runs: { string },
	read: boolean,
}

type Observation = {
	address: string,
	state: string,
	status: string,
	ordinal: number,
	runs: { string },
}

type Store = {
	version: number,
	baseline: boolean,
	saturated: boolean,
	serial: number,
	ordinal: number,
	events: { Event },
	seen: { Observation },
}

local KEY = "activity"
local MAX_EVENTS = 100
local MAX_SEEN = 512
local MAX_RUNS = 12
local store: Store = { version = 1, baseline = false, saturated = false, serial = 0, ordinal = 0, events = {}, seen = {} }
local by_address: { [string]: Observation } = {}
-- Request times belong to this VM's monotonic clock, never to persisted data.
local last_request: { [string]: number } = {}
local loaded = false
local dirty = false
local problem: string? = nil

-- Rebase only exhausted/corrupt counters, retaining ordering and shared refs.
-- Leave ample exact-integer headroom rather than incrementing near 2^53.
local function normalize_counters()
	if store.serial >= 4503599627370496 then
		for index, event in store.events do event.id = index end
		store.serial = #store.events
		dirty = true
	end
	if store.ordinal >= 4503599627370496 then
		table.sort(store.seen, function(a: Observation, b: Observation): boolean
			return if a.ordinal == b.ordinal then a.address < b.address else a.ordinal < b.ordinal
		end)
		for index, seen in store.seen do seen.ordinal = index end
		store.ordinal = #store.seen
		dirty = true
	end
end

local function next_ordinal(): number
	normalize_counters()
	store.ordinal += 1
	return store.ordinal
end

local function next_id(): number
	normalize_counters()
	store.serial += 1
	return store.serial
end

local function text(value: any, maximum: number): string?
	return if type(value) == "string" and #value > 0 and #value <= maximum
		and not string.find(value, "%c") then value else nil
end

local function finite(value: any): number?
	return if type(value) == "number" and value == value and math.abs(value) < math.huge then value else nil
end

local function integer(value: any): number?
	local n = finite(value)
	return if n and n % 1 == 0 and math.abs(n) < 9007199254740991 then n else nil
end

local function counter(value: any): number?
	local n = integer(value)
	return if n and n >= 0 then n else nil
end

local function add_run(runs: { string }, run: string?): boolean
	if not run or #runs >= MAX_RUNS or table.find(runs, run) then return false end
	table.insert(runs, run)
	return true
end

local function read_runs(value: any): { string }
	local runs: { string } = {}
	if type(value) == "table" then
		local values: { any } = value
		for _, item in ipairs(values) do
			add_run(runs, common.scope(item))
			if #runs == MAX_RUNS then break end
		end
	end
	return runs
end

local function event_status(value: any): string?
	return if value == "blocked" or value == "error" or value == "done"
		or value == "idle" or value == "finished" then value else nil
end

local function read_event(value: any): Event?
	if type(value) ~= "table" then return nil end
	local id = counter(value.id)
	local at = finite(value.at)
	local address = text(value.address, 256)
	local status = event_status(value.status)
	if not id or id == 0 or not at or at < 0 or not address or not status then return nil end
	return {
		id = id,
		at = at,
		address = address,
		name = text(value.name, 256),
		from = text(value.from, 32),
		status = status,
		exit_code = integer(value.exit_code),
		runs = read_runs(value.runs),
		read = value.read == true,
	}
end

local function read_observation(value: any): Observation?
	if type(value) ~= "table" then return nil end
	local address = text(value.address, 256)
	local state = text(value.state, 32)
	local status = text(value.status, 32)
	local ordinal = counter(value.ordinal)
	if not address or not state or not status or not ordinal then return nil end
	return { address = address, state = state, status = status, ordinal = ordinal, runs = read_runs(value.runs) }
end

-- Compare against the whitelist-built value, including unknown keys. Valid
-- stores do not get rewritten on reload; malformed/oversized metadata does.
local function same(value: any, clean: any): boolean
	if type(value) ~= type(clean) then return false end
	if type(clean) ~= "table" then return value == clean end
	for key, item in clean do
		if not same(value[key], item) then return false end
	end
	for key in value do
		if clean[key] == nil then return false end
	end
	return true
end

local function trim_seen()
	if #store.seen >= MAX_SEEN and not store.saturated then
		store.saturated = true
		dirty = true
	end
	if #store.seen <= MAX_SEEN then return end
	table.sort(store.seen, function(a: Observation, b: Observation): boolean
		return if a.ordinal == b.ordinal then a.address < b.address else a.ordinal < b.ordinal
	end)
	while #store.seen > MAX_SEEN do
		local old = store.seen[1]
		table.remove(store.seen, 1)
		by_address[old.address] = nil
		last_request[old.address] = nil
	end
end

local function load(): boolean
	if loaded then return true end
	local ok, saved = pcall(tern.kv.get, KEY)
	if not ok then
		problem = "Activity history could not be read: " .. tostring(saved)
		return false
	end
	if type(saved) == "table" then
		store.saturated = saved.saturated == true
		store.baseline = saved.baseline == true
		store.serial = counter(saved.serial) or 0
		store.ordinal = counter(saved.ordinal) or 0
		if type(saved.events) == "table" then
			local values: { any } = saved.events
			for _, value in ipairs(values) do
				local event = read_event(value)
				if event then
					local duplicate = false
					for _, previous in store.events do
						if previous.id == event.id then duplicate = true; break end
					end
					if not duplicate then
						table.insert(store.events, event)
						table.sort(store.events, function(a: Event, b: Event): boolean return a.id < b.id end)
						if #store.events > MAX_EVENTS then table.remove(store.events, 1) end
						store.serial = math.max(store.serial, event.id)
					end
				end
			end
		end
		if type(saved.seen) == "table" then
			local values: { any } = saved.seen
			for _, value in ipairs(values) do
				local seen = read_observation(value)
				if seen then
					local previous = by_address[seen.address]
					if not previous or seen.ordinal > previous.ordinal then
						if previous then
							for index, item in store.seen do
								if item == previous then table.remove(store.seen, index); break end
							end
						end
						table.insert(store.seen, seen)
						by_address[seen.address] = seen
						store.ordinal = math.max(store.ordinal, seen.ordinal)
						trim_seen()
					end
				end
			end
		end
		-- Old observations are a baseline even if an old store omitted the flag.
		if #store.seen > 0 then store.baseline = true end
	end
	normalize_counters()
	loaded = true
	problem = nil
	dirty = saved ~= nil and not same(saved, store)
	return true
end

local function persist()
	if not dirty then return end
	local ok, err = pcall(function(): boolean
		tern.kv.set(KEY, store)
		return true
	end)
	if ok then
		dirty = false
		problem = nil
	else
		-- Retain the in-memory ledger and retry on the next public API call.
		problem = "Activity history could not be saved: " .. tostring(err)
	end
end

local function selected(event: Event, run: string?): boolean
	return run == nil or table.find(event.runs, run) ~= nil
end

local function latest(address: string): Event?
	for index = #store.events, 1, -1 do
		local event = store.events[index]
		if event.address == address then return event end
	end
	return nil
end

local function associate(address: string, run: string?)
	if not run then return end
	local seen = by_address[address]
	if seen and add_run(seen.runs, run) then dirty = true end
	local event = latest(address)
	if event and add_run(event.runs, run) then dirty = true end
end

function M.observe(terms: { Terminal }, run: string?, request_at: number): { Event }
	local added: { Event } = {}
	if not load() then return added end
	local scope = common.scope(run)
	if run ~= nil and run ~= "" and not scope then persist(); return added end
	if not finite(request_at) then persist(); return added end
	local baseline = store.baseline
	for _, terminal in terms do
		if type(terminal) ~= "table" then continue end
		local address = text(terminal.address, 256)
		local state = text(terminal.state, 32)
		local status = text(terminal.status, 32)
		if not address or not state or not status then continue end
		local requested = last_request[address]
		local previous = by_address[address]
		if requested and request_at < requested then
			-- An older scoped reply may confirm the same transition that All
			-- already recorded. Preserve its membership without replaying state.
			if previous and previous.state == state and previous.status == status then
				associate(address, scope)
			end
			continue
		end
		last_request[address] = request_at
		local from: string? = if previous then (if previous.state == "finished" then "finished" else previous.status) else nil
		local to = if state == "finished" then "finished" else status
		local transition = false
		if previous then
			if state == "finished" then
				transition = previous.state == "live"
			elseif from ~= to then
				transition = to == "blocked" or to == "error" or (from == "working" and (to == "done" or to == "idle"))
			end
		elseif baseline and not store.saturated and #store.seen < MAX_SEEN then
			-- Once retention fills, an unknown address may be an eviction, not
			-- a new terminal. Baseline it instead of recreating old unread news.
			transition = to == "blocked" or to == "error"
		end
		if not previous then
			local ordinal = next_ordinal()
			local runs: { string } = {}
			add_run(runs, scope)
			local observation: Observation = { address = address, state = state, status = status, ordinal = ordinal, runs = runs }
			by_address[address] = observation
			table.insert(store.seen, observation)
			trim_seen()
			dirty = true
		else
			if previous.state ~= state or previous.status ~= status then
				previous.state, previous.status, previous.ordinal = state, status, next_ordinal()
				dirty = true
			end
			if add_run(previous.runs, scope) then dirty = true end
		end
		if transition then
			local id = next_id()
			local observation = by_address[address]
			local runs: { string } = table.clone(observation.runs)
			local event: Event = {
				id = id,
				at = os.time(),
				address = address,
				name = text(terminal.name, 256),
				from = from,
				status = to,
				exit_code = if to == "finished" then integer(terminal.exit_code) else nil,
				runs = runs,
				read = false,
			}
			table.insert(store.events, event)
			if #store.events > MAX_EVENTS then table.remove(store.events, 1) end
			table.insert(added, event)
			dirty = true
		else
			-- A scoped poll can discover a transition first seen by All without
			-- producing a second event or making old finished rows look new.
			associate(address, scope)
		end
	end
	if not store.baseline then store.baseline = true; dirty = true end
	trim_seen()
	persist()
	return added
end

function M.list(run: string?): { Event }
	local events: { Event } = {}
	if not load() then return events end
	local scope = common.scope(run)
	if run ~= nil and run ~= "" and not scope then persist(); return events end
	for index = #store.events, 1, -1 do
		local event = store.events[index]
		if selected(event, scope) then table.insert(events, event) end
	end
	persist()
	return events
end

function M.unread(run: string?): number
	if not load() then return 0 end
	local scope = common.scope(run)
	if run ~= nil and run ~= "" and not scope then persist(); return 0 end
	local count = 0
	for _, event in store.events do
		if not event.read and selected(event, scope) then count += 1 end
	end
	persist()
	return count
end

function M.mark_read(run: string?): ()
	if not load() then return end
	local scope = common.scope(run)
	if run ~= nil and run ~= "" and not scope then persist(); return end
	for _, event in store.events do
		if not event.read and selected(event, scope) then event.read = true; dirty = true end
	end
	persist()
end

function M.clear(run: string?): ()
	if not load() then return end
	local scope = common.scope(run)
	if run ~= nil and run ~= "" and not scope then persist(); return end
	for index = #store.events, 1, -1 do
		if selected(store.events[index], scope) then table.remove(store.events, index); dirty = true end
	end
	-- Keep observations, baseline, and request ordering: clearing history must
	-- not turn the next identical poll into a fresh transition.
	persist()
end

function M.note_run(address: string, run: string): ()
	if not load() then return end
	local clean = text(address, 256)
	if clean then associate(clean, common.scope(run)) end
	persist()
end

-- Read failures leave kv untouched and retry on the next API call. Callers may
-- display this message instead of presenting an unavailable history as empty.
function M.status(): string?
	if load() then persist() end
	return problem
end

return M
