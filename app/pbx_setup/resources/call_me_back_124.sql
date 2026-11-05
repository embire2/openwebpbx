BEGIN;
-- 1.0.24: service-local callback selection never writes normal provider routes.
ALTER TABLE v_pbx_cmb_services ADD COLUMN IF NOT EXISTS callback_gateway_uuid uuid;
ALTER TABLE v_pbx_cmb_accounts ADD COLUMN IF NOT EXISTS web_user_uuid uuid;
CREATE UNIQUE INDEX IF NOT EXISTS openweb_cmb_web_account ON v_pbx_cmb_accounts(domain_uuid,web_user_uuid) WHERE web_user_uuid IS NOT NULL;
CREATE TABLE IF NOT EXISTS v_pbx_cmb_speed_dials (
 domain_uuid uuid NOT NULL,service_uuid uuid NOT NULL,account_uuid uuid NOT NULL,
 slot smallint NOT NULL CHECK(slot BETWEEN 1 AND 9),label text NOT NULL DEFAULT '' CHECK(length(label)<=80),
 phone_number text NOT NULL CHECK(phone_number ~ '^\+?[0-9]{7,16}$'),updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(domain_uuid,account_uuid,slot),
 FOREIGN KEY(domain_uuid,service_uuid,account_uuid) REFERENCES v_pbx_cmb_accounts(domain_uuid,service_uuid,account_uuid) ON DELETE CASCADE
);
-- Greeting IDs are resolved through same-domain joins. Greetings is installed
-- after this component, so no cross-component creation-order FK is introduced.
CREATE TABLE IF NOT EXISTS v_pbx_cmb_scripts (
 domain_uuid uuid NOT NULL,service_uuid uuid NOT NULL,
 step text NOT NULL CHECK(step IN ('incoming-new','incoming-known','callback-authenticate','authenticated','enter-number','invalid-id','unavailable','invalid-number','quota-exhausted')),
 script_text text NOT NULL CHECK(length(script_text) BETWEEN 1 AND 1500),
 greeting_uuid uuid NOT NULL,active_greeting_uuid uuid,
 updated_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(domain_uuid,service_uuid,step),
 FOREIGN KEY(domain_uuid,service_uuid) REFERENCES v_pbx_cmb_services(domain_uuid,service_uuid) ON DELETE CASCADE
);
COMMIT;
