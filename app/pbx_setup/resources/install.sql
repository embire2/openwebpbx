-- Apply after tenant_services/resources/install.sql with psql -v ON_ERROR_STOP=1.
BEGIN;
CREATE TABLE IF NOT EXISTS v_pbx_setup_drafts (
 draft_uuid uuid PRIMARY KEY, user_uuid uuid NOT NULL REFERENCES v_users(user_uuid) ON DELETE CASCADE,
 kind text NOT NULL CHECK(kind IN ('setup','import')), payload_ciphertext text,
 preview jsonb NOT NULL, expires_at timestamptz NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
 completed_domain_uuid uuid REFERENCES v_domains(domain_uuid) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS openweb_setup_owner ON v_pbx_setup_drafts(user_uuid,expires_at);
DO $$
DECLARE r record; menu_id uuid; item_id uuid := '7bc5a01f-1a32-4ad9-8a9a-0c7a861eaa11';
BEGIN
 IF NOT EXISTS(SELECT 1 FROM v_permissions WHERE permission_name='pbx_setup_manage') THEN
  INSERT INTO v_permissions(permission_uuid,permission_name,application_name,application_uuid,permission_description)
  VALUES(gen_random_uuid(),'pbx_setup_manage','PBX Setup','7bc5a01f-1a32-4ad9-8a9a-0c7a861eaa10','Guided PBX setup and reviewed configuration migration');
 END IF;
 SELECT menu_uuid INTO menu_id FROM v_menus ORDER BY menu_name LIMIT 1;
 INSERT INTO v_menu_items(menu_item_uuid,menu_uuid,menu_item_title,menu_item_link,menu_item_category,menu_item_order,menu_item_icon)
 VALUES(item_id,menu_id,'PBX Setup','/app/pbx_setup/','internal',0,'fa-solid fa-wand-magic-sparkles') ON CONFLICT(menu_item_uuid) DO NOTHING;
 INSERT INTO v_menu_languages(menu_language_uuid,menu_uuid,menu_item_uuid,menu_language,menu_item_title)
 SELECT gen_random_uuid(),menu_id,item_id,l.menu_language,'PBX Setup' FROM (SELECT DISTINCT menu_language FROM v_menu_languages WHERE menu_uuid=menu_id) l
 WHERE NOT EXISTS(SELECT 1 FROM v_menu_languages x WHERE x.menu_item_uuid=item_id AND x.menu_language=l.menu_language);
 FOR r IN SELECT group_uuid,group_name FROM v_groups WHERE group_name IN ('superadmin','tenant_admin') AND domain_uuid IS NULL LOOP
  IF NOT EXISTS(SELECT 1 FROM v_group_permissions WHERE group_uuid=r.group_uuid AND permission_name='pbx_setup_manage') THEN
   INSERT INTO v_group_permissions(group_permission_uuid,group_uuid,group_name,permission_name,permission_assigned)
   VALUES(gen_random_uuid(),r.group_uuid,r.group_name,'pbx_setup_manage','true');
  END IF;
  IF NOT EXISTS(SELECT 1 FROM v_menu_item_groups WHERE menu_item_uuid=item_id AND group_uuid=r.group_uuid) THEN
   INSERT INTO v_menu_item_groups(menu_item_group_uuid,menu_uuid,menu_item_uuid,group_uuid,group_name)
   VALUES(gen_random_uuid(),menu_id,item_id,r.group_uuid,r.group_name);
  END IF;
 END LOOP;
END $$;
COMMIT;
