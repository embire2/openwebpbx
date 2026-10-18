BEGIN;
CREATE TABLE IF NOT EXISTS v_pbx_mobile_enrollments (
 enrollment_uuid uuid PRIMARY KEY, domain_uuid uuid NOT NULL REFERENCES v_domains ON DELETE CASCADE,
 extension_uuid uuid NOT NULL REFERENCES v_extensions ON DELETE CASCADE,
 code_hash text UNIQUE NOT NULL CHECK(length(code_hash)=64),
 created_by uuid NOT NULL REFERENCES v_users ON DELETE CASCADE,
 created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL,
 used_at timestamptz
);
CREATE INDEX IF NOT EXISTS openweb_mobile_enroll_extension ON v_pbx_mobile_enrollments(extension_uuid);
CREATE TABLE IF NOT EXISTS v_pbx_mobile_devices (
 device_uuid uuid PRIMARY KEY, domain_uuid uuid NOT NULL REFERENCES v_domains ON DELETE CASCADE,
 extension_uuid uuid NOT NULL REFERENCES v_extensions ON DELETE CASCADE,
 device_name text NOT NULL, platform text NOT NULL CHECK(platform='android'),
 token_hash text UNIQUE NOT NULL CHECK(length(token_hash)=64),
 sip_username text UNIQUE NOT NULL CHECK(sip_username ~ '^owm-[0-9a-f]{32}$'),
 sip_a1_hash text NOT NULL CHECK(length(sip_a1_hash)=32),
 created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL,
 last_seen_at timestamptz, revoked_at timestamptz
);
CREATE INDEX IF NOT EXISTS openweb_mobile_device_extension ON v_pbx_mobile_devices(extension_uuid);
CREATE TABLE IF NOT EXISTS v_pbx_mobile_presence (
 domain_uuid uuid NOT NULL REFERENCES v_domains ON DELETE CASCADE,
 extension_uuid uuid NOT NULL REFERENCES v_extensions ON DELETE CASCADE,
 number text NOT NULL, previous_profile text NOT NULL, target_profile text NOT NULL,
 expires_at timestamptz NOT NULL, PRIMARY KEY(domain_uuid,extension_uuid)
);
CREATE INDEX IF NOT EXISTS openweb_mobile_presence_expiry ON v_pbx_mobile_presence(expires_at);
ALTER TABLE v_pbx_mobile_devices ADD COLUMN IF NOT EXISTS push_token text;
ALTER TABLE v_pbx_mobile_devices ADD COLUMN IF NOT EXISTS push_project text;
CREATE TABLE IF NOT EXISTS v_pbx_mobile_push_config (
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
 enabled boolean NOT NULL DEFAULT false, project_id text NOT NULL,
 client_config jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE TABLE IF NOT EXISTS v_pbx_mobile_push_calls (
 request_uuid uuid PRIMARY KEY, call_uuid uuid NOT NULL,
 device_uuid uuid NOT NULL REFERENCES v_pbx_mobile_devices ON DELETE CASCADE,
 domain_uuid uuid NOT NULL REFERENCES v_domains ON DELETE CASCADE,
 extension_uuid uuid NOT NULL REFERENCES v_extensions ON DELETE CASCADE,
 state text NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','sent','ended','dismissed')),
 attempts integer NOT NULL DEFAULT 0, next_attempt_at timestamptz NOT NULL DEFAULT now(),
 created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL,
 UNIQUE(call_uuid,device_uuid)
);
CREATE INDEX IF NOT EXISTS openweb_mobile_push_pending ON v_pbx_mobile_push_calls(state,next_attempt_at);
ALTER TABLE v_pbx_mobile_push_calls ADD COLUMN IF NOT EXISTS lease_uuid uuid;
ALTER TABLE v_pbx_mobile_push_calls ADD COLUMN IF NOT EXISTS lease_until timestamptz;
ALTER TABLE v_pbx_mobile_push_calls ADD COLUMN IF NOT EXISTS notification_attempted_at timestamptz;
ALTER TABLE v_pbx_mobile_push_calls ADD COLUMN IF NOT EXISTS cancellation_sent_at timestamptz;
CREATE TABLE IF NOT EXISTS v_pbx_mobile_rate (
 bucket text PRIMARY KEY, window_start timestamptz NOT NULL, attempts integer NOT NULL
);
CREATE TABLE IF NOT EXISTS v_pbx_mobile_calls (
 device_uuid uuid NOT NULL REFERENCES v_pbx_mobile_devices ON DELETE CASCADE,
 call_uuid uuid NOT NULL, domain_uuid uuid NOT NULL REFERENCES v_domains ON DELETE CASCADE,
 extension_uuid uuid NOT NULL REFERENCES v_extensions ON DELETE CASCADE,
 party_number text NOT NULL, direction text NOT NULL CHECK(direction IN ('incoming','outgoing','missed')),
 started_at timestamptz NOT NULL, duration integer NOT NULL CHECK(duration BETWEEN 0 AND 86400),
 answered boolean NOT NULL, PRIMARY KEY(device_uuid,call_uuid)
);
CREATE INDEX IF NOT EXISTS openweb_mobile_calls_extension ON v_pbx_mobile_calls(extension_uuid,started_at DESC);
CREATE TABLE IF NOT EXISTS v_pbx_mobile_reviewers (
 user_uuid uuid PRIMARY KEY REFERENCES v_users ON DELETE CASCADE,
 domain_uuid uuid NOT NULL REFERENCES v_domains ON DELETE CASCADE,
 extension_uuid uuid UNIQUE NOT NULL REFERENCES v_extensions ON DELETE CASCADE,
 echo_number text NOT NULL CHECK(echo_number ~ '^[0-9]{2,10}$'),
 voicemail_number text NOT NULL CHECK(voicemail_number ~ '^[0-9]{2,10}$'),
 enabled boolean NOT NULL DEFAULT true,
 created_at timestamptz NOT NULL DEFAULT now()
);
-- App sign-in is independent of the extension's original SIP password.
CREATE TABLE IF NOT EXISTS v_pbx_mobile_accounts (
 extension_uuid uuid PRIMARY KEY REFERENCES v_extensions ON DELETE CASCADE,
 domain_uuid uuid NOT NULL REFERENCES v_domains ON DELETE CASCADE,
 password_hash text NOT NULL CHECK(password_hash LIKE '$argon2id$%'),
 generation bigint NOT NULL DEFAULT 1 CHECK(generation>0),
 updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid REFERENCES v_users ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS openweb_mobile_account_domain ON v_pbx_mobile_accounts(domain_uuid);
ALTER TABLE v_pbx_mobile_enrollments ALTER COLUMN created_by DROP NOT NULL;
ALTER TABLE v_pbx_mobile_enrollments ADD COLUMN IF NOT EXISTS purpose text NOT NULL DEFAULT 'screen';
CREATE TABLE IF NOT EXISTS v_pbx_mobile_welcome (
 welcome_uuid uuid PRIMARY KEY, domain_uuid uuid NOT NULL REFERENCES v_domains ON DELETE CASCADE,
 extension_uuid uuid NOT NULL REFERENCES v_extensions ON DELETE CASCADE,
 email_queue_uuid uuid REFERENCES v_email_queue ON DELETE SET NULL,
 enrollment_uuid uuid REFERENCES v_pbx_mobile_enrollments ON DELETE SET NULL,
 recipient text NOT NULL, created_by uuid REFERENCES v_users ON DELETE SET NULL,
 created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS openweb_mobile_welcome_extension ON v_pbx_mobile_welcome(domain_uuid,extension_uuid,created_at DESC);
-- Do not leave a queued setup invitation behind after its user is deleted.
CREATE OR REPLACE FUNCTION openweb_mobile_cancel_welcome() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 UPDATE v_email_queue SET email_status='cancelled',update_date=now()
 WHERE email_queue_uuid=OLD.email_queue_uuid AND email_status IN('waiting','trying');
 RETURN OLD;
END $$;
DROP TRIGGER IF EXISTS openweb_mobile_welcome_delete ON v_pbx_mobile_welcome;
CREATE TRIGGER openweb_mobile_welcome_delete BEFORE DELETE ON v_pbx_mobile_welcome
 FOR EACH ROW EXECUTE FUNCTION openweb_mobile_cancel_welcome();
COMMIT;
