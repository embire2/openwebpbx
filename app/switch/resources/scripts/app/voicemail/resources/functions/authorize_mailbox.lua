-- Every mailbox-management entry point uses the same authenticated phone identity.
function authorize_mailbox(requested)
    local identity=require 'resources.functions.mailbox_identity'
    local p=identity.mailbox(session,dbh,requested)
    if not p then session:hangup('CALL_REJECTED');return false end
    voicemail_id=p.number;voicemail_uuid=p.voicemail_uuid
    return true
end
