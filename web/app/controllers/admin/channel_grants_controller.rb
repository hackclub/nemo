module Admin
  class ChannelGrantsController < BaseController
    def create
      return refuse unless may_grant?

      channel_id = params[:channel_id].to_s
      return refuse("pick a channel") if channel_id.blank?
      return refuse("#{channel_id} is not a channel") unless known?(channel_id)

      ActiveRecord::Base.transaction do
        held = Channels::Audience::Grant.create!(user_id: who, channel_id: channel_id,
          granted_by: current_account.user_id, granted_at: Time.current,
          reason: params[:reason].presence)
        Account.find_or_create_by!(user_id: who)
        audit(held, "granted", entity_id: channel_id,
          after: { "user_id" => who, "channel_id" => channel_id })
      end
      Current.forget_roles

      redirect_to admin_person_path(who), notice: "##{channel_id} is theirs to read"
    rescue ActiveRecord::RecordNotUnique
      refuse("they already hold that channel")
    end

    def destroy
      return refuse unless may_grant?

      Channels::Audience::Grant.live.where(user_id: who, channel_id: params[:channel_id])
        .find_each { |held| take_back(held) }
      redirect_to admin_person_path(who), notice: "##{params[:channel_id]} taken back"
    end

    private

    def take_back(held)
      ActiveRecord::Base.transaction do
        held.update!(revoked_by: current_account.user_id, revoked_at: Time.current)
        audit(held, "revoked", entity_id: held.channel_id,
          before: { "user_id" => held.user_id, "channel_id" => held.channel_id },
          after: { "user_id" => held.user_id, "channel_id" => held.channel_id,
                   "revoked_by" => current_account.user_id })
      end
    end

    def who
      params[:person_user_id].to_s.upcase
    end

    def known?(channel_id)
      Analytics::DimChannel.where(channel_id: channel_id, archived: false).exists?
    end

    def refuse(why = nil)
      redirect_to admin_person_path(who),
        alert: why || Community::Access.why_not(current_account, "analytics.grant")
    end
  end
end
