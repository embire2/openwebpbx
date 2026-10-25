-- A voicemail notification becomes visible only with its durable audio snapshot.
-- One PostgreSQL statement avoids per-query pooled-connection transaction state.
local M = {}
local MAX_AUDIO = 32 * 1024 * 1024

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

function M.enqueue(db, values, path, encoded)
    local audio = snapshot(path, encoded)
    if not audio then return nil, 'Voicemail audio is unavailable; the mailbox copy is retained.' end
    local name = type(path) == 'string' and path:match('([^/\\]+)$') or nil
    if not name then return nil, 'Voicemail attachment name is unavailable; the mailbox copy is retained.' end
    local kind = name:match('%.([A-Za-z0-9]+)$')
    kind = kind and kind:lower()
    local mime = ({wav='audio/x-wav', mp3='audio/mpeg', ogg='audio/ogg', opus='audio/opus'})[kind]
    if not mime then return nil, 'Voicemail audio type is unavailable; the mailbox copy is retained.' end
    local params = {
        queue=values.queue, attachment=values.attachment, domain=values.domain,
        hostname=values.hostname, sender=values.sender, recipient=values.recipient,
        subject=values.subject, body=values.body, message=values.message,
        after=values.after, name=name, kind=kind, mime=mime, audio=audio,
        path=path:sub(1, #path - #name - 1),
    }
    local sql = [[WITH durable AS MATERIALIZED (
        SELECT set_config('synchronous_commit','on',true)
    ), queued AS (
        INSERT INTO v_email_queue
            (email_queue_uuid,domain_uuid,hostname,email_date,email_from,email_to,
             email_subject,email_body,email_status,email_uuid,email_action_before,email_action_after,insert_date)
        SELECT :queue,:domain,:hostname,now(),:sender,:recipient,:subject,:body,
               'waiting',:message,'voicemail-attachment-v1',:after,now() FROM durable
        RETURNING email_queue_uuid,domain_uuid
    ), attached AS (
        INSERT INTO v_email_queue_attachments
            (email_queue_attachment_uuid,email_queue_uuid,domain_uuid,email_attachment_mime_type,
             email_attachment_type,email_attachment_path,email_attachment_name,email_attachment_base64,insert_date)
        SELECT :attachment,email_queue_uuid,domain_uuid,:mime,:kind,:path,:name,:audio,now() FROM queued
        RETURNING email_queue_uuid
    ) SELECT email_queue_uuid::text AS email_queue_uuid FROM attached]]
    local returned
    local called, ok = pcall(function()
        return db:query(sql, params, function(row) returned = row.email_queue_uuid end)
    end)
    if not called or not ok or returned ~= values.queue then
        return nil, 'Voicemail email could not be queued; the mailbox copy is retained.'
    end
    return returned
end

return M
