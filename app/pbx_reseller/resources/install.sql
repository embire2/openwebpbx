BEGIN;
CREATE TABLE IF NOT EXISTS v_pbx_access_keys (
 key_uuid uuid PRIMARY KEY, owner_user_uuid uuid NOT NULL REFERENCES v_users(user_uuid) ON DELETE CASCADE,
 tenant_uuid uuid REFERENCES v_pbx_tenants(tenant_uuid) ON DELETE CASCADE,
 domain_uuid uuid REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 key_name text NOT NULL CHECK(length(key_name) BETWEEN 1 AND 100),
 token_hash text NOT NULL UNIQUE CHECK(token_hash ~ '^[a-f0-9]{64}$'), prefix text NOT NULL,
 scopes jsonb NOT NULL CHECK(jsonb_typeof(scopes)='array'), expires_at timestamptz NOT NULL,
 revoked_at timestamptz, last_used_at timestamptz, last_used_ip inet,
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE v_pbx_access_keys ADD COLUMN IF NOT EXISTS parent_key_uuid uuid REFERENCES v_pbx_access_keys(key_uuid) ON DELETE CASCADE;
ALTER TABLE v_pbx_access_keys ADD COLUMN IF NOT EXISTS request_window timestamptz NOT NULL DEFAULT now();
ALTER TABLE v_pbx_access_keys ADD COLUMN IF NOT EXISTS request_count integer NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS openweb_access_key_owner ON v_pbx_access_keys(owner_user_uuid,created_at);
CREATE TABLE IF NOT EXISTS v_pbx_resource_plans (
 plan_uuid uuid PRIMARY KEY, owner_user_uuid uuid NOT NULL REFERENCES v_users(user_uuid),
 plan_name text NOT NULL CHECK(length(plan_name) BETWEEN 1 AND 100),
 extension_limit integer NOT NULL CHECK(extension_limit BETWEEN 1 AND 10000),
 concurrent_calls integer NOT NULL CHECK(concurrent_calls BETWEEN 1 AND 10000),
 extension_price_cents integer NOT NULL DEFAULT 0 CHECK(extension_price_cents>=0),
 call_price_cents integer NOT NULL DEFAULT 0 CHECK(call_price_cents>=0),
 currency text NOT NULL DEFAULT 'ZAR' CHECK(currency ~ '^[A-Z]{3}$'),
 enabled boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS v_pbx_service_entitlements (
 domain_uuid uuid PRIMARY KEY REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 plan_uuid uuid REFERENCES v_pbx_resource_plans(plan_uuid),
 extension_limit integer NOT NULL CHECK(extension_limit BETWEEN 1 AND 10000),
 concurrent_calls integer NOT NULL CHECK(concurrent_calls BETWEEN 1 AND 10000),
 extra_extensions integer NOT NULL DEFAULT 0 CHECK(extra_extensions BETWEEN 0 AND 10000),
 extra_calls integer NOT NULL DEFAULT 0 CHECK(extra_calls BETWEEN 0 AND 10000),
 billable boolean NOT NULL DEFAULT false, restore_hold boolean NOT NULL DEFAULT false,
 updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid REFERENCES v_users(user_uuid)
);
CREATE TABLE IF NOT EXISTS v_pbx_resource_orders (
 order_uuid uuid PRIMARY KEY, domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid),
 requested_by uuid NOT NULL REFERENCES v_users(user_uuid), idempotency_key text NOT NULL,
 extra_extensions integer NOT NULL CHECK(extra_extensions BETWEEN 0 AND 10000),
 extra_calls integer NOT NULL CHECK(extra_calls BETWEEN 0 AND 10000),
 monthly_amount_cents bigint NOT NULL CHECK(monthly_amount_cents>=0), currency text NOT NULL,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','approved','cancelled')),
 approved_by uuid REFERENCES v_users(user_uuid), created_at timestamptz NOT NULL DEFAULT now(), approved_at timestamptz,
 UNIQUE(domain_uuid,idempotency_key)
);
CREATE TABLE IF NOT EXISTS v_pbx_reseller_audit (
 event_uuid uuid PRIMARY KEY, actor_uuid uuid, tenant_uuid uuid, domain_uuid uuid,
 event_type text NOT NULL, details jsonb NOT NULL DEFAULT '{}', created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS v_pbx_protection_jobs (
 job_uuid uuid PRIMARY KEY, tenant_uuid uuid REFERENCES v_pbx_tenants(tenant_uuid),
 domain_uuid uuid REFERENCES v_domains(domain_uuid), requested_by uuid NOT NULL REFERENCES v_users(user_uuid),
 action text NOT NULL CHECK(action IN ('tenant_create','tenant_verify','tenant_restore','tenant_import','instance_verify','instance_restore','instance_import')),
 backup_uuid uuid, secret_ciphertext text NOT NULL, request jsonb NOT NULL DEFAULT '{}',
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','running','completed','failed')),
 message text NOT NULL DEFAULT '', created_at timestamptz NOT NULL DEFAULT now(), started_at timestamptz, finished_at timestamptz
);
CREATE TABLE IF NOT EXISTS v_pbx_tenant_backups (
 backup_uuid uuid PRIMARY KEY, tenant_uuid uuid NOT NULL REFERENCES v_pbx_tenants(tenant_uuid),
 requested_by uuid NOT NULL REFERENCES v_users(user_uuid), filename text NOT NULL UNIQUE,
 status text NOT NULL CHECK(status IN ('creating','ready','failed')), app_version text NOT NULL,
 size_bytes bigint NOT NULL DEFAULT 0, sha256 text NOT NULL DEFAULT '', media_count integer NOT NULL DEFAULT 0,
 created_at timestamptz NOT NULL DEFAULT now(), verified_at timestamptz, message text NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS v_pbx_reseller_settings (singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton), hosted boolean NOT NULL DEFAULT false, default_plan_uuid uuid REFERENCES v_pbx_resource_plans(plan_uuid));
INSERT INTO v_pbx_reseller_settings(singleton) VALUES(true) ON CONFLICT DO NOTHING;
ALTER TABLE v_pbx_tenants ADD COLUMN IF NOT EXISTS resource_plan_assigned_by uuid REFERENCES v_users(user_uuid);
ALTER TABLE v_pbx_tenants ADD COLUMN IF NOT EXISTS reseller_user_uuid uuid REFERENCES v_users(user_uuid);
ALTER TABLE v_pbx_tenants ADD COLUMN IF NOT EXISTS resource_plan_uuid uuid REFERENCES v_pbx_resource_plans(plan_uuid);
ALTER TABLE v_pbx_templates ADD COLUMN IF NOT EXISTS resource_plan_uuid uuid REFERENCES v_pbx_resource_plans(plan_uuid);
ALTER TABLE v_pbx_templates ADD COLUMN IF NOT EXISTS reseller_api_enabled boolean NOT NULL DEFAULT false;
CREATE OR REPLACE FUNCTION openweb_extension_entitlement() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE maximum integer; used integer;
BEGIN
 IF TG_OP='UPDATE' AND NEW.domain_uuid IS NOT DISTINCT FROM OLD.domain_uuid THEN RETURN NEW; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('openweb-extensions:'||NEW.domain_uuid::text,0));
 SELECT extension_limit+extra_extensions INTO maximum FROM v_pbx_service_entitlements WHERE domain_uuid=NEW.domain_uuid;
 IF maximum IS NULL THEN RETURN NEW; END IF;
 SELECT count(*) INTO used FROM v_extensions WHERE domain_uuid=NEW.domain_uuid;
 IF used>=maximum THEN RAISE EXCEPTION 'This PBX has reached its extension allowance. Ask your administrator to add capacity.' USING ERRCODE='P0001'; END IF;
 RETURN NEW;
END $$;
DO $$ BEGIN EXECUTE format('ALTER FUNCTION %I.openweb_extension_entitlement() SET search_path TO %I,pg_temp',current_schema(),current_schema()); END $$;
DROP TRIGGER IF EXISTS openweb_extension_entitlement ON v_extensions;
CREATE TRIGGER openweb_extension_entitlement BEFORE INSERT OR UPDATE OF domain_uuid ON v_extensions FOR EACH ROW EXECUTE FUNCTION openweb_extension_entitlement();
DO $$ DECLARE p text; g record; BEGIN
 FOREACH p IN ARRAY ARRAY['pbx_api_key_manage','pbx_tenant_backup','pbx_reseller_manage'] LOOP
  IF NOT EXISTS(SELECT 1 FROM v_permissions WHERE permission_name=p) THEN
   INSERT INTO v_permissions(permission_uuid,permission_name,application_name,application_uuid,permission_description)
   VALUES(gen_random_uuid(),p,'Reseller Services','7481a0dc-c025-4c23-9140-002500000001',replace(p,'_',' '));
  END IF;
  FOR g IN SELECT group_uuid,group_name FROM v_groups WHERE domain_uuid IS NULL AND (group_name='superadmin' OR (group_name='tenant_admin' AND p<>'pbx_reseller_manage') OR (group_name='admin' AND p='pbx_api_key_manage')) LOOP
   IF NOT EXISTS(SELECT 1 FROM v_group_permissions WHERE group_uuid=g.group_uuid AND permission_name=p) THEN
    INSERT INTO v_group_permissions(group_permission_uuid,group_uuid,group_name,permission_name,permission_assigned)
    VALUES(gen_random_uuid(),g.group_uuid,g.group_name,p,'true');
   END IF;
  END LOOP;
 END LOOP;
END $$;
COMMIT;
