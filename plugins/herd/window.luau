--!strict
-- Window-only actions use the block's inert surface mailbox, not URL effects.
-- The host grants each request to one window, even with multiple replicas.
-- This half also owns the palette command, key and status segment.

local common = require("./common")

local KIND = common.KIND
local ACTION = common.OPEN_ACTION
local STATUS_MS = 3000

-- The Herd block shown in this window, if any.
local function find_herd(cx: WindowCx): PaneInfo?
	for _, pane in cx.session:panes() do
		if pane.block == KIND or pane.block == "plugin." .. KIND then
			return pane
		end
	end
	return nil
end

local function open_herd(cx: WindowCx)
	local pane = find_herd(cx)
	if pane then
		if pane.parked then
			cx.layout:unpark(pane.pane)
		else
			cx.layout:focus(pane.pane)
		end
		return
	end
	if cx:new_block(KIND, nil, "beside") == nil then
		cx:toast("error", "Herd is not loaded on this host", "Install the plugin where your panes run.")
	end
end

tern.command({
	id = "open",
	title = "Open herd console",
	icon = "users",
	run = open_herd,
})

tern.bind(if tern.runtime.os == "macos" then "cmd+alt+shift+h" else "ctrl+alt+shift+h", ACTION)

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

local function ask_send(cx: WindowCx, block: number, address: string, label: string)
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
					local value = tern.json.encode({ address = address, text = text })
					wcx3.session:event(block, { ev = "action", id = "main", act = "herd_send=" .. value })
				end
			end)
		end)
end

local function ask_interrupt(cx: WindowCx, block: number, address: string, label: string)
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
			wcx.session:event(block, { ev = "action", id = "main", act = "herd_interrupt=" .. address })
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
		ask_send(cx, pane, address, name)
	elseif verb == "interrupt" then
		ask_interrupt(cx, pane, address, name)
	elseif verb == "worktree" then
		open_worktree(cx, address, name)
	end
end

-- A fresh VM identity prevents a reload from executing its old grant again.
-- Window keys alone are not unique across machines; include this VM's nonce.
local nonce = tostring({}) .. ":" .. tostring(tern.now())
local completed: { [string]: boolean } = {}
local waiting: { [string]: number } = {}
local request_timer: TimerHandle? = nil
local REQUEST_MS = 100

local function poll_requests(cx: WindowCx?)
	request_timer = nil
	if cx == nil then return end
	local wcx: WindowCx = cx
	local tabs: { [number]: boolean } = {}
	for _, session in wcx.session:sessions() do
		if session.current then
			for _, tab in session.tabs do tabs[tab] = true end
		end
	end
	local found = false
	local present: { [string]: boolean } = {}
	local owner = wcx:window_key() .. ":" .. nonce
	for _, pane in wcx.session:panes() do
		if (pane.block == KIND or pane.block == "plugin." .. KIND) and pane.tab and tabs[pane.tab] then
			found = true
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
						if pane.focused or tern.now() - since >= 200 then
							wcx.session:event(pane.pane, { ev = "action", id = "main", act = "herd_claim=" .. claim })
						end
					end
				end
			end
		end
	end
	for id in completed do if not present[id] then completed[id] = nil end end
	for id in waiting do if not present[id] then waiting[id] = nil end end
	if found then request_timer = tern.timer(REQUEST_MS, poll_requests) end
end

local function wake_requests(_ev: any, cx: WindowCx)
	if request_timer == nil then poll_requests(cx) end
end

-- No action polling without a Herd block in this session; lifecycle/focus
-- wakes it. There is no surface-update event, so a visible console needs a
-- cheap 10 Hz root-prop read to keep the claim/grant round trip responsive.
tern.on("pane_created", wake_requests)
tern.on("focus", wake_requests)
tern.on("tab_created", wake_requests)
request_timer = tern.timer(0, poll_requests)

-- Status segment: counts the host half publishes in kv while a Herd block
-- polls, read on a timer (formatters must stay pure and fast).
type Summary = { working: number, blocked: number, errors: number }
local summary: Summary? = nil

local function same(a: Summary?, b: Summary?): boolean
	if a == nil or b == nil then
		return a == b
	end
	return a.working == b.working and a.blocked == b.blocked and a.errors == b.errors
end

local function tick(cx: WindowCx?)
	local next: Summary? = nil
	if cx and find_herd(cx :: WindowCx) then
		local ok, s = pcall(tern.kv.get, common.KV_SUMMARY)
		if ok and type(s) == "table" and type(s.working) == "number" then
			local n: Summary = { working = s.working, blocked = tonumber(s.blocked) or 0, errors = tonumber(s.errors) or 0 }
			if n.working + n.blocked + n.errors > 0 then
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
	local text = "herd " .. s.working .. " working"
	if s.blocked > 0 then
		text ..= " · " .. s.blocked .. " blocked"
	end
	if s.errors > 0 then
		text ..= " · " .. s.errors .. " error"
	end
	local tone = if s.errors > 0 then "error" elseif s.blocked > 0 then "warning" elseif s.working > 0 then "info" else "muted"
	return { { text = text, icon = "users", tone = tone, command = ACTION } }
end)
