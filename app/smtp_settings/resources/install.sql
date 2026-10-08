-- Register instance SMTP administration without inventing relay settings.
-- smtp_global records whether an administrator saved a global relay; false means mail must wait.
BEGIN;
INSERT INTO v_permissions(permission_uuid,permission_name,application_name,application_uuid,permission_description)
 SELECT gen_random_uuid(),'smtp_settings_manage','SMTP Outgoing Mail','986b9340-3285-4708-840d-eb5790e94110','Manage the global outgoing mail server'
 WHERE NOT EXISTS(SELECT 1 FROM v_permissions WHERE permission_name='smtp_settings_manage');
INSERT INTO v_group_permissions(group_permission_uuid,group_uuid,group_name,permission_name,permission_assigned)
 SELECT gen_random_uuid(),g.group_uuid,g.group_name,'smtp_settings_manage','true' FROM v_groups g
 WHERE g.group_name='superadmin' AND g.domain_uuid IS NULL
 AND NOT EXISTS(SELECT 1 FROM v_group_permissions p WHERE p.group_uuid=g.group_uuid AND p.permission_name='smtp_settings_manage');
INSERT INTO v_default_settings(default_setting_uuid,default_setting_category,default_setting_subcategory,default_setting_name,default_setting_value,default_setting_enabled,default_setting_order,default_setting_description)
 SELECT gen_random_uuid(),'email','smtp_global','text','false',true,100,'The instance outgoing mail server has been configured'
 WHERE NOT EXISTS(SELECT 1 FROM v_default_settings WHERE default_setting_category='email' AND default_setting_subcategory='smtp_global');
DO $$
DECLARE menu_id uuid; item_id uuid := '986b9340-3285-4708-840d-eb5790e94111';
BEGIN
 SELECT menu_uuid INTO menu_id FROM v_menus ORDER BY menu_name LIMIT 1;
 INSERT INTO v_menu_items(menu_item_uuid,menu_uuid,menu_item_title,menu_item_link,menu_item_category,menu_item_order,menu_item_icon)
  SELECT item_id,menu_id,'SMTP Outgoing Mail','/app/smtp_settings/','internal',6,'fa-solid fa-envelope'
  WHERE NOT EXISTS(SELECT 1 FROM v_menu_items WHERE menu_item_uuid=item_id);
 INSERT INTO v_menu_languages(menu_language_uuid,menu_uuid,menu_item_uuid,menu_language,menu_item_title)
  SELECT gen_random_uuid(),menu_id,item_id,l.menu_language,'SMTP Outgoing Mail'
  FROM (SELECT DISTINCT menu_language FROM v_menu_languages WHERE menu_uuid=menu_id) l
  WHERE NOT EXISTS(SELECT 1 FROM v_menu_languages x WHERE x.menu_item_uuid=item_id AND x.menu_language=l.menu_language);
 INSERT INTO v_menu_item_groups(menu_item_group_uuid,menu_uuid,menu_item_uuid,group_uuid,group_name)
  SELECT gen_random_uuid(),menu_id,item_id,g.group_uuid,g.group_name FROM v_groups g
  WHERE g.group_name='superadmin' AND g.domain_uuid IS NULL
  AND NOT EXISTS(SELECT 1 FROM v_menu_item_groups x WHERE x.menu_item_uuid=item_id AND x.group_uuid=g.group_uuid);
END $$;
COMMIT;
