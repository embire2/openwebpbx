BEGIN;
CREATE TABLE IF NOT EXISTS v_pbx_meetings (
 meeting_uuid uuid PRIMARY KEY, domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 owner_uuid uuid NOT NULL REFERENCES v_users(user_uuid) ON DELETE CASCADE,
 subject varchar(120) NOT NULL, notes varchar(2000) NOT NULL DEFAULT '',
 starts_at timestamptz NOT NULL, ends_at timestamptz NOT NULL,
 invite_hash char(64) NOT NULL UNIQUE, dial_number varchar(12) NOT NULL,
 video_enabled boolean NOT NULL DEFAULT true, lobby_required boolean NOT NULL DEFAULT true,
 locked boolean NOT NULL DEFAULT false, started_at timestamptz, ended_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(domain_uuid,dial_number),
 CHECK(ends_at>starts_at AND ends_at<=starts_at+interval '8 hours')
);
CREATE TABLE IF NOT EXISTS v_pbx_meeting_members (
 member_uuid uuid PRIMARY KEY, meeting_uuid uuid NOT NULL REFERENCES v_pbx_meetings(meeting_uuid) ON DELETE CASCADE,
 member_name varchar(80) NOT NULL, role varchar(8) NOT NULL CHECK(role IN ('host','guest')),
 state varchar(12) NOT NULL CHECK(state IN ('waiting','admitted','removed','left')),
 token_hash char(64) NOT NULL UNIQUE, sip_username varchar(40) NOT NULL UNIQUE, sip_a1_hash char(32) NOT NULL,
 call_uuid uuid, muted boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(), seen_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS openweb_meeting_owner ON v_pbx_meetings(domain_uuid,owner_uuid,starts_at DESC);
CREATE INDEX IF NOT EXISTS openweb_meeting_attendees ON v_pbx_meeting_members(meeting_uuid,state);
COMMIT;
