--!strict
-- Window-only identity registry for read-only Watch and writable Attach panes.
-- Requires Tern 0.9.12's hosts:list() pane membership. No layout, lifecycle
-- subscriptions, processes or timers belong here: the caller owns those.
--
-- Public API (all errors are returned, including plugin-KV failures):
--   find(cx, source, hc, address, mode) -> pane?, error?
--     nil, nil means no reusable viewer; a hit refreshes its bounded recency.
--   record(cx, source, hc, address, mode, pane) -> boolean, error?
--     Call ONLY after actual creation of that viewer with the requested mode.
--   prune(cx) -> removed?, error?
--     Reconcile this window only, preserving other windows' records.
--   forget(cx, pane) -> removed?, error?
--     Call for pane_closed and before a tracked pane is genuinely repurposed.
--
-- Watch is mode "read"; writable Attach is "write". They never share entries.
-- Source ownership must be unambiguous in hosts:list() and session:sessions()
-- tab membership; current host/session, titles and command substrings are NOT
-- identity. The console pane is deliberately absent from the registry key.
-- Pane ids plus caller-owned lifecycle invalidation identify viewers. Do not
-- invalidate on forwarded OSC 133 command events or compare running.line:
-- hc attach can forward the viewed terminal's changing shell state.
-- Parked viewers retain their recorded session until moved or forgotten;
-- a parked SOURCE has no provable tab membership and returns an error.
--
-- Storage is lazy, bounded to 64 records, oldest first (used = 1..64). Each
-- operation rereads KV so other clients' latest records survive read/merge/
-- write. KV has no compare-and-swap; simultaneous writers are best-effort.

local M = {}

export type Mode = "read" | "write"
type Entry = {
	window_key: string,
	host: number,
	session: number,
	hc: string,
	address: string,
	mode: Mode,
	pane: number,
	used: number,
}
type Inspection = {
	panes: { [number]: PaneInfo },
	hosts: { [number]: number },
	tabs: { [number]: number },
	sessions: { [number]: boolean },
}

local KV_KEY = "viewer_registry"
local CAP = 64
local MAX_ID = 9007199254740991

local function valid_id(value: any): boolean
	return type(value) == "number" and value >= 0 and value <= MAX_ID and value % 1 == 0
end

local function valid_text(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 4096
end

-- Tern's first window has the valid key ""; only hc/address must be nonempty.
local function valid_window_key(value: any): boolean
	return type(value) == "string" and #value <= 4096
end

local function same_key(a: Entry, b: Entry): boolean
	return a.window_key == b.window_key and a.host == b.host and a.session == b.session
		and a.hc == b.hc and a.address == b.address and a.mode == b.mode
end

local function decode(value: any): Entry?
	if type(value) ~= "table" or not valid_window_key(value.window_key)
		or not valid_id(value.host) or not valid_id(value.session) or not valid_id(value.pane)
		or not valid_text(value.hc) or not valid_text(value.address)
		or (value.mode ~= "read" and value.mode ~= "write")
		or not valid_id(value.used) or value.used < 1 or value.used > CAP then
		return nil
	end
	return {
		window_key = value.window_key, host = value.host, session = value.session,
		hc = value.hc, address = value.address, mode = value.mode,
		pane = value.pane, used = value.used,
	}
end

local function load(): ({ Entry }?, boolean, string?)
	local ok, value = pcall(tern.kv.get, KV_KEY)
	if not ok then return nil, false, "Could not read viewer registry: " .. tostring(value) end
	local entries: { Entry } = {}
	if value == nil then return entries, false, nil end
	if type(value) ~= "table" or type(value.records) ~= "table" then
		return nil, false, "Viewer registry has an unknown storage format"
	end
	local raw = value.records
	local dirty = #raw > CAP
	-- Inspect at most the newest 64 stored rows, even for oversized input.
	for index = #raw, math.max(1, #raw - CAP + 1), -1 do
		local entry = decode(raw[index])
		local duplicate = false
		if entry then
			for _, newer in entries do
				if same_key(entry, newer) or (entry.window_key == newer.window_key and entry.pane == newer.pane) then
					duplicate = true
					break
				end
			end
		end
		if entry and not duplicate then table.insert(entries, 1, entry) else dirty = true end
	end
	for index, entry in entries do
		if entry.used ~= index then dirty = true end
		entry.used = index
	end
	return entries, dirty, nil
end

local function save(entries: { Entry }): string?
	for index, entry in entries do entry.used = index end
	local ok, why = pcall(function(): boolean
		tern.kv.set(KV_KEY, { records = entries })
		return true
	end)
	return if ok then nil else "Could not save viewer registry: " .. tostring(why)
end

local function window_key(cx: WindowCx): (string?, string?)
	local key = cx:window_key()
	if not valid_window_key(key) then return nil, "Viewer source window key is unknown" end
	return key, nil
end

-- -1 marks ambiguous ownership, including duplicate membership rows.
local function inspect(cx: WindowCx): Inspection
	local view: Inspection = { panes = {}, hosts = {}, tabs = {}, sessions = {} }
	for _, pane in cx.session:panes() do view.panes[pane.pane] = pane end
	for _, host in cx.hosts:list() do
		for _, pane in host.panes do
			view.hosts[pane] = if view.hosts[pane] == nil then host.id else -1
		end
	end
	for _, session in cx.session:sessions() do
		view.sessions[session.id] = true
		for _, tab in session.tabs do
			view.tabs[tab] = if view.tabs[tab] == nil then session.id else -1
		end
	end
	return view
end

local function ownership(view: Inspection, pane_id: number): (number?, number?, string?)
	local pane = view.panes[pane_id]
	if not pane then return nil, nil, "Viewer source pane is absent from this window" end
	local host = view.hosts[pane_id]
	if host == nil or host < 0 then
		return nil, nil, "Viewer source host is unknown or ambiguous"
	end
	local session = if pane.tab then view.tabs[pane.tab] else nil
	if session == nil or session < 0 then
		return nil, nil, "Viewer source session is unknown or ambiguous"
	end
	return host, session, nil
end

local function live_viewer(pane: PaneInfo): boolean
	return (pane.kind == "terminal" or pane.kind == "agent") and pane.exited == nil and pane.block == nil
end

local function prune_entries(entries: { Entry }, key: string, view: Inspection): number
	local removed = 0
	for index = #entries, 1, -1 do
		local entry = entries[index]
		if entry.window_key == key then
			local pane = view.panes[entry.pane]
			local host = view.hosts[entry.pane]
			local session = if pane and pane.tab then view.tabs[pane.tab] else nil
			-- Unknown membership alone is not proof a pane was repurposed.
			-- Keep that row, but find() cannot reuse it until ownership is known.
			if not pane or not live_viewer(pane) or not view.sessions[entry.session]
				or (host ~= nil and host >= 0 and host ~= entry.host)
				or (session ~= nil and session >= 0 and session ~= entry.session) then
				table.remove(entries, index)
				removed += 1
			end
		end
	end
	return removed
end

local function target(cx: WindowCx, source: number, hc: string, address: string, mode: Mode): (Entry?, Inspection?, string?)
	if not valid_id(source) or not valid_text(hc) or not valid_text(address)
		or (mode ~= "read" and mode ~= "write") then
		return nil, nil, "Invalid viewer source, hc path, terminal address or mode"
	end
	local key, key_error = window_key(cx)
	if not key then return nil, nil, key_error end
	local view = inspect(cx)
	local host, session, why = ownership(view, source)
	if host == nil or session == nil then return nil, nil, why end
	return {
		window_key = key, host = host, session = session, hc = hc,
		address = address, mode = mode, pane = source, used = 1,
	}, view, nil
end

function M.find(cx: WindowCx, source: number, hc: string, address: string, mode: Mode): (number?, string?)
	local wanted, view, why = target(cx, source, hc, address, mode)
	if not wanted or not view then return nil, why end
	local entries, dirty, load_error = load()
	if not entries then return nil, load_error end
	dirty = prune_entries(entries, wanted.window_key, view) > 0 or dirty
	local found: number? = nil
	for index, entry in entries do
		if same_key(entry, wanted) then
			local pane = view.panes[entry.pane]
			local session = if pane and pane.tab then view.tabs[pane.tab] else nil
			if view.hosts[entry.pane] == wanted.host
				and (session == wanted.session or (pane and pane.parked and session == nil)) then
				found = entry.pane
				if index ~= #entries then
					table.remove(entries, index)
					table.insert(entries, entry)
					dirty = true
				end
			end
			break
		end
	end
	if dirty then
		local save_error = save(entries)
		if save_error then return nil, save_error end
	end
	return found, nil
end

function M.record(cx: WindowCx, source: number, hc: string, address: string, mode: Mode, pane: number): (boolean, string?)
	local entry, view, why = target(cx, source, hc, address, mode)
	if not entry or not view then return false, why end
	if not valid_id(pane) or pane == source then return false, "Viewer must be a newly created pane, not the source" end
	local created = view.panes[pane]
	if not created or not live_viewer(created) then return false, "Viewer pane is absent, exited or not a terminal/agent" end
	local host, session, owner_error = ownership(view, pane)
	if host == nil or session == nil then return false, owner_error end
	if host ~= entry.host or session ~= entry.session then
		return false, "Viewer pane does not belong to the source host and session"
	end
	local entries, _dirty, load_error = load()
	if not entries then return false, load_error end
	prune_entries(entries, entry.window_key, view)
	entry.pane = pane
	for index = #entries, 1, -1 do
		local known = entries[index]
		if same_key(known, entry) or (known.window_key == entry.window_key and known.pane == pane) then
			table.remove(entries, index)
		end
	end
	if #entries == CAP then table.remove(entries, 1) end
	table.insert(entries, entry)
	local save_error = save(entries)
	return save_error == nil, save_error
end

function M.prune(cx: WindowCx): (number?, string?)
	local key, why = window_key(cx)
	if not key then return nil, why end
	local entries, dirty, load_error = load()
	if not entries then return nil, load_error end
	local removed = prune_entries(entries, key, inspect(cx))
	if removed > 0 or dirty then
		local save_error = save(entries)
		if save_error then return nil, save_error end
	end
	return removed, nil
end

function M.forget(cx: WindowCx, pane: number): (number?, string?)
	local key, why = window_key(cx)
	if not key then return nil, why end
	if not valid_id(pane) then return nil, "Invalid viewer pane id" end
	local entries, dirty, load_error = load()
	if not entries then return nil, load_error end
	local removed = 0
	for index = #entries, 1, -1 do
		if entries[index].window_key == key and entries[index].pane == pane then
			table.remove(entries, index)
			removed += 1
		end
	end
	if removed > 0 or dirty then
		local save_error = save(entries)
		if save_error then return nil, save_error end
	end
	return removed, nil
end

return M
