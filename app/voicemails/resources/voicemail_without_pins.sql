-- Voicemail is available only through the authenticated extension identity.
-- Keep the legacy nullable column for old schema/restore compatibility, with no
-- usable credential. Apply after schema creation, before enabling call services.
ALTER TABLE v_voicemails ALTER COLUMN voicemail_password DROP NOT NULL;
ALTER TABLE v_voicemails ALTER COLUMN voicemail_password DROP DEFAULT;
UPDATE v_voicemails SET voicemail_password = NULL WHERE voicemail_password IS NOT NULL;

CREATE OR REPLACE FUNCTION openweb_voicemail_without_pin()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
    NEW.voicemail_password := NULL;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS openweb_voicemail_without_pin ON v_voicemails;
CREATE TRIGGER openweb_voicemail_without_pin
BEFORE INSERT OR UPDATE OF voicemail_password ON v_voicemails
FOR EACH ROW EXECUTE FUNCTION openweb_voicemail_without_pin();

-- These controls cannot enable access or introduce PIN requirements again.
-- Other voicemail settings, greetings, messages and SIP/conference secrets stay
-- unchanged. Optional settings tables also support an early fresh bootstrap.
DO $$
DECLARE kind text; table_name text; prefix text;
BEGIN
    FOREACH kind IN ARRAY ARRAY['default','domain','user'] LOOP
        table_name := 'v_' || kind || '_settings';
        prefix := kind || '_setting_';
        IF to_regclass(table_name) IS NOT NULL THEN
            EXECUTE format('DELETE FROM %I WHERE %I = $1 AND %I IN ($2,$3,$4,$5)',
                table_name, prefix || 'category', prefix || 'subcategory')
            USING 'voicemail','password_length','password_complexity','password_min_length','remote_access';
        END IF;
    END LOOP;
END;
$$;
