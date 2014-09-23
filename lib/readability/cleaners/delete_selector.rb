module Readability
  module Cleaners
    class DeleteSelector
      def initialize(selector)
        @selector = selector
      end

      def call(html)
        html = html.dup
        html.css(@selector).remove
        html
      end
    end
  end
end
