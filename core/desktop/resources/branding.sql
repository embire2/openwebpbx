-- Apply OpenWeb PBX branding to an existing installation. Safe to run again.
BEGIN;
UPDATE v_default_settings SET default_setting_value = replace(default_setting_value, 'FusionPBX', 'OpenWeb PBX')
 WHERE default_setting_value LIKE '%FusionPBX%' AND default_setting_value NOT LIKE '%X-FusionPBX%'
 AND default_setting_subcategory !~* '(password|secret|token|key)';
UPDATE v_domain_settings SET domain_setting_value = replace(domain_setting_value, 'FusionPBX', 'OpenWeb PBX')
 WHERE domain_setting_value LIKE '%FusionPBX%' AND domain_setting_value NOT LIKE '%X-FusionPBX%'
 AND domain_setting_subcategory !~* '(password|secret|token|key)';
UPDATE v_email_templates SET template_subject = replace(template_subject, 'FusionPBX', 'OpenWeb PBX'),
 template_body = replace(template_body, 'FusionPBX', 'OpenWeb PBX')
 WHERE template_subject LIKE '%FusionPBX%' OR template_body LIKE '%FusionPBX%';
UPDATE v_software SET software_name = 'OpenWeb PBX', software_url = 'https://github.com/embire2/openwebpbx'
 WHERE software_name IN ('FusionPBX', 'OpenWeb PBX');
UPDATE v_menu_languages SET menu_item_title = replace(menu_item_title, 'FusionPBX', 'OpenWeb PBX') WHERE menu_item_title LIKE '%FusionPBX%';
DO $$
DECLARE branding record;
BEGIN
 FOR branding IN SELECT * FROM (VALUES
 ('theme','title','OpenWeb PBX'),
 ('theme','logo','/themes/default/images/openweb-logo.svg'),
 ('theme','logo_login','/themes/default/images/openweb-logo.svg'),
 ('theme','favicon','/themes/default/images/openweb-mark.svg'),
 ('theme','menu_brand_text','OpenWeb PBX'),
 ('theme','body_header_brand_text','OpenWeb PBX'),
 ('theme','menu_side_brand_image_contracted','/themes/default/images/openweb-mark.svg'),
 ('theme','menu_side_brand_image_expanded','/themes/default/images/openweb-logo.svg'),
 ('theme','footer','OpenWeb PBX · MPL 1.1'),
 ('login','destination','/core/desktop/')
 ) AS b(category,subcategory,value)
 LOOP
  UPDATE v_default_settings SET default_setting_value = branding.value, default_setting_enabled = true
   WHERE default_setting_category = branding.category AND default_setting_subcategory = branding.subcategory AND default_setting_name = 'text';
  IF NOT FOUND THEN
   INSERT INTO v_default_settings (default_setting_uuid,default_setting_category,default_setting_subcategory,default_setting_name,default_setting_value,default_setting_enabled,default_setting_description)
   VALUES (gen_random_uuid(),branding.category,branding.subcategory,'text',branding.value,true,'OpenWeb PBX branding');
  END IF;
 END LOOP;
END $$;
COMMIT;
