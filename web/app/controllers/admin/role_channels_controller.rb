module Admin
  class RoleChannelsController < BaseController
    SHARED_ROLE = "gardener".freeze
    SHARED_ROLES = %w[gardener].freeze

    def show
      @role = wanted
      @channels = Channels::Audience::Grant.live.where(role: @role).to_a
      @named = Analytics::DimChannel.where(channel_id: @channels.map(&:channel_id))
        .index_by(&:channel_id)
      @reaches = ApplicationRecord.connection.select_values(
        ApplicationRecord.sanitize_sql([
          "SELECT DISTINCT user_id FROM app.effective_role WHERE role = ? ORDER BY user_id", @role
        ])
      )
      @holders = @reaches.size
      @names = Fd::Names.for(@channels.map(&:granted_by) + @reaches)
    end

    def create
      return refuse unless may_grant?

      channel_id = params[:channel_id].to_s
      return refuse("pick a channel") if channel_id.blank?
      unless Analytics::DimChannel.where(channel_id: channel_id, archived: false).exists?
        return refuse("#{channel_id} is not a channel")
      end

      Channels::Audience::Grant.create!(role: wanted, channel_id: channel_id,
        granted_by: current_staff.user_id, granted_at: Time.current)
      redirect_to back_to,
        notice: "##{channel_id} is now read by every #{Authz.role_label(wanted).downcase}"
    rescue ActiveRecord::RecordNotUnique
      refuse("the set already holds that channel")
    end

    def destroy
      return refuse unless may_grant?

      Channels::Audience::Grant.live.where(role: wanted, channel_id: params[:channel_id])
        .find_each { |held| held.update!(revoked_by: current_staff.user_id,
                                        revoked_at: Time.current) }
      redirect_to back_to, notice: "##{params[:channel_id]} taken out of the set"
    end

    private

    def wanted
      asked = params[:role].to_s
      SHARED_ROLES.include?(asked) ? asked : SHARED_ROLE
    end

    def back_to
      return admin_channels_path(q: params[:q].presence) if params[:from] == "channels"

      admin_role_channels_path(role: wanted)
    end

    def refuse(why = nil)
      redirect_to back_to,
        alert: why || Community::Access.why_not(current_staff, "analytics.grant")
    end
  end
end
