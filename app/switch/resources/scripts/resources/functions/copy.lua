--add the copy function
	function copy(src,dst)
        if package.config:sub(1,1)==[[\]] then
            -- Preserve drive letters/spaces and bytes without invoking cmd.exe.
            local function path(value)
                assert(type(value)=='string' and value:match('^%a:[/\\]') and not value:find('[%z\1-\31<>"|?*]'), 'An ordinary absolute Windows file path is required')
                local normalized=value:gsub([[\]],'/'):gsub('/+','/')
                assert(not normalized:sub(3):find(':',1,true), 'Windows alternate streams are not file paths')
                for component in normalized:sub(4):gmatch('[^/]+') do
                    local stem=component:match('^([^.]*)'):upper()
                    assert(component~='.' and component~='..' and not component:match('[. ]$') and stem~='CON' and stem~='PRN' and stem~='AUX' and stem~='NUL' and not stem:match('^COM[1-9]$') and not stem:match('^LPT[1-9]$'), 'An ordinary Windows file path is required')
                end
                return normalized
            end
            src,dst=path(src),path(dst)
            assert(src:lower()~=dst:lower(), 'Source and destination must differ')
            local input=assert(io.open(src,'rb'))
            local output,err=io.open(dst,'wb')
            if not output then input:close();error(err) end
            local ok,failure=pcall(function()
                while true do
                    local bytes,read_error=input:read(65536)
                    assert(not read_error,read_error)
                    if not bytes then break end
                    assert(output:write(bytes))
                end
                assert(output:flush())
            end)
            input:close()
            local closed,close_error=output:close()
            if not ok or not closed then os.remove(dst);error(failure or close_error) end
            return true
        end
		--retrieve allowed characters and then use it to sanitize the dir variable
		local allowed_chars = os.getenv("ALLOWED_CHARS") or "^%a%d%-%._~/";
		src = src:gsub("[^" .. allowed_chars .. "]", "");
		dst = dst:gsub("[^" .. allowed_chars .. "]", "");

		if (package.config:sub(1,1) == "/") then
			--unix
			cmd = [[cp "]] .. src .. [[" "]] .. dst .. [["]];
		elseif (package.config:sub(1,1) == [[\]]) then
			--windows
			src = src:gsub("/",[[\]]);
			dst = dst:gsub("/",[[\]]);
			cmd = [[copy "]] .. src .. [[" "]] ..dst.. [["]];
		end
		os.execute(cmd);
		return cmd;
	end
