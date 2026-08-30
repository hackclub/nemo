class DocsController < You::BaseController
  def show
    @rate = Api::Setting.value("rate_per_minute")
  end
end
