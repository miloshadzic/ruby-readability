require 'spec_helper'
require 'nokogiri'
require './lib/readability/cleaners/remove_headers'

module Readability
  module Cleaners
    describe RemoveHeaders do
      specify '.call' do
        html = Nokogiri::HTML(<<-HTML)
        <html>
          <body>
            <h1>A normal header</h1>
            <h2><a href="http://example.com">Example</a></h2>
          </body>
        </html>
        HTML

        expect(RemoveHeaders.new.call(html).xpath('//h1'))
          .to_not be_empty
        expect(RemoveHeaders.new.call(html).xpath('//h2'))
          .to be_empty
      end
    end
  end
end
