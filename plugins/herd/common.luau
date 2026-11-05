--!strict
-- Shared block identity, the inert host/window action mailbox, and quoting.

local M = {}

M.KIND = "herd.herd"
M.OPEN_ACTION = "plugin.herd.open"

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

-- kv keys both halves read: the hc the host half found, and the latest
-- status counts for the status-line segment.
M.KV_HC = "hc_path"
M.KV_SUMMARY = "summary"
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
	expires: number,
	owner: string?,
	generation: number?,
	scopes: { string }?,
}

-- One POSIX shell word.
function M.quote(s: string): string
	if string.match(s, "^[%w%-%._/=:@]+$") then
		return s
	end
	return "'" .. (string.gsub(s, "'", "'\\''")) .. "'"
end

return M
