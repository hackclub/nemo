LOCK TABLE slack.audit_event IN SHARE MODE;

INSERT INTO slack.user_agent (ua)
SELECT DISTINCT btrim(context->>'ua')
FROM slack.audit_event
WHERE coalesce(btrim(context->>'ua'), '') <> ''
ON CONFLICT (md5(ua)) DO NOTHING;

ALTER TABLE slack.audit_view ADD COLUMN ours boolean NOT NULL DEFAULT false;

DO $$
DECLARE
    month timestamptz := date_trunc('month', (SELECT min(at) FROM slack.audit_event));
    last_month timestamptz := date_trunc('month', (SELECT max(at) FROM slack.audit_event));
BEGIN
    IF month IS NOT NULL THEN
        PERFORM slack.ensure_months('slack.audit_event_monthly', 'audit_event', month::date, 2);
        PERFORM slack.ensure_months('slack.audit_view', 'audit_view', month::date, 2);
    END IF;
    WHILE month IS NOT NULL AND month <= last_month LOOP
        INSERT INTO slack.audit_event_monthly
            (id, at, action, category, actor_kind, actor_id, actor_email, entity_kind, entity_id,
             entity_email, channel_id, app_id, ours, ip, ua_id, session_id, source_key, payload)
        WITH category (action, category) AS (
            VALUES
                ('anomaly', 'sign_ins'),
                ('app_allowlist_rule_activated', 'apps_and_ai'),
                ('app_allowlist_rule_created', 'apps_and_ai'),
                ('app_allowlist_rule_deactivated', 'apps_and_ai'),
                ('app_allowlist_rule_deleted', 'apps_and_ai'),
                ('app_allowlist_rule_matched', 'apps_and_ai'),
                ('app_allowlist_rule_reordered', 'apps_and_ai'),
                ('app_allowlist_rule_updated', 'apps_and_ai'),
                ('app_allowlist_scopes_rating_updated', 'apps_and_ai'),
                ('app_approved', 'apps_and_ai'),
                ('app_collaborator_added', 'apps_and_ai'),
                ('app_collaborator_removed', 'apps_and_ai'),
                ('app_deleted', 'apps_and_ai'),
                ('app_installed', 'apps_and_ai'),
                ('app_manifest_created', 'apps_and_ai'),
                ('app_manifest_updated', 'apps_and_ai'),
                ('app_removed_from_whitelist', 'apps_and_ai'),
                ('app_restricted', 'apps_and_ai'),
                ('app_scopes_expanded', 'apps_and_ai'),
                ('app_token_preserved', 'apps_and_ai'),
                ('app_uninstalled', 'apps_and_ai'),
                ('audit_logs_export_json_started', 'admin_and_roles'),
                ('audit_logs_records_searched', 'admin_and_roles'),
                ('audit_logs_records_searched_anomaly', 'admin_and_roles'),
                ('bulk_session_reset_by_admin', 'sign_ins'),
                ('canvas_access_added', 'canvases_and_lists'),
                ('canvas_access_downgraded', 'canvases_and_lists'),
                ('canvas_access_revoked', 'canvases_and_lists'),
                ('canvas_access_upgraded', 'canvases_and_lists'),
                ('canvas_created', 'canvases_and_lists'),
                ('canvas_deleted', 'canvases_and_lists'),
                ('canvas_downloaded', 'canvases_and_lists'),
                ('canvas_edited', 'canvases_and_lists'),
                ('canvas_linksharing_disabled', 'canvases_and_lists'),
                ('canvas_linksharing_enabled', 'canvases_and_lists'),
                ('canvas_opened', 'canvases_and_lists'),
                ('canvas_shared', 'canvases_and_lists'),
                ('canvas_slack_ai_exclusion_enabled', 'canvases_and_lists'),
                ('canvas_template_used', 'canvases_and_lists'),
                ('canvas_unshared', 'canvases_and_lists'),
                ('channel_email_address_created', 'channels'),
                ('channel_email_address_deleted', 'channels'),
                ('channel_exclude_from_slack_ai_updated', 'channels'),
                ('channel_posting_permissions_updated', 'channels'),
                ('channel_renamed', 'channels'),
                ('channel_restrict_guests_updated', 'channels'),
                ('channel_restrict_message_and_file_sharing_updated', 'channels'),
                ('channel_retention_changed', 'channels'),
                ('channel_tab_added', 'channels'),
                ('channel_tab_removed', 'channels'),
                ('child_app_auto_install_denied', 'apps_and_ai'),
                ('child_app_manifest_created', 'apps_and_ai'),
                ('child_app_manifest_updated', 'apps_and_ai'),
                ('cli_login', 'sign_ins'),
                ('custom_tos_accepted', 'people'),
                ('custom_tos_link_clicked', 'people'),
                ('default_channel_added_to_usergroup', 'admin_and_roles'),
                ('default_channel_removed_from_usergroup', 'admin_and_roles'),
                ('dm_user_added', 'channels'),
                ('email_change_confirmed', 'people'),
                ('email_change_created', 'people'),
                ('emoji_added', 'messages_and_files'),
                ('emoji_aliased', 'messages_and_files'),
                ('emoji_removed', 'messages_and_files'),
                ('external_shared_channel_connected', 'channels'),
                ('external_shared_channel_invite_accepted', 'channels'),
                ('external_shared_channel_invite_approved', 'channels'),
                ('file_deleted', 'messages_and_files'),
                ('file_downloaded', 'messages_and_files'),
                ('file_malicious_content_detected', 'messages_and_files'),
                ('file_public_link_created', 'messages_and_files'),
                ('file_public_link_revoked', 'messages_and_files'),
                ('file_shared', 'messages_and_files'),
                ('file_uploaded', 'messages_and_files'),
                ('guest_channel_join', 'channels'),
                ('guest_channel_leave', 'channels'),
                ('guest_created', 'people'),
                ('guest_deactivated', 'people'),
                ('guest_joined_workspace', 'people'),
                ('guest_reactivated', 'people'),
                ('huddle_ended', 'huddles'),
                ('huddle_knock_accepted', 'huddles'),
                ('huddle_participant_dropped', 'huddles'),
                ('huddle_participant_joined', 'huddles'),
                ('huddle_participant_left', 'huddles'),
                ('huddle_screenshare_off', 'huddles'),
                ('huddle_screenshare_on', 'huddles'),
                ('huddle_started', 'huddles'),
                ('huddle_transcription_start_notification', 'huddles'),
                ('list_access_added', 'canvases_and_lists'),
                ('list_access_revoked', 'canvases_and_lists'),
                ('list_cell_updated', 'canvases_and_lists'),
                ('list_column_created', 'canvases_and_lists'),
                ('list_column_deleted', 'canvases_and_lists'),
                ('list_column_updated', 'canvases_and_lists'),
                ('list_created', 'canvases_and_lists'),
                ('list_default_view_updated', 'canvases_and_lists'),
                ('list_deleted', 'canvases_and_lists'),
                ('list_description_updated', 'canvases_and_lists'),
                ('list_downloaded', 'canvases_and_lists'),
                ('list_opened', 'canvases_and_lists'),
                ('list_row_created', 'canvases_and_lists'),
                ('list_row_deleted', 'canvases_and_lists'),
                ('list_row_updated', 'canvases_and_lists'),
                ('list_rows_archived', 'canvases_and_lists'),
                ('list_rows_deleted', 'canvases_and_lists'),
                ('list_shared', 'canvases_and_lists'),
                ('list_title_updated', 'canvases_and_lists'),
                ('list_todo_mode_updated', 'canvases_and_lists'),
                ('list_view_created', 'canvases_and_lists'),
                ('list_view_updated', 'canvases_and_lists'),
                ('mcp_slack_add_list_record_tool_called', 'apps_and_ai'),
                ('mcp_slack_add_reaction_tool_called', 'apps_and_ai'),
                ('mcp_slack_complete_file_upload_tool_called', 'apps_and_ai'),
                ('mcp_slack_create_conversation_tool_called', 'apps_and_ai'),
                ('mcp_slack_create_list_tool_called', 'apps_and_ai'),
                ('mcp_slack_get_file_upload_url_tool_called', 'apps_and_ai'),
                ('mcp_slack_get_reactions_tool_called', 'apps_and_ai'),
                ('mcp_slack_list_channel_members_tool_called', 'apps_and_ai'),
                ('mcp_slack_list_user_channels_tool_called', 'apps_and_ai'),
                ('mcp_slack_read_canvas_tool_called', 'apps_and_ai'),
                ('mcp_slack_read_channel_tool_called', 'apps_and_ai'),
                ('mcp_slack_read_file_tool_called', 'apps_and_ai'),
                ('mcp_slack_read_list_tool_called', 'apps_and_ai'),
                ('mcp_slack_read_thread_tool_called', 'apps_and_ai'),
                ('mcp_slack_read_user_profile_tool_called', 'apps_and_ai'),
                ('mcp_slack_search_channels_tool_called', 'apps_and_ai'),
                ('mcp_slack_search_emojis_tool_called', 'apps_and_ai'),
                ('mcp_slack_search_public_and_private_tool_called', 'apps_and_ai'),
                ('mcp_slack_search_public_tool_called', 'apps_and_ai'),
                ('mcp_slack_search_users_tool_called', 'apps_and_ai'),
                ('mcp_slack_send_message_draft_tool_called', 'apps_and_ai'),
                ('mcp_slack_send_message_tool_called', 'apps_and_ai'),
                ('mcp_slack_update_canvas_tool_called', 'apps_and_ai'),
                ('mcp_slack_update_list_record_tool_called', 'apps_and_ai'),
                ('message_activity_viewed', 'messages_and_files'),
                ('mpim_converted_to_private', 'channels'),
                ('org_app_workspace_added', 'apps_and_ai'),
                ('org_app_workspace_removed', 'apps_and_ai'),
                ('permissions_assigned', 'admin_and_roles'),
                ('permissions_removed', 'admin_and_roles'),
                ('pref.app_whitelist_enabled', 'admin_and_roles'),
                ('pref.display_email_addresses', 'admin_and_roles'),
                ('pref.sign_in_with_slack_disabled', 'admin_and_roles'),
                ('private_channel_archive', 'channels'),
                ('private_channel_converted_to_public', 'channels'),
                ('private_channel_created', 'channels'),
                ('private_channel_deleted', 'channels'),
                ('private_channel_unarchive', 'channels'),
                ('private_message_forwarded', 'messages_and_files'),
                ('public_channel_archive', 'channels'),
                ('public_channel_converted_to_private', 'channels'),
                ('public_channel_created', 'channels'),
                ('public_channel_deleted', 'channels'),
                ('public_channel_preview', 'channels'),
                ('public_channel_unarchive', 'channels'),
                ('record_channel_archive', 'channels'),
                ('role_assigned', 'admin_and_roles'),
                ('role_change_to_user', 'admin_and_roles'),
                ('role_created', 'admin_and_roles'),
                ('role_removed', 'admin_and_roles'),
                ('role_updated', 'admin_and_roles'),
                ('slack_ai_agent_stream_stopped', 'apps_and_ai'),
                ('thread_hidden', 'messages_and_files'),
                ('thread_replies_disabled', 'messages_and_files'),
                ('thread_replies_enabled', 'messages_and_files'),
                ('user_added_reminder', 'people'),
                ('user_added_to_usergroup', 'admin_and_roles'),
                ('user_channel_join', 'channels'),
                ('user_channel_leave', 'channels'),
                ('user_created', 'people'),
                ('user_deactivated', 'people'),
                ('user_email_updated', 'people'),
                ('user_joined_workspace', 'people'),
                ('user_login', 'sign_ins'),
                ('user_login_failed', 'sign_ins'),
                ('user_logout', 'sign_ins'),
                ('user_password_reset_requested', 'sign_ins'),
                ('user_profile_deleted', 'people'),
                ('user_profile_updated', 'people'),
                ('user_reactivated', 'people'),
                ('user_removed_from_usergroup', 'admin_and_roles'),
                ('user_session_invalidated', 'sign_ins'),
                ('user_session_reset_by_admin', 'sign_ins'),
                ('user_sessions_reset_by_anomaly_event_response', 'sign_ins'),
                ('user_username_updated', 'people'),
                ('usergroup_section_updated', 'admin_and_roles')
        )
        SELECT e.id::uuid, e.at, e.action, c.category, e.actor_kind, e.actor_id,
               CASE WHEN e.actor_kind = 'user'
                    THEN nullif(lower(btrim(e.payload #>> '{actor,user,email}')), '') END,
               e.entity_kind, e.entity_id,
               CASE WHEN e.entity_kind = 'user'
                    THEN nullif(lower(btrim(e.payload #>> '{entity,user,email}')), '') END,
               CASE WHEN e.entity_kind = 'channel' THEN e.entity_id
                    WHEN jsonb_typeof(e.payload #> ARRAY['entity', e.entity_kind, 'channel']) = 'string'
                        THEN e.payload #>> ARRAY['entity', e.entity_kind, 'channel']
                    WHEN jsonb_typeof(e.payload #> ARRAY['entity', e.entity_kind, 'channel_id']) = 'string'
                        THEN e.payload #>> ARRAY['entity', e.entity_kind, 'channel_id'] END,
               e.app_id, e.ours,
               CASE WHEN pg_input_is_valid(e.context->>'ip_address', 'inet')
                    THEN (e.context->>'ip_address')::inet END,
               u.id,
               CASE WHEN e.context->>'session_id' ~ '^[0-9]{1,18}$'
                    THEN (e.context->>'session_id')::bigint END,
               e.source_key, e.payload
        FROM slack.audit_event e
        LEFT JOIN category c ON c.action = e.action
        LEFT JOIN slack.user_agent u ON md5(u.ua) = md5(btrim(e.context->>'ua'))
        WHERE e.at >= month AND e.at < month + interval '1 month'
          AND NOT EXISTS (SELECT 1 FROM slack.audit_view_action a WHERE a.action = e.action)
        ON CONFLICT (id, at) DO NOTHING;

        INSERT INTO slack.audit_view (id, at, action, actor_id, object_id, ip, ua_id, session_id, ours)
        SELECT e.id::uuid, e.at, a.code, e.actor_id, e.entity_id,
               CASE WHEN pg_input_is_valid(e.context->>'ip_address', 'inet')
                    THEN (e.context->>'ip_address')::inet END,
               u.id,
               CASE WHEN e.context->>'session_id' ~ '^[0-9]{1,18}$'
                    THEN (e.context->>'session_id')::bigint END,
               e.ours
        FROM slack.audit_event e
        JOIN slack.audit_view_action a ON a.action = e.action
        LEFT JOIN slack.user_agent u ON md5(u.ua) = md5(btrim(e.context->>'ua'))
        WHERE e.at >= month AND e.at < month + interval '1 month'
        ON CONFLICT (id, at) DO NOTHING;

        RAISE NOTICE 'copied audit events for %', to_char(month, 'YYYY-MM');
        month := month + interval '1 month';
    END LOOP;
END
$$;

ALTER TABLE slack.audit_view_action ADD COLUMN entity_kind text;

UPDATE slack.audit_view_action a
SET entity_kind = (SELECT e.entity_kind FROM slack.audit_event e
                   WHERE e.action = a.action AND e.entity_kind IS NOT NULL
                   GROUP BY 1 ORDER BY count(*) DESC LIMIT 1);

SET LOCAL maintenance_work_mem = '512MB';

CREATE INDEX audit_event_monthly_search_idx ON slack.audit_event_monthly USING gin ((
    to_tsvector('simple'::regconfig,
        coalesce(action, '') || ' ' || coalesce(actor_id, '') || ' ' ||
        coalesce(entity_id, '') || ' ' || coalesce(entity_kind, '') || ' ' ||
        coalesce(host(ip), '') || ' ' || coalesce(payload #>> '{context,app,name}', '') || ' ' ||
        coalesce(actor_email, '') || ' ' || coalesce(payload #>> '{actor,user,name}', '') || ' ' ||
        coalesce(entity_email, '') || ' ' || coalesce(payload #>> '{entity,user,name}', '') || ' ' ||
        coalesce(payload #>> '{entity,channel,name}', ''))
));

DROP TABLE slack.audit_event;

ALTER TABLE slack.audit_event_monthly RENAME TO audit_event;
ALTER TABLE slack.audit_event_monthly_default RENAME TO audit_event_default;
ALTER TABLE slack.audit_event RENAME CONSTRAINT audit_event_monthly_pkey TO audit_event_pkey;
ALTER TABLE slack.audit_event RENAME CONSTRAINT audit_event_monthly_emails_lower TO audit_event_emails_lower;
ALTER TABLE slack.audit_event RENAME CONSTRAINT audit_event_monthly_ua_id_fkey TO audit_event_ua_id_fkey;
ALTER INDEX slack.audit_event_monthly_recent_idx RENAME TO audit_event_recent_idx;
ALTER INDEX slack.audit_event_monthly_action_idx RENAME TO audit_event_action_idx;
ALTER INDEX slack.audit_event_monthly_category_idx RENAME TO audit_event_category_idx;
ALTER INDEX slack.audit_event_monthly_actor_idx RENAME TO audit_event_actor_idx;
ALTER INDEX slack.audit_event_monthly_entity_idx RENAME TO audit_event_entity_idx;
ALTER INDEX slack.audit_event_monthly_channel_idx RENAME TO audit_event_channel_idx;
ALTER INDEX slack.audit_event_monthly_ip_idx RENAME TO audit_event_ip_idx;
ALTER INDEX slack.audit_event_monthly_actor_email_idx RENAME TO audit_event_actor_email_idx;
ALTER INDEX slack.audit_event_monthly_entity_email_idx RENAME TO audit_event_entity_email_idx;
ALTER INDEX slack.audit_event_monthly_session_idx RENAME TO audit_event_session_idx;
ALTER INDEX slack.audit_event_monthly_search_idx RENAME TO audit_event_search_idx;

CREATE OR REPLACE FUNCTION slack.ensure_months(parent regclass, prefix text, first_month date,
                                                months_ahead integer)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = slack, pg_temp
AS $f$
DECLARE
    month date := date_trunc('month', first_month)::date;
    last_month date := (date_trunc('month', now()) + make_interval(months => months_ahead))::date;
    compressed boolean := EXISTS (SELECT 1 FROM pg_attribute
                                  WHERE attrelid = parent AND attname = 'payload' AND NOT attisdropped);
    named text;
    made integer := 0;
BEGIN
    IF parent NOT IN ('slack.audit_event'::regclass, 'slack.audit_view'::regclass) THEN
        RAISE EXCEPTION 'ensure_months only creates months of the audit tables, not %', parent;
    END IF;
    WHILE month <= last_month LOOP
        named := prefix || '_' || to_char(month, 'YYYY_MM');
        IF to_regclass('slack.' || named) IS NULL THEN
            EXECUTE format(
                'CREATE TABLE slack.%I PARTITION OF %s FOR VALUES FROM (%L) TO (%L)',
                named, parent,
                to_char(month, 'YYYY-MM-DD') || ' 00:00:00+00',
                to_char((month + interval '1 month')::date, 'YYYY-MM-DD') || ' 00:00:00+00');
            IF compressed THEN
                EXECUTE format('ALTER TABLE slack.%I ALTER COLUMN payload SET COMPRESSION lz4', named);
            END IF;
            made := made + 1;
        END IF;
        month := (month + interval '1 month')::date;
    END LOOP;
    RETURN made;
END
$f$;

CREATE OR REPLACE FUNCTION slack.ensure_audit_event_months(first_month date, months_ahead integer)
RETURNS integer
LANGUAGE sql
AS $f$
    SELECT slack.ensure_months('slack.audit_event', 'audit_event', first_month, months_ahead)
$f$;
