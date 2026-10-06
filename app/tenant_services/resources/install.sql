-- OpenWeb PBX tenant workspace. Apply with psql -v ON_ERROR_STOP=1.
BEGIN;
CREATE TABLE IF NOT EXISTS v_pbx_tenants (
 tenant_uuid uuid PRIMARY KEY, tenant_name text NOT NULL, slug text NOT NULL UNIQUE,
 home_domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 owner_user_uuid uuid UNIQUE REFERENCES v_users(user_uuid) ON DELETE SET NULL,
 invite_email text NOT NULL, invite_hash text UNIQUE, invite_expires timestamptz,
 enabled boolean NOT NULL DEFAULT true, service_limit integer NOT NULL DEFAULT 10 CHECK(service_limit BETWEEN 1 AND 100),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS v_pbx_templates (
 template_uuid uuid PRIMARY KEY, tenant_uuid uuid REFERENCES v_pbx_tenants(tenant_uuid) ON DELETE CASCADE,
 template_name text NOT NULL, description text NOT NULL DEFAULT '',
 published boolean NOT NULL DEFAULT false, version integer NOT NULL DEFAULT 1,
 payload_ciphertext text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS v_pbx_services (
 service_uuid uuid PRIMARY KEY, tenant_uuid uuid NOT NULL REFERENCES v_pbx_tenants(tenant_uuid) ON DELETE CASCADE,
 domain_uuid uuid NOT NULL UNIQUE REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 template_uuid uuid REFERENCES v_pbx_templates(template_uuid) ON DELETE SET NULL,
 template_name text NOT NULL, template_version integer NOT NULL, service_name text NOT NULL,
 request_uuid uuid NOT NULL UNIQUE, created_by uuid NOT NULL REFERENCES v_users(user_uuid),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS openweb_domain_name_unique ON v_domains(lower(domain_name));
CREATE UNIQUE INDEX IF NOT EXISTS openweb_invite_email_unique ON v_pbx_tenants(lower(invite_email));
CREATE UNIQUE INDEX IF NOT EXISTS openweb_username_unique ON v_users(lower(username)) WHERE username IS NOT NULL AND username<>'';
CREATE UNIQUE INDEX IF NOT EXISTS openweb_email_unique ON v_users(lower(user_email)) WHERE user_email IS NOT NULL AND user_email<>'';
CREATE INDEX IF NOT EXISTS openweb_service_tenant ON v_pbx_services(tenant_uuid);
-- All tenants sign in on the central hostname with globally unique email identities.
UPDATE v_default_settings SET default_setting_value='global', default_setting_enabled='true'
 WHERE default_setting_category='users' AND default_setting_subcategory='unique';
DO $$
DECLARE tenant_group uuid; p text; r record; menu_id uuid; item_id uuid := '1c279eb7-b1c1-4f67-bef8-dda4a1110101';
BEGIN
 SELECT group_uuid INTO tenant_group FROM v_groups WHERE group_name='tenant_admin' AND domain_uuid IS NULL LIMIT 1;
 IF tenant_group IS NULL THEN
  tenant_group:=gen_random_uuid();
  INSERT INTO v_groups(group_uuid,group_name,group_level,group_description,group_protected)
   VALUES(tenant_group,'tenant_admin',40,'Tenant administrator with isolated PBX services','true');
 END IF;
 -- Copy ordinary PBX administration capabilities, excluding cross-domain and role delegation privileges.
 FOR r IN SELECT DISTINCT permission_name FROM v_group_permissions WHERE group_name='admin' AND permission_assigned='true'
  AND permission_name !~ '(^domain_|_all$|^user_group|^group_|^user_setting_|^user_type$|_domain$|_domain_all$)' LOOP
  IF NOT EXISTS(SELECT 1 FROM v_group_permissions WHERE group_uuid=tenant_group AND permission_name=r.permission_name) THEN
   INSERT INTO v_group_permissions(group_permission_uuid,group_uuid,group_name,permission_name,permission_assigned)
    VALUES(gen_random_uuid(),tenant_group,'tenant_admin',r.permission_name,'true');
  END IF;
 END LOOP;
 FOREACH p IN ARRAY ARRAY['pbx_service_view','pbx_service_create','pbx_template_manage','pbx_tenant_manage','user_groups','gateway_view','gateway_add','gateway_edit','gateway_delete','dialplan_view','dialplan_add','dialplan_edit','dialplan_delete','dialplan_detail_add','dialplan_detail_edit','dialplan_detail_delete'] LOOP
  IF NOT EXISTS(SELECT 1 FROM v_permissions WHERE permission_name=p) THEN
   INSERT INTO v_permissions(permission_uuid,permission_name,application_name,application_uuid,permission_description)
    VALUES(gen_random_uuid(),p,'Tenant Services','1c279eb7-b1c1-4f67-bef8-dda4a1110100',replace(p,'_',' '));
  END IF;
  FOR r IN SELECT group_uuid,group_name FROM v_groups WHERE domain_uuid IS NULL AND
   (group_name='superadmin' OR (group_name='tenant_admin' AND p<>'pbx_tenant_manage')) LOOP
   IF NOT EXISTS(SELECT 1 FROM v_group_permissions WHERE group_uuid=r.group_uuid AND permission_name=p) THEN
    INSERT INTO v_group_permissions(group_permission_uuid,group_uuid,group_name,permission_name,permission_assigned)
     VALUES(gen_random_uuid(),r.group_uuid,r.group_name,p,'true');
   END IF;
  END LOOP;
 END LOOP;
 SELECT menu_uuid INTO menu_id FROM v_menus ORDER BY menu_name LIMIT 1;
 IF NOT EXISTS(SELECT 1 FROM v_menu_items WHERE menu_item_uuid=item_id) THEN
  INSERT INTO v_menu_items(menu_item_uuid,menu_uuid,menu_item_title,menu_item_link,menu_item_category,menu_item_order,menu_item_icon)
   VALUES(item_id,menu_id,'Tenant Services','/app/tenant_services/','internal',5,'fa-solid fa-building');
 END IF;
 INSERT INTO v_menu_languages(menu_language_uuid,menu_uuid,menu_item_uuid,menu_language,menu_item_title)
  SELECT gen_random_uuid(),menu_id,item_id,l.menu_language,'Tenant Services'
   FROM (SELECT DISTINCT menu_language FROM v_menu_languages WHERE menu_uuid=menu_id) l
   WHERE NOT EXISTS(SELECT 1 FROM v_menu_languages x WHERE x.menu_item_uuid=item_id AND x.menu_language=l.menu_language);
 FOR r IN SELECT group_uuid,group_name FROM v_groups WHERE group_name IN ('superadmin','tenant_admin') AND domain_uuid IS NULL LOOP
  IF NOT EXISTS(SELECT 1 FROM v_menu_item_groups WHERE menu_item_uuid=item_id AND group_uuid=r.group_uuid) THEN
   INSERT INTO v_menu_item_groups(menu_item_group_uuid,menu_uuid,menu_item_uuid,group_uuid,group_name)
    VALUES(gen_random_uuid(),menu_id,item_id,r.group_uuid,r.group_name);
  END IF;
  -- Use the ordinary admin menu for tenant PBX applications; endpoint permissions still apply.
  IF r.group_name='tenant_admin' THEN
   INSERT INTO v_menu_item_groups(menu_item_group_uuid,menu_uuid,menu_item_uuid,group_uuid,group_name)
    SELECT gen_random_uuid(),m.menu_uuid,m.menu_item_uuid,r.group_uuid,r.group_name FROM v_menu_item_groups m
     WHERE m.group_name='admin' AND NOT EXISTS(SELECT 1 FROM v_menu_item_groups x WHERE x.menu_item_uuid=m.menu_item_uuid AND x.group_uuid=r.group_uuid);
  END IF;
 END LOOP;
END $$;
COMMIT;
