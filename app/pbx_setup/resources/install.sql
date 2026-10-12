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

-- OpenWeb PBX 1.0.9 core operations
create table if not exists v_pbx_core_checks (
    check_uuid uuid primary key,
    domain_uuid uuid not null,
    trunk_id varchar(40) not null,
    check_kind varchar(24) not null,
    call_uuid uuid,
    result varchar(24) not null,
    note varchar(500) not null default '',
    checked_by uuid not null,
    created_at timestamptz not null default now()
);
create index if not exists pbx_core_checks_scope on v_pbx_core_checks(domain_uuid,trunk_id,created_at desc);
alter table v_pbx_core_checks add column if not exists config_hash varchar(64) not null default '';
create table if not exists v_pbx_core_audit (
    audit_uuid uuid primary key,
    domain_uuid uuid not null,
    actor_uuid uuid not null,
    action varchar(32) not null,
    call_uuid uuid,
    target varchar(80) not null default '',
    result varchar(24) not null,
    created_at timestamptz not null default now()
);
create index if not exists pbx_core_audit_scope on v_pbx_core_audit(domain_uuid,created_at desc);
create table if not exists v_pbx_queue_tickets (
    ticket_id bigserial primary key,
    domain_uuid uuid not null,
    queue_number varchar(10) not null,
    call_uuid uuid not null,
    state varchar(16) not null default 'waiting',
    job_uuid uuid,
    joined_at timestamptz not null default now(),
    ended_at timestamptz,
    wait_seconds integer not null default 0,
    unique(domain_uuid,queue_number,call_uuid)
);
create index if not exists pbx_queue_ticket_order on v_pbx_queue_tickets(domain_uuid,queue_number,state,joined_at);
