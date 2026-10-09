BEGIN;
CREATE TABLE IF NOT EXISTS v_pbx_update_policies (
 scope_key text PRIMARY KEY CHECK(scope_key='instance' OR scope_key ~ '^tenant:[0-9a-f-]{36}$'),
 mode text NOT NULL DEFAULT 'notify' CHECK(mode IN ('notify','download','automatic','required')),
 channel text NOT NULL DEFAULT 'stable' CHECK(channel='stable'),
 maintenance_hour integer NOT NULL DEFAULT 2 CHECK(maintenance_hour BETWEEN 0 AND 23),
 maintenance_duration integer NOT NULL DEFAULT 2 CHECK(maintenance_duration BETWEEN 1 AND 6),
 updated_by uuid REFERENCES v_users(user_uuid) ON DELETE SET NULL,
 updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK((scope_key='instance' AND mode IN ('notify','download','automatic')) OR (scope_key<>'instance' AND mode IN ('notify','download','required')))
);
INSERT INTO v_pbx_update_policies(scope_key) VALUES('instance') ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS v_pbx_update_commands (
 command_uuid uuid PRIMARY KEY,
 action text NOT NULL CHECK(action IN ('check','download','install')),
 requested_by uuid REFERENCES v_users(user_uuid) ON DELETE SET NULL,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','running','completed','failed')),
 message text NOT NULL DEFAULT '',
 created_at timestamptz NOT NULL DEFAULT now(),
 started_at timestamptz, finished_at timestamptz
);
CREATE INDEX IF NOT EXISTS openweb_update_pending ON v_pbx_update_commands(status,created_at);
CREATE TABLE IF NOT EXISTS v_pbx_update_status (
 singleton integer PRIMARY KEY CHECK(singleton=1),
 status_json jsonb NOT NULL DEFAULT '{}'::jsonb,
 updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO v_pbx_update_status(singleton) VALUES(1) ON CONFLICT DO NOTHING;
DO $$
DECLARE permission text; target_group record;
BEGIN
 FOREACH permission IN ARRAY ARRAY['pbx_update_manage','pbx_update_instance'] LOOP
  IF NOT EXISTS(SELECT 1 FROM v_permissions WHERE permission_name=permission) THEN
   INSERT INTO v_permissions(permission_uuid,permission_name,application_name,application_uuid,permission_description)
    VALUES(gen_random_uuid(),permission,'Updates','5a609fd8-a63f-47f2-9a50-47903c6b2104',replace(permission,'_',' '));
  END IF;
  FOR target_group IN SELECT group_uuid,group_name FROM v_groups WHERE domain_uuid IS NULL AND
   (group_name='superadmin' OR (group_name='tenant_admin' AND permission='pbx_update_manage')) LOOP
   IF NOT EXISTS(SELECT 1 FROM v_group_permissions WHERE group_uuid=target_group.group_uuid AND permission_name=permission) THEN
    INSERT INTO v_group_permissions(group_permission_uuid,group_uuid,group_name,permission_name,permission_assigned)
     VALUES(gen_random_uuid(),target_group.group_uuid,target_group.group_name,permission,'true');
   END IF;
  END LOOP;
 END LOOP;
END $$;
COMMIT;
