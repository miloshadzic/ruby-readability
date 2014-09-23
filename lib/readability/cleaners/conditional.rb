module Readability
  module Cleaners
    class Conditional
      REGEXES = {
        :positiveRe => /article|body|content|entry|hentry|main|page|pagination|post|text|blog|story/i,
        :negativeRe => /combx|comment|com-|contact|foot|footer|footnote|masthead|media|meta|outbrain|promo|related|scroll|shoutbox|sidebar|sponsor|shopping|tags|tool|widget/i,
      }

      def initialize(selector, candidates, options={})
        @selector = selector
        @candidates = candidates
        @options = options
      end

      def call(node)
        node.css(@selector).each do |el|
          weight = class_weight(el)

          content_score = @candidates[el] ? @candidates[el].score : 0
          name = el.name.downcase

          if weight + content_score < 0
            el.remove
          elsif el.text.count(",") < 10
            counts = %w[p img li a embed input].inject({}) { |m, kind| m[kind] = el.css(kind).length; m }
            counts["li"] -= 100

            # For every img under a noscript tag discount one from the count to avoid double counting
            counts["img"] -= el.css("noscript").css("img").length

            content_length = el.text.strip.length  # Count the text length excluding any surrounding whitespace
            link_density = get_link_density(el)

            reason = clean_conditionally_reason?(name, counts, content_length, weight, link_density)
            if reason
              el.remove
            end
          end
        end

        node
      end

      def clean_conditionally_reason?(name, counts, content_length, weight, link_density)
        if (counts["img"] > counts["p"]) && (counts["img"] > 1)
          "too many images"
        elsif counts["li"] > counts["p"] && name != "ul" && name != "ol"
          "more <li>s than <p>s"
        elsif counts["input"] > (counts["p"] / 3).to_i
          "less than 3x <p>s than <input>s"
        elsif (content_length < @options.fetch(:min_text_length, 25) && counts["img"] < 1)
          "too short a content length without a single image"
        elsif weight < 25 && link_density > 0.2
          "too many links for its weight (#{weight})"
        elsif weight >= 25 && link_density > 0.8
          "too many links for its weight (#{weight})"
        elsif (counts["embed"] == 1 && content_length < 75) || counts["embed"] > 1
          "<embed>s with too short a content length, or too many <embed>s"
        else
          false
        end
      end

      def class_weight(e)
        [:class, :id].inject(0) do |weight, attr|
          unless e[attr].nil? && e[attr] == ""
            weight -= 25 if e[attr] =~ REGEXES[:negativeRe]
            weight += 25 if e[attr] =~ REGEXES[:positiveRe]
          end

          weight
        end
      end

      def get_link_density(elem)
        link_length = elem.css("a").map(&:text).join("").length
        text_length = elem.text.length
        link_length / text_length.to_f
      end
    end
  end
end
