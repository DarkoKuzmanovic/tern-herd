--!strict
-- The window half: the "Open herd console" command and its key, the
-- `herd://` link route the block uses for what only a window can do (open an
-- `hc attach` split, ask for a prompt, confirm, open a worktree's git
-- block), and a status segment "herd N working" while a Herd block is open.

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

local function hc(): string
	local ok, path = pcall(tern.kv.get, common.KV_HC)
	return if ok and type(path) == "string" and path ~= "" then path else "hc"
end

local function preview(text: string): string
	local one = string.gsub(text, "%s+", " ")
	return if #one > 80 then string.sub(one, 1, 79) .. "…" else one
end

-- Opens `hc attach` on `address` in a split right of `beside`.
local function attach(cx: WindowCx, beside: number, address: string, observe: boolean)
	local line = common.quote(hc()) .. " attach "
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

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	local verb, address, label = common.parse(link.url)
	if verb == nil or address == nil then
		return nil
	end
	local name = label or address :: string
	local pane = link.pane
	-- Splitting and opening dialogs can outlast the route hook's budget on a
	-- cold start; claim the link now and do the work on the next tick.
	tern.timer(0, function(tcx: WindowCx?)
		if tcx == nil then
			return
		end
		local wcx: WindowCx = tcx
		if verb == "watch" then
			attach(wcx, pane, address :: string, true)
		elseif verb == "attach" then
			attach(wcx, pane, address :: string, false)
		elseif verb == "send" then
			ask_send(wcx, pane, address :: string, name)
		elseif verb == "interrupt" then
			ask_interrupt(wcx, pane, address :: string, name)
		elseif verb == "worktree" then
			-- The link's "address" is the working directory.
			open_worktree(wcx, address :: string, name)
		else
			wcx:toast("error", "Unknown herd link", link.url)
		end
	end)
	return { handled = true }
end)

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
