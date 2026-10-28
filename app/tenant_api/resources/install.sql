-- Tenant API data is separate from tenant PBX configuration. Re-runnable.
BEGIN;
-- Public registration must never inherit an existing customer's provider
-- credentials through a shared GUI template. Operators opt in safe starters.
ALTER TABLE v_pbx_templates ADD COLUMN IF NOT EXISTS api_enabled boolean NOT NULL DEFAULT false;
CREATE TABLE IF NOT EXISTS v_pbx_api_registrations (
 registration_uuid uuid PRIMARY KEY,
 tenant_name text NOT NULL, slug text NOT NULL, email text NOT NULL,
 password_hash text NOT NULL, verification_hash text UNIQUE,
 expires_at timestamptz NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
 verified_at timestamptz, tenant_uuid uuid REFERENCES v_pbx_tenants(tenant_uuid) ON DELETE SET NULL,
 terms_version text NOT NULL DEFAULT '2026-10-28'
);
CREATE INDEX IF NOT EXISTS openweb_api_pending_email ON v_pbx_api_registrations(lower(email),created_at);
CREATE TABLE IF NOT EXISTS v_pbx_api_tokens (
 token_uuid uuid PRIMARY KEY,
 tenant_uuid uuid NOT NULL REFERENCES v_pbx_tenants(tenant_uuid) ON DELETE CASCADE,
 user_uuid uuid NOT NULL REFERENCES v_users(user_uuid) ON DELETE CASCADE,
 token_name text NOT NULL, token_hash text NOT NULL UNIQUE,
 created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL,
 revoked_at timestamptz, last_used_at timestamptz
);
CREATE INDEX IF NOT EXISTS openweb_api_token_owner ON v_pbx_api_tokens(tenant_uuid,user_uuid);
CREATE TABLE IF NOT EXISTS v_pbx_api_idempotency (
 tenant_uuid uuid NOT NULL REFERENCES v_pbx_tenants(tenant_uuid) ON DELETE CASCADE,
 idempotency_key uuid NOT NULL, operation text NOT NULL, request_hash text NOT NULL,
 response_status integer, response_body jsonb,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(tenant_uuid,idempotency_key)
);
CREATE TABLE IF NOT EXISTS v_pbx_api_rate (
 bucket text PRIMARY KEY, window_start timestamptz NOT NULL, attempts integer NOT NULL
);
CREATE TABLE IF NOT EXISTS v_pbx_api_audit (
 audit_uuid uuid PRIMARY KEY, tenant_uuid uuid REFERENCES v_pbx_tenants(tenant_uuid) ON DELETE SET NULL,
 user_uuid uuid REFERENCES v_users(user_uuid) ON DELETE SET NULL,
 action text NOT NULL, target_uuid uuid, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS openweb_api_audit_owner ON v_pbx_api_audit(tenant_uuid,created_at);
COMMIT;
