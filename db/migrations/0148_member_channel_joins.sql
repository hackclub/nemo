CREATE TABLE fd.member_channel_join (
    audit_id     text        NOT NULL PRIMARY KEY,
    at           timestamptz NOT NULL,
    user_id      text        NOT NULL,
    channel_id   text        NOT NULL,
    channel_name text,
    privacy      text,
    verb         text        NOT NULL,
    by_workflow  boolean     NOT NULL DEFAULT false,
    landed_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT member_channel_join_verb_known CHECK (verb IN ('joined', 'left'))
);

CREATE INDEX member_channel_join_room_idx
    ON fd.member_channel_join (channel_id, at DESC);
CREATE INDEX member_channel_join_who_idx
    ON fd.member_channel_join (user_id, at DESC);
CREATE INDEX member_channel_join_arriving_idx
    ON fd.member_channel_join (at DESC) WHERE verb = 'joined';

INSERT INTO fd.member_channel_join
    (audit_id, at, user_id, channel_id, channel_name, privacy, verb, by_workflow)
SELECT e.id,
       e.at,
       e.payload #>> '{actor,user,id}',
       e.payload #>> '{entity,channel,id}',
       e.payload #>> '{entity,channel,name}',
       e.payload #>> '{entity,channel,privacy}',
       CASE e.action WHEN 'user_channel_join' THEN 'joined' ELSE 'left' END,
       coalesce((e.payload #>> '{details,is_workflow}')::boolean, false)
FROM slack.audit_event e
WHERE e.action IN ('user_channel_join', 'user_channel_leave')
  AND e.payload #>> '{actor,user,id}' IS NOT NULL
  AND e.payload #>> '{entity,channel,id}' IS NOT NULL
ON CONFLICT (audit_id) DO NOTHING;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON fd.member_channel_join TO pipeline_writer;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rails_app') THEN
        GRANT SELECT ON fd.member_channel_join TO rails_app;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
        REVOKE ALL ON fd.member_channel_join FROM dbt_owner;
    END IF;
END
$$;
