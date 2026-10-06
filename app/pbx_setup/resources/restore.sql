BEGIN;
CREATE TABLE IF NOT EXISTS v_pbx_restore (
 domain_uuid uuid PRIMARY KEY REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 source_version text NOT NULL, config jsonb NOT NULL, report jsonb NOT NULL DEFAULT '{}',
 restored_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS v_pbx_media (
 media_uuid uuid PRIMARY KEY, domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 category text NOT NULL CHECK(category IN ('recordings','voicemails','prompts')),
 source_path text NOT NULL, file_path text NOT NULL, title text NOT NULL,
 owner_number text, created_at timestamptz, duration integer,
 UNIQUE(domain_uuid,source_path)
);
CREATE INDEX IF NOT EXISTS openweb_media_domain ON v_pbx_media(domain_uuid,category,created_at DESC);
CREATE TABLE IF NOT EXISTS v_pbx_call_history (
 history_uuid uuid PRIMARY KEY, domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 owner_number text NOT NULL, party_number text, party_name text, call_type text,
 start_time timestamptz, answer_time timestamptz, end_time timestamptz, end_status text,
 source_id text NOT NULL, UNIQUE(domain_uuid,source_id)
);
CREATE INDEX IF NOT EXISTS openweb_history_domain ON v_pbx_call_history(domain_uuid,start_time DESC);
UPDATE v_menu_items SET menu_item_title='Admin' WHERE menu_item_link='/app/pbx_setup/';
UPDATE v_menu_languages SET menu_item_title='Admin' WHERE menu_item_uuid IN(SELECT menu_item_uuid FROM v_menu_items WHERE menu_item_link='/app/pbx_setup/');
COMMIT;
