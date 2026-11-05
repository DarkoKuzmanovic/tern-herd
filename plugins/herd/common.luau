--!strict
-- Shared by both halves: the block kind, the `herd://` links the block opens
-- to ask the window half for things only a window can do (split a pane, ask
-- for text, confirm), and quoting.

local M = {}

M.KIND = "herd.herd"
M.OPEN_ACTION = "plugin.herd.open"
M.SCHEME = "herd://"

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

-- Percent-encodes everything but unreserved URL characters.
function M.encode(s: string): string
	return (string.gsub(s, "[^%w%-%._~]", function(c: string): string
		return string.format("%%%02X", string.byte(c))
	end))
end

function M.decode(s: string): string
	return (string.gsub(s, "%%(%x%x)", function(h: string): string
		return string.char(tonumber(h, 16) :: number)
	end))
end

-- `herd://<verb>/<address>[/<label>]`, each part percent-encoded. Verbs:
-- watch, attach, send, interrupt (an hc address) and worktree (whose
-- "address" is the terminal's working directory).
function M.link(verb: string, address: string, label: string?): string
	local url = M.SCHEME .. verb .. "/" .. M.encode(address)
	if label then
		url ..= "/" .. M.encode(label)
	end
	return url
end

-- The verb, address and label of a `herd://` link; nil for any other URL.
function M.parse(url: string): (string?, string?, string?)
	if string.sub(url, 1, #M.SCHEME) ~= M.SCHEME then
		return nil, nil, nil
	end
	local verb, rest = string.match(string.sub(url, #M.SCHEME + 1), "^([%w_]+)/(.+)$")
	if not verb or not rest then
		return nil, nil, nil
	end
	local addr, label = string.match(rest, "^([^/]+)/([^/]+)$")
	if addr and label then
		return verb, M.decode(addr), M.decode(label)
	end
	return verb, M.decode(rest), nil
end

-- One POSIX shell word.
function M.quote(s: string): string
	if string.match(s, "^[%w%-%._/=:@]+$") then
		return s
	end
	return "'" .. (string.gsub(s, "'", "'\\''")) .. "'"
end

return M
