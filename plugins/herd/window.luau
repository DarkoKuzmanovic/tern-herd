--!strict
-- Window-only actions use the block's inert surface mailbox, not URL effects.
-- The host grants each request to one window, even with multiple replicas.
-- This half also owns the palette command, key and status segment.

local common = require("./common")

local KIND = common.KIND
local ACTION = common.OPEN_ACTION
local STATUS_MS = 3000

-- PaneInfo has no session field for parked panes. Remember ownership while
-- visible, never guess across sessions; keep only 32 recently used consoles.
type Console = { session: number, used: number }
local consoles: { [number]: Console } = {}
local console_count = 0
local use_serial = 0
local last_focused: number? = nil

local function is_herd(pane: PaneInfo): boolean
	return pane.block == KIND or pane.block == "plugin." .. KIND
end

local function remember_console(pane: number, session: number): Console
	local entry = consoles[pane]
	if entry then entry.session = session; return entry end
	if console_count == 32 then
		local oldest: number? = nil
		local age = math.huge
		for id, known in consoles do
			if known.used < age or (known.used == age and (oldest == nil or id > oldest)) then
				oldest, age = id, known.used
			end
		end
		if oldest then consoles[oldest] = nil; console_count -= 1 end
	end
	local created: Console = { session = session, used = 0 }
	consoles[pane] = created
	console_count += 1
	return created
end

local function inspect_consoles(cx: WindowCx): ({ PaneInfo }, number?, { [number]: number })
	local tabs: { [number]: number } = {}
	local sessions: { [number]: boolean } = {}
	local current: number? = nil
	local only: number? = nil
	local session_count = 0
	for _, session in cx.session:sessions() do
		sessions[session.id] = true
		session_count += 1
		only = session.id
		if session.current then current = session.id end
		for _, tab in session.tabs do tabs[tab] = session.id end
	end
	local panes = cx.session:panes()
	local present: { [number]: boolean } = {}
	for _, pane in panes do
		if is_herd(pane) then present[pane.pane] = true end
	end
	for id, entry in consoles do
		if not present[id] or not sessions[entry.session] then
			consoles[id] = nil
			console_count -= 1
		end
	end
	local focused = cx.session:focused()
	for _, pane in panes do
		if is_herd(pane) then
			local session = if pane.tab then tabs[pane.tab] else nil
			if session == nil and pane.parked and session_count == 1 then session = only end
			if session then
				local entry = remember_console(pane.pane, session)
				if pane.pane == focused and focused ~= last_focused then
					use_serial += 1
					entry.used = use_serial
				end
			end
		end
	end
	last_focused = focused
	return panes, current, tabs
end

-- Current session only: focused console, then most recently focused/used,
-- then lowest pane id. Its host state, including saved run scope, stays intact.
local function find_herd(cx: WindowCx): PaneInfo?
	local panes, current, tabs = inspect_consoles(cx)
	if current == nil then return nil end
	local focused = cx.session:focused()
	local best: PaneInfo? = nil
	local latest = -1
	for _, pane in panes do
		if is_herd(pane) then
			local known = consoles[pane.pane]
			local session = if pane.tab then tabs[pane.tab] elseif known then known.session else nil
			if session == current then
				if pane.pane == focused then return pane end
				local used = if known then known.used else 0
				if best == nil or used > latest or (used == latest and pane.pane < best.pane) then
					best, latest = pane, used
				end
			end
		end
	end
	return best
end

local function open_herd(cx: WindowCx, initial_action: string?): number?
	local pane = find_herd(cx)
	if pane then
		if pane.parked then
			local ok, why = cx.layout:unpark(pane.pane)
			if not ok then
				cx:toast("error", "Could not unpark the Herd console", why)
				return nil
			end
		end
		cx.layout:focus(pane.pane)
		local known = consoles[pane.pane]
		if known then use_serial += 1; known.used = use_serial end
		if initial_action then
			cx.session:event(pane.pane, { ev = "action", id = "main", act = initial_action })
		end
		return pane.pane
	end
	-- Events sent immediately after new_block can precede host initialization.
	-- Launch args carry this one-shot action reliably, without a readiness poll.
	local args = if initial_action then { "initial_action=" .. initial_action } else nil
	local created = cx:new_block(KIND, args, "beside")
	if created == nil then
		cx:toast("error", "Herd is not loaded on this host", "Install the plugin where your panes run.")
	end
	return created
end

tern.command({
	id = "open",
	title = "Open herd console",
	icon = "users",
	run = open_herd,
})

tern.bind(if tern.runtime.os == "macos" then "cmd+alt+shift+h" else "ctrl+alt+shift+h", ACTION)

tern.command({
	id = "scope", title = "Choose Herd run scope", icon = "users",
	run = function(cx: WindowCx)
		open_herd(cx, "scope")
	end,
})


tern.command({
	id = "next_needs", title = "Next Herd terminal that needs you", icon = "users",
	run = function(cx: WindowCx) open_herd(cx, "herd_next=1") end,
})
tern.command({
	id = "previous_needs", title = "Previous Herd terminal that needs you", icon = "users",
	run = function(cx: WindowCx) open_herd(cx, "herd_next=-1") end,
})
local needs_prefix = if tern.runtime.os == "macos" then "cmd+alt+shift+" else "ctrl+alt+shift+"
tern.bind(needs_prefix .. "j", "plugin.herd.next_needs")
tern.bind(needs_prefix .. "u", "plugin.herd.previous_needs")

local function choose_scope(cx: WindowCx, block: number, request: common.WindowRequest)
	local items: { PickItem } = {
		{ label = "All terminals", run = "", current = request.address == "" },
		{ label = "Enter run label…", typed = true, detail = "Type a run label" },
	}
	local scopes: { string } = request.scopes or {}
	for _, run in scopes do
		table.insert(items, { label = "Run " .. run, run = run, current = request.address == run })
	end
	cx:pick({ items = items, placeholder = "Choose Herd run scope", icon = "users" })
		:next(function(choice: PickItem?, _err: string?, wcx: WindowCx?)
			if not choice or not wcx then return end
			if choice.typed then
				wcx:prompt({ placeholder = "Run label (run=…)", action = "switch" })
					:next(function(value: string?, _why: string?, current: WindowCx?)
						if value and current then
							current.session:event(block, { ev = "action", id = "main", act = "herd_scope=" .. tern.json.encode(value) })
						end
					end)
			else
				wcx.session:event(block, { ev = "action", id = "main", act = "herd_scope=" .. tern.json.encode(choice.run) })
			end
		end)
end

local function preview(text: string): string
	local one = string.gsub(text, "%s+", " ")
	return if #one > 80 then string.sub(one, 1, 79) .. "…" else one
end

-- Opens `hc attach` on `address` in a split right of `beside`.
local function attach(cx: WindowCx, beside: number, address: string, observe: boolean, binary: string)
	local line = common.quote(binary) .. " attach "
	if observe then
		line ..= "--observe --history 200 "
	end
	line ..= common.quote(address)
	local pane = cx.layout:split(beside, "right", { command = line }, { focus = true })
	if pane == nil then
		cx:toast("error", "Could not open a split for " .. address, line)
	end
end

local function ask_send(cx: WindowCx, block: number, address: string, label: string, generation: number?)
	cx:prompt({ placeholder = "Prompt for " .. label, icon = "send", action = "review" })
		:next(function(text: string?, _err: string?, cx2: WindowCx?)
			if text == nil or string.match(text :: string, "^%s*$") or cx2 == nil then
				return
			end
			local wcx = cx2 :: WindowCx
			wcx:pick({
				items = {
					{ label = "Send to " .. label, detail = preview(text :: string), icon = "send", go = true },
					{ label = "Cancel", icon = "x", go = false },
				},
				placeholder = "Send this prompt with hc send?",
				icon = "send",
				action = "choose",
			}):next(function(choice: PickItem?, _err2: string?, cx3: WindowCx?)
				if choice and choice.go == true and cx3 then
					local wcx3: WindowCx = cx3
					local value = tern.json.encode({ address = address, text = text, generation = generation })
					wcx3.session:event(block, { ev = "action", id = "main", act = "herd_send=" .. value })
				end
			end)
		end)
end

local function ask_interrupt(cx: WindowCx, block: number, address: string, label: string, generation: number?)
	cx:pick({
		items = {
			{ label = "Interrupt " .. label, detail = "hc interrupt " .. address, icon = "stop", go = true },
			{ label = "Cancel", icon = "x", go = false },
		},
		placeholder = "Press the stop key in " .. label .. "?",
		icon = "stop",
		action = "choose",
	}):next(function(choice: PickItem?, _err: string?, cx2: WindowCx?)
		if choice and choice.go == true and cx2 then
			local wcx: WindowCx = cx2
			wcx.session:event(block, { ev = "action", id = "main", act = "herd_interrupt=" .. tern.json.encode({ address = address, generation = generation }) })
		end
	end)
end

-- Opens a git block on a terminal's working directory (a worktree). The
-- git API is desktop-only and local: the host half sends only local
-- terminals' directories, and anything that isn't a repository fails here.
local function open_worktree(cx: WindowCx, path: string, label: string)
	local ok, err = pcall(function()
		cx.git:open(path, { how = "beside" }):next(function(pane: number?, why: string?, cx2: WindowCx?)
			if pane == nil and cx2 then
				local wcx: WindowCx = cx2
				wcx:toast("error", "Could not open a git block for " .. label, why or path)
			end
		end)
	end)
	if not ok then
		cx:toast("error", "Could not open a git block for " .. label, tostring(err))
	end
end

local function dispatch(cx: WindowCx, pane: number, request: common.WindowRequest)
	local verb, address, name = request.verb, request.address, request.label
	if verb == "watch" or verb == "attach" then
		attach(cx, pane, address, verb == "watch", request.hc)
	elseif verb == "send" then
		ask_send(cx, pane, address, name, request.generation)
	elseif verb == "interrupt" then
		ask_interrupt(cx, pane, address, name, request.generation)
	elseif verb == "worktree" then
		open_worktree(cx, address, name)
	elseif verb == "scope" then
		choose_scope(cx, pane, request)
	end
end

-- A fresh VM identity prevents a reload from executing its old grant again.
-- Window keys alone are not unique across machines; include this VM's nonce.
local nonce = tostring({}) .. ":" .. tostring(tern.now())
local completed: { [string]: boolean } = {}
local waiting: { [string]: number } = {}
local request_timer: TimerHandle? = nil
local REQUEST_MS = 100
local BACKGROUND_MS = 500

local function poll_requests(cx: WindowCx?)
	request_timer = nil
	if cx == nil then return end
	local wcx: WindowCx = cx
	local panes, current, tabs = inspect_consoles(wcx)
	local found = false
	local focused = wcx.session:focused()
	local herd_focused = false
	local present: { [string]: boolean } = {}
	local owner = wcx:window_key() .. ":" .. nonce
	for _, pane in panes do
		if current ~= nil and is_herd(pane) and pane.tab and tabs[pane.tab] == current then
			found = true
			if pane.pane == focused then herd_focused = true end
			-- Root props only: no descendants, rendered text or full-table read.
			local surface = wcx.session:surface(pane.pane, { root = "main", depth = 0, nodes = 1 })
			local root = if type(surface) == "table" then surface.main else nil
			local requests = if root and root.p then root.p.herd_requests else nil
			if type(requests) == "table" then
				for _, request in requests do
					present[request.id] = true
					local claim = tern.json.encode({ id = request.id, owner = owner })
					if request.owner == owner and not completed[request.id] then
						completed[request.id] = true
						wcx.session:event(pane.pane, { ev = "action", id = "main", act = "herd_ack=" .. claim })
						dispatch(wcx, pane.pane, request)
					elseif request.owner == nil then
						local since = waiting[request.id]
						if since == nil then
							since = tern.now()
							waiting[request.id] = since
						end
						-- Prefer a window with the console focused. No API
						-- identifies which replica originated the host input.
						if pane.pane == focused or tern.now() - since >= 200 then
							wcx.session:event(pane.pane, { ev = "action", id = "main", act = "herd_claim=" .. claim })
						end
					end
				end
			end
		end
	end
	for id in completed do if not present[id] then completed[id] = nil end end
	for id in waiting do if not present[id] then waiting[id] = nil end end
	if found then request_timer = tern.timer(if herd_focused or next(waiting) ~= nil then REQUEST_MS else BACKGROUND_MS, poll_requests) end
end

local function wake_requests(_ev: any, cx: WindowCx)
	if request_timer then request_timer:cancel(); request_timer = nil end
	poll_requests(cx)
end

-- No action polling without a Herd block in this session. Focus/lifecycle
-- changes restart the clock immediately. Use 10 Hz while focused or while
-- a seen request remains pending; otherwise idle at 2 Hz.
tern.on("pane_created", wake_requests)
tern.on("focus", wake_requests)
tern.on("tab_created", wake_requests)
tern.on("pane_closed", wake_requests)
tern.on("tab_closed", wake_requests)
tern.on("session_ended", wake_requests)
request_timer = tern.timer(0, poll_requests)

-- Status segment: the chosen console's scoped root summary, cached on a
-- timer so the formatter stays pure and fast even with only unread activity.
type Summary = { working: number, blocked: number, errors: number, unread: number, run: string }
local summary: Summary? = nil

local function same(a: Summary?, b: Summary?): boolean
	if a == nil or b == nil then
		return a == b
	end
	return a.working == b.working and a.blocked == b.blocked and a.errors == b.errors
		and a.unread == b.unread and a.run == b.run
end

local function tick(cx: WindowCx?)
	local next: Summary? = nil
	local pane = if cx then find_herd(cx) else nil
	if cx and pane then
		local surface = cx.session:surface(pane.pane, { root = "main", depth = 0, nodes = 1 })
		local root = if type(surface) == "table" then surface.main else nil
		local s = if root and root.p then root.p.herd_summary else nil
		if type(s) == "table" and type(s.working) == "number" then
			local n: Summary = { working = s.working, blocked = tonumber(s.blocked) or 0,
				errors = tonumber(s.errors) or 0, unread = tonumber(s.unread) or 0, run = s.run or "" }
			if n.working + n.blocked + n.errors + n.unread > 0 then
				next = n
			end
		end
	end
	if not same(next, summary) then
		summary = next
		tern.chrome.refresh()
	end
	tern.timer(STATUS_MS, tick)
end

tern.timer(STATUS_MS, tick)

tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	local s = summary
	if s == nil then
		return nil
	end
	local text = "herd" .. (if s.run ~= "" then " [" .. s.run .. "]" else "") .. " " .. s.working .. " working"
	if s.blocked > 0 then
		text ..= " · " .. s.blocked .. " blocked"
	end
	if s.errors > 0 then
		text ..= " · " .. s.errors .. " error"
	end
	if s.unread > 0 then
		text ..= " · " .. s.unread .. " unread"
	end
	local tone = if s.errors > 0 then "error" elseif s.blocked > 0 then "warning" elseif s.working > 0 then "info" else "muted"
	return { { text = text, icon = "users", tone = tone, command = ACTION } }
end)
