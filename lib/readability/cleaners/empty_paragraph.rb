module Readability
  module Cleaners
    class EmptyParagraph
      def call(html)
        html = html.dup
        html.css('p').each do |paragraph|
          paragraph.remove if paragraph.text.strip.empty?
        end
        html
      end
    end
  end
end
