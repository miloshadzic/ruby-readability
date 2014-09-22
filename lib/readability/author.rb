module Readability
  class Author
    # Try to get author information from the passed in HTML
    #
    # @param html [String] the HTML source
    # @return [String] author name
    def self.parse(html)
      [MetaDCCreator, VCard, Rel, Id].map { |strategy| strategy.parse(html) }
        .reject { |author_name| author_name.nil? || author_name == "" }
        .first
    end

    class MetaDCCreator
      # Parsing strategy to get the author from meta content dc.creator
      #
      # Example: <meta name="dc.creator" content="Finch - http://www.getfinch.com" />
      #
      # @param html [String] the HTML source
      # @return [String] author name or blank
      def self.parse(html)
        author_elements = html.xpath('//meta[@name = "dc.creator"]')
        author_elements.each do |element|
          return element['content'].strip if element['content']
        end
        nil
      end
    end

    class VCard
      # Parsing strategy to get the author from the author vcard
      #
      # Examples:
      #   <span class="byline author vcard">By <cite class="fn">Austin Fonacier</cite></span>
      #   <div class="author">
      #     By</div><div class="author vcard">
      #     <a class="url fn" href="http://austinlivesinyoapp.com/">Austin Fonacier</a>
      #   </div>
      #
      # @param html [String] the HTML source
      # @return [String] author name or blank
      def self.parse(html)
        author_elements = html.xpath('//*[contains(@class, "vcard")]//*[contains(@class, "fn")]')
        author_elements.each do |element|
          return element.text.strip if element.text
        end
        nil
      end
    end

    class Rel
      # Parsing strategy to get the author from the author vcard
      # TODO: strip out the (rel)?
      #
      # Example:
      #   <a rel="author" href="http://dbanksdesign.com">Danny Banks (rel)</a>
      #
      # @param html [String] the HTML source
      # @return [String] author name or blank
      def self.parse(html)
        author_elements = html.xpath('//a[@rel = "author"]')
        author_elements.each do |element|
          return element.text.strip if element.text
        end
        nil
      end
    end

    class Id
      def self.parse(html)
        author_elements = html.xpath('//*[@id = "author"]')
        author_elements.each do |element|
          return element.text.strip if element.text
        end
        nil
      end
    end
  end
end
