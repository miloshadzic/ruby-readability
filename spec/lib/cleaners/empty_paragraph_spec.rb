require 'spec_helper'
require 'nokogiri'
require './lib/readability/cleaners/empty_paragraph'

module Readability
  module Cleaners
    describe EmptyParagraph do
      specify '.call' do
        html = Nokogiri::HTML(<<-HTML)
        <html>
          <body>
            <p></p>
            <p>Nonempty paragraph</p>
          </body>
        </html>
        HTML

        expect(EmptyParagraph.new.call(html).xpath('//p').count)
          .to eq 1
      end
    end
  end
end
