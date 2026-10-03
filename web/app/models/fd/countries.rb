module Fd
  class Countries
    NAMES = {
      "AE" => "United Arab Emirates", "AR" => "Argentina", "AT" => "Austria",
      "AU" => "Australia", "BD" => "Bangladesh", "BE" => "Belgium", "BG" => "Bulgaria",
      "BR" => "Brazil", "CA" => "Canada", "CH" => "Switzerland", "CL" => "Chile",
      "CN" => "China", "CO" => "Colombia", "CZ" => "Czechia", "DE" => "Germany",
      "DK" => "Denmark", "EE" => "Estonia", "EG" => "Egypt", "ES" => "Spain",
      "FI" => "Finland", "FR" => "France", "GB" => "United Kingdom", "GH" => "Ghana",
      "GR" => "Greece", "HK" => "Hong Kong", "HR" => "Croatia", "HU" => "Hungary",
      "ID" => "Indonesia", "IE" => "Ireland", "IL" => "Israel", "IN" => "India",
      "IQ" => "Iraq", "IR" => "Iran", "IS" => "Iceland", "IT" => "Italy",
      "JP" => "Japan", "KE" => "Kenya", "KR" => "South Korea", "LK" => "Sri Lanka",
      "LT" => "Lithuania", "LV" => "Latvia", "MA" => "Morocco", "MX" => "Mexico",
      "MY" => "Malaysia", "NG" => "Nigeria", "NL" => "Netherlands", "NO" => "Norway",
      "NP" => "Nepal", "NZ" => "New Zealand", "PE" => "Peru", "PH" => "Philippines",
      "PK" => "Pakistan", "PL" => "Poland", "PT" => "Portugal", "RO" => "Romania",
      "RS" => "Serbia", "RU" => "Russia", "SA" => "Saudi Arabia", "SE" => "Sweden",
      "SG" => "Singapore", "SI" => "Slovenia", "SK" => "Slovakia", "TH" => "Thailand",
      "TN" => "Tunisia", "TR" => "Türkiye", "TW" => "Taiwan", "UA" => "Ukraine",
      "US" => "United States", "VN" => "Vietnam", "ZA" => "South Africa"
    }.freeze

    SHAPE = /\A[A-Za-z]{2}\z/
    FIRST = 0x1F1E6
    LETTER_A = "A".ord

    def self.name_for(code)
      code_text = code.to_s.strip.upcase
      return nil unless code_text.match?(SHAPE)

      NAMES.fetch(code_text, code_text)
    end

    def self.flag_for(code)
      code_text = code.to_s.strip.upcase
      return nil unless code_text.match?(SHAPE)

      code_text.each_char.map { |one| (FIRST + one.ord - LETTER_A).chr(Encoding::UTF_8) }.join
    end
  end
end
