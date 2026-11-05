--!strict
-- Shared relative preferences; discovery is host-only. The scan caller owns
-- selection, cadence and callback liveness. GNU find paths remain inert argv.

local M = {}

export type Spec = { label: string, path: string }
export type Match = { label: string, path: string? }

type Target = { directory: string, basename: string, parents: { string } }
type Mtime = { negative: boolean, seconds: string, fraction: string }

local KV_SPECS = "artifact_specs"
local MAX_SPECS = 8
local MAX_STDOUT = 64 * 1024
local MAX_RECORDS = 256

function M.defaults(): { Spec }
	return {
		{ label = "Report", path = ".scratch/report.md" },
		{ label = "Review", path = ".scratch/review-*.md" },
		{ label = "Brief", path = ".scratch/brief.md" },
	}
end

local function text(value: any, maximum: number): boolean
	-- Bound work before decoding UTF-8; each character uses at most four bytes.
	if type(value) ~= "string" or #value == 0 or #value > maximum * 4 then return false end
	local ok, length = pcall(utf8.len, value)
	if not ok or length == nil or length < 1 or length > maximum then return false end
	if string.find(value, "%c") then return false end
	-- %c covers ASCII controls; UTF-8 C1 controls are controls too.
	for _, codepoint in utf8.codes(value) do
		if codepoint >= 0x80 and codepoint <= 0x9f then return false end
	end
	return true
end

local function relative_path(path: string): boolean
	if string.sub(path, 1, 1) == "/" or string.match(path, "^%a:") then return false end
	-- At most one '*' is supported, only in the final component. Backslash
	-- would otherwise change find's glob interpretation of a literal basename.
	for _, char in { "?", "[", "]", "{", "}", "\\" } do
		if string.find(path, char, 1, true) then return false end
	end
	local basename = string.match(path, "([^/]+)$")
	if basename == nil or basename == "." or basename == ".." then return false end
	local star = string.find(basename, "*", 1, true)
	if star and string.find(basename, "*", star + 1, true) then return false end
	local parent = string.sub(path, 1, #path - #basename)
	if string.find(parent, "*", 1, true) then return false end
	for segment in string.gmatch(path, "[^/]+") do
		if segment == ".." then return false end
	end
	return true
end

local function validate(input: any): ({ Spec }?, string?)
	if type(input) ~= "table" then return nil, "Artifact specs must be an array" end
	local count = 0
	for key in input do
		count += 1
		if count > MAX_SPECS then return nil, "Use at most 8 artifact specs" end
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > MAX_SPECS then
			return nil, "Artifact specs must be a contiguous array"
		end
	end
	if count == 0 and tern.json.encode(input) ~= "[]" then
		return nil, "Artifact specs must be an array"
	end
	-- Preserve [] through KV and prompt encoding; a bare empty table is {}.
	local specs: { Spec } = tern.json.array()
	for index = 1, count do
		local entry = input[index]
		if type(entry) ~= "table" then return nil, "Each artifact spec needs a label and path" end
		if not text(entry.label, 32) then return nil, "Artifact labels need 1–32 characters without controls" end
		if not text(entry.path, 256) then return nil, "Artifact paths need 1–256 characters without controls" end
		if not relative_path(entry.path) then
			return nil, "Artifact paths must be relative, without '..'; at most one basename '*' is allowed"
		end
		table.insert(specs, { label = entry.label, path = entry.path })
	end
	return specs, nil
end

function M.config(): { Spec }
	local ok, saved = pcall(tern.kv.get, KV_SPECS)
	if ok and saved ~= nil then
		local specs = validate(saved)
		if specs then return specs end
	end
	return M.defaults()
end

function M.configure(input: any): (boolean, string?)
	local specs, err = validate(input)
	if not specs then return false, err end
	local ok = pcall(tern.kv.set, KV_SPECS, specs)
	if not ok then return false, "Could not save artifact specs" end
	return true, nil
end

-- Ordered tuples avoid depending on JSON object key order across host/window
-- VMs when checking whether a pending document open still names these specs.
function M.signature(specs: { Spec }): string
	local ordered: { { string } } = tern.json.array()
	for _, spec in specs do table.insert(ordered, { spec.label, spec.path }) end
	return tern.json.encode(ordered)
end

local function missing(specs: { Spec }): { Match }
	local matches: { Match } = {}
	for _, spec in specs do
		table.insert(matches, { label = spec.label })
	end
	return matches
end

local function join(directory: string, basename: string): string
	return directory .. (if directory == "/" then "" else "/") .. basename
end

local function target(cwd: string, path: string): Target
	local segments: { string } = {}
	-- Removing empty and '.' segments preserves relative path meaning.
	for segment in string.gmatch(path, "[^/]+") do
		if segment ~= "." then table.insert(segments, segment) end
	end
	local basename = table.remove(segments) :: string
	local directory = cwd
	local parents = { cwd }
	for _, segment in segments do
		directory = join(directory, segment)
		table.insert(parents, directory)
	end
	return { directory = directory, basename = basename, parents = parents }
end

local function glob(basename: string, pattern: string): boolean
	local star = string.find(pattern, "*", 1, true)
	if star == nil then return basename == pattern end
	local prefix_length = star - 1
	local suffix_length = #pattern - star
	if #basename < prefix_length + suffix_length then return false end
	return string.sub(basename, 1, prefix_length) == string.sub(pattern, 1, prefix_length)
		and string.sub(basename, #basename - suffix_length + 1) == string.sub(pattern, star + 1)
end

local function literal_path(path: string): string
	-- find's -path argument is a glob too, even when passed without a shell.
	return (string.gsub(path, ".", function(char: string): string
		return if string.find("\\*?[]", char, 1, true) then "\\" .. char else char
	end))
end

-- GNU find prints signed floor seconds and a positive fractional field:
-- an actual epoch -0.5 is "-1.5000000000", not decimal negative one-and-a-half.
-- Keep both fields exact: tonumber(epoch) loses nanoseconds at current dates.
local function modification_time(stamp: string): Mtime?
	local sign, seconds, fraction = string.match(stamp, "^(%-?)(%d+)%.?(%d*)$")
	if sign == nil or seconds == nil or fraction == nil then return nil end
	seconds = string.gsub(seconds, "^0+", "")
	if seconds == "" then seconds = "0" end
	fraction = string.gsub(fraction, "0+$", "")
	return { negative = sign == "-" and seconds ~= "0", seconds = seconds, fraction = fraction }
end

local function compare_time(left: Mtime, right: Mtime): number
	if left.negative ~= right.negative then return if left.negative then -1 else 1 end
	if left.seconds ~= right.seconds then
		local magnitude = if #left.seconds ~= #right.seconds
			then (if #left.seconds < #right.seconds then -1 else 1)
			else (if left.seconds < right.seconds then -1 else 1)
		return if left.negative then -magnitude else magnitude
	end
	-- With trailing zeroes removed, lexical order equals exact fractional
	-- order, including different output widths and pre-epoch timestamps.
	if left.fraction == right.fraction then return 0 end
	return if left.fraction < right.fraction then -1 else 1
end

local function parse(stdout: string, specs: { Spec }, targets: { Target }): ({ Match }?, string?)
	if #stdout > MAX_STDOUT then return nil, "Artifact scan exceeded 64 KiB of output" end
	local matches = missing(specs)
	local newest: { [number]: Mtime } = {}
	local offset = 1
	local count = 0
	while offset <= #stdout do
		count += 1
		if count > MAX_RECORDS then return nil, "Artifact scan exceeded 256 candidates" end
		local time_end = string.find(stdout, "\0", offset, true)
		if time_end == nil then return nil, "Artifact scan returned incomplete output" end
		local path_end = string.find(stdout, "\0", time_end + 1, true)
		if path_end == nil then return nil, "Artifact scan returned incomplete output" end
		local stamp = string.sub(stdout, offset, time_end - 1)
		local path = string.sub(stdout, time_end + 1, path_end - 1)
		offset = path_end + 1
		local mtime = modification_time(stamp)
		if mtime == nil then
			return nil, "Artifact scan returned an invalid modification time"
		end
		local directory, basename = string.match(path, "^(.*)/([^/]+)$")
		if directory == nil or basename == nil then return nil, "Artifact scan returned an invalid path" end
		if directory == "" then directory = "/" end
		for index, item in targets do
			if directory == item.directory and glob(basename, item.basename) then
				local previous = newest[index]
				local previous_path = matches[index].path
				local order = if previous then compare_time(mtime, previous) else 1
				if order > 0 or (order == 0 and (previous_path == nil or path < previous_path)) then
					newest[index] = mtime
					matches[index].path = path
				end
			end
		end
	end
	return matches, nil
end

function M.scan(cwd: string, input: { Spec }, done: ({ Match }, string?) -> ()): ()
	local specs, invalid = validate(input)
	if not specs then done({}, invalid); return end
	local absent = missing(specs)
	if string.sub(cwd, 1, 1) ~= "/" or string.find(cwd, "\0", 1, true) then
		done(absent, "Artifact scan needs an absolute cwd")
		return
	end
	-- Keep the supplied cwd's internal components: resolving '..' lexically
	-- would change its meaning when an earlier component is a symlink.
	cwd = string.gsub(cwd, "/+$", "")
	if cwd == "" then cwd = "/" end
	local targets: { Target } = {}
	local parents: { [string]: boolean } = {}
	local allowed = { cwd }
	local seen_allowed: { [string]: boolean } = { [cwd] = true }
	local file_patterns: { string } = {}
	local seen_patterns: { [string]: boolean } = {}
	local maxdepth = 1
	for _, spec in specs do
		local item = target(cwd, spec.path)
		table.insert(targets, item)
		if parents[item.directory] == nil then
			local ok, exists = pcall(tern.fs.exists, item.directory)
			if not ok then done(absent, "Artifact scan could not inspect a parent directory"); return end
			parents[item.directory] = exists
			if exists then
				for _, directory in item.parents do
					if not seen_allowed[directory] then
						seen_allowed[directory] = true
						table.insert(allowed, directory)
					end
				end
			end
		end
		if parents[item.directory] then
			maxdepth = math.max(maxdepth, #item.parents)
			local pattern = join(literal_path(item.directory), item.basename)
			if not seen_patterns[pattern] then
				seen_patterns[pattern] = true
				table.insert(file_patterns, pattern)
			end
		end
	end
	if #file_patterns == 0 then done(absent, nil); return end

	-- One root is essential: a nested explicit root would follow symlink
	-- components before find sees them. From cwd, -P encounters each nested
	-- symlink itself and never descends through it. Prune all other directories.
	local argv = { "find", "-P", cwd, "-maxdepth", tostring(maxdepth), "(", "-type", "d", "!", "(" }
	for index, directory in allowed do
		if index > 1 then table.insert(argv, "-o") end
		table.insert(argv, "-path")
		table.insert(argv, literal_path(directory))
	end
	for _, arg in { ")", "-prune", ")", "-o", "(", "-type", "f", "(" } do table.insert(argv, arg) end
	for index, pattern in file_patterns do
		if index > 1 then table.insert(argv, "-o") end
		table.insert(argv, "-path")
		table.insert(argv, pattern)
	end
	table.insert(argv, ")")
	table.insert(argv, "-printf")
	-- Literal backslash-zero in argv, not an embedded NUL. find emits NUL pairs.
	table.insert(argv, "%T@\\0%p\\0")
	table.insert(argv, ")")
	local completed = false
	local function finish(matches: { Match }, err: string?)
		if completed then return end
		completed = true
		done(matches, err)
	end
	local ok = pcall(function()
		tern.process.run(argv, { timeout_ms = 2000, env = { LC_ALL = "C" } }, function(result: ProcessResult, _)
			if result.timed_out then
				finish(absent, "Artifact scan timed out after 2 s")
			elseif result.status ~= 0 then
				-- Includes missing find and directories removed after exists().
				finish(absent, "Artifact scan unavailable (GNU find exit " .. tostring(result.status) .. ")")
			else
				for directory, existed in parents do
					if existed then
						local exists_ok, exists = pcall(tern.fs.exists, directory)
						if not exists_ok or not exists then
							finish(absent, "Artifact scan unavailable: a parent directory disappeared")
							return
						end
					end
				end
				local matches, err = parse(result.stdout, specs, targets)
				finish(matches or absent, err)
			end
		end)
	end)
	if not ok then finish(absent, "Artifact scan unavailable: could not start GNU find") end
end

return M
