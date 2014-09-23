module Readability
  Candidate = Struct.new :node, :score do
    def parent
      node.parent
    end
  end
end
