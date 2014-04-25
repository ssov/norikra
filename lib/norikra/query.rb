require 'java'
require 'esper-4.9.0.jar'
require 'esper/lib/commons-logging-1.1.1.jar'
require 'esper/lib/antlr-runtime-3.2.jar'
require 'esper/lib/cglib-nodep-2.2.jar'

require 'norikra/error'
require 'norikra/query/ast'
require 'norikra/field'

require 'base64'

module Norikra
  class Query
    attr_accessor :name, :group, :expression, :statement_name, :fieldsets, :hook

    def initialize(param={})
      @name = param[:name]
      raise Norikra::ArgumentError, "Query name MUST NOT be blank" if @name.nil? || @name.empty?
      @group = param[:group] # default nil
      @expression = param[:expression]
      raise Norikra::ArgumentError, "Query expression MUST NOT be blank" if @expression.nil? || @expression.empty?
      @hook = Base64.decode64(param[:hook]) unless param[:hook].nil?

      @statement_name = nil
      @fieldsets = {} # { target => fieldset }
      @ast = nil
      @targets = nil
      @aliases = nil
      @subqueries = nil
      @fields = nil
    end

    def <=>(other)
      if @group.nil? || other.group.nil?
        if @group.nil? && other.group.nil?
          @name <=> other.name
        else
          @group.to_s <=> other.group.to_s
        end
      else
        if @group == other.group
          self.name <=> other.name
        else
          self.group <=> other.group
        end
      end
    end

    def dup
      self.class.new(:name => @name, :group => @group, :expression => @expression.dup)
    end

    def to_hash
      {'name' => @name, 'group' => @group, 'expression' => @expression, 'targets' => self.targets}
    end

    def dump
      {name: @name, group: @group, expression: @expression}
    end

    def targets
      return @targets if @targets
      @targets = (self.ast.listup(:stream).map(&:targets).flatten + self.subqueries.map(&:targets).flatten).sort.uniq
      @targets
    end

    def aliases
      return @aliases if @aliases
      @aliases = (self.ast.listup(:stream).map{|s| s.aliases.map(&:first) }.flatten + self.subqueries.map(&:aliases).flatten).sort.uniq
      @aliases
    end

    def subqueries
      return @subqueries if @subqueries
      @subqueries = self.ast.listup(:subquery).map{|n| Norikra::SubQuery.new(n)}
      @subqueries
    end

    def explore(outer_targets=[], alias_overridden={})
      fields = {}
      alias_map = {}.merge(alias_overridden)

      all = []
      unknowns = []
      self.ast.listup(:stream).each do |node|
        node.aliases.each do |alias_name, target|
          alias_map[alias_name] = target
        end
        node.targets.each do |target|
          fields[target] ||= []
        end
      end

      dup_aliases = (alias_map.keys & fields.keys)
      unless dup_aliases.empty?
        raise Norikra::ClientError, "Invalid alias '#{dup_aliases.join(',')}', same with target name"
      end

      default_target = fields.keys.size == 1 ? fields.keys.first : nil

      outer_targets.each do |t|
        fields[t] ||= []
      end

      field_bag = []
      self.subqueries.each do |subquery|
        field_bag.push(subquery.explore(fields.keys, alias_map))
      end

      # names of 'AS'
      field_aliases = self.ast.listup(:selection).map(&:alias).compact

      known_targets_aliases = fields.keys + alias_map.keys
      self.ast.fields(default_target, known_targets_aliases).each do |field_def|
        f = field_def[:f]
        next if field_aliases.include?(f)

        all.push(f)

        if field_def[:t]
          t = alias_map[field_def[:t]] || field_def[:t]
          unless fields[t]
            raise Norikra::ClientError, "unknown target alias name for: #{field_def[:t]}.#{field_def[:f]}"
          end
          fields[t].push(f)

        else
          unknowns.push(f)
        end
      end

      field_bag.each do |bag|
        all += bag['']
        unknowns += bag[nil]
        bag.keys.each do |t|
          fields[t] ||= []
          fields[t] += bag[t]
        end
      end

      fields.keys.each do |target|
        fields[target] = fields[target].sort.uniq
      end
      fields[''] = all.sort.uniq
      fields[nil] = unknowns.sort.uniq

      fields
    end

    def fields(target='')
      # target '': fields for all targets (without target name)
      # target nil: fields for unknown targets
      return @fields[target] if @fields

      @fields = explore()
      @fields[target]
    end

    class ParseRuleSelectorImpl
      include com.espertech.esper.epl.parse.ParseRuleSelector
      def invokeParseRule(parser)
        parser.startEPLExpressionRule().getTree()
      end
    end

    def ast
      return @ast if @ast
      rule = ParseRuleSelectorImpl.new
      target = @expression.dup
      forerrmsg = @expression.dup
      result = com.espertech.esper.epl.parse.ParseHelper.parse(target, forerrmsg, true, rule, false)

      @ast = astnode(result.getTree)
      @ast
    rescue Java::ComEspertechEsperClient::EPStatementSyntaxException => e
      raise Norikra::QueryError, e.message
    end

    def self.rewrite_query(statement_model, mapping)
      rewrite_event_type_name(statement_model, mapping)
      rewrite_event_field_name(statement_model, mapping)
    end

    def self.rewrite_event_field_name(statement_model, mapping)
      # mapping: {target_name => query_event_type_name}
      #  mapping is for target name rewriting of fully qualified field name access


      # model.getFromClause.getStreams[0].getViews[0].getParameters[0].getPropertyName

      # model.getSelectClause.getSelectList[0].getExpression.getPropertyName
      # model.getSelectClause.getSelectList[0].getExpression.getChildren[0].getPropertyName #=> 'field.key1.$0'

      # model.getWhereClause.getChildren[1].getChildren[0].getPropertyName #=> 'field.key1.$1'
      # model.getWhereClause.getChildren[2].getChildren[0].getChain[0].getName #=> 'opts.num.$0' from opts.num.$0.length()

      query = Norikra::Query.new(:name => 'dummy name by .rewrite_event_field_name', :expression => statement_model.toEPL)
      targets = query.targets
      fqfs_prefixes = targets + query.aliases

      default_target = (targets.size == 1 ? targets.first : nil)

      rewrite_name = lambda {|node,getter,setter|
        name = node.send(getter)
        if name && name.index('.')
          prefix = nil
          body = nil
          first_part = name.split('.').first
          if fqfs_prefixes.include?(first_part) or mapping.has_key?(first_part) # fully qualified field specification
            prefix = first_part
            if mapping[prefix]
              prefix = mapping[prefix]
            end
            body = name.split('.')[1..-1].join('.')
          elsif default_target # default target field (outside of join context)
            body = name
          else
            raise Norikra::QueryError, "target cannot be determined for field '#{name}'"
          end
          #### 'field.javaMethod("args")' MUST NOT be escaped....
          # 'getPropertyName' returns a String "path.index(\".\")" for java method calling,
          #  and other optional informations are not provided.
          # We seems that '.camelCase(ANYTHING)' should be a method calling, not nested field accesses.
          # This is ugly, but works.
          #
          # 'path.substring(0, path.indexOf(path.substring(1,1)))' is parsed as 3-times-nested LIB_FUNCTION_CHAIN,
          #  so does not make errors.
          #
          method_chains = []
          body_chains = body.split('.')
          while body_chains.size > 0
            break unless body_chains.last =~ /^[a-z][a-zA-Z]*\(.*\)$/
            method_chains.unshift body_chains.pop
          end

          escaped_body = Norikra::Field.escape_name(body_chains.join('.'))
          encoded = (prefix ? "#{prefix}." : "") + escaped_body + (method_chains.size > 0 ? '.' + method_chains.join('.') : '' )
          node.send(setter, encoded)
        end
      }

      rewriter = lambda {|node|
        if node.respond_to?(:getPropertyName)
          rewrite_name.call(node, :getPropertyName, :setPropertyName)
        elsif node.respond_to?(:getChain)
          node.getChain.each do |chain|
            rewrite_name.call(chain, :getName, :setName)
          end
        end
      }
      recaller = lambda {|node|
        Norikra::Query.rewrite_event_field_name(node.getModel, mapping)
      }

      traverse_fields(rewriter, recaller, statement_model)
    end

    def self.rewrite_event_type_name(statement_model, mapping)
      # mapping: {target_name => query_event_type_name}

      ### esper-4.9.0/esper/doc/reference/html/epl_clauses.html#epl-subqueries
      # Subqueries can only consist of a select clause, a from clause and a where clause.
      # The group by and having clauses, as well as joins, outer-joins and output rate limiting are not permitted within subqueries.

      # model.getFromClause.getStreams[0].getFilter.setEventTypeName("hoge") # normal Stream
      # model.getFromClause.getStreams[1].getExpression.getChildren[0].getChildren[0].getFilter.getEventTypeName # pattern

      # model.getSelectClause.getSelectList[1].getExpression => #<Java::ComEspertechEsperClientSoda::SubqueryExpression:0x3344c133>
      # model.getSelectClause.getSelectList[1].getExpression.getModel.getFromClause.getStreams[0].getFilter.getEventTypeName
      # model.getWhereClause.getChildren[1]                 .getModel.getFromClause.getStreams[0].getFilter.getEventTypeName

      rewriter = lambda {|node|
        if node.respond_to?(:getEventTypeName)
          target_name = node.getEventTypeName
          rewrite_name = mapping[ target_name ]
          unless rewrite_name
            raise RuntimeError, "target missing in mapping, maybe BUG: #{target_name}"
          end
          node.setEventTypeName(rewrite_name)
        end
      }
      recaller = lambda {|node|
        Norikra::Query.rewrite_event_type_name(node.getModel, mapping)
      }
      traverse_fields(rewriter, recaller, statement_model)
    end

    ### Targets and fields re-writing supports (*) nodes
    # model.methods.select{|m| m.to_s.start_with?('get')}
    # :getContextName,
    # :getCreateContext,
    # :getCreateDataFlow,
    # :getCreateExpression,
    # :getCreateIndex,
    # :getCreateSchema,
    # :getCreateVariable,
    # :getCreateWindow,
    # :getExpressionDeclarations,
    # :getFireAndForgetClause,
    # :getForClause,
    # (*) :getFromClause,
    # (*) :getGroupByClause,
    # (*) :getHavingClause,
    # :getInsertInto,
    # :getMatchRecognizeClause,
    # :getOnExpr,
    # (*) :getOrderByClause,
    # :getOutputLimitClause,
    # :getRowLimitClause,
    # :getScriptExpressions,
    # (*) :getSelectClause,
    # :getTreeObjectName,
    # :getUpdateClause,
    # (*) :getWhereClause,

    def self.traverse_fields(rewriter, recaller, statement_model)
      #NOTICE: SQLStream is not supported yet.
      dig = lambda {|node|
        return unless node
        rewriter.call(node)

        if node.is_a?(Java::ComEspertechEsperClientSoda::SubqueryExpression)
          recaller.call(node)
        end
        if node.respond_to?(:getFilter)
          dig.call(node.getFilter)
        end
        if node.respond_to?(:getChildren)
          node.getChildren.each do |c|
            dig.call(c)
          end
        end
        if node.respond_to?(:getParameters)
          node.getParameters.each do |p|
            dig.call(p)
          end
        end
        if node.respond_to?(:getChain)
          node.getChain.each do |c|
            dig.call(c)
          end
        end
      }

      statement_model.getFromClause.getStreams.each do |stream|
        if stream.respond_to?(:getExpression) # PatternStream < ProjectedStream
          dig.call(stream.getExpression)
        end
        if stream.respond_to?(:getFilter) # Filter < ProjectedStream
          dig.call(stream.getFilter)
        end
        if stream.respond_to?(:getParameterExpressions) # MethodInvocationStream
          dig.call(stream.getParameterExpressions)
        end
        if stream.respond_to?(:getViews) # ProjectedStream
          stream.getViews.each do |view|
            view.getParameters.each do |parameter|
              dig.call(parameter)
            end
          end
        end
      end

      if statement_model.getSelectClause
        statement_model.getSelectClause.getSelectList.each do |item|
          if item.respond_to?(:getExpression)
            dig.call(item.getExpression)
          end
        end
      end

      if statement_model.getWhereClause
        statement_model.getWhereClause.getChildren.each do |child|
          dig.call(child)
        end
      end

      if statement_model.getGroupByClause
        statement_model.getGroupByClause.getGroupByExpressions.each do |child|
          dig.call(child)
        end
      end

      if statement_model.getOrderByClause
        statement_model.getOrderByClause.getOrderByExpressions.each do |item|
          if item.respond_to?(:getExpression)
            dig.call(item.getExpression)
          end
        end
      end

      if statement_model.getHavingClause
        dig.call(statement_model.getHavingClause)
      end

      statement_model
    end
  end

  class SubQuery < Query
    def initialize(ast_nodetree)
      @ast = ast_nodetree
      @targets = nil
      @subqueries = nil
    end

    def ast; @ast; end

    def subqueries
      return @subqueries if @subqueries
      @subqueries = @ast.children.map{|c| c.listup(:subquery)}.reduce(&:+).map{|n| Norikra::SubQuery.new(n)}
      @subqueries
    end

    def name; ''; end
    def expression; ''; end
    def dup; self; end
    def dup_with_stream_name(actual_name); self; end
  end
end
