# encoding: utf-8

require 'rubygems'
require 'nokogiri'
require 'fastimage'
require 'guess_html_encoding'
require_relative 'readability/author'
require_relative 'readability/article'
require_relative 'readability/errors'
require_relative 'readability/image'
require_relative 'readability/candidate'

module Readability
  class Document
    DEFAULT_OPTIONS = {
      :retry_length               => 250,
      :min_text_length            => 25,
      :remove_unlikely_candidates => true,
      :weight_classes             => true,
      :clean_conditionally        => true,
      :remove_empty_nodes         => true,
      :min_image_width            => 130,
      :min_image_height           => 80,
      :ignore_image_format        => [],
      :blacklist                  => nil,
      :whitelist                  => nil
    }.freeze
    
    REGEXES = {
        :unlikelyCandidatesRe => /combx|comment|community|disqus|extra|foot|header|menu|remark|rss|shoutbox|sidebar|sponsor|ad-break|agegate|pagination|pager|popup/i,
        :okMaybeItsACandidateRe => /and|article|body|column|main|shadow/i,
        :positiveRe => /article|body|content|entry|hentry|main|page|pagination|post|text|blog|story/i,
        :negativeRe => /combx|comment|com-|contact|foot|footer|footnote|masthead|media|meta|outbrain|promo|related|scroll|shoutbox|sidebar|sponsor|shopping|tags|tool|widget/i,
        :divToPElementsRe => /<(a|blockquote|dl|div|img|ol|p|pre|table|ul)/i,
        :replaceBrsRe => /(<br[^>]*>[ \n\r\t]*){2,}/i,
        :replaceFontsRe => /<(\/?)font[^>]*>/i,
        :trimRe => /^\s+|\s+$/,
        :normalizeRe => /\s{2,}/,
        :killBreaksRe => /(<br\s*\/?>(\s|&nbsp;?)*){1,}/,
        :videoRe => /http:\/\/(www\.)?(youtube|vimeo)\.com/i
    }
    
    attr_accessor :options, :html, :best_candidate, :candidates, :best_candidate_has_image

    def initialize(input, options = {})
      @options = DEFAULT_OPTIONS.merge(options)
      @input = input

      if RUBY_VERSION =~ /^(1\.9|2)/ && !@options[:encoding]
        @input = GuessHtmlEncoding.encode(@input, @options[:html_headers]) unless @options[:do_not_guess_encoding]
        @options[:encoding] = @input.encoding.to_s
      end

      @input = @input.gsub(REGEXES[:replaceBrsRe], '</p><p>').gsub(REGEXES[:replaceFontsRe], '<\1span>')
      @remove_unlikely_candidates = @options[:remove_unlikely_candidates]
      @weight_classes = @options[:weight_classes]
      @clean_conditionally = @options[:clean_conditionally]
      @best_candidate_has_image = true

      @whitelist = options.fetch(:whitelist, nil)
      @blacklist = options.fetch(:blacklist, nil)

      @html = make_html


      remove_unlikely_candidates! if @remove_unlikely_candidates
      transform_misused_divs_into_paragraphs!

      @candidates     = score_paragraphs(@options[:min_text_length])
      @best_candidate = select_best_candidate
    end

    def exclude!(html)
      return unless @blacklist || @whitelist

      if @blacklist
        html.css(@blacklist).remove
      end

      if @whitelist
        elems = html.css(@whitelist).to_s

        if body = html.at_css('body')
          body.inner_html = elems
        end
      end

      @input = html.to_s
      html
    end

    def make_html
      html = Nokogiri::HTML(@input, nil, @options[:encoding])

      # In case document has no body, such as from empty string or redirect
      if html.css('body').empty?
        html = Nokogiri::HTML('<body />', nil, @options[:encoding])
      else
        html.xpath('//comment()').remove
        html.css("script, style").remove
        exclude!(html)
      end

      html
    end

    def images
      @images ||= get_images
    end

    def get_images(content=nil, reload=false)
      @best_candidate_has_image = false if reload

      content       = @best_candidate.node unless reload

      return [] if content.nil?

      elements = content.css("img").map(&:attributes)

      list = elements.reject { |e| e['src'].nil? || e['src'] == "" }.map do |element|
        url     = element["src"].value
        height  = element["height"].nil?  ? 0 : element["height"].value.to_i
        width   = element["width"].nil?   ? 0 : element["width"].value.to_i

        if url =~ /\Ahttps?:\/\//i && (height.zero? || width.zero?)
          begin
            width, height = get_image_size(url)
          rescue Errors::UnknownImageSize
          end
        end

        image = Image.new(url,
                          File.extname(url).gsub(".", "").downcase,
                          width,
                          height)

      end.select { |image| image_meets_criteria?(image) }.uniq.map(&:url)

      (list.empty? && content != @html) ? get_images(@html, true) : list
    end

    def get_image_size(url)
      w, h = FastImage.size(url)
      raise Errors::UnknownImageSize if w.nil? || h.nil?
      [w, h]
    end

    def image_meets_criteria?(image)
      return false if options[:ignore_image_format].include?(image.format)

      image.width >= (options.fetch(:min_image_width, 0)) &&
        image.height >= (options.fetch(:min_image_height, 0))
    end

    # Title of the parsed document. Empty string if there's no
    #
    # @return [String]
    def title
      @title ||= @html.xpath('//title').text
    end

    # Look through the @html document looking for the author
    #
    # Returns nil if no author is detected
    def author
      @author ||= Author.parse(@html)
    end

    # The cleaned up article content
    #
    # @returns [String] the article content
    def content
      @content ||= sanitize(get_article(@best_candidate))
    end

    # Now that we have the top candidate, look through its siblings
    # for content that might also be related. Things like preambles,
    # content split by ads that we removed, etc.
    #
    # @returns [Article]
    def get_article(best_candidate)
      sibling_score_threshold = [10, best_candidate.score * 0.2].max
      output = Nokogiri::XML::Node.new('div', @html)
      best_candidate.node.parent.children.each do |sibling|
        append = false
        append = true if sibling == best_candidate.node
        append = true if @candidates[sibling] && @candidates[sibling].score >= sibling_score_threshold

        if sibling.name.downcase == "p"
          link_density = get_link_density(sibling)
          node_content = sibling.text
          node_length = node_content.length

          append = if node_length > 80 && link_density < 0.25
            true
          elsif node_length < 80 && link_density == 0 && node_content =~ /\.( |$)/
            true
          end
        end

        if append
          # otherwise the state of the document in processing will change,
          # thus creating side effects
          sibling_dup = sibling.dup
          sibling_dup.name = "div" unless %w[div p].include?(sibling.name.downcase)
          output << sibling_dup
        end
      end

      Article.new(output)
    end

    def select_best_candidate
      sorted_candidates = @candidates.values.sort { |a, b| b.score <=> a.score }

      debug("Top 5 candidates:")
      sorted_candidates[0...5].each do |candidate|
        debug("Candidate #{candidate.node.name}##{candidate.node.attributes[:id]}.#{candidate.node.attributes[:class]} with score #{candidate.score}")
      end

      best_candidate = sorted_candidates.first || Candidate.new(@html.css("body").first, 0)
      debug("Best candidate #{best_candidate.node.name}##{best_candidate.node.attributes[:id]}.#{best_candidate.node.attributes[:class]} with score #{best_candidate.score}")

      best_candidate
    end

    def get_link_density(elem)
      link_length = elem.css("a").map(&:text).join("").length
      text_length = elem.text.length
      link_length / text_length.to_f
    end

    def score_paragraphs(min_text_length)
      candidates = {}
      @html.css("p,td").each do |elem|
        parent_node = elem.parent
        grand_parent_node = parent_node.respond_to?(:parent) ? parent_node.parent : nil
        inner_text = elem.text

        # If this paragraph is less than 25 characters, don't even count it.
        next if inner_text.length < min_text_length

        content_score = 1
        content_score += inner_text.split(',').length
        content_score += [(inner_text.length / 100).to_i, 3].min

        candidates[parent_node] = score_node(parent_node, content_score)
        candidates[grand_parent_node] = score_node(grand_parent_node, content_score / 2.0) if grand_parent_node
      end

      # Scale the final candidates score based on link density. Good content should have a
      # relatively small link density (5% or less) and be mostly unaffected by this operation.
      candidates.values.each do |candidate|
        candidate.score = candidate.score * (1 - get_link_density(candidate.node))
      end

      candidates
    end

    def class_weight(e)
      return 0 unless @weight_classes

      [:class, :id].inject(0) do |weight, attr|
        unless e[attr].nil? && e[attr] == ""
          weight -= 25 if e[attr] =~ REGEXES[:negativeRe]
          weight += 25 if e[attr] =~ REGEXES[:positiveRe]
        end

        weight
      end
    end

    ELEMENT_SCORES = {
      'div' => 5,
      'blockquote' => 3,
      'form' => -3,
      'th' => -5
    }.freeze

    def score_node(elem, content_score)
      score = class_weight(elem) + content_score
      score += ELEMENT_SCORES.fetch(elem.name.downcase, 0)
      Candidate.new(elem, score)
    end

    def debug(str)
      puts str if options[:debug]
    end

    def remove_unlikely_candidates!
      @html.css("*").each do |elem|
        str = "#{elem[:class]}#{elem[:id]}"
        if str =~ REGEXES[:unlikelyCandidatesRe] && str !~ REGEXES[:okMaybeItsACandidateRe] && (elem.name.downcase != 'html') && (elem.name.downcase != 'body')
          debug("Removing unlikely candidate - #{str}")
          elem.remove
        end
      end
    end

    def transform_misused_divs_into_paragraphs!
      @html.css("*").each do |elem|
        if elem.name.downcase == "div"

          # transform <div>s that do not contain other block elements into <p>s
          if elem.inner_html !~ REGEXES[:divToPElementsRe]
            debug("Altering div(##{elem[:id]}.#{elem[:class]}) to p");
            elem.name = "p"
          end
        else
          # wrap text nodes in p tags
#          elem.children.each do |child|
#            if child.text?
#              debug("wrapping text node with a p")
#              child.swap("<p>#{child.text}</p>")
#            end
#          end
        end
      end
    end

    def sanitize(article, options = {})
      node = article.content

      node.css("h1, h2, h3, h4, h5, h6").each do |header|
        header.remove if class_weight(header) < 0 || get_link_density(header) > 0.33
      end

      node.css("form, object, iframe, embed").each do |elem|
        elem.remove
      end

      if @options[:remove_empty_nodes]
        # remove <p> tags that have no text content - this will also remove p tags that contain only images.
        node.css("p").each do |elem|
          elem.remove if elem.content.strip.empty?
        end
      end

      # Conditionally clean <table>s, <ul>s, and <div>s
      clean_conditionally(node, "table, ul, div")

      # We'll sanitize all elements using a whitelist
      base_whitelist = @options.fetch(:tags, %w[div p])
      # We'll add whitespace instead of block elements,
      # so a<br>b will have a nice space between them
      base_replace_with_whitespace = %w[br hr h1 h2 h3 h4 h5 h6 dl dd ol li ul address blockquote center]


      # Use a hash for speed (don't want to make a million calls to include?)
      whitelist = base_whitelist.inject({}) { |hsh, tag| hsh[tag] = true; hsh }
      replace_with_whitespace = base_replace_with_whitespace.inject({}) { |hsh, tag| hsh[tag] = true; hsh }

      ([node] + node.css("*")).each do |el|
        # If element is in whitelist, delete all its attributes
        if whitelist[el.node_name]
          el.attributes.each { |a, x| el.delete(a) unless @options[:attributes] && @options[:attributes].include?(a.to_s) }

          # Otherwise, replace the element with its contents
        else
          # If element is root, replace the node as a text node
          if el.parent.nil?
            node = Nokogiri::XML::Text.new(el.text, el.document)
            break
          else
            if replace_with_whitespace[el.node_name]
              el.swap(Nokogiri::XML::Text.new(' ' << el.text << ' ', el.document))
            else
              el.swap(Nokogiri::XML::Text.new(el.text, el.document))
            end
          end
        end

      end

      s = Nokogiri::XML::Node::SaveOptions
      save_opts = s::NO_DECLARATION | s::NO_EMPTY_TAGS | s::AS_XHTML
      html = node.serialize(:save_with => save_opts)

      # Get rid of duplicate whitespace
      return html.gsub(/[\r\n\f]+/, "\n" )
    end

    def clean_conditionally(node, selector)
      return unless @clean_conditionally
      node.css(selector).each do |el|
        weight = class_weight(el)

        content_score = @candidates[el] ? @candidates[el].score : 0
        name = el.name.downcase

        if weight + content_score < 0
          el.remove
          debug("Conditionally cleaned #{name}##{el[:id]}.#{el[:class]} with weight #{weight} and content score #{content_score} because score + content score was less than zero.")
        elsif el.text.count(",") < 10
          counts = %w[p img li a embed input].inject({}) { |m, kind| m[kind] = el.css(kind).length; m }
          counts["li"] -= 100

          # For every img under a noscript tag discount one from the count to avoid double counting
          counts["img"] -= el.css("noscript").css("img").length

          content_length = el.text.strip.length  # Count the text length excluding any surrounding whitespace
          link_density = get_link_density(el)

          reason = clean_conditionally_reason?(name, counts, content_length, options, weight, link_density)
          if reason
            debug("Conditionally cleaned #{name}##{el[:id]}.#{el[:class]} with weight #{weight} and content score #{content_score} because it has #{reason}.")
            el.remove
          end
        end
      end
    end

    def clean_conditionally_reason?(name, counts, content_length, options, weight, link_density)
      if (counts["img"] > counts["p"]) && (counts["img"] > 1)
        "too many images"
      elsif counts["li"] > counts["p"] && name != "ul" && name != "ol"
        "more <li>s than <p>s"
      elsif counts["input"] > (counts["p"] / 3).to_i
        "less than 3x <p>s than <input>s"
      elsif (content_length < options[:min_text_length]) && (counts["img"] != 1)
        "too short a content length without a single image"
      elsif weight < 25 && link_density > 0.2
        "too many links for its weight (#{weight})"
      elsif weight >= 25 && link_density > 0.75
        "too many links for its weight (#{weight})"
      elsif (counts["embed"] == 1 && content_length < 75) || counts["embed"] > 1
        "<embed>s with too short a content length, or too many <embed>s"
      else
        false
      end
    end

  end
end
