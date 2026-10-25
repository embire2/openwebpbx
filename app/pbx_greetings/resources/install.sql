BEGIN;
CREATE TABLE IF NOT EXISTS v_pbx_greetings (
 greeting_uuid uuid PRIMARY KEY,
 domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 created_by uuid REFERENCES v_users(user_uuid) ON DELETE SET NULL,
 name text NOT NULL CHECK(length(name) BETWEEN 1 AND 120),
 category text NOT NULL CHECK(category IN ('voicemail','receptionist','queue_intro','queue_wait','hold_music','announcement')),
 source text NOT NULL CHECK(source IN ('phone','text')),
 company_name text NOT NULL CHECK(length(company_name) BETWEEN 1 AND 120),
 script text NOT NULL DEFAULT '' CHECK(length(script)<=3000),
 target_number text NOT NULL DEFAULT '', caller_extension text NOT NULL DEFAULT '',
 state text NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','preparing','ready_to_call','calling','ready','failed','cancelled','archived')),
 call_uuid uuid, media_uuid uuid UNIQUE,
 last_result text NOT NULL DEFAULT '',
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),
 lease_until timestamptz,
 attempts integer NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 3)
);
CREATE INDEX IF NOT EXISTS openweb_greetings_domain ON v_pbx_greetings(domain_uuid,created_at DESC);
CREATE INDEX IF NOT EXISTS openweb_greetings_pending ON v_pbx_greetings(created_at) WHERE state IN ('pending','ready_to_call');
CREATE TABLE IF NOT EXISTS v_pbx_greeting_status (
 singleton integer PRIMARY KEY CHECK(singleton=1),
 provider_configured boolean NOT NULL DEFAULT false,
 checked_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS v_pbx_greeting_uses (
 domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 greeting_uuid uuid NOT NULL REFERENCES v_pbx_greetings(greeting_uuid) ON DELETE RESTRICT,
 kind text NOT NULL CHECK(kind IN ('voicemail','receptionist','queue_intro','queue_wait','hold_music','extension_hold')),
 target_number text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(domain_uuid,kind,target_number)
);
COMMIT;
