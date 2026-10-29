-- Browser/image pairing holds no owner password or owner bearer credential.
BEGIN;
CREATE TABLE IF NOT EXISTS v_pbx_wizard_devices (
 pairing_uuid uuid PRIMARY KEY, bootstrap_uuid uuid NOT NULL UNIQUE,
 provider text NOT NULL CHECK(provider IN ('webhotel','debian')),
 image_version text NOT NULL, server_address text NOT NULL,
 local_tenant_uuid uuid NOT NULL, domain_uuid uuid NOT NULL,
 public_key text NOT NULL, key_hash text NOT NULL,
 device_hash text NOT NULL UNIQUE, user_code_hash text NOT NULL UNIQUE,
 account_tenant_uuid uuid REFERENCES v_pbx_tenants(tenant_uuid) ON DELETE SET NULL,
 account_user_uuid uuid REFERENCES v_users(user_uuid) ON DELETE SET NULL,
 label text, server_host text,
 bootstrap_nonce text NOT NULL, complete_nonce text,
 challenge_uuid uuid, installation_uuid uuid,
 activation jsonb, activation_expires_at timestamptz,
 tenant_hostname text,
 state text NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','claimed','bootstrap_pending','dns_ready','authorized','complete','revoked')),
 expires_at timestamptz NOT NULL, claimed_at timestamptz,
 terms_version text, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS openweb_wizard_owner ON v_pbx_wizard_devices(account_tenant_uuid,account_user_uuid,created_at);
CREATE INDEX IF NOT EXISTS openweb_wizard_identity ON v_pbx_wizard_devices(key_hash,local_tenant_uuid,domain_uuid);
COMMIT;
