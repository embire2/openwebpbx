-- Keep telephone audio at the PBX, including ringback for remote softphones.
-- Do not log SIP packets, credentials, SDP, DTMF or customer recordings.
local M={}
local RINGBACK='%(400,200,400,450);%(400,2000,400,450)'
local GROUP_VARS={'ringback','transfer_ringback','ignore_early_media','bridge_early_media','instant_ringback'}
function M.trace(session,domain,stage,fields)
    pcall(function()
        local event=freeswitch.Event('CUSTOM','openweb::call_trace')
        event:addHeader('Unique-ID',session:getVariable('uuid') or '')
        event:addHeader('variable_domain_uuid',domain)
        event:addHeader('OpenWeb-Stage',stage)
        for key,value in pairs(fields or {}) do
            event:addHeader('OpenWeb-'..key,tostring(value))
        end
        event:fire()
    end)
end
function M.apply(session,domain)
    -- Export to every new bridge leg; do not replace other inherited variables
    -- or alter encryption, codecs, recording ownership or RTP address learning.
    for _,name in ipairs({'bypass_media','bypass_media_after_bridge','proxy_media'}) do
        session:execute('export',name..'=false')
    end
    session:setVariable('disable_rtp_auto_adjust','false')
    session:setVariable('openweb_pbx_delivers_audio','true')
    -- Generate audible ringback when the destination signals ringing. Keep
    -- real provider early media (announcements, busy tones) and never fake an
    -- answer. An existing deliberately selected ringback remains unchanged.
    if not session:getVariable('ringback') or session:getVariable('ringback')=='' then
        session:setVariable('ringback',RINGBACK)
    end
    session:setVariable('instant_ringback','false')
    M.trace(session,domain,'media_policy',{['PBX-Audio']='true'})
end
function M.begin_group(session)
    -- Answered transfers use transfer_ringback instead of ringback. Never
    -- inherit a receptionist's/previous queue's music while offering phones.
    local previous={}
    for _,name in ipairs(GROUP_VARS) do previous[name]=session:getVariable(name) end
    session:setVariable('ringback',RINGBACK)
    session:setVariable('transfer_ringback',RINGBACK)
    session:setVariable('ignore_early_media','true')
    session:setVariable('bridge_early_media','false')
    session:setVariable('instant_ringback','false')
    return previous
end
function M.end_group(session,previous)
    -- A configured no-answer destination may be a queue or an outside number.
    -- Its ordinary announcements and hold policy resume after this offer.
    for _,name in ipairs(GROUP_VARS) do session:setVariable(name,previous[name]) end
end
return M
