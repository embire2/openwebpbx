--	xml_handler.lua
--	Part of FusionPBX
--	Copyright (C) 2015-2018 Mark J Crane <markjcrane@fusionpbx.com>
--	All rights reserved.
--
--	Redistribution and use in source and binary forms, with or without
--	modification, are permitted provided that the following conditions are met:
--
--	1. Redistributions of source code must retain the above copyright notice,
--	   this list of conditions and the following disclaimer.
--
--	2. Redistributions in binary form must reproduce the above copyright
--	   notice, this list of conditions and the following disclaimer in the
--	   documentation and/or other materials provided with the distribution.
--
--	THIS SOFTWARE IS PROVIDED ''AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
--	INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
--	AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
--	AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
--	OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
--	SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
--	INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
--	CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
--	ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
--	POSSIBILITY OF SUCH DAMAGE.

	--[[
	These ACL's are automatically created on startup.
		rfc1918.auto  - RFC1918 Space
		nat.auto      - RFC1918 Excluding your local lan.
		localnet.auto - ACL for your local lan.
		loopback.auto - ACL for your local lan.
	]]

--include xml library
	local Xml = require "resources.functions.xml";

--get the cache
	local cache = require "resources.functions.cache"
	local acl_cache_key = "configuration:acl.conf"
	XML_STRING, err = cache.get(acl_cache_key)

--set the cache
	if not XML_STRING then

		--log cache error
			if (debug["cache"]) then
				freeswitch.consoleLog("warning", "[xml_handler] configuration:acl.conf can not be get from the cache: " .. tostring(err) .. "\n");
			end

		--set a default value
			if (expire["acl"] == nil) then
				expire["acl"]= "3600";
			end

		--connect to the database
			local Database = require "resources.functions.database";
			dbh = Database.new('system');

		--include json library
			local json
			if (debug["sql"]) then
				json = require "resources.functions.lunajson"
			end

		--exits the script if we didn't connect properly
			assert(dbh:connected());

		--start the xml array
			local xml = Xml:new();
			xml:append([[<?xml version="1.0" encoding="UTF-8" standalone="no"?>]]);
			xml:append([[<document type="freeswitch/xml">]]);
			xml:append([[	<section name="configuration">]]);
			xml:append([[		<configuration name="acl.conf" description="Network Lists">]]);
			xml:append([[			<network-lists>]]);

		--run the query
			sql = "select * from v_access_controls ";
			sql = sql .. "order by access_control_name asc ";
			if (debug["sql"]) then
				freeswitch.consoleLog("notice", "[xml_handler] SQL: " .. sql .. "\n");
			end
			x = 0;
			dbh:query(sql, function(row)

				--list open tag
					xml:append([[				<list name="]] .. xml.sanitize(row.access_control_name) .. [[" default="]] .. xml.sanitize(row.access_control_default) .. [[">]]);

				--get the nodes
					sql = "select * from v_access_control_nodes ";
					sql = sql .. "where access_control_uuid = :access_control_uuid ";
					sql = sql .. "and length(node_cidr) > 0 ";
					local params = {access_control_uuid = row.access_control_uuid}
					if (debug["sql"]) then
						freeswitch.consoleLog("notice", "[xml_handler] SQL: " .. sql .. "; params:" .. json.encode(params) .. "\n");
					end
					x = 0;
					dbh:query(sql, params, function(field)
						xml:append([[					<node type="]] .. xml.sanitize(field.node_type) .. [[" cidr="]] .. xml.sanitize(field.node_cidr) .. [[" description="]] .. xml.sanitize(field.node_description) .. [["/>]]);
					end)

				--add the domains
					if (row.access_control_name == 'providers' or row.access_control_name == 'domains') then
						sql = "select domain_name, domain_description from v_domains ";
						sql = sql .. "where domain_uuid in (select distinct(domain_uuid) ";
						sql = sql .. "from v_extensions where enabled = true) ";
						sql = sql .. "and domain_enabled = true ";
						local params = {}
						if (debug["sql"]) then
							freeswitch.consoleLog("notice", "[xml_handler] SQL: " .. sql .. ";\n");
						end
						x = 0;
						dbh:query(sql, params, function(field)
							xml:append([[					<node type="allow" domain="]] .. xml.sanitize(field.domain_name) .. [[" description="]] .. xml.sanitize(field.domain_description) .. [["/>]]);
						end)
					end


                -- OpenWeb PBX provider IPs authorize only the SIP handshake. The
                -- domain-owned dialplan and Lua policy still check the number,
                -- gateway, source address and tenant before admitting a call.
                if row.access_control_name == 'providers' then
                    local installed = false
                    dbh:query("select to_regclass('v_pbx_restore') is not null as installed", function(item)
                        installed = item.installed == 't' or item.installed == 'true' or item.installed == true
                    end)
                    if installed then
                        local approved_sql = [[
                            select distinct address.value as provider_ip
                            from v_pbx_restore restored
                            join v_domains domain on domain.domain_uuid=restored.domain_uuid and domain.domain_enabled=true
                            cross join lateral jsonb_each(case when jsonb_typeof(restored.config->'trunks')='object' then restored.config->'trunks' else '{}'::jsonb end) trunk
                            join v_gateways gateway on gateway.domain_uuid=restored.domain_uuid
                                and gateway.gateway_uuid::text=trunk.value->>'gateway_uuid' and gateway.enabled=true
                            cross join lateral jsonb_array_elements_text(case when jsonb_typeof(trunk.value->'allowed_ips')='array' then trunk.value->'allowed_ips' else '[]'::jsonb end) address
                            where trunk.value->>'enabled'='true'
                                and not exists(select 1 from v_pbx_services service join v_pbx_tenants tenant using(tenant_uuid)
                                    where service.domain_uuid=restored.domain_uuid and tenant.enabled=false)
                        ]]
                        local function ipv4(ip)
                            local parts={ip:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')}
                            if #parts~=4 then return false end
                            for _,part in ipairs(parts) do
                                if #part>3 or tonumber(part)>255 or (#part>1 and part:sub(1,1)=='0') then return false end
                            end
                            return true
                        end
                        local function ipv6(ip)
                            if #ip>45 or not ip:find(':',1,true) then return false end
                            -- A dotted tail occupies two IPv6 hextets. Preserve
                            -- the original literal when rendering the /128 ACL.
                            if ip:find('.',1,true) then
                                local tail=ip:match('(%d+%.%d+%.%d+%.%d+)$')
                                if not tail or not ipv4(tail) then return false end
                                local prefix=ip:sub(1,#ip-#tail)
                                if prefix:sub(-1)~=':' then return false end
                                ip=prefix..'0:0'
                            end
                            if not ip:match('^[%x:]+$') or ip:find(':::',1,true) then return false end
                            local _,compressed=ip:gsub('::','')
                            if compressed>1 then return false end
                            local function groups(part)
                                if part=='' then return 0 end
                                if part:sub(1,1)==':' or part:sub(-1)==':' then return nil end
                                local total=0
                                for value in part:gmatch('[^:]+') do
                                    if #value>4 or not value:match('^%x+$') then return nil end
                                    total=total+1
                                end
                                return total
                            end
                            if compressed==0 then return groups(ip)==8 end
                            local left,right=ip:match('^(.-)::(.-)$')
                            local a,b=groups(left),groups(right)
                            return a~=nil and b~=nil and a+b<8
                        end
                        dbh:query(approved_sql, function(item)
                            local ip = item.provider_ip or ''
                            -- Admin accepts only literal addresses; validate again before XML.
                            local valid = ip:find(':',1,true) and ipv6(ip) or ipv4(ip)
                            if valid then
                                local mask = ip:find(':',1,true) and '/128' or '/32'
                                xml:append([[<node type="allow" cidr="]]..xml.sanitize(ip..mask)..[[" description="OpenWeb PBX incoming provider"/>]])
                            end
                        end)
                    end
                end

				--list close tag
					xml:append([[				</list>]]);

			end)

		--close the extension tag if it was left open
			xml:append([[			</network-lists>]]);
			xml:append([[		</configuration>]]);
			xml:append([[	</section>]]);
			xml:append([[</document>]]);
			XML_STRING = xml:build();
			if (debug["xml_string"]) then
				freeswitch.consoleLog("notice", "[xml_handler] XML_STRING: " .. XML_STRING .. "\n");
			end

		--close the database connection
			dbh:release();

		--set the cache
			local ok, err = cache.set(acl_cache_key, XML_STRING, expire["acl"]);
			if debug["cache"] then
				if ok then
					freeswitch.consoleLog("notice", "[xml_handler] " .. acl_cache_key .. " stored in the cache\n");
				else
					freeswitch.consoleLog("warning", "[xml_handler] " .. acl_cache_key .. " can not be stored in the cache: " .. tostring(err) .. "\n");
				end
			end

		--send to the console
			if (debug["cache"]) then
				freeswitch.consoleLog("notice", "[xml_handler] " .. acl_cache_key .. " source: database\n");
			end
	else
		--send to the console
			if (debug["cache"]) then
				freeswitch.consoleLog("notice", "[xml_handler] " .. acl_cache_key .. " source: cache\n");
			end
	end --if XML_STRING

--send the xml to the console
	if (debug["xml_string"]) then
		local file = assert(io.open(temp_dir .. "/acl.conf.xml", "w"));
		file:write(XML_STRING);
		file:close();
	end
