BEGIN;
-- The installer/operator sets this flag only for a fresh managed installation.
-- Reapplying this migration never enables a registration gate on existing PBXs.
CREATE TABLE IF NOT EXISTS v_pbx_onboarding_policy (
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
 required boolean NOT NULL DEFAULT false,
 canonical_host text NOT NULL DEFAULT '',
 instance_key_hash text NOT NULL DEFAULT ''
);
INSERT INTO v_pbx_onboarding_policy(singleton) VALUES(true) ON CONFLICT(singleton) DO NOTHING;

CREATE TABLE IF NOT EXISTS v_pbx_onboarding (
 domain_uuid uuid PRIMARY KEY REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 tenant_uuid uuid NOT NULL REFERENCES v_pbx_tenants(tenant_uuid) ON DELETE CASCADE,
 service_uuid uuid NOT NULL UNIQUE REFERENCES v_pbx_services(service_uuid) ON DELETE CASCADE,
 owner_user_uuid uuid NOT NULL REFERENCES v_users(user_uuid),
 account_tenant_uuid uuid, account_email text NOT NULL DEFAULT '',
 requested_label text NOT NULL DEFAULT '', server_host text NOT NULL DEFAULT '', key_hash text NOT NULL DEFAULT '',
 token_ciphertext text NOT NULL DEFAULT '', token_expires_at timestamptz,
 state text NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','account_pending','account_ready','queued','preparing','ready','retry')),
 activation jsonb, grant_expires_at timestamptz,
 revision bigint NOT NULL DEFAULT 0 CHECK(revision>=0), last_error_category text NOT NULL DEFAULT '',
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS v_pbx_onboarding_jobs (
 job_uuid uuid PRIMARY KEY,
 domain_uuid uuid NOT NULL REFERENCES v_pbx_onboarding(domain_uuid) ON DELETE CASCADE,
 revision bigint NOT NULL CHECK(revision>0),
 state text NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','preparing','completed','retry','superseded')),
 attempts integer NOT NULL DEFAULT 0 CHECK(attempts>=0), next_attempt timestamptz NOT NULL DEFAULT now(),
 error_category text NOT NULL DEFAULT '', created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(domain_uuid,revision)
);
CREATE INDEX IF NOT EXISTS openweb_onboarding_job_due ON v_pbx_onboarding_jobs(state,next_attempt);
COMMIT;
