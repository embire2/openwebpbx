-- Central authorization of external installations. Never creates a hosted PBX.
BEGIN;
CREATE TABLE IF NOT EXISTS v_pbx_installation_email_verifications (
 verification_uuid uuid PRIMARY KEY,
 account_tenant_uuid uuid NOT NULL REFERENCES v_pbx_tenants(tenant_uuid) ON DELETE CASCADE,
 account_user_uuid uuid NOT NULL REFERENCES v_users(user_uuid) ON DELETE CASCADE,
 email text NOT NULL, verification_hash text UNIQUE, expires_at timestamptz NOT NULL,
 verified_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(account_tenant_uuid,account_user_uuid,email)
);
CREATE TABLE IF NOT EXISTS v_pbx_installation_challenges (
 challenge_uuid uuid PRIMARY KEY,
 account_tenant_uuid uuid NOT NULL REFERENCES v_pbx_tenants(tenant_uuid) ON DELETE CASCADE,
 account_user_uuid uuid NOT NULL REFERENCES v_users(user_uuid) ON DELETE CASCADE,
 nonce text NOT NULL UNIQUE, public_key text NOT NULL, key_hash text NOT NULL,
 server_host text NOT NULL, local_tenant_uuid uuid NOT NULL, domain_uuid uuid NOT NULL,
 label text NOT NULL, expires_at timestamptz NOT NULL, consumed_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS openweb_installation_challenge_owner ON v_pbx_installation_challenges(account_tenant_uuid,expires_at);
CREATE TABLE IF NOT EXISTS v_pbx_installation_authorizations (
 installation_uuid uuid PRIMARY KEY,
 account_tenant_uuid uuid NOT NULL REFERENCES v_pbx_tenants(tenant_uuid) ON DELETE CASCADE,
 local_tenant_uuid uuid NOT NULL, domain_uuid uuid NOT NULL,
 key_hash text NOT NULL, public_key text NOT NULL, server_host text NOT NULL, label text NOT NULL,
 generation integer NOT NULL DEFAULT 1 CHECK(generation>0),
 state text NOT NULL DEFAULT 'authorized' CHECK(state IN ('authorized','revoked')),
 issued_at timestamptz NOT NULL, expires_at timestamptz NOT NULL,
 activation jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(key_hash,domain_uuid)
);
CREATE INDEX IF NOT EXISTS openweb_installation_authorization_owner ON v_pbx_installation_authorizations(account_tenant_uuid,created_at);
COMMIT;
