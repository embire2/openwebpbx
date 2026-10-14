--add the mkdir function
	function mkdir(dir)
		api = freeswitch.API();
        if package.config:sub(1,1)==[[\]] then
            -- The standard Windows install path contains a drive colon and spaces.
            -- Reject cmd expansion/control characters instead of deleting the path.
            if type(dir)~='string' or not dir:match('^%a:[/\\]') or dir:find('[%%!"&|<>%^%c]') or dir:find('[/\\]%.%.[/\\]') then error('Ordinary absolute Windows storage path required') end
            local command='mkdir "'..dir:gsub([[\]],'/')..'" >NUL 2>NUL'
            os.execute(command);return command
        end
		dir = dir:gsub([[\]], "/");

		--retrieve allowed characters and then use it to sanitize the dir variable
		local allowed_chars = os.getenv("ALLOWED_CHARS") or "^%a%d%-%._~/"
		dir = dir:gsub("[^" .. allowed_chars .. "]", "")

		if (package.config:sub(1,1) == "/") then
			--unix
			cmd = [[mkdir -p "]] .. dir .. [["]];
		elseif (package.config:sub(1,1) == [[\]]) then
			--windows
			cmd = [[mkdir "]] .. dir .. [["]];
		end
		os.execute(cmd);
		--api:executeString("system " .. cmd  );
		return cmd;
	end
