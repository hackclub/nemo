module Fd
  class Resolution
    DEFAULT_MESSAGE = YAML.load_file(Rails.root.join("../db/resolutions.yml")).fetch("reporter_message").freeze
  end
end
