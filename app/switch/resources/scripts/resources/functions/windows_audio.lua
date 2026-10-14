-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Bounded PCM WAV forwarding on Windows; no shell/converter dependency.
local M={}
-- Keep the native Lua 5.2 build compatible; string.pack/unpack is Lua 5.3+.
local function uint(bytes,first,size)
    local n,m=0,1
    for i=first,first+size-1 do local v=bytes:byte(i);assert(v,'Truncated integer');n=n+v*m;m=m*256 end
    return n
end
local function little(n,size)
    local result={}
    for i=1,size do result[i]=string.char(n%256);n=math.floor(n/256) end
    assert(n==0,'Integer too large');return table.concat(result)
end
function M.kind(path)
    local f=io.open(path,'rb');if not f then return nil end
    local h=f:read(12) or '';f:close()
    if h:sub(1,4)=='RIFF' and h:sub(9,12)=='WAVE' then return 'wav' end
    if h:sub(1,3)=='ID3' or (#h>=2 and h:byte(1)==255 and h:byte(2)>=224) then return 'mp3' end
    return nil
end
local function pcm(path)
    local f=assert(io.open(path,'rb'));local bytes=f:read(33554433);f:close()
    assert(bytes and #bytes<=33554432 and bytes:sub(1,4)=='RIFF' and bytes:sub(9,12)=='WAVE','Bounded WAV recording required')
    local i,format,data=13,nil,nil
    while i+7<=#bytes do
        local id=bytes:sub(i,i+3);local size=uint(bytes,i+4,4);local first=i+8
        assert(size<=33554432 and first+size-1<=#bytes,'Invalid WAV chunk')
        if id=='fmt ' then assert(not format and size>=16 and size<=40,'Unsupported WAV format');format=bytes:sub(first,first+size-1)
        elseif id=='data' then assert(not data,'Ambiguous WAV audio');data=bytes:sub(first,first+size-1) end
        i=first+size+size%2
    end
    assert(format and data,'WAV audio missing')
    local encoding,channels,rate,align,bits=uint(format,1,2),uint(format,3,2),uint(format,5,4),uint(format,13,2),uint(format,15,2)
    assert(encoding==1 and (channels==1 or channels==2) and bits==16 and align==channels*2 and #data%align==0 and rate>=8000 and rate<=48000,'PCM WAV recording required')
    return format,data
end
function M.concat(intro,message,output)
    local a,x=pcm(intro);local b,y=pcm(message);assert(a==b,'Voicemail intro format must match message')
    assert(#x+#y<=33554432,'Combined voicemail too large')
    local fmt='fmt '..little(#a,4)..a..(#a%2==1 and '\0' or '')
    local audio='data'..little(#x+#y,4)..x..y
    local f=assert(io.open(output,'wb'));assert(f:write('RIFF'..little(4+#fmt+#audio,4)..'WAVE'..fmt..audio));assert(f:close());return true
end
return M
