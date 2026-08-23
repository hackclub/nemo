module Fd
  class Resolution
    TOLD = YAML.load_file(Rails.root.join("../db/resolutions.yml")).fetch("told").freeze
  end
end
