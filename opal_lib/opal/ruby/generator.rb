module Opal
  class RubyParser < Racc::Parser
    class Generator

      INDENT = '  '

      LEVEL_TOP         = 0
      LEVEL_TOP_CLOSURE = 1
      LEVEL_LIST        = 2
      LEVEL_EXPR        = 3

      class Scope
        attr_accessor :parent

        attr_reader :temps

        attr_reader :lvars

        def initialize(type)
          @parent = nil
          @type = type
          @lvars = []
          @temp_queue = []
          @temp = 'a'
          @temps = []
        end

        def new_temp
          return @temp_queue.pop if @temp_queue.last

          name = "__#{@temp}"
          @temps << name
          @temp = @temp.succ
          name
        end

        def queue_temp(tmp)
          @temp_queue << tmp
        end
      end

      def self.process(sexp)
        self.new.process_top sexp
      end

      def initialize
        @scope = nil
        @line = 1
        @indent = ''
      end

      def process(sexp, level)
        type = sexp.shift
        mid = "process_#{type}"
        raise "Unsupported sexp: #{type}" unless respond_to? mid

        line = fix_line sexp.line
        code = __send__ mid, sexp, level

        line + code
      end

      def s(*p)
        Opal::RubyParser::Sexp.new *p
      end

      def scope(type = nil)
        top = @scope
        scope = Scope.new type
        scope.parent = top
        @scope = scope
        yield scope
        @scope = top
      end

      def fix_line(line)
        res = ""
        if @line < line
          res = "\n" * (line - @line)
          res += @indent
          @line = line
        end
        res
      end

      def expression?(sexp)
        ![:if, :xstr].include?(sexp[0])
      end

      def returns(sexp)
        unless sexp
          s = returns s(:nil)
          s
        end

        case sexp[0]
        when :scope
          sexp
        when :block
          if sexp.length > 1
            sexp[-1] = returns sexp[-1]
          else
            sexp << returns(s(:nil))
          end
          sexp
        else
          res = s(:js_return, sexp)
          res.line = sexp.line
          res
        end
      end

      def process_top(sexp)
        code = nil
        top = s(:scope, sexp)
        scope do
          code = process top, LEVEL_TOP
        end
        code
      end

      def process_scope(sexp, level)
        stmt = returns sexp.shift
        code = process stmt, LEVEL_TOP
        vars = []
        pre = ''

        vars.push *@scope.temps

        pre += "var #{vars.join ', '};" unless vars.empty?

        pre + code
      end

      def process_block(sexp, level)
        result = []
        parts = sexp
        parts << s(:nil) if parts.empty?

        until sexp.empty?
          stmt = sexp.shift
          exp = expression?(stmt) and level < LEVEL_LIST
          result << process(stmt, level)
          result << ';' if exp
        end

        result.join ''
      end

      def process_lit(sexp, level)
        lit = sexp.shift
        case lit
        when Numeric
          lit.inspect
        when Symbol
          "$symbol('#{lit}')"
        else
          raise "Bad lit type #{lit}"
        end
      end

      def process_true(sexp, level)
        "Qtrue"
      end

      def process_false(sexp, level)
        "Qfalse"
      end

      def process_self(sexp, level)
        "self"
      end

      def process_nil(sexp, level)
        "nil"
      end

      def process_and(sexp, level)
        tmp = @scope.new_temp
        res = "((#{tmp} = #{process sexp.shift, LEVEL_LIST}).$r ? "
        res += "#{process sexp.shift, LEVEL_LIST} : #{tmp})"
        @scope.queue_temp tmp
        res
      end

      def process_or(sexp, level)
        tmp = @scope.new_temp
        res = "((#{tmp} = #{process sexp.shift, LEVEL_LIST}).$r ? #{tmp}"
        res += " : #{process sexp.shift, LEVEL_LIST})"
        @scope.queue_temp tmp
        res
      end

      def process_not(sexp, level)
        res = "((#{process sexp.shift, LEVEL_LIST}).$r ? Qfalse : Qtrue)"
        res
      end

      def process_defn(sexp, level)
        mid = sexp.shift
        args = sexp.first

        # if last args is a s(:exp) then it contains opt arg assigns etc
        if args.last.is_a? Array
          opt_asgns = args.pop
        end

        # also need to check if last arg is splat op so we can use it

        args = process sexp.shift, LEVEL_EXPR
        stmt = ""
        indent = @indent
        @indent += INDENT
        scope do
          stmts = sexp.shift
          if opt_asgns
            stmts[1].insert(1, *opt_asgns[1..-1].map { |a| s(:js_opt_asgn, a[1], a[2]) })
          end
          puts stmts.inspect
          stmt += process(stmts, LEVEL_TOP)
        end
        @indent = indent

        "$def(self, '#{mid}', function(#{args}) { #{stmt} #{fix_line sexp.end_line}}, 0)"
      end

      def process_js_opt_asgn(sexp, level)
        id = sexp.shift
        rhs = sexp.shift
        "if (#{id} == undefined) { id = #{process rhs, LEVEL_TOP};}"
      end

      def process_args(sexp, level)
        args = []

        until sexp.empty?
          arg = sexp.shift

          if Symbol === arg
            args << arg
          end

        end

        args.join ', '
      end

      def process_lasgn(sexp, level)
        "assign"
      end

      def process_js_return(sexp, level)
        "return #{process sexp.shift, LEVEL_EXPR}"
      end

      def process_hash(sexp, level)
        parts = []

        until sexp.empty?
          parts << process(sexp.shift, LEVEL_EXPR)
        end

        "$hash(#{ parts.join ', ' }#{fix_line sexp.end_line})"
      end

    end # Generator
  end
end
