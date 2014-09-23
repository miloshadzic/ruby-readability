require 'spec_helper'
require 'nokogiri'
require './lib/readability/cleaners/delete_selector'

module Readability
  module Cleaners
    describe DeleteSelector do
      specify '.call' do
        html = Nokogiri::HTML(<<-HTML)
        <html>
          <body>
            <h1>A normal header</h1>
            <h2><a href="http://example.com">Example</a></h2>
          </body>
        </html>
        HTML

        expect(DeleteSelector.new("h1").call(html).xpath('//h1'))
          .to be_empty
        expect(DeleteSelector.new("h1").call(html).xpath('//h2'))
          .to_not be_empty
        expect(DeleteSelector.new("h2").call(html).xpath('//h2'))
          .to be_empty
        expect(DeleteSelector.new("h2").call(html).xpath('//h1'))
          .to_not be_empty
      end
    end
  end
end
