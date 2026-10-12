BEGIN;
CREATE TABLE IF NOT EXISTS v_pbx_backup_settings (
 singleton integer PRIMARY KEY CHECK(singleton=1),
 enabled boolean NOT NULL DEFAULT false,
 schedule_hour integer NOT NULL DEFAULT 2 CHECK(schedule_hour BETWEEN 0 AND 23),
 retention integer NOT NULL DEFAULT 7 CHECK(retention BETWEEN 2 AND 90),
 include_media boolean NOT NULL DEFAULT true,
 passphrase_secret text NOT NULL DEFAULT '',
 sftp_enabled boolean NOT NULL DEFAULT false,
 sftp_host text NOT NULL DEFAULT '', sftp_port integer NOT NULL DEFAULT 22 CHECK(sftp_port BETWEEN 1 AND 65535),
 sftp_user text NOT NULL DEFAULT '', sftp_directory text NOT NULL DEFAULT '',
 sftp_host_key text NOT NULL DEFAULT '', sftp_identity_secret text NOT NULL DEFAULT '',
 updated_by uuid REFERENCES v_users(user_uuid) ON DELETE SET NULL,
 updated_at timestamptz NOT NULL DEFAULT now(), last_scheduled_date date
);
INSERT INTO v_pbx_backup_settings(singleton) VALUES(1) ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS v_pbx_backup_commands (
 command_uuid uuid PRIMARY KEY, action text NOT NULL CHECK(action IN ('create','verify')),
 backup_uuid uuid, requested_by uuid REFERENCES v_users(user_uuid) ON DELETE SET NULL,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','running','completed','failed')),
 message text NOT NULL DEFAULT '', created_at timestamptz NOT NULL DEFAULT now(),
 started_at timestamptz, finished_at timestamptz,
 CHECK((action='create' AND backup_uuid IS NULL) OR (action='verify' AND backup_uuid IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS openweb_backup_requests ON v_pbx_backup_commands(status,created_at);
CREATE TABLE IF NOT EXISTS v_pbx_backups (
 backup_uuid uuid PRIMARY KEY, command_uuid uuid REFERENCES v_pbx_backup_commands(command_uuid) ON DELETE SET NULL,
 filename text NOT NULL UNIQUE CHECK(filename ~ '^[0-9a-f-]{36}[.]owpbx$'),
 status text NOT NULL CHECK(status IN ('creating','ready','failed')),
 include_media boolean NOT NULL, app_version text NOT NULL,
 size_bytes bigint NOT NULL DEFAULT 0 CHECK(size_bytes>=0), sha256 text NOT NULL DEFAULT '',
 remote_status text NOT NULL DEFAULT 'disabled' CHECK(remote_status IN ('disabled','pending','uploaded','failed')),
 message text NOT NULL DEFAULT '', created_at timestamptz NOT NULL DEFAULT now(), completed_at timestamptz,
 verified_at timestamptz
);
CREATE TABLE IF NOT EXISTS v_pbx_backup_status (
 singleton integer PRIMARY KEY CHECK(singleton=1), state text NOT NULL DEFAULT 'waiting',
 message text NOT NULL DEFAULT 'Waiting for the backup service.', updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO v_pbx_backup_status(singleton) VALUES(1) ON CONFLICT DO NOTHING;
DO $$
DECLARE target_group record;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM v_permissions WHERE permission_name='pbx_backup_instance') THEN
  INSERT INTO v_permissions(permission_uuid,permission_name,application_name,application_uuid,permission_description)
   VALUES(gen_random_uuid(),'pbx_backup_instance','Backups','e6c8b7b1-21b5-4acd-b08c-9b1073fd9bac','Manage encrypted instance backups');
 END IF;
 FOR target_group IN SELECT group_uuid,group_name FROM v_groups WHERE domain_uuid IS NULL AND group_name='superadmin' LOOP
  IF NOT EXISTS(SELECT 1 FROM v_group_permissions WHERE group_uuid=target_group.group_uuid AND permission_name='pbx_backup_instance') THEN
   INSERT INTO v_group_permissions(group_permission_uuid,group_uuid,group_name,permission_name,permission_assigned)
    VALUES(gen_random_uuid(),target_group.group_uuid,target_group.group_name,'pbx_backup_instance','true');
  END IF;
 END LOOP;
END $$;
COMMIT;
