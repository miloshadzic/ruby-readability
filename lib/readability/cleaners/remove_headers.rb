module Readability
  module Cleaners
    class RemoveHeaders
      def call(html)
        html.css("h1, h2, h3, h4, h5, h6").each do |header|
          header.remove if link_density(header) > 0.33
        end

        html
      end

      def link_density(elem)
        text_length = elem.text.length
        link_length = elem.css('a').map(&:text).join('').length
        link_length / text_length.to_f
      end
    end
  end
end
