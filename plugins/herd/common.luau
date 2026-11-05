--!strict
-- Shared block identity, the inert host/window action mailbox, and quoting.

local M = {}

M.KIND = "herd.herd"
M.OPEN_ACTION = "plugin.herd.open"

-- Normalized hc list row, shared without per-observation projection copies.
export type Term = {
	address: string,
	name: string?,
	agent: string,
	cwd: string,
	-- Program's 7501 word, or running when no status is reported.
	status: string,
	state: string,
	turn: number?,
	where: string,
	parent: string?,
	exit_code: number?,
	reason: string?,
}

-- `hc` by name first, then where it is installed: a daemon started by systemd
-- or a desktop launcher often has a PATH without ~/.local/bin.
local home = tern.getenv("HOME")
M.HC = { "hc" }
local paths = { "/usr/local/bin/hc", "/usr/bin/hc" }
if home then
	table.insert(paths, 1, home .. "/.local/bin/hc")
end
for _, path in paths do
	if not table.find(M.HC, path) then
		table.insert(M.HC, path)
	end
end

-- Shared kv keys for executable resolution and bounded run-scope preferences.
M.KV_HC = "hc_path"
M.KV_SCOPES = "recent_scopes"
M.KV_PANE_SCOPES = "pane_scopes"

function M.scope(value: any): string?
	if type(value) ~= "string" then return nil end
	local clean = string.match(value, "^%s*(.-)%s*$") or ""
	return if #clean > 0 and #clean <= 128 and not string.find(clean, "%c") then clean else nil
end

-- Carried as inert root-node metadata, never as a URL/open effect. The
-- serial host worker grants each request to one window before it acts.
export type WindowRequest = {
	id: string,
	verb: string,
	address: string,
	label: string,
	hc: string,
	mode: ("read" | "write")?,
	expires: number,
	owner: string?,
	generation: number?,
	scopes: { string }?,
	selection: number?,
	path: string?,
	config: string?,
}

-- One POSIX shell word.
function M.quote(s: string): string
	if string.match(s, "^[%w%-%._/=:@]+$") then
		return s
	end
	return "'" .. (string.gsub(s, "'", "'\\''")) .. "'"
end

return M
