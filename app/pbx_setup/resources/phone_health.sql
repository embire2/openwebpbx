-- Phone Health is additive. Successful registrations, never failed identity claims,
-- establish the office history used to authorise a recovery.
CREATE TABLE IF NOT EXISTS v_pbx_phone_health_contacts (
 domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 extension_uuid uuid NOT NULL REFERENCES v_extensions(extension_uuid) ON DELETE CASCADE,
 source_address inet NOT NULL, first_seen timestamptz NOT NULL DEFAULT now(),
 last_seen timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL, missing_since timestamptz,
 PRIMARY KEY(domain_uuid,extension_uuid,source_address)
);
CREATE INDEX IF NOT EXISTS openweb_phone_health_source ON v_pbx_phone_health_contacts(source_address,last_seen);
CREATE TABLE IF NOT EXISTS v_pbx_phone_health_recoveries (
 recovery_uuid uuid PRIMARY KEY, domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 actor_uuid uuid NOT NULL, block_uuid uuid NOT NULL, source_address inet NOT NULL,
 status text NOT NULL CHECK(status IN ('pending','acknowledged','refused','dispatch_failed')),
 created_at timestamptz NOT NULL DEFAULT now(), acknowledged_at timestamptz,
 instance_id text
);
ALTER TABLE v_pbx_phone_health_recoveries ADD COLUMN IF NOT EXISTS instance_id text;
CREATE INDEX IF NOT EXISTS openweb_phone_health_recovery_source ON v_pbx_phone_health_recoveries(source_address,created_at);
CREATE TABLE IF NOT EXISTS v_pbx_phone_health_issues (
 issue_uuid uuid NOT NULL UNIQUE, domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 issue_key text NOT NULL, kind text NOT NULL, severity text NOT NULL CHECK(severity IN ('warning','danger')),
 summary text NOT NULL, extra jsonb NOT NULL DEFAULT '{}', first_seen timestamptz NOT NULL DEFAULT now(),
 last_seen timestamptz NOT NULL DEFAULT now(), resolved_at timestamptz, acknowledged_at timestamptz,
 notified_at timestamptz, resolved_notified_at timestamptz,
 PRIMARY KEY(domain_uuid,issue_key)
);
CREATE TABLE IF NOT EXISTS v_pbx_phone_health_settings (
 domain_uuid uuid PRIMARY KEY REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 alerts_enabled boolean NOT NULL DEFAULT false, updated_by uuid, updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS v_pbx_phone_health_state (
 domain_uuid uuid PRIMARY KEY REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 checked_at timestamptz NOT NULL, available boolean NOT NULL, detail text NOT NULL
);
