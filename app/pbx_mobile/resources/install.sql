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
COMMIT;
