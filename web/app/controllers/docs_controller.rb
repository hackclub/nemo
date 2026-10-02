class DocsController < ApplicationController
  def index
    redirect_to doc_path(Docs.first.slug)
  end

  def show
    @topic = Docs.find(params[:slug])
    return redirect_to docs_path if @topic.nil?

    @rate = Api::Setting.value("rate_per_minute")
  end
end
