require "peg/version"

module Peg
  class ParseError < StandardError; end

  class Rule
    attr_accessor :action, :name
    attr_reader :value

    def initialize(name: nil, &action)
      @name = name
      @action = action
    end

    def bindings
      if @name && @value
        {@name => @value}
      else
        {}
      end
    end

    def =~(other)
      match(other)
    end

    def ===(other)
      match(other)
    end
  end

  class Literal < Rule
    def initialize(s, **options, &action)
      super(**options, &action)
      @s = s
      @value = nil
    end

    def match(g, lookup_context = NullContext.new)
      return nil unless g.input.start_with?(@s)

      g.advance(@s.size)
      @value = @s

      if @action
        @value = @action.call(**bindings)
      end

      @value
    end
  end

  class VariableLookup
    def initialize(name)
      @name = name
    end

    def lookup(context)
      context.lookup(@name)
    end
  end

  class NullContext
    def lookup(name)
      nil
    end

    def merge(seq)
      LookupContext.new(seq, self)
    end
  end

  class LookupContext
    def initialize(seq, parent)
      @seq = seq
      @parent = parent
    end

    def merge(seq)
      LookupContext.new(seq, self)
    end

    def lookup(name)
      @seq.lookup(name) || @parent.lookup(name)
    end
  end

  class Sequence < Rule
    def initialize(*rules, **options, &action)
      super(**options, &action)
      @rules = rules
      @value = nil
    end

    def match(g, lookup_context = NullContext.new)
      @rules.each do |rule|
        @value = rule.match(g, lookup_context.merge(self))

        return nil unless @value
      end

      if @action
        @value = @action.call(**bindings_of_children)
      end

      @value
    end

    def lookup(name)
      bindings_of_children[name]
    end

    private

    def bindings_of_children
      if @value
        @rules.map(&:bindings).reduce(:merge)
      else
        {}
      end
    end
  end

  class OrderedChoice < Rule
    def initialize(*rules, **options, &action)
      super(**options, &action)
      @rules = rules
      @value = nil
    end

    def match(g, lookup_context = NullContext.new)
      @rules.each do |rule|
        @value = rule.match(g, lookup_context)

        if @value
          @matched_rule = rule
          break
        end
      end

      if @value && @action
        @value = @action.call(**bindings)
      end

      @value
    end

    private

    def bindings_of_children
      if @value
        @matched_rule.bindings
      else
        {}
      end
    end
  end

  class Any < Rule
    def initialize(**options, &action)
      super(**options, &action)
      @value = nil
    end

    def match(g, lookup_context = NullContext.new)
      unless g.input.empty?
        @value = g.input[0]
        g.advance(1)

        if @action
          @value = @action.call(**bindings)
        end

        @value
      end
    end
  end

  class Not < Rule
    def initialize(rule, **options, &action)
      super(**options, &action)
      @rule = rule
      @value = nil
    end

    def match(g, lookup_context = NullContext.new)
      unless @rule.match(g.dup, lookup_context)
        @value = true

        if @action
          @value = @action.call(**bindings)
        end

        @value
      end
    end
  end

  class Lookahead < Rule
    def initialize(rule, **options, &action)
      super(**options, &action)
      @rule = Not.new(Not.new(rule))
      @value = nil
    end

    def match(g, lookup_context = NullContext.new)
      @value = @rule.match(g, lookup_context)

      if @value && @action
        @value = @action.call(**bindings)
      end

      @value
    end
  end

  class Maybe < Rule
    def initialize(rule, **options, &action)
      super(**options, &action)
      @rule = rule
      @value = nil
    end

    def match(g, lookup_context = NullContext.new)
      @value = @rule.match(g, lookup_context)

      if @action
        @value = @action.call(**bindings)
      end

      # TODO: :not_matched is a gross hack, especially because if I want this
      # to be an Ometa implementation, we'll need to be able to pattern match
      # on symbols. A cleaner thing to do would be to rewrite this interface so
      # that the result and the state are returned. This way we can return the
      # old result if maybe fails but still succeeds.
      #
      # Another alternative would be to return a tuple [value, matched] so that
      # here we can return [nil, true] to say that we didn't get anything but
      # we still matched.
      @value || :maybe_not_matched
    end

    def bindings
      if @name
        {@name => @value}
      else
        {}
      end
    end
  end

  class ZeroOrMore < Rule
    def initialize(rule, **options, &action)
      super(**options, &action)
      @rule = rule
      @value = []
    end

    def match(g, lookup_context = NullContext.new)
      loop do
        val = @rule.match(g, lookup_context)
        break unless val

        @value << val
      end

      if @action
        @value = @action.call(**bindings)
      end

      @value
    end
  end

  class OneOrMore < Rule
    def initialize(rule, **options, &action)
      super(**options, &action)
      @rule = rule
      @value = nil
    end

    def match(g, lookup_context = NullContext.new)
      val = @rule.match(g, lookup_context)
      return nil unless val

      @value = [val]

      until val.nil?
        val = @rule.match(g)
        @value << val if val
      end

      if @action
        @value = @action.call(**bindings)
      end

      @value
    end
  end

  class Grouping < Rule
    def initialize(rule, **options, &action)
      super(**options, &action)
      @rule = rule
      @value = nil
    end

    def match(g, lookup_context = NullContext.new)
      @value = @rule.match(g, lookup_context)

      if @value && @action
        @value = @action.call(**bindings)
      end

      @value
    end
  end

  class Characters < Rule
    def initialize(*chars, **options, &action)
      super(**options, &action)

      chars = chars.map do |c|
        if c.respond_to?(:to_a)
          c.to_a
        else
          c
        end
      end.flatten

      @rule = OrderedChoice.new(*chars.map { |c| Literal.new(c) })
      @value = nil
    end

    def match(g, lookup_context = NullContext.new)
      @value = @rule.match(g, lookup_context)

      if @value && @action
        @value = @action.call(**bindings)
      end

      @value
    end
  end

  class Call < Rule
    def initialize(target, *args, **options, &action)
      super(**options, &action)
      @target = target
      @args = args
      @value = nil
    end

    def match(g, lookup_context = NullContext.new)
      @value = g.send(@target, *evaluated_args(lookup_context)).match(g, lookup_context)

      if @value && @action
        @value = @action.call(**bindings)
      end

      @value
    end

    private

    def evaluated_args(context)
      @args.map do |a|
        if a.is_a? VariableLookup
          a.lookup(context)
        else
          a
        end
      end
    end
  end

  class Foreign
    def initialize(klass, target)
      @klass = klass
      @target = target || klass.target
    end

    def match(caller, lookup_context = NullContext.new)
      p = @klass.new(caller.input)

      p.match(@target)
    ensure
      caller.advance(p.pos)
    end
  end

  class Grammar
    class << self
      def target(target = nil)
        if target
          @target = target
        else
          @target
        end
      end

      def match(input, target = @target)
        new(input).match(target)
      end

      alias =~ match
      alias === match

      private

      def define_proxy(*names, **explicit_mappings)
        default_mappings = names.map do |name|
          [name, Peg.const_get(name[1..-1].to_s.split("_").map(&:capitalize).join)]
        end.to_h

        all_mappings = default_mappings.merge(explicit_mappings)

        all_mappings.each do |name, klass|
          define_method :"#{name}" do |*args, &action|
            klass.new(*args, &action)
          end
        end
      end
    end

    define_proxy :_any, :_not, :_maybe, :_zero_or_more, :_one_or_more, :_call,
      _look: Lookahead,
      _lit: Literal,
      _seq: Sequence,
      _or: OrderedChoice,
      _group: Grouping,
      _chars: Characters

    attr_reader :pos

    def initialize(input)
      @input = input
      @pos = 0
    end

    def match(target = nil)
      if target.nil? && self.class.target.nil?
        raise ParseError, "Target cannot be nil. Either specify a target or set a default one using the `target' class method."
      elsif target.nil?
        raise ParseError, "Target cannot be nil."
      end

      send(target).match(self)
    end

    def apply(rule_name, *args)
      _call(rule_name, *args)
    end

    def foreign(parser_klass, target = nil)
      Foreign.new(parser_klass, target)
    end

    def anything
      _any
    end

    def end
      _not(_any)
    end

    def _var(name)
      VariableLookup.new(name)
    end

    def input
      @input[@pos..-1]
    end

    def advance(n)
      @pos += n
    end
  end
end
