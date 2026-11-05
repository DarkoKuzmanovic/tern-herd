--!strict
-- Test-only bootstrap: renders the host block but has no action consumer,
-- like a remote/web replica without the plugin's window half.
tern.command({
	id = "open",
	title = "Open host-only Herd test block",
	run = function(cx: WindowCx)
		cx:new_block("herd.herd", nil, "beside")
	end,
})
