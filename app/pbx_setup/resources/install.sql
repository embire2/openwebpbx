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
-- A public phone address can change without renaming private media, routing or app accounts.
create table if not exists v_pbx_sip_domains (
    sip_domain varchar(253) primary key check (sip_domain=lower(sip_domain)),
    domain_uuid uuid not null references v_domains(domain_uuid) on delete cascade,
    enabled boolean not null default true,
    created_by uuid not null,
    created_at timestamptz not null default now()
);
create index if not exists pbx_sip_domains_owner on v_pbx_sip_domains(domain_uuid,enabled);

-- Department-scoped staff accounts. These do not receive native administrator permissions.
BEGIN;
CREATE TABLE IF NOT EXISTS v_pbx_staff_roles (
 staff_role_uuid uuid PRIMARY KEY, domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 user_uuid uuid NOT NULL REFERENCES v_users(user_uuid) ON DELETE CASCADE,
 extension_uuid uuid NOT NULL REFERENCES v_extensions(extension_uuid) ON DELETE CASCADE,
 department_id text NOT NULL, role text NOT NULL CHECK(role IN ('user','receptionist','supervisor','department_admin','manager','owner')),
 enabled boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(domain_uuid,user_uuid,department_id)
);
CREATE INDEX IF NOT EXISTS openweb_staff_lookup ON v_pbx_staff_roles(user_uuid,domain_uuid) WHERE enabled;
CREATE TABLE IF NOT EXISTS v_pbx_staff_invites (
 invite_uuid uuid PRIMARY KEY, domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 user_uuid uuid NOT NULL REFERENCES v_users(user_uuid) ON DELETE CASCADE,
 token_hash text NOT NULL UNIQUE, expires_at timestamptz NOT NULL, consumed_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS v_pbx_staff_audit (
 audit_uuid uuid PRIMARY KEY, domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 actor_uuid uuid NOT NULL, action text NOT NULL, target text NOT NULL, result text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
DO $$
DECLARE g uuid; m uuid; existing_item uuid; item uuid := 'c493b34d-1ca4-4a1c-8dc3-129662029e61';
BEGIN
 SELECT group_uuid INTO g FROM v_groups WHERE domain_uuid IS NULL AND group_name='openweb_staff';
 IF g IS NULL THEN
  g:=gen_random_uuid();INSERT INTO v_groups(group_uuid,group_name,group_description)VALUES(g,'openweb_staff','Department-scoped OpenWeb PBX staff');
 END IF;
 INSERT INTO v_permissions(permission_uuid,permission_name,application_name,application_uuid,permission_description)
 SELECT gen_random_uuid(),'pbx_staff_view','PBX Staff','c493b34d-1ca4-4a1c-8dc3-129662029e60','Open the department-scoped staff workspace'
 WHERE NOT EXISTS(SELECT 1 FROM v_permissions WHERE permission_name='pbx_staff_view');
 INSERT INTO v_group_permissions(group_permission_uuid,group_uuid,group_name,permission_name,permission_assigned)
 SELECT gen_random_uuid(),g,'openweb_staff','pbx_staff_view','true'
 WHERE NOT EXISTS(SELECT 1 FROM v_group_permissions WHERE group_uuid=g AND permission_name='pbx_staff_view');
 SELECT menu_uuid INTO m FROM v_menus ORDER BY (menu_name='default') DESC,menu_name LIMIT 1;
 SELECT menu_item_uuid INTO existing_item FROM v_menu_items WHERE menu_uuid=m AND (uuid=item OR menu_item_uuid=item) LIMIT 1;
 IF existing_item IS NOT NULL THEN item:=existing_item; END IF;
 INSERT INTO v_menu_items(menu_item_uuid,menu_uuid,uuid,menu_item_title,menu_item_link,menu_item_category,menu_item_order,menu_item_icon)
 VALUES(item,m,item,'My PBX','/app/pbx_staff/','internal',1,'fa-solid fa-users') ON CONFLICT(menu_item_uuid) DO NOTHING;
 INSERT INTO v_menu_item_groups(menu_item_group_uuid,menu_uuid,menu_item_uuid,group_uuid,group_name)
 SELECT gen_random_uuid(),m,item,g,'openweb_staff' WHERE NOT EXISTS(SELECT 1 FROM v_menu_item_groups WHERE menu_item_uuid=item AND group_uuid=g);
END $$;
COMMIT;

BEGIN;
CREATE TABLE IF NOT EXISTS v_pbx_phone_moves (
 move_uuid uuid PRIMARY KEY, domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 extension_uuid uuid NOT NULL REFERENCES v_extensions(extension_uuid) ON DELETE CASCADE,
 number text NOT NULL, model text NOT NULL CHECK(model IN ('yealink_w60b','fanvil_v62w')),
 firmware text NOT NULL, line_number integer NOT NULL CHECK(line_number BETWEEN 1 AND 8),
 mac text NOT NULL DEFAULT '', old_domain text NOT NULL, phone_domain text NOT NULL,
 sip_port integer NOT NULL CHECK(sip_port BETWEEN 1 AND 65535), transport text NOT NULL CHECK(transport IN ('udp','tcp','tls')),
 identity_hmac text NOT NULL, policy_hmac text NOT NULL, backup_verified boolean NOT NULL,
 provisioning_reviewed boolean NOT NULL DEFAULT false, source_ciphertext text, source_sha256 text,
 export_expires timestamptz NOT NULL DEFAULT (now()+interval '48 hours'),
 created_at timestamptz NOT NULL DEFAULT now(), created_by uuid NOT NULL,
 UNIQUE(domain_uuid,extension_uuid,mac,line_number)
);
CREATE TABLE IF NOT EXISTS v_pbx_phone_move_checks (
 check_uuid uuid PRIMARY KEY, domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 move_uuid uuid NOT NULL REFERENCES v_pbx_phone_moves(move_uuid) ON DELETE CASCADE,
 check_kind text NOT NULL, call_uuid uuid, policy_hmac text NOT NULL, note text NOT NULL DEFAULT '',
 checked_by uuid NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS v_pbx_migration_resolutions (
 resolution_uuid uuid PRIMARY KEY, domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 note_hash text NOT NULL, decision text NOT NULL CHECK(decision='accepted_source_limitation'),
 explanation text NOT NULL, actor_uuid uuid NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
COMMIT;

BEGIN;
CREATE TABLE IF NOT EXISTS v_pbx_provider_attempts (
 attempt_uuid uuid PRIMARY KEY, domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 call_uuid uuid NOT NULL, attempt_no integer NOT NULL CHECK(attempt_no BETWEEN 1 AND 100), leg_uuid uuid NOT NULL,
 trunk_id text NOT NULL, provider_uuid uuid NOT NULL, owner_number text NOT NULL, dialled_number text NOT NULL,
 state text NOT NULL CHECK(state IN ('calling','skipped','answered','failed','cancelled')),
 cause text NOT NULL DEFAULT '', sip_status integer NOT NULL DEFAULT 0, will_retry boolean NOT NULL DEFAULT false,
 config_hash text NOT NULL, started_at timestamptz NOT NULL DEFAULT now(), finished_at timestamptz,
 UNIQUE(domain_uuid,call_uuid,attempt_no)
);
CREATE INDEX IF NOT EXISTS openweb_provider_calls ON v_pbx_provider_attempts(domain_uuid,started_at DESC);
COMMIT;
