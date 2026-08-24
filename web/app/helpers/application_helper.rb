module ApplicationHelper
  def open_case_count
    @open_case_count ||= Fd::Case.unresolved.count
  end

  def on?(key)
    Fd::Flag.on?(key)
  end
end
