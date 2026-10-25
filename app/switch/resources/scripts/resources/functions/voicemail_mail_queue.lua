-- Bounded PostgreSQL transport; waiting mail appears only with complete durable audio.
local M = {}
local MAX_AUDIO = 32 * 1024 * 1024
local CHUNK = 8192
local MAX_META = 4096

local function snapshot(path, encoded)
    require 'resources.functions.base64'
    local codec = base64
    local file = type(path) == 'string' and io.open(path, 'rb') or nil
    if file then
        local ok, data = pcall(function()
            local size = file:seek('end')
            if not size or size < 1 or size > MAX_AUDIO then return nil end
            if not file:seek('set', 0) then return nil end
            local bytes = file:read(size + 1)
            if not bytes or #bytes ~= size or file:seek('end') ~= size then return nil end
            return bytes
        end)
        file:close()
        if not ok or not data then return nil end
        return codec.encode(data)
    end
    if type(encoded) ~= 'string' or #encoded < 4 or #encoded > math.ceil(MAX_AUDIO / 3) * 4 then return nil end
    local compact = encoded:gsub('%s', '')
    if #compact % 4 ~= 0 or compact:find('[^A-Za-z0-9+/=]') then return nil end
    local ok, bytes = pcall(codec.decode, compact)
    if not ok or not bytes or #bytes < 1 or #bytes > MAX_AUDIO or codec.encode(bytes) ~= compact then return nil end
    return compact
end

-- Lua5.2 supplies bit32; newer Lua supplies the same32-bit operations natively.
-- Hash independently before staging; PostgreSQL verifies the reconstructed bytes.
local bits = bit32 or bit
if not bits then
    local compile = load([[return {
      band=function(a,b) return (a & b) & 0xffffffff end,
      bxor=function(a,b,c) return (a ~ b ~ (c or 0)) & 0xffffffff end,
      bnot=function(a) return (~a) & 0xffffffff end,
      rshift=function(a,n) return (a & 0xffffffff) >> n end,
      rrotate=function(a,n) return ((a >> n) | (a << (32-n))) & 0xffffffff end
    }]])
    if compile then bits = compile() end
end
local function sha256(text)
    if not bits then return nil end
    local band, bxor, bnot, shr, ror = bits.band, bits.bxor, bits.bnot, bits.rshift, bits.rrotate or bits.ror
    local h = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}
    local k = {0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
      0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
      0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
      0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
      0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
      0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
      0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
      0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2}
    local function word(n)
        return string.char(math.floor(n/16777216)%256,math.floor(n/65536)%256,math.floor(n/256)%256,n%256)
    end
    local length = #text * 8
    text = text .. '\128' .. string.rep('\0',(55-#text)%64) .. word(math.floor(length/4294967296)) .. word(length%4294967296)
    local w = {}
    for offset=1,#text,64 do
        for i=0,15 do
            local a,b,c,d = text:byte(offset+i*4,offset+i*4+3)
            w[i] = a*16777216+b*65536+c*256+d
        end
        for i=16,63 do
            local x,y = w[i-15],w[i-2]
            w[i] = (w[i-16]+bxor(ror(x,7),ror(x,18),shr(x,3))+w[i-7]+bxor(ror(y,17),ror(y,19),shr(y,10)))%4294967296
        end
        local a,b,c,d,e,f,g,j = h[1],h[2],h[3],h[4],h[5],h[6],h[7],h[8]
        for i=0,63 do
            local t = (j+bxor(ror(e,6),ror(e,11),ror(e,25))+bxor(band(e,f),band(bnot(e),g))+k[i+1]+w[i])%4294967296
            local u = (bxor(ror(a,2),ror(a,13),ror(a,22))+bxor(band(a,b),band(a,c),band(b,c)))%4294967296
            j,g,f,e,d,c,b,a = g,f,e,(d+t)%4294967296,c,b,a,(t+u)%4294967296
        end
        local values = {a,b,c,d,e,f,g,j}
        for i=1,8 do h[i] = (h[i]+values[i])%4294967296 end
    end
    for i=1,8 do h[i] = string.format('%08x',h[i]) end
    return table.concat(h)
end

local function uuid(value)
    return type(value)=='string' and #value==36 and value:match('^[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+$')
end
local function query(db, sql, params, callback)
    local called, ok = pcall(function() return db:query(sql,params,callback) end)
    return called and ok
end

function M.enqueue(db, values, path, encoded)
    local failure = 'Voicemail email could not be queued; the mailbox copy is retained.'
    local audio = snapshot(path,encoded)
    if not audio then return nil,'Voicemail audio is unavailable; the mailbox copy is retained.' end
    local name = type(path)=='string' and path:match('([^/\\]+)$') or nil
    local kind = name and name:match('%.([A-Za-z0-9]+)$');kind = kind and kind:lower()
    local mime = ({wav='audio/x-wav',mp3='audio/mpeg',ogg='audio/ogg',opus='audio/opus'})[kind]
    if not mime or not uuid(values.queue) or not uuid(values.attachment) or not uuid(values.domain) or not uuid(values.message) then return nil,failure end
    local directory = path:sub(1,#path-#name-1)
    local size = #name+#directory
    for _,field in ipairs({'hostname','sender','recipient','subject','body','after'}) do
        local value = values[field]
        if type(value)~='string' then return nil,failure end
        size = size+#value
    end
    if size>MAX_META then return nil,failure end
    local hashed, digest = pcall(sha256,audio)
    if not hashed or not digest then return nil,failure end
    local called, api = pcall(function() return freeswitch.API() end)
    if not called or not api then return nil,failure end
    local function fresh()
        local ok,value = pcall(function() return api:executeString('create_uuid') end)
        return ok and uuid(value) and value or nil
    end
    local token = fresh()
    if not token then return nil,failure end
    local count,ids = math.ceil(#audio/CHUNK),{}
    local cid = 'sha256:'..digest
    local function cleanup()
        for index,id in ipairs(ids) do
            query(db,[[DELETE FROM v_email_queue_attachments
              WHERE email_queue_attachment_uuid=:id AND email_queue_uuid IS NULL AND domain_uuid=:domain
                AND email_attachment_type='openweb-voicemail-chunk-v1'
                AND email_attachment_mime_type='application/x-openwebpbx-voicemail-chunk-v1'
                AND email_attachment_path=:token AND email_attachment_name=:ordinal
                AND email_attachment_cid=:cid AND email_attachment_base64=:piece]],
              {id=id,domain=values.domain,token=token,ordinal=string.format('%08d',index),cid=cid,
               piece=audio:sub((index-1)*CHUNK+1,index*CHUNK)})
        end
    end
    for index=1,count do
        local id = fresh()
        if not id then cleanup();return nil,failure end
        ids[index] = id -- Includes a possibly committed insert whose callback is lost.
        local piece = audio:sub((index-1)*CHUNK+1,index*CHUNK)
        local ack = false
        local ok = query(db,[[WITH durable AS MATERIALIZED (SELECT set_config('synchronous_commit','on',true)),
          staged AS (INSERT INTO v_email_queue_attachments
            (email_queue_attachment_uuid,email_queue_uuid,domain_uuid,email_attachment_mime_type,
             email_attachment_type,email_attachment_path,email_attachment_name,email_attachment_base64,email_attachment_cid,insert_date)
            SELECT :id,NULL,:domain,'application/x-openwebpbx-voicemail-chunk-v1',
              'openweb-voicemail-chunk-v1',:token,:ordinal,:piece,:cid,now() FROM durable
            RETURNING email_queue_attachment_uuid,email_attachment_base64)
          SELECT email_queue_attachment_uuid::text AS staged_uuid,email_attachment_base64 AS staged_bytes FROM staged]],
          {id=id,domain=values.domain,token=token,ordinal=string.format('%08d',index),piece=piece,cid=cid},
          function(row) ack = row.staged_uuid==id and row.staged_bytes==piece end)
        if not ok or not ack then cleanup();return nil,failure end
    end
    local ids_digest = sha256(table.concat(ids,','))
    local params = {queue=values.queue,attachment=values.attachment,domain=values.domain,message=values.message,
      hostname=values.hostname,sender=values.sender,recipient=values.recipient,subject=values.subject,body=values.body,
      after=values.after,name=name,kind=kind,mime=mime,path=directory,token=token,cid=cid,
      count=count,length=#audio,digest=digest,ids_digest=ids_digest,chunk=CHUNK,last=#audio-(count-1)*CHUNK}
    local returned
    local ok = query(db,[[WITH locked AS MATERIALIZED (
      SELECT * FROM v_email_queue_attachments WHERE email_queue_uuid IS NULL AND domain_uuid=:domain
        AND email_attachment_type='openweb-voicemail-chunk-v1'
        AND email_attachment_mime_type='application/x-openwebpbx-voicemail-chunk-v1'
        AND email_attachment_path=:token AND email_attachment_cid=:cid
      ORDER BY email_attachment_name FOR UPDATE
    ), assembled AS MATERIALIZED (
      SELECT count(*) AS total,count(DISTINCT email_attachment_name) AS unique_names,
        min(email_attachment_name) AS first_name,max(email_attachment_name) AS last_name,
        bool_and(email_attachment_name ~ '^[0-9]{8}$' AND
          octet_length(email_attachment_base64)=CASE WHEN email_attachment_name=lpad(:count::text,8,'0') THEN :last::integer ELSE :chunk::integer END) AS lengths_valid,
        string_agg(email_attachment_base64,'' ORDER BY email_attachment_name) AS audio,
        string_agg(email_queue_attachment_uuid::text,',' ORDER BY email_attachment_name) AS ids FROM locked
    ), valid AS MATERIALIZED (
      SELECT audio FROM assembled WHERE total=:count::integer AND unique_names=total
        AND first_name='00000001' AND last_name=lpad(:count::text,8,'0') AND lengths_valid
        AND octet_length(audio)=:length::integer
        AND encode(sha256(convert_to(audio,'UTF8')),'hex')=:digest
        AND encode(sha256(convert_to(ids,'UTF8')),'hex')=:ids_digest
    ), durable AS MATERIALIZED (SELECT set_config('synchronous_commit','on',true)), queued AS (
      INSERT INTO v_email_queue
        (email_queue_uuid,domain_uuid,hostname,email_date,email_from,email_to,email_subject,email_body,
         email_status,email_uuid,email_action_before,email_action_after,insert_date)
      SELECT :queue,:domain,:hostname,now(),:sender,:recipient,:subject,:body,
        'waiting',:message,'voicemail-attachment-v1',:after,now() FROM valid,durable
      RETURNING email_queue_uuid,domain_uuid
    ), attached AS (
      INSERT INTO v_email_queue_attachments
        (email_queue_attachment_uuid,email_queue_uuid,domain_uuid,email_attachment_mime_type,
         email_attachment_type,email_attachment_path,email_attachment_name,email_attachment_base64,insert_date)
      SELECT :attachment,email_queue_uuid,domain_uuid,:mime,:kind,:path,:name,audio,now() FROM queued,valid
      RETURNING email_queue_uuid
    ), cleaned AS (
      DELETE FROM v_email_queue_attachments target USING locked,attached
      WHERE target.email_queue_attachment_uuid=locked.email_queue_attachment_uuid
        AND target.email_queue_uuid IS NULL AND target.domain_uuid=:domain
        AND target.email_attachment_type='openweb-voicemail-chunk-v1'
        AND target.email_attachment_mime_type='application/x-openwebpbx-voicemail-chunk-v1'
        AND target.email_attachment_path=:token AND target.email_attachment_cid=:cid
        AND target.email_attachment_name=locked.email_attachment_name
        AND target.email_attachment_base64=locked.email_attachment_base64
      RETURNING target.email_queue_attachment_uuid
    ) SELECT email_queue_uuid::text AS email_queue_uuid,
        1 / (((SELECT count(*) FROM cleaned)=:count::integer)::integer) AS complete FROM attached]],
      params,function(row) if tostring(row.complete)=='1' then returned=row.email_queue_uuid end end)
    if ok and returned==values.queue then return returned end
    -- A native timeout can lose a callback after COMMIT. A fresh bounded read
    -- acknowledges only this exact complete published snapshot, never its header alone.
    local recovered
    local recovered_ok = query(db,[[SELECT q.email_queue_uuid::text AS email_queue_uuid FROM v_email_queue q
      JOIN v_email_queue_attachments a ON a.email_queue_uuid=q.email_queue_uuid AND a.domain_uuid=q.domain_uuid
      WHERE q.email_queue_uuid=:queue AND q.domain_uuid=:domain AND q.email_uuid=:message
        AND q.email_action_before='voicemail-attachment-v1' AND q.hostname=:hostname
        AND q.email_from=:sender AND q.email_to=:recipient AND q.email_subject=:subject
        AND q.email_body=:body AND q.email_action_after=:after AND a.email_queue_attachment_uuid=:attachment
        AND a.email_attachment_name=:name AND a.email_attachment_path=:path
        AND a.email_attachment_type=:kind AND a.email_attachment_mime_type=:mime
        AND octet_length(a.email_attachment_base64)=:length::integer
        AND encode(sha256(convert_to(a.email_attachment_base64,'UTF8')),'hex')=:digest
        AND (SELECT count(*) FROM v_email_queue_attachments WHERE email_queue_uuid=:queue)=1]],
      params,function(row) recovered=row.email_queue_uuid end)
    if recovered_ok and recovered==values.queue then return recovered end
    cleanup()
    return nil,failure
end

return M
