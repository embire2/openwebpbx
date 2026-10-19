-- Keep telephone audio at the PBX, including ringback for remote softphones.
-- Do not log SIP packets, credentials, SDP, DTMF or customer recordings.
local M={}
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
        session:setVariable('ringback','%(400,200,400,450);%(400,2000,400,450)')
    end
    session:setVariable('instant_ringback','false')
    M.trace(session,domain,'media_policy',{['PBX-Audio']='true'})
end
return M
