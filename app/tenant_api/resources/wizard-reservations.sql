BEGIN;
-- Custodian controls outlive deletion of the registering account so a provider
-- can still remove its exact DNS before reusing the VM's address. They confer
-- cleanup authority only and cannot enable calls or register another server.
CREATE TABLE IF NOT EXISTS v_pbx_wizard_reservation_controls (
 reservation_uuid uuid PRIMARY KEY, account_tenant_uuid uuid NOT NULL,
 account_user_uuid uuid NOT NULL, request_uuid uuid NOT NULL, label text NOT NULL,
 control_hash text NOT NULL UNIQUE, control_ciphertext text NOT NULL,
 bootstrap_uuid uuid, key_hash text, domain_uuid uuid, server_address text,
 state text NOT NULL DEFAULT 'reserved' CHECK(state IN ('reserved','bound','revoking','revoked','released')),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(account_tenant_uuid,request_uuid)
);
COMMIT;
