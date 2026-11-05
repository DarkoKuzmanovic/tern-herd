--!strict
-- The `herd` block: herdr-core's terminals and agents (`hc ls --json --all`) as
-- one page: a head row, four run facts the tabs don't count (machines,
-- worktrees, turns, finished), filter tabs (All, Needs you, Working, Done),
-- the terminal tree at full width and the selected terminal's card beside it
-- (below it in a narrow pane), refreshed every two seconds.
--
-- Keys: ↑/↓ (or k/j) move, Home/End jump, 1–4 or Tab/⇧Tab pick a filter,
-- Enter (or o) watches the terminal in a split (`hc attach --observe`),
-- a attaches to type into it, l reads its last 40 lines once, s sends a
-- prompt, x interrupts, w opens its worktree in a git block, f focuses the
-- selected terminal's subtree, h shows finished terminals,
-- m mutes the toasts, r refreshes now, [/] select previous/next needs-you,
-- v opens the activity inbox; Esc closes the inbox, logs, then the focus.
-- Only s and x change terminals, and the window half asks before either.
--
-- Window-only work travels as inert surface metadata. Windows claim a
-- request through an event; this serial worker grants it to just one.
-- Confirmed send/interrupt events are still checked against the latest list.
--
-- The selected terminal's card adds `hc get <address> --json` (model, start
-- time, exit code): fetched 200 ms after the selection settles, at most once
-- every 10 seconds per terminal, and only for the selected one. Rendering
-- never starts a process.

local common = require("./common")
local activity = require("./activity")
local ui = tern.ui

local POLL_MS = 2000
local LS_TIMEOUT_MS = 10 * 1000
local GET_TIMEOUT_MS = 10 * 1000
local READ_TIMEOUT_MS = 30 * 1000
local ACT_TIMEOUT_MS = 60 * 1000
local READ_LINES = 40
local NOTICE_S = 20
local DETAIL_DEBOUNCE_MS = 200
local DETAIL_MAX_AGE_MS = 10 * 1000
local HOME = tern.getenv("HOME")

-- Layout, in cells. The table's columns are sized from the rows it shows
-- (widest cell plus padding), so the choice below is what the table can
-- really draw: Terminal, Status and Worktree always; then Turn, Agent,
-- Where (only when the rows differ) and the address after the name while
-- they fit. The card sits beside the table (at CARD_CH) only when the table
-- keeps Terminal, Status, Worktree, Turn and Agent there; otherwise it goes
-- under the table.
local CARD_CH = 48
local CARD_MIN_CH = 40
local VIEW_GAP = 2
local PAGE_PAD = 4
local COL_PAD = 2
local LEAF_MAX = 24
local NARROW_COLS = 72
-- A name past NAME_MAX cells (less its tree connectors, keeping NAME_MIN) and
-- a `where` past WHERE_MAX are cut with "…" and shown whole in the cell's
-- tooltip, so one long value can't push Where or Agent out of the table.
local NAME_MAX = 36
local NAME_MIN = 12
local WHERE_MAX = 24

-- The card's kv value column, in cells, is the card's width less the body's
-- insets (36px left past the head icon, 12px right, the ring), the key column
-- (as wide as "Children"/"Worktree" drawn in sans, plus a cell of margin) and
-- the grid's 14px column gap. Mono values are counted a cell per character.
local CARD_INSET_CH = 6
local KV_KEY_CH = 9
local KV_GAP_CH = 2

-- Heights use the window's native flex layout. The list gets the actual
-- height remaining after the chrome and card have their natural heights;
-- the four-row minimum is only a floor. Terminal-cell counts (`cx.rows`)
-- are not sans line counts and cannot safely budget this page.
-- Only natural table extents and the minimum use lines: a native table row
-- is a line plus 6px (4/3 of one), as is the toolbar plus its small gap.
local ROW_LINES = 4 / 3
-- The list never shrinks below the toolbar, the header and this many rows.
local MIN_TABLE_ROWS = 4
-- The card's lines outside its facts: head row, three action rows with their
-- gaps, and the body's padding. Beside the table the card's height (with a
-- little slack) bounds the row the two share.
local CARD_FIXED_H = 8
local MIN_LOG_LINES = 6

local FILTERS = { "all", "needs", "working", "done" }
local FILTER_LABEL: { [string]: string } = {
	all = "All",
	needs = "Needs you",
	working = "Working",
	done = "Done",
}

-- Inbox keys are deliberately limited to visible controls and needs navigation.
local INBOX_KEYS: { [string]: boolean } = {
	v = true, r = true, m = true, u = true, h = true,
	["]"] = true, ["["] = true, escape = true,
}

type Term = common.Term

-- A table row: the terminal, its depth and its tree connectors.
type Row = { t: Term, depth: number, prefix: string }

-- What a terminal said at the last poll, and since when (nil: since before
-- this block first saw it, so unknown).
type Seen = { status: string, since: number? }

type Machine = { name: string, state: string, why: string, since: number? }

-- Why the list could not be loaded: `missing` (no hc) or `failed`.
type Problem = { kind: string, text: string, detail: string? }

-- What `hc get <address> --json` adds for the card. Times are epoch seconds.
type Info = {
	state: string,
	model: string?,
	created: number?,
	finished: number?,
	exit_code: number?,
	signal: number?,
	reason: string?,
	status: string?,
	status_kind: string?,
	status_msg: string?,
	status_since: number?,
	foreground: string?,
	run: string?,
}

-- The cached `hc get` of one terminal; `at` is `tern.now()` of the last
-- answer (or failure), which rate-limits the next one.
type Detail = { info: Info?, error: string?, loading: boolean, at: number? }

-- The last lines `l` read.
type Logs = {
	address: string,
	label: string,
	text: string?,
	error: string?,
	loading: boolean,
	at: number?,
}

type Notice = { text: string, tone: string, at: number }

type Counts = { [string]: number }

type State = {
	cx: BlockCx,
	run: string?,
	scopes: { string },
	terms: { Term }?,
	observed: { Term }?,
	by_addr: { [string]: Term },
	kids: { [string]: { string } },
	rows: { Row },
	cursor: string?,
	index: number,
	hidden: number,
	machines: { Machine },
	-- How many remote machines hc lists (reachable or not).
	remotes: number,
	loading: boolean,
	gen: number,
	scope_epoch: number,
	fetched: number?,
	last_stdout: string?,
	problem: Problem?,
	timer: TimerHandle?,
	filter: string,
	subtree: string?,
	finished: boolean,
	muted: boolean,
	seen: { [string]: Seen },
	inbox: boolean,
	activity: { activity.Event },
	unread: number,
	activity_problem: string?,
	details: { [string]: Detail },
	detail_timer: TimerHandle?,
	detail_busy: boolean,
	read_busy: boolean,
	act_busy: boolean,
	scope_busy: boolean,
	pending_read: string?,
	pending_next: number?,
	logs: Logs?,
	notice: Notice?,
	requests: { common.WindowRequest },
}

-- A pane id survives a block restart; the state object identifies this run.
local running: { [number]: State } = {}

-- The hc that last started.
local hc_path: string? = nil
local request_serial = 0

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function num(v: any): number?
	return if type(v) == "number" then v else nil
end


local function recent_scopes(): { string }
	local out: { string } = {}
	local ok, saved = pcall(tern.kv.get, common.KV_SCOPES)
	if ok and type(saved) == "table" then
		for _, value in saved do
			local run = common.scope(value)
			if run and not table.find(out, run) and #out < 12 then table.insert(out, run) end
		end
	end
	return out
end

local function remember_scope(run: string?)
	if not run then return end
	local scopes = recent_scopes()
	local index = table.find(scopes, run)
	if index then table.remove(scopes, index) end
	table.insert(scopes, 1, run)
	while #scopes > 12 do table.remove(scopes) end
	pcall(tern.kv.set, common.KV_SCOPES, scopes)
end
-- Epoch milliseconds to epoch seconds.
local function secs(v: any): number?
	return if type(v) == "number" then v / 1000 else nil
end

local function retire(state: State)
	if running[state.cx.pane] == state then
		running[state.cx.pane] = nil
	end
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
	if state.detail_timer then
		state.detail_timer:cancel()
		state.detail_timer = nil
	end
	-- Pending processes may still call back; they check `alive` first.
	state.loading = false
	state.terms = nil
	state.rows = {}
	state.details = {}
	state.logs = nil
end

-- This run, not just its pane: a restart reuses the pane id. Blocks have no
-- close hook, so callbacks retire a pane that disappeared.
local function alive(state: State): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	retire(state)
	return false
end

local function first_lines(text: string, n: number): string
	local out = {}
	for line in string.gmatch(text, "[^\n]+") do
		table.insert(out, line)
		if #out == n then
			break
		end
	end
	return table.concat(out, "\n")
end

-- The last `n` lines of `text`, blank lines at either end dropped.
local function last_lines(text: string, n: number): string
	local lines = string.split(text, "\n")
	while #lines > 0 and string.match(lines[#lines], "^%s*$") do
		table.remove(lines)
	end
	local from = math.max(1, #lines - n + 1)
	while from < #lines and string.match(lines[from], "^%s*$") do
		from += 1
	end
	return table.concat(lines, "\n", from, #lines)
end

local function tilde(path: string): string
	if HOME and HOME ~= "" then
		if path == HOME then
			return "~"
		end
		if string.sub(path, 1, #HOME + 1) == HOME .. "/" then
			return "~" .. string.sub(path, #HOME + 1)
		end
	end
	return path
end

-- The last segment of a working directory: the worktree's name.
local function leaf(cwd: string): string
	if cwd == "" then
		return ""
	end
	if HOME and cwd == HOME then
		return "~"
	end
	return string.match(cwd, "([^/]+)/*$") or cwd
end

local function width(s: string): number
	return utf8.len(s) or #s
end

-- The worktree's name, cut in the middle past LEAF_MAX characters (the full
-- path is the cell's tooltip), so a long branch name can't push the other
-- columns out.
local function short_leaf(cwd: string): string
	local s = leaf(cwd)
	local n = width(s)
	if n <= LEAF_MAX or n ~= #s then
		return s
	end
	local head = (LEAF_MAX - 1) // 2
	return string.sub(s, 1, head) .. "…" .. string.sub(s, n - (LEAF_MAX - 1 - head) + 1)
end

-- A duration in seconds, compactly: `12s`, `4m`, `2h 5m`, `3d`.
local function dur(s: number): string
	local n = math.max(0, math.floor(s))
	if n < 60 then
		return n .. "s"
	elseif n < 3600 then
		return n // 60 .. "m"
	elseif n < 86400 then
		local m = (n % 3600) // 60
		return n // 3600 .. "h" .. (if m > 0 then " " .. m .. "m" else "")
	end
	return n // 86400 .. "d"
end

local function ago(t: number): string
	return dur(os.time() - t) .. " ago"
end

local function set_notice(state: State, text: string, tone: string)
	state.notice = { text = text, tone = tone, at = os.time() }
end

-- Starts `hc args…`, trying each place it may be installed; returns the last
-- spawn error when none starts.
local function run_hc(args: { string }, timeout_ms: number, done: (ProcessResult) -> ()): string?
	local candidates: { string } = {}
	if hc_path then
		table.insert(candidates, hc_path :: string)
	end
	for _, c in common.HC do
		if c ~= hc_path then
			table.insert(candidates, c)
		end
	end
	local last = "hc is not on this machine's PATH (tried " .. table.concat(common.HC, ", ") .. ")"
	for _, hc in candidates do
		if hc == "hc" or tern.fs.exists(hc) then
			local argv: { string } = { hc }
			for _, a in args do
				table.insert(argv, a)
			end
			local ok, err = pcall(function()
				tern.process.run(argv, { timeout_ms = timeout_ms, env = { NO_COLOR = "1" } }, function(result: ProcessResult, _)
					done(result)
				end)
			end)
			if ok then
				if hc_path ~= hc then
					hc_path = hc
					pcall(tern.kv.set, common.KV_HC, hc)
				end
				return nil
			end
			last = tostring(err)
		end
	end
	hc_path = nil
	return last
end

-- What a failed hc run means: hc's own `{error: {kind, message, hint}}`
-- when it printed one, else its first lines.
local function failure(result: ProcessResult, what: string, timeout_ms: number): string
	if result.timed_out then
		return what .. " timed out after " .. math.floor(timeout_ms / 1000) .. " s."
	end
	local ok, data = pcall(tern.json.decode, result.stderr)
	if ok and type(data) == "table" and type(data.error) == "table" then
		local e = data.error
		local message = str(e.message) or "failed"
		local kind = str(e.kind)
		local text = what .. (if kind then " (" .. kind .. ")" else "") .. ": " .. message
		local hint = str(e.hint)
		return if hint then text .. " " .. hint else text
	end
	local err = first_lines(result.stderr, 3)
	if err == "" then
		err = first_lines(result.stdout, 3)
	end
	return what .. " exited with status " .. result.status .. (if err ~= "" then ": " .. err else ".")
end

local function status_of(t: Term): string
	return if t.state ~= "live" then t.state else t.status
end

local function label_of(t: Term): string
	return if t.name then t.name .. " (" .. t.address .. ")" else t.address
end

local function short_of(t: Term): string
	return t.name or t.address
end

local function is_remote(address: string): boolean
	return string.find(address, "/", 1, true) ~= nil
end

-- Interrupting makes sense while the program is busy or waiting; a done,
-- idle or finished terminal has nothing to stop.
local function interruptible(t: Term): boolean
	local s = status_of(t)
	return t.state == "live" and s ~= "done" and s ~= "idle"
end

-- The terminals, hidden count, unreachable machines and number of remote
-- machines in `hc ls --json`, or nil. `status` is a word in `ls` and
-- `{app, state}` in `get`; both are read.
local function parse(stdout: string): ({ Term }?, number, { Machine }, number)
	local ok, data = pcall(tern.json.decode, stdout)
	if not ok or type(data) ~= "table" or type(data.terminals) ~= "table" then
		return nil, 0, {}, 0
	end
	local list: { Term } = {}
	for _, item in data.terminals do
		local address = if type(item) == "table" then str(item.address) else nil
		if address then
			local s = item.status
			local word = if type(s) == "table" then str(s.state) else str(s)
			local agent = str(item.agent) or (if type(s) == "table" then str(s.app) else nil) or "program"
			table.insert(list, {
				address = address,
				name = str(item.name),
				agent = agent,
				cwd = str(item.cwd) or "",
				status = word or "running",
				state = str(item.state) or "live",
				turn = num(item.turn),
				where = str(item.where) or "",
				parent = str(item.parent),
				exit_code = num(item.exit_code),
				reason = str(item.reason),
			})
		end
	end
	local machines: { Machine } = {}
	local remotes = 0
	if type(data.machines) == "table" then
		for _, m in data.machines do
			if type(m) == "table" then
				remotes += 1
				if str(m.why) then
					table.insert(machines, {
						name = str(m.name) or "?",
						state = str(m.state) or "?",
						why = m.why,
						since = secs(m.since_ms),
					})
				end
			end
		end
	end
	return list, num(data.hidden_finished) or 0, machines, remotes
end

-- The model a command line names (`-m X`, `--model X`, `--model=X`).
local function model_of(argv: any): string?
	if type(argv) ~= "table" then
		return nil
	end
	for i, a in argv do
		if type(a) == "string" then
			if (a == "-m" or a == "--model") and str(argv[i + 1]) then
				return argv[i + 1]
			end
			local v = string.match(a, "^%-%-model=(.+)$")
			if v then
				return v
			end
		end
	end
	return nil
end

-- One terminal in `hc get <address> --json`, or nil.
local function parse_info(stdout: string): Info?
	local ok, data = pcall(tern.json.decode, stdout)
	if not ok or type(data) ~= "table" or not str(data.address) then
		return nil
	end
	local s = data.status
	local fg = if type(data.foreground) == "table" then data.foreground else nil
	local labels = if type(data.labels) == "table" then data.labels else nil
	return {
		state = str(data.state) or "live",
		model = model_of(data.argv) or (if fg then model_of(fg.argv) else nil),
		created = secs(data.created_ms),
		finished = secs(data.finished_ms),
		exit_code = num(data.exit_code),
		signal = num(data.signal),
		reason = str(data.reason),
		status = if type(s) == "table" then str(s.state) else str(s),
		status_kind = if type(s) == "table" then str(s.kind) else nil,
		status_msg = if type(s) == "table" then str(s.msg) else nil,
		status_since = secs(data.status_ms),
		foreground = if fg then str(fg.name) else nil,
		run = if labels then str(labels.run) else nil,
	}
end

-- Rows for `list`: parents before their children, depth-first in hc's
-- order, with ├─ └─ │ connectors. A terminal whose parent isn't in `list` is
-- a root; a parent cycle's terminals become roots too.
local function tree(list: { Term }): { Row }
	local present: { [string]: boolean } = {}
	for _, t in list do
		present[t.address] = true
	end
	local kids: { [string]: { Term } } = {}
	local roots: { Term } = {}
	for _, t in list do
		local p = t.parent
		if p and p ~= t.address and present[p] then
			local k = kids[p] or {}
			table.insert(k, t)
			kids[p] = k
		else
			table.insert(roots, t)
		end
	end
	local out: { Row } = {}
	local seen: { [string]: boolean } = {}
	local function walk(t: Term, depth: number, guide: string, last: boolean)
		if seen[t.address] then
			return
		end
		seen[t.address] = true
		local prefix = if depth == 0 then "" else guide .. (if last then "└─ " else "├─ ")
		table.insert(out, { t = t, depth = depth, prefix = prefix })
		local children = kids[t.address]
		if children then
			local inner = if depth == 0 then "" else guide .. (if last then "  " else "│ ")
			for i, c in children do
				walk(c, depth + 1, inner, i == #children)
			end
		end
	end
	for _, r in roots do
		walk(r, 0, "", true)
	end
	for _, t in list do
		walk(t, 0, "", true)
	end
	return out
end

local function matches(filter: string, t: Term): boolean
	local s = status_of(t)
	if filter == "needs" then
		return s == "blocked" or s == "error"
	elseif filter == "working" then
		return s == "working"
	elseif filter == "done" then
		return s == "done" or s == "idle" or s == "finished"
	end
	return true
end

-- The terminals the table shows: the focused subtree (when one is), then
-- the filter.
local function visible(state: State): { Term }
	local scope: { [string]: boolean }? = nil
	local root = state.subtree
	if root and state.by_addr[root] then
		local inside: { [string]: boolean } = {}
		local stack: { string } = { root }
		while #stack > 0 do
			local a = table.remove(stack) :: string
			if not inside[a] then
				inside[a] = true
				local children: { string } = state.kids[a] or {}
				for _, c in children do
					table.insert(stack, c)
				end
			end
		end
		scope = inside
	end
	local out: { Term } = {}
	local terms: { Term } = state.terms or {}
	for _, t in terms do
		if (scope == nil or (scope :: { [string]: boolean })[t.address]) and matches(state.filter, t) then
			table.insert(out, t)
		end
	end
	return out
end

local function counts(state: State): Counts
	local c: Counts = {}
	local terms: { Term } = state.terms or {}
	for _, t in terms do
		local s = status_of(t)
		c[s] = (c[s] or 0) + 1
	end
	return c
end

-- Ledger reads/writes happen in callbacks, never in view/title formatters.
-- Every console caches its own scope's history; a read/clear is shared.
local function sync_activity()
	for _, state in running do
		if alive(state) then
			state.scopes = recent_scopes()
			state.activity = activity.list(state.run)
			state.unread = activity.unread(state.run)
			state.activity_problem = activity.status()
			state.cx:render()
		end
	end
end

-- Fetches the card's `hc get` for `address`, unless one is running or the
-- last answer is younger than 10 seconds.
local function fetch_detail(state: State, address: string)
	if state.detail_busy then return end
	local d = state.details[address]
	if d and (d.loading or (d.at and tern.now() - (d.at :: number) < DETAIL_MAX_AGE_MS)) then
		return
	end
	local entry: Detail = d or { info = nil, error = nil, loading = false, at = nil }
	entry.loading = true
	state.detail_busy = true
	state.details[address] = entry
	local spawn_error = run_hc({ "get", address, "--json" }, GET_TIMEOUT_MS, function(result)
		if not alive(state) then return end
		state.detail_busy = false
		if state.details[address] ~= entry then
			if state.cursor then fetch_detail(state, state.cursor) end
			return
		end
		entry.loading = false
		entry.at = tern.now()
		if result.status == 0 then
			local info = parse_info(result.stdout)
			if info then
				entry.info = info
				remember_scope(info.run)
				if info.run then
					activity.note_run(address, info.run)
					sync_activity()
				end
				entry.error = nil
			else
				entry.error = "hc get printed something other than a terminal."
			end
		else
			entry.error = failure(result, "hc get", GET_TIMEOUT_MS)
		end
		state.cx:render()
	end)
	if spawn_error then
		state.detail_busy = false
		entry.loading = false
		entry.at = tern.now()
		entry.error = "Tern could not start hc: " .. spawn_error
	end
end

-- Fetches the selected terminal's card 200 ms after the selection last
-- moved, so holding ↓ starts no process per row.
local function schedule_detail(state: State)
	if state.detail_timer then
		state.detail_timer:cancel()
		state.detail_timer = nil
	end
	local address = state.cursor
	if address == nil then
		return
	end
	state.detail_timer = tern.timer(DETAIL_DEBOUNCE_MS, function()
		if not alive(state) then
			return
		end
		state.detail_timer = nil
		if state.cursor == address then
			fetch_detail(state, address)
			state.cx:render()
		end
	end)
end

local function set_cursor(state: State, address: string?, index: number)
	local before = state.cursor
	state.cursor = address
	state.index = index
	if address ~= before then
		schedule_detail(state)
	end
end

-- Rebuilds the rows and keeps the cursor on its terminal, else on the row
-- where it was.
local function rebuild(state: State)
	state.rows = tree(visible(state))
	for i, r in state.rows do
		if r.t.address == state.cursor then
			state.index = i
			return
		end
	end
	local n = #state.rows
	local i = math.clamp(state.index, 1, math.max(1, n))
	local row = state.rows[i]
	set_cursor(state, if row then row.t.address else nil, if row then i else 0)
end

-- Navigate the complete current-scope tree, not a filtered or focused view.
-- Opening a console queues only the latest direction for its normal first list.
local function next_needs(state: State, step: number): boolean
	local terms = state.terms
	if terms == nil then
		state.pending_next = step
		set_notice(state, if state.problem
			then "No current list is available; navigation will wait for the next successful refresh."
			else "Waiting for the first list; will select the " .. (if step == 1 then "next" else "previous") .. " terminal that needs you.", "muted")
		return false
	end
	local ordered = tree(terms)
	local at = if step == 1 then 0 else #ordered + 1
	for i, row in ordered do
		if row.t.address == state.cursor then at = i; break end
	end
	local fetched = state.fetched
	local stale = state.problem ~= nil or (fetched ~= nil and os.time() - fetched > 2 * POLL_MS / 1000)
	for offset = 1, #ordered do
		local row = ordered[(at - 1 + step * offset) % #ordered + 1]
		if matches("needs", row.t) then
			state.inbox = false
			state.subtree = nil
			state.filter = "needs"
			set_cursor(state, row.t.address, 1)
			rebuild(state)
			set_notice(state, "Selected " .. label_of(row.t) .. (if stale
				then " from the cached list; it may be out of date."
				else " — needs you."), if stale then "warning" else "muted")
			return true
		end
	end
	set_notice(state, "No blocked or errored terminals in this scope" .. (if stale
		then " in the cached list; it may be out of date." else "."), if stale then "warning" else "muted")
	return false
end

-- Only newly added ledger events toast, once globally even when several
-- consoles observe the same transition. Prefer any alive, unmuted relevant
-- console, not necessarily the observer that happened to finish its poll first.
local function announce(events: { activity.Event })
	for _, event in events do
		local recipient: State? = nil
		local terminal: Term? = nil
		for _, candidate in running do
			if not candidate.muted and alive(candidate) then
				local relevant = candidate.run == nil or table.find(event.runs, candidate.run :: string) ~= nil
				local observed: { Term } = candidate.observed or {}
				for _, t in observed do
					if t.address == event.address then
						terminal = t
						relevant = true
						break
					end
				end
				if relevant and (recipient == nil or candidate.cx.pane < recipient.cx.pane) then
					recipient = candidate
				end
			end
		end
		if recipient == nil then continue end
		local name = event.name or event.address
		local to = event.status
		local level: ToastLevel = "info"
		local text = name .. " is " .. to
		if to == "blocked" then
			text = name .. " is blocked"
		elseif to == "error" then
			level, text = "error", name .. " reported an error"
		elseif to == "finished" then
			local code = event.exit_code
			level = if code == nil or code == 0 then "success" else "error"
			text = name .. " finished" .. (if code then " (exit " .. code .. ")" else "")
		elseif to == "done" then
			level = "success"
		end
		recipient.cx:toast(level, text, if terminal and terminal.cwd ~= "" then tilde(terminal.cwd) else nil)
	end
end

-- Finished visibility is presentation only. The full snapshot drives status
-- ages and history, including non-selected finishes while h is off.
local function present(state: State)
	local terms: { Term } = {}
	local by: { [string]: Term } = {}
	local hidden = 0
	local observed: { Term } = state.observed or {}
	for _, t in observed do
		if t.state == "finished" and not state.finished then
			hidden += 1
		else
			table.insert(terms, t)
			by[t.address] = t
		end
	end
	local kids: { [string]: { string } } = {}
	for _, t in terms do
		local parent = t.parent
		if parent and parent ~= t.address and by[parent] then
			local children = kids[parent] or {}
			table.insert(children, t.address)
			kids[parent] = children
		end
	end
	state.terms, state.by_addr, state.kids = terms, by, kids
	state.hidden = hidden
	local root = state.subtree
	if root and not by[root] then
		state.subtree = nil
		set_notice(state, "Focus cleared: " .. root .. " left the list.", "muted")
	end
	local details: { [string]: Detail } = {}
	for address, detail in state.details do
		if by[address] then details[address] = detail end
	end
	state.details = details
	local pending = state.pending_next
	state.pending_next = nil
	if pending == nil or not next_needs(state, pending) then rebuild(state) end
end

local function apply(state: State, terms: { Term }, machines: { Machine }, remotes: number, request_at: number)
	local now = os.time()
	local seen: { [string]: Seen } = {}
	for _, t in terms do
		local status = status_of(t)
		local previous = state.seen[t.address]
		seen[t.address] = if previous == nil then { status = status, since = nil }
			elseif previous.status ~= status then { status = status, since = now }
			else previous
	end
	local cursor = state.cursor
	local old = if cursor then state.by_addr[cursor] else nil
	state.seen, state.observed = seen, terms
	state.machines, state.remotes = machines, remotes
	local events = activity.observe(terms, state.run, request_at)
	-- Details already cached by All can establish a run association without
	-- introducing discovery requests or per-row detail polling.
	for _, t in terms do
		local detail = state.details[t.address]
		local info = if detail then detail.info else nil
		if info and info.run then activity.note_run(t.address, info.run) end
	end
	present(state)
	if old and not state.by_addr[old.address] then
		local finished: Term? = nil
		for _, t in terms do
			if t.address == old.address and t.state == "finished" then finished = t; break end
		end
		if finished then
			local code = finished.exit_code
			set_notice(state, label_of(old) .. " finished" .. (if code then " with exit " .. code else "")
				.. ".  h shows finished terminals.", if code == nil or code == 0 then "success" else "error")
		else
			set_notice(state, label_of(old) .. " left the list.", "muted")
		end
	end
	announce(events)
	sync_activity()
end

local function ls_args(state: State): { string }
	local args = { "ls", "--json", "--all" }
	if state.run then
		table.insert(args, "--label")
		table.insert(args, "run=" .. (state.run :: string))
	end
	return args
end

local function refresh(state: State)
	if not alive(state) or state.loading then
		return
	end
	state.loading = true
	local gen = state.gen
	local request_at = tern.now()
	local spawn_error = run_hc(ls_args(state), LS_TIMEOUT_MS, function(result)
		if not alive(state) then
			return
		end
		state.loading = false
		if gen ~= state.gen then
			-- The run scope changed while this request was in flight.
			refresh(state)
			return
		end
		if result.status ~= 0 then
			state.problem = { kind = "failed", text = failure(result, "hc ls", LS_TIMEOUT_MS) }
		elseif result.stdout == state.last_stdout then
			-- The same list as last time: nothing changed but the clock.
			state.problem = nil
			state.fetched = os.time()
			-- Still advance request ordering and associate known run labels.
			local observed: { Term } = state.observed or {}
			announce(activity.observe(observed, state.run, request_at))
			sync_activity()
		else
			local terms, _hidden, machines, remotes = parse(result.stdout)
			if terms then
				state.last_stdout = result.stdout
				state.problem = nil
				state.fetched = os.time()
				apply(state, terms, machines, remotes, request_at)
			else
				state.problem = {
					kind = "failed",
					text = "hc ls printed something other than its JSON list.",
					detail = string.sub(result.stdout, 1, 200),
				}
			end
		end
		-- The selected card refreshes at most every 10 s; while the selection
		-- is still moving, the debounce timer fetches it instead.
		if state.cursor and not state.detail_timer then
			fetch_detail(state, state.cursor :: string)
		end
		state.cx:render()
	end)
	if spawn_error then
		state.loading = false
		state.problem = { kind = "missing", text = "Tern could not start hc.", detail = spawn_error }
		state.cx:render()
	end
end

local function switch_scope(state: State, value: string)
	local run = common.scope(value)
	if value ~= "" and run == nil then
		set_notice(state, "Run labels must be 1–128 characters without control characters.", "warning")
		return
	end
	if run == state.run then return end
	state.run = run
	remember_scope(run)
	state.gen += 1
	state.scope_epoch += 1
	state.pending_read = nil
	state.pending_next = nil
	state.requests = {}
	state.terms = nil
	state.observed = nil
	state.by_addr, state.kids, state.rows = {}, {}, {}
	state.cursor, state.subtree = nil, nil
	state.index = 1
	state.details, state.seen = {}, {}
	state.logs, state.last_stdout, state.fetched, state.problem = nil, nil, nil, nil
	if state.detail_timer then state.detail_timer:cancel(); state.detail_timer = nil end
	local ok, saved = pcall(tern.kv.get, common.KV_PANE_SCOPES)
	local entries: { any } = if ok and type(saved) == "table" then saved else {}
	local next_entries: { any } = { { pane = state.cx.pane, run = run or "" } }
	for _, entry in entries do
		if type(entry) == "table" and entry.pane ~= state.cx.pane and #next_entries < 32 then
			table.insert(next_entries, entry)
		end
	end
	pcall(tern.kv.set, common.KV_PANE_SCOPES, next_entries)
	set_notice(state, if run then "Run " .. run else "All terminals", "muted")
	sync_activity()
	refresh(state)
end

-- One pending timer per live run.
local function poll(state: State)
	if not alive(state) or state.timer then
		return
	end
	state.timer = tern.timer(POLL_MS, function()
		if not alive(state) then
			return
		end
		state.timer = nil
		refresh(state)
		state.cx:render()
		poll(state)
	end)
end

-- Reads the selected terminal, or a logs card's explicit target, once.
local function read_logs(state: State, address: string?)
	if state.read_busy then
		state.pending_read = address or state.cursor
		set_notice(state, "Waiting for the current read; the latest logs request is queued.", "muted")
		return
	end
	local target = address or state.cursor
	local t = if target then state.by_addr[target :: string] else nil
	if not t then
		set_notice(state, "No terminal selected.", "muted")
		return
	end
	local term: Term = t
	local previous = state.logs
	local logs: Logs = {
		address = term.address,
		label = label_of(term),
		text = if previous and previous.address == term.address then previous.text else nil,
		error = nil,
		loading = true,
		at = nil,
	}
	state.logs = logs
	state.read_busy = true
	local spawn_error = run_hc({ "read", term.address, "--lines", tostring(READ_LINES) }, READ_TIMEOUT_MS, function(result)
		if not alive(state) then return end
		state.read_busy = false
		local pending = state.pending_read
		state.pending_read = nil
		if state.logs ~= logs then
			if pending then read_logs(state, pending) end
			return
		end
		logs.loading = false
		logs.at = os.time()
		if result.status == 0 then
			logs.text = last_lines(result.stdout, READ_LINES)
			logs.error = nil
		else
			logs.error = failure(result, "hc read", READ_TIMEOUT_MS)
		end
		state.cx:render()
		if pending then read_logs(state, pending) end
	end)
	if spawn_error then
		state.read_busy = false
		logs.loading = false
		logs.error = "Tern could not start hc: " .. spawn_error
	end
end

-- Runs a confirmed send or interrupt and reports how it went.
local function act(state: State, verb: string, args: { string }, label: string)
	if state.act_busy then
		set_notice(state, "An action is still running; wait for its result.", "warning")
		return
	end
	state.act_busy = true
	set_notice(state, (if verb == "send" then "Sending to " else "Interrupting ") .. label .. "…", "muted")
	local spawn_error = run_hc(args, ACT_TIMEOUT_MS, function(result)
		if not alive(state) then
			return
		end
		state.act_busy = false
		if result.status == 0 then
			local said = first_lines(result.stdout, 1)
			local ok, data = pcall(tern.json.decode, result.stdout)
			if ok and type(data) == "table" then
				said = str(data.what) or str(data.result) or str(data.status) or ""
			end
			local head = if verb == "send" then "Sent to " .. label else "Interrupted " .. label
			set_notice(state, head .. (if said ~= "" then ": " .. string.sub(said, 1, 120) else "."), "success")
		else
			set_notice(state, failure(result, "hc " .. verb, ACT_TIMEOUT_MS), "error")
		end
		state.cx:render()
		refresh(state)
	end)
	if spawn_error then
		state.act_busy = false
		set_notice(state, "Tern could not start hc: " .. spawn_error, "error")
	end
end

-- Views.

local TONES: { [string]: string } = {
	working = "info",
	blocked = "warning",
	error = "error",
	done = "success",
	idle = "muted",
	finished = "muted",
}

-- The status word's span tokens: blocked and error take a weight step.
local WORDS: { [string]: string } = {
	working = "info",
	blocked = "warning strong",
	error = "error strong",
	done = "success",
	idle = "muted",
	finished = "muted",
}

-- Icons Tern ships for the programs hc reports (Elements › Data › Icon
-- names); any other agent is shown as text.
local AGENT_ICONS: { [string]: string } = {
	codex = "app-codex",
	hermes = "app-hermes",
	omp = "app-omp",
	claude = "app-claude",
	pi = "pi-mark",
	python = "app-python",
	python3 = "app-python",
	node = "app-node",
	bun = "app-bun",
	deno = "app-deno",
	docker = "app-docker",
	vim = "app-vim",
	nvim = "app-vim",
	htop = "app-htop",
	btop = "app-btop",
	zsh = "terminal",
	bash = "terminal",
	sh = "terminal",
	fish = "terminal",
}

local function button(label: string, action: string, props: { [string]: any }?): Node
	local p: { [string]: any } = props or {}
	p.key = p.key or action
	p.actions = { click = action }
	return ui.button(label, p)
end

-- How long the terminal has said its status, when this block saw it change.
local function since_of(state: State, t: Term): number?
	local s = state.seen[t.address]
	return if s and s.status == status_of(t) then s.since else nil
end

local function status_cell(state: State, t: Term): Cell
	local s = status_of(t)
	if s == "running" then
		local plain: TextCell = { text = ui.span("–", "dim"), title = "A plain program: it reports no status" }
		return plain
	end
	local spans: { Span | string } = { ui.span(s, WORDS[s] or "muted") }
	if s == "finished" then
		local code = t.exit_code
		if code then
			table.insert(spans, ui.span("  exit " .. code, if code == 0 then "muted" else "error"))
		end
	else
		local since = since_of(state, t)
		if since then
			table.insert(spans, ui.span("  " .. dur(os.time() - since), "muted"))
		end
	end
	local cell: TextCell = { text = spans, dot = TONES[s] or "muted" }
	return cell
end

local function agent_cell(t: Term): Cell
	local icon = AGENT_ICONS[t.agent]
	if icon then
		local cell: TextCell = { text = t.agent, icon = icon }
		return cell
	end
	return t.agent
end

-- At most `n` cells of `s`, cut at the end with "…" (the full text goes in
-- the cell's tooltip).
local function clip(s: string, n: number): string
	if width(s) <= n then
		return s
	end
	local cut = utf8.offset(s, n)
	return if cut then string.sub(s, 1, cut - 1) .. "…" else s
end

-- The machine of a remote address (`build-box/t10` → `build-box`).
local function machine_of(address: string): string?
	return string.match(address, "^(.+)/[^/]+$")
end

-- What a named remote terminal shows before its name, so the machine stays
-- visible even when the address after the name doesn't fit: `machine/`.
-- A nameless terminal shows its whole address, machine included.
local function machine_tag(t: Term): string
	local m = if t.name then machine_of(t.address) else nil
	return if m then m .. "/" else ""
end

-- The name as the Terminal column draws it: cut so a very long name can't
-- take the room of Where and the other columns.
local function shown_name(r: Row): string
	local lead = width(r.prefix) + width(machine_tag(r.t))
	return clip(r.t.name or r.t.address, math.max(NAME_MIN, NAME_MAX - lead))
end

-- The address after a name: its local part when the machine already leads.
local function shown_address(t: Term): string
	return if machine_tag(t) ~= "" then string.match(t.address, "[^/]+$") or t.address else t.address
end

local function name_cell(r: Row, address: boolean): Cell
	local t = r.t
	local spans: { Span | string } = {}
	if r.prefix ~= "" then
		table.insert(spans, ui.span(r.prefix, "dim mono"))
	end
	local tag = machine_tag(t)
	if tag ~= "" then
		table.insert(spans, ui.span(tag, "muted mono"))
	end
	local name = shown_name(r)
	table.insert(spans, ui.span(name, if r.depth == 0 then "strong" else nil))
	if t.name and address then
		table.insert(spans, ui.span("  " .. shown_address(t), "muted mono"))
	end
	if name ~= (t.name or t.address) then
		local cell: TextCell = { text = spans, title = label_of(t) }
		return cell
	end
	return spans
end

local function where_cell(t: Term): Cell
	local text = clip(t.where, WHERE_MAX)
	local cell: TextCell = { text = { ui.span(text, "muted") }, title = if text ~= t.where then t.where else nil }
	return cell
end

local function worktree_cell(t: Term): Cell
	local cell: TextCell = { text = short_leaf(t.cwd), title = if t.cwd ~= "" then t.cwd else nil }
	return cell
end

-- What the view draws at this width: the card beside or under the table,
-- and which optional columns the table keeps.
type Layout = {
	beside: boolean,
	narrow: boolean,
	address: boolean,
	agent: boolean,
	turn: boolean,
	where: boolean,
}

-- Picks the layout from the widest cell of each column (headers included),
-- in one pass over the rows.
local function layout(state: State, cols: number): Layout
	local name_w, name_addr_w = width("Terminal"), width("Terminal")
	local agent_w, status_w, turn_w = width("Agent"), width("Status"), width("Turn")
	local tree_w, where_w = width("Worktree"), width("Where")
	-- Where is worth a column only when the rows disagree; a uniform value
	-- stays in the card and reserves no room here.
	local where_first: string? = nil
	local where_mixed = false
	for _, r in state.rows do
		local t = r.t
		local base = width(r.prefix) + width(machine_tag(t)) + width(shown_name(r))
		name_w = math.max(name_w, base)
		name_addr_w = math.max(name_addr_w, base + (if t.name then 2 + width(shown_address(t)) else 0))
		agent_w = math.max(agent_w, width(t.agent) + (if AGENT_ICONS[t.agent] then 2 else 0))
		local s = status_of(t)
		-- dot, word, and room for "  2h 5m" or "  exit 127"
		status_w = math.max(status_w, 2 + width(s) + (if since_of(state, t) or t.exit_code then 10 else 0))
		turn_w = math.max(turn_w, #(if t.turn then tostring(t.turn) else ""))
		tree_w = math.max(tree_w, width(short_leaf(t.cwd)))
		where_w = math.max(where_w, width(clip(t.where, WHERE_MAX)))
		if where_first == nil then
			where_first = t.where
		elseif t.where ~= where_first then
			where_mixed = true
		end
	end
	local core = name_w + status_w + tree_w + 3 * COL_PAD
	local turn = turn_w + COL_PAD
	local agent = agent_w + COL_PAD
	local beside_room = cols - PAGE_PAD - CARD_CH - VIEW_GAP
	local beside = beside_room >= core + turn + agent
	local room = if beside then beside_room else cols - PAGE_PAD
	local used = core
	local function fits(extra: number): boolean
		if used + extra <= room then
			used += extra
			return true
		end
		return false
	end
	-- Where (when the rows differ) wins over the address after each name:
	-- the address is also in the card's head.
	local has_turn = fits(turn)
	local has_agent = fits(agent)
	local has_where = where_mixed and fits(where_w + COL_PAD)
	local has_address = fits(name_addr_w - name_w)
	return {
		beside = beside,
		narrow = cols < NARROW_COLS,
		address = has_address,
		agent = has_agent,
		turn = has_turn,
		where = has_where,
	}
end

local function head_view(state: State): Node
	local spans: { Span | string } = { ui.span("Herd", "title") }
	local meta = "   herdr-core · " .. (if state.run then "run " .. (state.run :: string) else "All terminals")
	if state.loading and not state.fetched then
		meta ..= " · loading"
	elseif state.fetched then
		meta ..= " · updated " .. os.date("%H:%M:%S", state.fetched)
	end
	table.insert(spans, ui.span(meta, "muted"))
	if state.subtree then
		local root = state.by_addr[state.subtree :: string]
		table.insert(spans, ui.span(" · focus " .. (if root then short_of(root) else state.subtree :: string), "accent"))
	end
	if state.problem and state.terms and state.fetched then
		table.insert(spans, ui.span(" · stale, " .. dur(os.time() - (state.fetched :: number)) .. " old", "warning"))
	end
	local function toggle(label: string, icon: string, action: string, on: boolean, key: string, title: string): Node
		return button(label, action, {
			icon = icon,
			variant = "quiet",
			on = on,
			keys = { key },
			title = title,
		})
	end
	local controls: { Node } = {
		button("Run…", "scope", { icon = "tag", keys = { "u" }, title = "Switch run scope" }),
		ui.node("row", { key = "activity_control", gap = "xs", align = "center" }, {
			toggle("Activity", "history", "activity", state.inbox, "v", "Observed activity inbox; opening does not mark read"),
			ui.badge(tostring(state.unread), if state.unread > 0 then "accent" else "muted"),
		}),
		toggle("Finished", "history", "finished", state.finished, "h", "Show or hide finished terminal rows"),
		toggle("Mute", "bell", "mute", state.muted, "m", "Mute status toasts"),
		button("Refresh", "refresh", {
			icon = "repeat",
			keys = { "r" },
			busy = state.loading,
			title = "Refresh now",
		}),
	}
	-- Let the window wrap at its actual sans width: cx.cols is terminal
	-- geometry and can describe a much wider pane on another client.
	return ui.node("row", { key = "head", justify = "between", align = "center", gap = "md", wrap = true }, {
		ui.node("text", { key = "title", spans = spans, basis = "content", max = { w = 1 } }),
		ui.node("row", { key = "end", gap = "sm", align = "center", wrap = true,
			basis = "content", max = { w = 1 } }, controls),
	})
end

-- Facts about the run that the tabs don't already count (the tabs and the
-- toolbar carry the status counts and the total): where the terminals run,
-- how many worktrees they use, how much work the turn counters add up to,
-- and the finished terminals out of view. One pass over the list.
local function stats_view(state: State, c: Counts): Node
	local terms: { Term } = state.terms or {}
	local per_cwd: { [string]: number } = {}
	local worktrees, shared, turns, counted = 0, 0, 0, 0
	local busiest: Term? = nil
	for _, t in terms do
		if t.cwd ~= "" then
			local n = (per_cwd[t.cwd] or 0) + 1
			per_cwd[t.cwd] = n
			if n == 1 then
				worktrees += 1
			elseif n == 2 then
				shared += 1
			end
		end
		local turn = t.turn
		if turn then
			counted += 1
			turns += turn
			if busiest == nil or turn > ((busiest :: Term).turn :: number) then
				busiest = t
			end
		end
	end
	local unreachable = #state.machines
	local busy = busiest
	local finished = if state.finished then c.finished or 0 else state.hidden

	local items: { StatItem } = {
		{
			label = "Machines",
			value = tostring(1 + state.remotes),
			tone = if unreachable > 0 then "warning" else nil,
			sub = if unreachable > 0 then unreachable .. " unreachable"
				elseif state.remotes > 0 then "all connected"
				else "this one only",
			title = "This machine plus the remote machines hc lists",
		},
		{
			label = "Worktrees",
			value = tostring(worktrees),
			sub = if shared > 0 then shared .. " shared" elseif worktrees > 0 then "one per terminal" else nil,
			title = "Distinct working directories of the listed terminals",
		},
		{
			label = "Turns",
			value = if counted > 0 then tostring(turns) else "–",
			sub = if busy then "most " .. (busy.turn :: number) .. " · " .. short_of(busy) else "none report turns",
			title = "hc's turn counters, summed over the listed terminals",
		},
		{
			label = "Finished",
			value = tostring(finished),
			sub = if state.finished then "listed · h hides" elseif finished > 0 then "hidden · h shows" else "none hidden",
			title = "Finished terminals in the full observation; h only controls row visibility",
		},
	}
	local node = ui.stats(items)
	local p: { [string]: any } = node.p or {}
	p.key = "stats"
	p.role = "herd.stats"
	node.p = p
	return node
end

local function tabs_view(state: State, c: Counts): Node
	local items = {}
	for _, id in FILTERS do
		local label: { Span | string } = { ui.span(FILTER_LABEL[id]) }
		if id == "needs" then
			local n = (c.blocked or 0) + (c.error or 0)
			if n > 0 then
				table.insert(label, ui.span(" " .. n, "muted"))
			end
		end
		table.insert(items, { id = id, label = label })
	end
	return ui.node("tabs", { key = "filter", active = state.filter, items = items })
end

-- One warning card per machine hc can't reach, with hc's reason.
local function machines_view(state: State): Node?
	if #state.machines == 0 then
		return nil
	end
	local cards: { Node } = {}
	for i, m in state.machines do
		local meta = if m.since then "since " .. ago(m.since :: number) else nil
		local card = ui.card({ ui.span(m.name, "strong"), ui.span("  " .. string.gsub(m.state, "_", " "), "warning") }, {
			ui.text(ui.span(m.why, "muted")),
		}, { key = "m" .. i, icon = "warn", tone = "warning", meta = meta })
		table.insert(cards, card)
	end
	return ui.node("col", { key = "machines", gap = "sm" }, cards)
end

local function empty_text(state: State): string
	local f = state.filter
	local under = if state.subtree then " under " .. (state.subtree :: string) else ""
	if f == "needs" then
		return "Nothing" .. under .. " needs you right now."
	elseif f == "working" then
		return "No terminal" .. under .. " is working."
	elseif f == "done" then
		return "Nothing" .. under .. " is done yet." .. (if state.finished then "" else "  h shows finished terminals.")
	end
	return "No terminals" .. under .. "."
end

local function description(state: State): string
	local text = if state.filter == "needs"
		then "Blocked or failed, waiting for you"
		elseif state.filter == "working" then "In a turn now"
		elseif state.filter == "done" then "Done, idle or finished"
		else "Parents before their children"
	local root = state.subtree
	if root then
		local t = state.by_addr[root]
		text = "Under " .. (if t then short_of(t) else root) .. " · " .. text
	end
	return text .. " · " .. #state.rows .. " of " .. #(state.terms or {})
end

local function table_view(state: State, lay: Layout): Node
	local terms = state.terms or {}
	if #terms == 0 and state.filter == "all" and not state.subtree then
		local hidden = state.hidden
		local text = if state.finished then "hc has no terminals here."
			elseif hidden > 0 then hidden .. " finished terminals are hidden."
			else "Start one with hc run --bg -- <command>."
		local action = if not state.finished and hidden > 0
			then button("Show finished", "finished", { keys = { "h" } })
			else button("Refresh", "refresh", { icon = "repeat", keys = { "r" } })
		return ui.node("empty", {
			key = "table",
			variant = "inline",
			frame = true,
			icon = "terminal",
			title = if state.finished then "No hc terminals" else "No live hc terminals",
			text = text,
		}, { action })
	end
	-- Priorities match the drop order above, so if Tern still runs short it
	-- hides Where, then Agent, then Turn, and keeps Worktree.
	local cols: { Col } = {
		{ id = "name", head = "Terminal", grow = 1, truncate = "end", priority = 9 },
	}
	if lay.agent then
		table.insert(cols, { id = "agent", head = "Agent", priority = 3 })
	end
	table.insert(cols, { id = "status", head = "Status", priority = 8 })
	if lay.turn then
		table.insert(cols, { id = "turn", head = "Turn", align = "end", mono = true, priority = 4 })
	end
	table.insert(cols, { id = "tree", head = "Worktree", truncate = "middle", mono = true, priority = 7 })
	if lay.where then
		table.insert(cols, { id = "where", head = "Where", priority = 1 })
	end
	local rows: { TableRow } = {}
	for _, r in state.rows do
		local t = r.t
		local cells: { Cell } = { name_cell(r, lay.address) }
		if lay.agent then
			table.insert(cells, agent_cell(t))
		end
		table.insert(cells, status_cell(state, t))
		if lay.turn then
			table.insert(cells, if t.turn then tostring(t.turn) else "")
		end
		table.insert(cells, worktree_cell(t))
		if lay.where then
			table.insert(cells, where_cell(t))
		end
		table.insert(rows, { id = t.address, cells = cells, title = if t.cwd ~= "" then t.cwd else nil })
	end
	local node = ui.table(cols, rows, { selectable = true, selected = state.cursor, empty = empty_text(state) })
	local p: { [string]: any } = node.p or {}
	p.key = "table"
	node.p = p
	return node
end

-- The table's height in lines for `n` rows plus the header (each a line
-- plus 6px).
local function table_h(n: number): number
	return math.ceil((n + 1) * ROW_LINES)
end

-- How short the list (toolbar over the table box) may get, in lines: the
-- toolbar's line and the 6px under it are one row's worth, then the header
-- and MIN_TABLE_ROWS rows. Nil when the table has no more rows than that, so
-- the list keeps its natural height and never needs to shrink.
local function list_floor(state: State): number?
	if #state.rows <= MIN_TABLE_ROWS then
		return nil
	end
	return table_h(MIN_TABLE_ROWS + 1)
end

-- The table (or its empty state) in a box no taller than the table. With
-- `fill` the box takes the list's height left under the toolbar (see the
-- view): when that is less than the table it scrolls with a persistent bar.
-- No fade covers the selected row. The table keeps its selection in view
-- as the cursor moves. The rows stay one table in tree
-- order, so the connectors never depend on what fits.
local function table_box(state: State, lay: Layout, fill: boolean): Node
	local n = #state.rows
	return ui.node("scroll", {
		key = "rows",
		variant = "bar",
		bar = "always",
		grow = if fill then 1 else nil,
		basis = if fill then 0 else nil,
		max = if n > 0 then { h = table_h(n) .. "lines" } else nil,
	}, {
		table_view(state, lay),
	})
end

-- Keeps a part of the page at its natural height (`basis = "content"`: its
-- own size, never shrunk), so only the list gives or takes height.
local function fixed(node: Node): Node
	local p: { [string]: any } = node.p or {}
	p.basis = "content"
	node.p = p
	return node
end

local function toolbar_view(state: State): Node
	local children: { Node } = { ui.node("text", { key = "about", spans = { ui.span(description(state), "muted") } }) }
	if state.subtree then
		table.insert(children, button("Clear focus", "clear_focus", { variant = "quiet", keys = { "esc" } }))
	end
	return ui.node("row", { key = "bar", justify = "between", align = "center", gap = "md" }, children)
end

local function selected(state: State): Term?
	return if state.cursor then state.by_addr[state.cursor :: string] else nil
end

-- The selected terminal's card at its natural height, and that height in
-- lines as far as the card's own content tells it: the parts outside the
-- facts, a line per fact and one per extra line a fact or an error breaks
-- onto. Beside the table it is the floor of the row the two share.
local function detail_view(state: State, wide: boolean, cols: number): (Node, number)
	local size: { [string]: any } = { key = "detail" }
	if wide then
		size.min = { w = CARD_MIN_CH .. "ch" }
		size.max = { w = CARD_CH .. "ch" }
	end
	local t = selected(state)
	if not t then
		return ui.card("No terminal selected", {
			ui.text(ui.span("Select a terminal to see its model, parent and worktree.", "muted")),
		}, size), 3
	end
	local term: Term = t
	local d = state.details[term.address]
	local info = if d then d.info else nil
	local waiting = if d then d.loading and info == nil else true
	local s = status_of(term)

	local status: { Span | string } = {}
	if s == "running" then
		table.insert(status, ui.span("no status", "muted"))
		table.insert(status, ui.span(" · a plain program", "muted"))
	else
		table.insert(status, ui.span(s, WORDS[s] or "muted"))
		-- How long: hc's own `status_ms` (when it says the same word), else
		-- the change this block saw; a first sight has neither.
		if s ~= "finished" then
			if info and info.status == s and info.status_since then
				local age = dur(os.time() - (info.status_since :: number))
				table.insert(status, ui.span(" · for " .. age .. ", per hc", "muted"))
			else
				local since = since_of(state, term)
				table.insert(status, ui.span(
					if since then " · for " .. dur(os.time() - (since :: number)) .. ", seen here" else " · since unknown",
					"muted"
				))
			end
		end
		if info and info.status_kind and s == "blocked" then
			table.insert(status, ui.span(" · " .. (info.status_kind :: string), "warning"))
		end
	end

	local function later(v: string?, missing: string): Spans
		if v then
			return ui.span(v :: string, "mono")
		end
		return ui.span(if waiting then "fetching…" else missing, "muted")
	end

	local parent: Spans = ui.span("none", "muted")
	if term.parent then
		local p = state.by_addr[term.parent :: string]
		parent = if p then label_of(p) else ui.span(term.parent :: string, "mono")
	end
	local children = #(state.kids[term.address] or {})

	local function fact(label: string, value: Spans): { Spans }
		local row: { Spans } = { label, value }
		return row
	end

	local items: { { Spans } } = {
		fact("Status", status),
	}
	if info and info.status_msg then
		table.insert(items, fact("Says", info.status_msg :: string))
	end
	local agent: Spans = term.agent
	if info and info.foreground and info.foreground ~= term.agent then
		local spans: { Span | string } = { ui.span(term.agent), ui.span(" · running " .. (info.foreground :: string), "muted") }
		agent = spans
	end
	table.insert(items, fact("Agent", agent))
	table.insert(items, fact("Model", later(if info then info.model else nil, "not in its command line")))
	table.insert(items, fact("Turn", ui.span(if term.turn then tostring(term.turn) else "–", "mono")))
	table.insert(items, fact("Started", later(if info and info.created then ago(info.created :: number) else nil, "unknown")))
	if term.state ~= "live" or (info and info.state ~= "live") then
		local code = if info and info.exit_code ~= nil then info.exit_code else term.exit_code
		local spans: { Span | string } = {}
		if code ~= nil then
			table.insert(spans, ui.span("exit " .. code, if code == 0 then "mono" else "mono error"))
		elseif info and info.signal then
			table.insert(spans, ui.span("signal " .. (info.signal :: number), "mono error"))
		else
			table.insert(spans, ui.span("finished", "muted"))
		end
		local reason = if info and info.reason then info.reason else term.reason
		if reason then
			table.insert(spans, ui.span(" · " .. string.gsub(reason :: string, "_", " "), "muted"))
		end
		if info and info.finished then
			table.insert(spans, ui.span(" · " .. ago(info.finished :: number), "muted"))
		end
		table.insert(items, fact("Exit", spans))
	end
	table.insert(items, fact("Parent", parent))
	table.insert(items, fact("Children", if children > 0 then ui.span(tostring(children), "mono") else ui.span("none", "muted")))
	local cwd = tilde(term.cwd)
	-- One line when the whole path fits the value column; otherwise break
	-- before the distinctive leaf so it isn't split at the card's edge. A
	-- card with a long path grows to CARD_CH beside the table.
	local value_ch = math.max(1, (if wide then CARD_CH else cols - PAGE_PAD) - CARD_INSET_CH - KV_KEY_CH - KV_GAP_CH)
	local directory, leaf_name = string.match(cwd, "^(.*)/([^/]+)$")
	local cwd_lines = if directory and leaf_name and width(cwd) > value_ch then directory .. "/\n" .. leaf_name else cwd
	table.insert(items, fact("Worktree", if cwd_lines ~= "" then ui.span(cwd_lines, "mono") else ui.span("unknown", "muted")))
	if term.where ~= "" then
		table.insert(items, fact("Where", term.where))
	end
	if info and info.run then
		table.insert(items, fact("Run", ui.span(info.run :: string, "mono")))
	end

	local body: { Node } = {}
	table.insert(body, ui.node("row", { key = "end", gap = "sm" }, {
		button("Watch", "watch", { variant = "primary", size = "sm", icon = "eye", keys = { "enter" } }),
	}))
	local facts = #items + (if string.find(cwd_lines, "\n", 1, true) then 1 else 0)
	if info and info.status_msg then
		facts += math.max(0, math.ceil(width(info.status_msg :: string) / value_ch) - 1)
	end
	if waiting then
		-- The first `hc get` for this terminal is on its way (a remote one
		-- can take seconds); say what is being asked, not how long.
		local m = machine_of(term.address)
		table.insert(body, ui.node("shimmer", {
			key = "fetching",
			text = "Fetching details" .. (if m then " from " .. m else "") .. "…",
		}))
		facts += 1
	end
	table.insert(body, ui.kv(items))
	if d and d.error then
		table.insert(body, ui.text(ui.span(d.error :: string, "error")))
		facts += math.ceil(width(d.error :: string) / (value_ch + KV_KEY_CH + KV_GAP_CH))
	end
	local why_not_interrupt: string? = if interruptible(term)
		then nil
		else short_of(term) .. " is " .. s .. "; there is nothing to interrupt"
	local why_not_tree: string? = if is_remote(term.address)
		then "Worktrees open on this machine only"
		elseif term.cwd == "" then "hc reports no working directory"
		else nil
	-- Actions in deliberate groups: what reaches the terminal (attach, read,
	-- send), then where to look (its worktree, its subtree), then the one
	-- destructive action alone at the end of its own row.
	table.insert(body, ui.node("col", { key = "actions", gap = "md" }, {
		ui.node("col", { key = "safe", gap = "sm" }, {
			ui.node("row", { key = "use", gap = "sm", wrap = true }, {
				button("Attach", "attach", { size = "sm", keys = { "a" } }),
				button("Logs", "logs", { size = "sm", keys = { "l" } }),
				button("Send…", "send", { size = "sm", keys = { "s" }, disabled = if term.state == "live" then nil else "It has finished" }),
			}),
			ui.node("row", { key = "go", gap = "sm", wrap = true }, {
				button("Worktree", "worktree", { size = "sm", keys = { "w" }, disabled = why_not_tree }),
				button("Focus", "focus", { size = "sm", keys = { "f" }, on = state.subtree == term.address }),
			}),
		}),
		ui.node("row", { key = "danger", gap = "sm", justify = "end" }, {
			button("Interrupt…", "interrupt", {
				size = "sm",
				variant = "danger",
				keys = { "x" },
				disabled = why_not_interrupt,
			}),
		}),
	}))

	local meta = if term.name then term.address else nil
	size.icon = AGENT_ICONS[term.agent] or "terminal"
	size.meta = meta
	-- The card is in `page` when stacked, in its `view` row when beside.
	size["end"] = if wide then "main.page.view.detail.end" else "main.page.detail.end"
	return ui.card({ ui.span(term.name or term.address, "strong") }, body, size), CARD_FIXED_H + facts
end

local function logs_view(state: State, logs: Logs): Node
	local meta: { Span | string } = { ui.span("last " .. READ_LINES .. " lines", "muted") }
	if logs.loading then
		table.insert(meta, ui.span(" · reading…", "muted"))
	elseif logs.at then
		table.insert(meta, ui.span(" · read " .. os.date("%H:%M:%S", logs.at), "muted"))
	end
	if not state.by_addr[logs.address] then
		table.insert(meta, ui.span(" · gone from hc ls", "warning"))
	end
	local body: { Node } = {
		ui.node("row", { key = "end", gap = "sm" }, {
			button("Read again", "logs_again", { variant = "quiet", size = "sm", keys = { "l" } }),
			button("Close", "close_logs", { variant = "quiet", size = "sm", keys = { "esc" } }),
		}),
	}
	if logs.error then
		table.insert(body, ui.text(ui.span(logs.error :: string, "error")))
	end
	if logs.text then
		-- The newest lines matter most: a box half the pane tall that starts
		-- at the end and scrolls up through the rest.
		local fit = math.clamp(math.floor(state.cx.rows / 2), MIN_LOG_LINES, READ_LINES)
		table.insert(body, ui.node("scroll", { key = "out", stick = "end", noun = "line", max = { h = fit .. "lines" } }, {
			ui.ansi(logs.text :: string),
		}))
	elseif logs.loading then
		table.insert(body, ui.node("shimmer", { text = "hc read " .. logs.address .. " --lines " .. READ_LINES }))
	end
	return ui.card({ ui.span(logs.label, "strong") }, body, {
		key = "logs",
		icon = "terminal",
		meta = meta,
		["end"] = "main.page.logs.end",
	})
end

-- Metadata only: no terminal output, prompts, cwd or commands enter this view.
-- The ledger caps the newest-first cache at 100 events; the list scrolls in
-- the same remaining-height region as the terminal table.
local function activity_view(state: State): Node
	local scope = if state.run then "run " .. (state.run :: string) else "All terminals"
	local children: { Node } = {
		ui.node("row", { key = "toolbar", justify = "between", align = "center", gap = "sm", wrap = true }, {
			ui.text({ ui.span("Activity", "strong"), ui.span(" · " .. scope .. " · " .. state.unread .. " unread", "muted") }),
			ui.node("row", { key = "actions", gap = "sm", wrap = true }, {
				button("Mark read", "activity_read", { variant = "quiet", disabled = state.unread == 0,
					title = "Mark this scope's retained activity read in every console" }),
				button("Clear", "activity_clear", { variant = "quiet", disabled = #state.activity == 0,
					title = "Remove this scope's retained events from shared history; keep transition baselines" }),
				button("Back", "activity_back", { variant = "quiet", keys = { "esc" } }),
			}),
		}),
		ui.text(ui.span("Observed history, not a complete audit. Newest first; opening does not mark read.", "muted")),
	}
	if state.activity_problem then
		table.insert(children, ui.text(ui.span(state.activity_problem :: string, "warning")))
	end
	local rows: { Node } = {}
	for _, event in state.activity do
		local status = event.status .. (if event.exit_code ~= nil then " · exit " .. event.exit_code else "")
		local name = if event.name then event.name .. " (" .. event.address .. ")" else event.address
		table.insert(rows, ui.node("col", { key = "event_" .. event.id, role = "herd.activity.event", gap = "xs" }, {
			ui.node("row", { key = "meta", gap = "sm", align = "center", wrap = true }, {
				ui.text(ui.span(os.date("%Y-%m-%d %H:%M:%S", event.at), "muted mono")),
				ui.text(ui.span(status, WORDS[event.status] or "muted")),
				ui.badge(if event.read then "read" else "unread", if event.read then "muted" else "accent"),
			}),
			ui.text(ui.span(name, if event.read then "muted" else "strong")),
		}))
	end
	if #rows == 0 then
		table.insert(children, ui.node("empty", { key = "empty", variant = "inline", frame = true,
			icon = "history", title = if state.activity_problem then "Activity unavailable" else "No observed activity",
			text = if state.activity_problem then "Refresh to retry reading history."
				else "Transitions observed while a console polls will appear here. A run includes only known scope associations." }))
	else
		table.insert(children, ui.node("scroll", { key = "entries", grow = 1, basis = 0,
			min = { h = "6lines" }, noun = "event" }, {
			ui.node("col", { key = "events", gap = "md" }, rows),
		}))
	end
	return ui.node("col", { key = "activity", role = "herd.activity", gap = "md", grow = 1,
		basis = 0, min = { h = "12lines" } }, children)
end

local function problem_view(problem: Problem): Node
	local help = if problem.kind == "missing"
		then "The Herd block runs `hc ls --json --all` on the machine that runs your panes. Install herdr-core there "
			.. "(`hc` in ~/.local/bin, /usr/local/bin or /usr/bin), then press **r**."
		elseif string.find(problem.text, "server status", 1, true) then "Press **r** to try again."
		else "`hc server status` says whether herdr-core is running. Press **r** to try again."
	local children: { Node } = {
		ui.node("row", { key = "end", gap = "sm" }, {
			button("Retry", "retry", { icon = "repeat", keys = { "r" } }),
		}),
		ui.md(problem.text .. " " .. help),
	}
	if problem.detail and problem.detail ~= "" then
		table.insert(children, ui.code(problem.detail :: string))
	end
	return ui.card(
		{ ui.span(if problem.kind == "missing" then "hc not found" else "Could not list hc terminals", "strong") },
		children,
		{ key = "view", icon = "warn", tone = "error", ["end"] = "main.view.end" }
	)
end

-- The dock's key legend: only what has no button on screen (moving the
-- selection, Enter on a row, the filter keys); every other action shows its
-- keycap on its own button. Shorter when narrow.
local LEGEND: { { string } } = {
	{ "↑↓", "select" },
	{ "home/end", "jump" },
	{ "enter", "watch" },
	{ "1–4 tab", "filter" },
	{ "[/]", "needs you" },
}
local LEGEND_SHORT: { { string } } = {
	{ "↑↓", "select" },
	{ "enter", "watch" },
	{ "tab", "filter" },
	{ "[/]", "needs" },
}

local function legend(compact: boolean): Node
	local spans: { Span | string } = {}
	local entries: { { string } } = if compact then LEGEND_SHORT else LEGEND
	for _, entry in entries do
		table.insert(spans, ui.span(entry[1], "key"))
		table.insert(spans, ui.span(" " .. entry[2] .. "  ", "muted"))
	end
	return ui.node("text", { key = "keys", spans = spans })
end

local function dock_view(state: State, compact: boolean): Node
	local lines: { Node } = {}
	local n = state.notice
	if n and os.time() - n.at < NOTICE_S then
		table.insert(lines, ui.node("text", { key = "notice", spans = { ui.span(n.text, n.tone) } }))
	end
	local problem = state.problem
	if problem and state.terms then
		table.insert(lines, ui.node("text", {
			key = "problem",
			spans = { ui.span(problem.text, "warning"), ui.span("  showing the last list", "muted") },
		}))
	end
	if not state.inbox then table.insert(lines, legend(compact)) end
	return ui.col({ ui.lines(lines) })
end

local function move(state: State, to: number)
	local n = #state.rows
	local i = math.clamp(to, 1, math.max(1, n))
	local r = state.rows[i]
	if r then
		set_cursor(state, r.t.address, i)
	end
end

local function set_filter(state: State, filter: string)
	if FILTER_LABEL[filter] == nil or filter == state.filter then
		return
	end
	state.filter = filter
	rebuild(state)
end

local function cycle_filter(state: State, step: number)
	local at = table.find(FILTERS, state.filter) or 1
	set_filter(state, FILTERS[(at - 1 + step) % #FILTERS + 1])
end

local function toggle_subtree(state: State)
	if state.subtree then
		state.subtree = nil
	else
		local t = selected(state)
		if not t then
			set_notice(state, "No terminal selected.", "muted")
			return
		end
		state.subtree = t.address
	end
	rebuild(state)
end

local function toggle_finished(state: State)
	state.finished = not state.finished
	-- No request generation change, baseline reset or extra poll: h only
	-- projects the last complete observation into visible terminal rows.
	if state.observed then present(state) end
	set_notice(state, if state.finished then "Showing finished terminals." else "Hiding finished terminals.", "muted")
end

local function toggle_mute(state: State)
	state.muted = not state.muted
	set_notice(state, if state.muted then "Toasts muted." else "Toasts on.", "muted")
end

local function enqueue_window(state: State, verb: string, address: string, label: string)
	if #state.requests >= 16 then
		set_notice(state, "Too many pending Herd actions; wait for a window to respond.", "warning")
		return
	end
	request_serial += 1
	local request: common.WindowRequest = {
		id = tostring(tern.now()) .. ":" .. request_serial,
		verb = verb, address = address, label = label,
		hc = hc_path or "hc", expires = tern.now() + 5000,
		generation = state.scope_epoch,
		scopes = if verb == "scope" then recent_scopes() else nil,
	}
	table.insert(state.requests, request)
	tern.timer(5000, function()
		if not alive(state) then return end
		for i, pending in state.requests do
			if pending.id == request.id then
				table.remove(state.requests, i)
				set_notice(state, "No Herd window completed " .. verb .. " for " .. label .. "; try again.", "warning")
				state.cx:render()
				break
			end
		end
	end)
end

-- Bare `hc --json` retains Terminal.labels, unlike the reduced `hc ls`
-- projection. Discover live run labels once when asked, not per row/poll.
local function choose_scope(state: State)
	if state.scope_busy then return end
	state.scope_busy = true
	local generation = state.scope_epoch
	local spawn_error = run_hc({ "--json" }, LS_TIMEOUT_MS, function(result)
		if not alive(state) then return end
		state.scope_busy = false
		if state.scope_epoch ~= generation then return end
		local ok, data = pcall(tern.json.decode, result.stdout)
		if result.status == 0 and ok and type(data) == "table" and type(data.terminals) == "table" then
			local found: { [string]: boolean } = {}
			local total = 0
			for _, terminal in data.terminals do
				local run = if type(terminal) == "table" and type(terminal.labels) == "table"
					then common.scope(terminal.labels.run) else nil
				if run and not found[run] then
					remember_scope(run)
					found[run] = true
					total += 1
					if total == 12 then break end
				end
			end
		else
			set_notice(state, "Run discovery unavailable; choose a remembered label or type one.", "warning")
		end
		enqueue_window(state, "scope", state.run or "", "Run scope")
		sync_activity()
		state.cx:render()
	end)
	if spawn_error then
		state.scope_busy = false
		enqueue_window(state, "scope", state.run or "", "Run scope")
	end
end

-- Ask one window to do `verb` for the selected terminal. Never broadcast an
-- open effect: replicas without window.luau would launch a system browser.
local function ask_window(state: State, cx: BlockCx, verb: string)
	if verb == "scope" then
		choose_scope(state)
		return
	end
	local t = selected(state)
	if not t then
		set_notice(state, "No terminal selected.", "muted")
		return
	end
	local term: Term = t
	if verb == "interrupt" and not interruptible(term) then
		set_notice(state, label_of(term) .. " is " .. status_of(term) .. "; nothing to interrupt.", "muted")
		return
	end
	if verb == "send" and term.state ~= "live" then
		set_notice(state, label_of(term) .. " has finished; nothing reads a prompt.", "muted")
		return
	end
	if verb == "worktree" then
		if is_remote(term.address) then
			set_notice(state, label_of(term) .. " runs on another machine; worktrees open on this one only.", "muted")
			return
		end
		if term.cwd == "" then
			set_notice(state, "hc reports no working directory for " .. label_of(term) .. ".", "muted")
			return
		end
		enqueue_window(state, verb, term.cwd, short_of(term))
		return
	end
	enqueue_window(state, verb, term.address, label_of(term))
end

-- Button clicks, and `herd_send=<json {address, text}>` /
-- `herd_interrupt=<address>` from the window half after the person
-- confirmed. A confirmed action is checked again against the latest list:
-- the terminal may have finished while the dialog was open.
local function on_action(state: State, cx: BlockCx, act_name: string, value: string?)
	if (act_name == "herd_claim" or act_name == "herd_ack") and value then
		local ok, claim = pcall(tern.json.decode, value)
		if ok and type(claim) == "table" and type(claim.owner) == "string" then
			for i, request in state.requests do
				if request.id == claim.id and tern.now() < request.expires then
					if act_name == "herd_claim" and request.owner == nil then
						request.owner = claim.owner
					elseif act_name == "herd_ack" and request.owner == claim.owner then
						table.remove(state.requests, i)
					end
					break
				end
			end
		end
		return
	end
	if act_name == "retry" or act_name == "refresh" then
		refresh(state)
		sync_activity()
	elseif act_name == "activity" then
		state.inbox = not state.inbox
		sync_activity()
	elseif act_name == "activity_back" then
		state.inbox = false
	elseif act_name == "activity_read" then
		activity.mark_read(state.run)
		sync_activity()
	elseif act_name == "activity_clear" then
		activity.clear(state.run)
		sync_activity()
	elseif act_name == "scope" then
		ask_window(state, cx, "scope")
	elseif act_name == "herd_scope" and value then
		local ok, run = pcall(tern.json.decode, value)
		if ok and type(run) == "string" then switch_scope(state, run) end
	elseif act_name == "herd_next" and (value == "1" or value == "-1") then
		next_needs(state, if value == "1" then 1 else -1)
	elseif act_name == "finished" then
		toggle_finished(state)
	elseif act_name == "mute" then
		toggle_mute(state)
	elseif act_name == "watch" or act_name == "attach" or act_name == "send" or act_name == "interrupt" or act_name == "worktree" then
		ask_window(state, cx, act_name)
	elseif act_name == "logs" then
		read_logs(state)
	elseif act_name == "logs_again" and state.logs then
		read_logs(state, (state.logs :: Logs).address)
	elseif act_name == "close_logs" then
		state.logs = nil
	elseif act_name == "focus" then
		toggle_subtree(state)
	elseif act_name == "clear_focus" then
		state.subtree = nil
		rebuild(state)
	elseif act_name == "herd_send" and value then
		local ok, data = pcall(tern.json.decode, value)
		if ok and type(data) == "table" and str(data.address) and type(data.text) == "string" and data.generation == state.scope_epoch then
			local t = state.by_addr[data.address]
			if not t or t.state ~= "live" then
				set_notice(state, "Not sent: " .. data.address .. " is no longer live.", "warning")
			else
				act(state, "send", { "send", data.address, data.text }, label_of(t))
			end
		end
	elseif act_name == "herd_interrupt" and value and value ~= "" then
		local ok, data = pcall(tern.json.decode, value)
		if not ok or type(data) ~= "table" or data.generation ~= state.scope_epoch or type(data.address) ~= "string" then return end
		local t = state.by_addr[data.address]
		if not t then
			set_notice(state, "Not interrupted: " .. data.address .. " left the list.", "warning")
		elseif not interruptible(t) then
			set_notice(state, "Not interrupted: " .. label_of(t) .. " is " .. status_of(t) .. " now.", "warning")
		else
			act(state, "interrupt", { "interrupt", data.address }, label_of(t))
		end
	end
end

tern.block.define("herd", {
	font = "sans",

	init = function(cx: BlockCx, args: { string }, saved: any): State
		local previous = running[cx.pane]
		if previous then
			retire(previous)
		end
		local s: any = if type(saved) == "table" then saved else {}
		local run: string? = nil
		local initial_action: string? = nil
		for _, a in args do
			local v = string.match(a, "^run=(.+)$")
			if v then
				run = v
			end
			local action = string.match(a, "^initial_action=(.+)$")
			if action == "scope" or action == "herd_next=1" or action == "herd_next=-1" then
				initial_action = action
			end
		end
		if s.run ~= nil then
			run = common.scope(s.run)
		else
			local ok, entries = pcall(tern.kv.get, common.KV_PANE_SCOPES)
			if ok and type(entries) == "table" then
				for _, entry in entries do
					if type(entry) == "table" and entry.pane == cx.pane then run = common.scope(entry.run); break end
				end
			end
		end
		remember_scope(run)
		local filter = str(s.filter)
		local state: State = {
			cx = cx,
			run = run,
			scopes = recent_scopes(),
			terms = nil,
			observed = nil,
			by_addr = {},
			kids = {},
			rows = {},
			cursor = str(s.cursor),
			index = 1,
			hidden = 0,
			machines = {},
			remotes = 0,
			loading = false,
			gen = 0,
			scope_epoch = tern.now(),
			fetched = nil,
			last_stdout = nil,
			problem = nil,
			timer = nil,
			filter = if filter and FILTER_LABEL[filter] then filter else "all",
			subtree = str(s.subtree),
			finished = s.finished == true,
			muted = s.muted == true,
			seen = {},
			inbox = false,
			activity = activity.list(run),
			unread = activity.unread(run),
			activity_problem = activity.status(),
			details = {},
			detail_timer = nil,
			detail_busy = false,
			read_busy = false,
			act_busy = false,
			scope_busy = false,
			pending_read = nil,
			pending_next = nil,
			logs = nil,
			notice = nil,
			requests = {},
		}
		running[cx.pane] = state
		refresh(state)
		poll(state)
		-- Launch actions are for the first init only, never replayed on restore.
		if saved == nil and initial_action then
			local name, value = string.match(initial_action, "^([%w_]+)=(.*)$")
			on_action(state, cx, name or initial_action, value)
		end
		return state
	end,

	title = function(state: State): string?
		local c = counts(state)
		local parts: { string } = {}
		if c.working then
			table.insert(parts, c.working .. " working")
		end
		local needs = (c.blocked or 0) + (c.error or 0)
		if needs > 0 then
			table.insert(parts, needs .. " need you")
		end
		if state.unread > 0 then table.insert(parts, state.unread .. " unread") end
		local title = if state.run then "Herd · " .. (state.run :: string) else "Herd · All terminals"
		return if #parts > 0 then title .. " · " .. table.concat(parts, " · ") else title
	end,

	view = function(state: State, cx: BlockCx): BlockView
		local lay = layout(state, cx.cols)
		local wide = lay.beside
		local compact = lay.narrow
		local main: { Node } = { fixed(head_view(state)) }
		if state.inbox then
			table.insert(main, activity_view(state))
		elseif state.terms then
			-- The scoped manifest sheet bounds the real page flex column
			-- to this window's main region. Natural-height chrome and the
			-- card keep their measured sizes; the list uses what remains.
			-- Its four-row minimum is a floor, never the normal height.
			local c = counts(state)
			table.insert(main, fixed(stats_view(state, c)))
			local m = machines_view(state)
			if m then
				table.insert(main, fixed(m))
			end
			table.insert(main, fixed(tabs_view(state, c)))
			local floor = list_floor(state)
			local n = #state.rows
			-- The list's natural height: the toolbar's line and the gap under
			-- it are one row's worth, then the header and the rows.
			local natural = table_h(n + 1)
			local list = ui.node("col", {
				key = "list",
				gap = "sm",
				grow = if wide or floor then 1 else nil,
				basis = if wide or floor then 0 else "content",
				min = if floor and not wide then { h = floor .. "lines" } else nil,
				max = if floor and not wide then { h = natural .. "lines" } else nil,
			}, {
				fixed(toolbar_view(state)),
				table_box(state, lay, floor ~= nil),
			})
			local card, card_lines = detail_view(state, wide, cx.cols)
			if wide then
				-- The card's content is the floor of the shared row, not a
				-- cap: longer facts must remain reachable in short panes.
				local card_h = card_lines + 2
				table.insert(main, ui.node("row", {
					key = "view",
					gap = "lg",
					align = "stretch",
					grow = if floor then 1 else nil,
					basis = if floor then 0 else "content",
					min = if floor then { h = math.max(floor, card_h) .. "lines" } else nil,
				}, { list, card }))
			else
				table.insert(main, list)
				table.insert(main, fixed(card))
			end
			if state.logs then
				table.insert(main, fixed(logs_view(state, state.logs :: Logs)))
			end
		elseif state.problem then
			local m = machines_view(state)
			if m then
				table.insert(main, m)
			end
			table.insert(main, problem_view(state.problem :: Problem))
		else
			table.insert(main, ui.node("skeleton", { key = "stats", shape = "card", tiles = 4 }))
			table.insert(main, ui.node("skeleton", { key = "view", shape = "rows", rows = 6 }))
		end
		local summary_counts = counts(state)
		return {
			main = ui.node("col", { role = "herd.console", herd_requests = state.requests,
				herd_scope = state.run or "", herd_scopes = state.scopes, herd_generation = state.scope_epoch,
				herd_cursor = state.cursor or "", herd_inbox = state.inbox,
				herd_activity = state.activity, herd_unread = state.unread,
				herd_summary = { working = summary_counts.working or 0, blocked = summary_counts.blocked or 0,
					errors = summary_counts.error or 0, unread = state.unread, run = state.run or "" } }, {
				ui.node("col", { key = "page", role = "herd.page", gap = "lg" }, main),
			}),
			dock = if state.terms or state.notice or state.inbox then dock_view(state, compact) else nil,
		}
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		if key.ctrl or key.alt or key.meta then
			return false
		end
		local k = key.text or key.name
		if state.inbox and not (INBOX_KEYS[k] or INBOX_KEYS[key.name]) then
			-- Do not steer an invisible selected terminal from the inbox.
			return false
		end
		local i = state.index
		if k == "v" then
			on_action(state, cx, "activity")
		elseif key.name == "tab" then
			cycle_filter(state, if key.shift then -1 else 1)
		elseif k == "1" or k == "2" or k == "3" or k == "4" then
			set_filter(state, FILTERS[tonumber(k) :: number])
		elseif k == "]" or k == "[" then
			next_needs(state, if k == "]" then 1 else -1)
		elseif key.name == "up" or k == "k" then
			move(state, i - 1)
		elseif key.name == "down" or k == "j" then
			move(state, i + 1)
		elseif key.name == "page_up" then
			move(state, i - 10)
		elseif key.name == "page_down" then
			move(state, i + 10)
		elseif key.name == "home" or k == "g" then
			move(state, 1)
		elseif key.name == "end" or k == "G" then
			move(state, #state.rows)
		elseif key.name == "enter" or k == "o" then
			ask_window(state, cx, "watch")
		elseif k == "a" then
			ask_window(state, cx, "attach")
		elseif k == "l" then
			read_logs(state)
		elseif k == "s" then
			ask_window(state, cx, "send")
		elseif k == "x" then
			ask_window(state, cx, "interrupt")
		elseif k == "w" then
			ask_window(state, cx, "worktree")
		elseif k == "f" then
			toggle_subtree(state)
		elseif k == "h" then
			toggle_finished(state)
		elseif k == "m" then
			toggle_mute(state)
		elseif k == "u" then
			ask_window(state, cx, "scope")
		elseif k == "r" then
			refresh(state)
			sync_activity()
		elseif key.name == "escape" then
			-- Back out one layer: inbox, logs, then focus.
			if state.inbox then
				state.inbox = false
			elseif state.logs then
				state.logs = nil
			elseif state.subtree then
				state.subtree = nil
				rebuild(state)
			else
				return false
			end
		else
			return false
		end
		return true
	end,

	event = function(state: State, ev: UiEvent, cx: BlockCx)
		if ev.ev == "action" and type(ev.act) == "string" then
			-- View actions arrive split into act and value; an event the window
			-- half sends with `session:event` keeps `name=value` whole.
			local name, value = string.match(ev.act, "^([%w_]+)=(.*)$")
			if name then
				on_action(state, cx, name, value)
			else
				on_action(state, cx, ev.act, if type(ev.value) == "string" then ev.value else nil)
			end
		elseif ev.ev == "select" and type(ev.id) == "string" and string.match(ev.id, "%.filter$") then
			if type(ev.item) == "string" then
				set_filter(state, ev.item)
			end
		elseif (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
			for i, r in state.rows do
				if r.t.address == ev.item then
					move(state, i)
					if ev.ev == "activate" then
						ask_window(state, cx, "watch")
					end
					break
				end
			end
		end
		cx:render()
	end,

	save = function(state: State): any
		return {
			run = state.run or "",
			cursor = state.cursor,
			filter = state.filter,
			subtree = state.subtree,
			finished = state.finished,
			muted = state.muted,
		}
	end,
})
