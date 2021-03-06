# encoding: utf-8

require 'rubygems'
require 'nokogiri'
require 'fastimage'
require 'guess_html_encoding'
require_relative 'readability/author'
require_relative 'readability/article'
require_relative 'readability/errors'
require_relative 'readability/image'
require_relative 'readability/cleaners/delete_selector'
require_relative 'readability/cleaners/remove_headers'
require_relative 'readability/cleaners/empty_paragraph'
require_relative 'readability/cleaners/conditional'

module Readability
  class Document
    DEFAULT_OPTIONS = {
      :retry_length               => 250,
      :min_text_length            => 25,
      :remove_unlikely_candidates => true,
      :guess_encoding             => true,
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


      if @options[:encoding].nil?
        if @options.fetch(:guess_encoding)
          input = GuessHtmlEncoding.encode(input, @options[:html_headers])
        end

        @options[:encoding] = input.encoding.to_s
      end

      input = input.gsub(REGEXES[:replaceBrsRe], '</p><p>').gsub(REGEXES[:replaceFontsRe], '<\1span>')
      @weight_classes = @options[:weight_classes]
      @clean_conditionally = @options[:clean_conditionally]
      @best_candidate_has_image = true

      @html = exclude(make_html(input),
                      @options.fetch(:whitelist),
                      @options.fetch(:blacklist))

      remove_unlikely_candidates! if @options.fetch(:remove_unlikely_candidates)
      transform_misused_divs_into_paragraphs!

      @candidates     = score_paragraphs(@options.fetch(:min_text_length))
      @best_candidate = select_best_candidate
    end

    def exclude(html, whitelist, blacklist)
      return html unless @blacklist || @whitelist

      html.css(@blacklist).remove if @blacklist

      if @whitelist
        elems = html.css(@whitelist).to_s

        if body = html.at_css('body')
          body.inner_html = elems
        end
      end

      html
    end

    def make_html(source)
      html = Nokogiri::HTML(source, nil, @options[:encoding])

      # In case document has no body, such as from empty string or redirect
      if html.css('body').empty?
        html = Nokogiri::HTML('<body />', nil, @options[:encoding])
      else
        html.xpath('//comment()').remove
        html.css("script, style").remove
      end

      html
    end

    def images
      @images ||= get_images
    end

    def get_images(content=nil, reload=false)
      @best_candidate_has_image = false if reload

      content       = @best_candidate[:elem] unless reload

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
      sibling_score_threshold = [10, best_candidate[:score] * 0.2].max
      output = Nokogiri::XML::Node.new('div', @html)
      best_candidate[:elem].parent.children.each do |sibling|
        append = false
        append = true if sibling == best_candidate[:elem]
        append = true if @candidates[sibling] && @candidates[sibling][:score] >= sibling_score_threshold

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
      sorted_candidates = @candidates.values.sort { |a, b| b[:score] <=> a[:score] }
      sorted_candidates.first || {elem: @html.css("body").first, score: 0}
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

        candidates[parent_node] ||= score_node(parent_node)
        candidates[grand_parent_node] ||= score_node(grand_parent_node) if grand_parent_node

        content_score = 1
        content_score += inner_text.split(',').length
        content_score += [(inner_text.length / 100).to_i, 3].min

        candidates[parent_node][:score] += content_score
        candidates[grand_parent_node][:score] += content_score / 2.0 if grand_parent_node
      end

      # Scale the final candidates score based on link density. Good content should have a
      # relatively small link density (5% or less) and be mostly unaffected by this operation.
      candidates.each do |elem, candidate|
        candidate[:score] = candidate[:score] * (1 - get_link_density(elem))
      end

      candidates
    end

    def score_node(elem)
      content_score = class_weight(elem)
      content_score += ELEMENT_SCORES.fetch(elem.name.downcase, 0)
      { :score => content_score, :elem => elem }
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

    def remove_unlikely_candidates!
      @html.css("*").each do |elem|
        str = "#{elem[:class]}#{elem[:id]}"
        if str =~ REGEXES[:unlikelyCandidatesRe] && str !~ REGEXES[:okMaybeItsACandidateRe] && (elem.name.downcase != 'html') && (elem.name.downcase != 'body')
          elem.remove
        end
      end
    end

    def transform_misused_divs_into_paragraphs!
      @html.css("*").each do |elem|
        if elem.name.downcase == "div"

          # transform <div>s that do not contain other block elements into <p>s
          if elem.inner_html !~ REGEXES[:divToPElementsRe]
            elem.name = "p"
          end
        else
          # wrap text nodes in p tags
#          elem.children.each do |child|
#            if child.text?
#              child.swap("<p>#{child.text}</p>")
#            end
#          end
        end
      end
    end

    def sanitize(article, options = {})
      node = article.content
      node = Cleaners::RemoveHeaders.new.call(node)
      node = Cleaners::DeleteSelector.new("form, object, iframe, embed").call(node)
      node = Cleaners::EmptyParagraph.new.call(node) if @options[:remove_empty_nodes]

      # Conditionally clean <table>s, <ul>s, and <div>s
      node = Cleaners::Conditional.new("table, ul, div", @candidates, @options).call(node) if @clean_conditionally

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
  end
end
