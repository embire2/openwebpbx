-- SHA-256/HMAC for the private callback-ID verifier. Portable across Lua 5.2/5.4;
-- no command line, SQL, provider or logging boundary ever receives the SA ID.
local C={}
local M=4294967296
local function band(a,b) local out,p=0,1;for _=1,32 do local x,y=a%2,b%2;if x==1 and y==1 then out=out+p end;a=math.floor(a/2);b=math.floor(b/2);p=p*2 end;return out end
local function xor(a,b,c) local out,p=0,1;for _=1,32 do local x,y=a%2,b%2;if x~=y then out=out+p end;a=math.floor(a/2);b=math.floor(b/2);p=p*2 end;if c then return xor(out,c) end;return out end
local function ror(a,n)return (math.floor(a/2^n)+(a%2^n)*2^(32-n))%M end
local K={0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2}
local function be(n)return string.char(math.floor(n/16777216)%256,math.floor(n/65536)%256,math.floor(n/256)%256,n%256)end
function C.sha256(data,raw)
 local bits=#data*8;data=data..'\128'..string.rep('\0',(55-#data)%64)..be(math.floor(bits/M))..be(bits%M)
 local h={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}
 for offset=1,#data,64 do
  local w={};for i=0,15 do local a,b,c,d=data:byte(offset+i*4,offset+i*4+3);w[i]=a*16777216+b*65536+c*256+d end
  for i=16,63 do local a,b=w[i-15],w[i-2];w[i]=(w[i-16]+xor(ror(a,7),ror(a,18),math.floor(a/8))+w[i-7]+xor(ror(b,17),ror(b,19),math.floor(b/1024)))%M end
  local a,b,c,d,e,f,g,j=h[1],h[2],h[3],h[4],h[5],h[6],h[7],h[8]
  for i=0,63 do local t=(j+xor(ror(e,6),ror(e,11),ror(e,25))+xor(band(e,f),band(M-1-e,g))+K[i+1]+w[i])%M;local u=(xor(ror(a,2),ror(a,13),ror(a,22))+xor(band(a,b),band(a,c),band(b,c)))%M;j=g;g=f;f=e;e=(d+t)%M;d=c;c=b;b=a;a=(t+u)%M end
  for i,n in ipairs({a,b,c,d,e,f,g,j}) do h[i]=(h[i]+n)%M end
 end
 local out='';for _,n in ipairs(h) do out=out..be(n) end
 if raw then return out end;return(out:gsub('.',function(c)return string.format('%02x',c:byte())end))
end
function C.hmac(key,data,raw)
 if #key>64 then key=C.sha256(key,true) end;key=key..string.rep('\0',64-#key)
 local inner,outer='', '';for i=1,64 do inner=inner..string.char(xor(key:byte(i),54));outer=outer..string.char(xor(key:byte(i),92)) end
 return C.sha256(outer..C.sha256(inner..data,true),raw)
end
function C.verifier(key,domain,id)
 if type(key)~='string' or #key~=32 or type(domain)~='string' or not domain:match('^[a-f0-9%-]+$') or #domain~=36 or type(id)~='string' or not id:match('^%d%d%d%d%d%d%d%d%d%d%d%d%d$') then return nil end
 return C.hmac(C.hmac(key,'openweb-call-me-back-id/v1\0'..domain,true),id)
end
return C
