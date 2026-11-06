BEGIN;
ALTER TABLE v_pbx_backup_commands ADD COLUMN IF NOT EXISTS full_backup boolean NOT NULL DEFAULT false;
ALTER TABLE v_pbx_protection_jobs DROP CONSTRAINT IF EXISTS v_pbx_protection_jobs_action_check;
ALTER TABLE v_pbx_protection_jobs ADD CONSTRAINT v_pbx_protection_jobs_action_check CHECK(action IN ('tenant_create','tenant_verify','tenant_restore','tenant_import','instance_verify','instance_restore','instance_import'));
CREATE TABLE IF NOT EXISTS v_pbx_tenant_restore_receipts (
 job_uuid uuid PRIMARY KEY, tenant_uuid uuid NOT NULL, committed_at timestamptz NOT NULL DEFAULT now()
);
COMMIT;
