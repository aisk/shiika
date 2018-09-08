require 'active_support/core_ext/hash/except'
require 'shiika/props'
require 'shiika/type'
require 'shiika/program/env'

module Shiika
  # Represents a Shiika program
  class Program
    # Shiika-level type error
    class SkTypeError < StandardError; end
    # Shiika-level name error
    class SkNameError < StandardError; end
    # Other Shiika-level errors
    class SkProgramError < StandardError; end

    def initialize(sk_classes, sk_main)
      @sk_classes, @sk_main = sk_classes, sk_main
    end
    attr_reader :sk_classes, :sk_main

    def add_type!
      constants = @sk_classes.map{|name, sk_class|
        const = SkConst.new(name: name)
        const.instance_variable_set(:@type, sk_class.meta_type)
        [name, const]
      }.to_h
      env = Shiika::Program::Env.new({
        sk_classes: @sk_classes,
        constants: constants,
      })
      @sk_classes.each_value{|x| x.add_type!(env)}
      @sk_main.add_type!(env)

      # Add specific classes to @sk_classes (for Shiika::Evaluator)
      specific_classes = @sk_classes.values.grep(SkGenericClass).map{|x|
        x.specialized_classes.values.map{|sp_cls|
          [sp_cls.name, sp_cls]
        }.to_h
      }.inject({}, :merge)
      @sk_classes.merge!(specific_classes)
    end

    # Return a PORO that represents this program (for unit tests)
    def serialize
      {
        class: 'Program',
        sk_classes: @sk_classes.transform_values(&:serialize),
        sk_main: @sk_main.serialize,
      }
    end

    # Base class of each program element.
    class Element
      include Type
      extend Props

      def add_type!(env)
        newenv, @type = calc_type!(env)
        raise TypeError unless newenv.is_a?(Shiika::Program::Env)
        return newenv
      end

      def set_type(ty)
        @type = ty
      end

      def type
        @type or raise "type not yet calculated on #{self.inspect}"
      end

      def calc_type!(env)
        raise "override me (#{self.class})"
      end

      def inspect
        cls_name = self.class.name.split('::').last
        ivars = self.instance_variables.map{|name|
          val = self.instance_variable_get(name)
          "#{name}=#{val.inspect}"
        }
        ivars_desc = ivars.join(' ')
        ivars_desc = ivars_desc[0, 90] + "..." if ivars_desc.length > 100
        "#<P::#{cls_name}##{self.object_id} #{ivars_desc}>"
      end

      #
      # Debug print for add_type!
      #
      module DebugAddType
        @@lv = 0
        def add_type!(env, *rest)
          raise "already has type: #{self.inspect}" if @type
          print " "*@@lv; p self
          @@lv += 2
          env = super(env, *rest)
          @@lv -= 2
          print " "*@@lv; puts "=> #{self.type.inspect}"
          env
        end
      end
      def self.inherited(cls)
        cls.prepend DebugAddType if ENV['DEBUG']
      end
    end

    class SkIvar < Element
      props name: String, type_spec: Type::Base

      def calc_type!(env)
        return env, env.find_type(type_spec)
      end
    end

    class Param < Element
      props name: String, type_spec: Type::Base, is_vararg: :boolean

      def calc_type!(env)
        return env, env.find_type(type_spec)
      end
    end

    class IParam < Param
      props name: String, type_spec: Type::Base, is_vararg: :boolean
    end

    class TypeParameter < Element
      props :name
    end

    class SkMethod < Element
      props name: String,
            params: [Param],
            ret_type_spec: Type::Base,
            body_stmts: nil #TODO: [Element or Proc]
      
      def init
        @class_typarams = []  # [TypeParameter]
      end

      def n_head_params
        has_varparam? ? varparam_idx : params.length
      end

      def n_tail_params
        has_varparam? ? params.length - (varparam_idx + 1) : 0
      end

      def vararg_range
        (n_head_params..-(n_tail_params+1))
      end

      def varparam
        params.find(&:is_vararg)
      end
      alias has_varparam? varparam

      def varparam_idx
        params.index(&:is_vararg)
      end
      private :varparam_idx

      def calc_type!(env)
        # TODO: raise error if there is more than one varargs
        # TODO: raise error if the type of vararg is not Array
        params.each{|x| x.add_type!(env)}
        ret_type = env.find_type(ret_type_spec)

        if !body_stmts.is_a?(Proc) && body_stmts[0] != :runtime_create_object
          lvars = params.map{|x|
            [x.name, Lvar.new(x.name, x.type, :let)]
          }.to_h
          bodyenv = env.merge(:local_vars, lvars)
          body_stmts.each{|x| bodyenv = x.add_type!(bodyenv)}
          check_body_stmts_type(body_stmts, ret_type)
          check_wrong_return_stmt(body_stmts, ret_type)
        end

        return env, TyMethod.new(name, params.map(&:type),
                                 ret_type)
      end

      def full_name(sk_class_or_type)
        case sk_class_or_type
        when SkMetaClass
          "#{sk_class_or_type.name}.#{self.name}"
        when SkClass
          "#{sk_class_or_type.name}##{self.name}"
        when TyRaw
          "#{sk_class_or_type.name}##{self.name}"
        when TyMeta, TyGenMeta
          "#{sk_class_or_type.base_name}.#{self.name}"
        when TySpe
          "#{sk_class_or_type.name}##{self.name}"
        when TySpeMeta
          "#{sk_class_or_type.spclass_name}.#{self.name}"
        else
          raise sk_class_or_type.inspect
        end
      end

      def inject_type_arguments(type_mapping)
        new_params = params.map{|x|
          param_cls = x.class  # Param or IParam
          param_cls.new(name: x.name,
                        type_spec: x.type_spec.substitute(type_mapping),
                        is_vararg: x.is_vararg).tap{|param|
            param.set_type(param.type_spec)
          }
        }
        SkMethod.new(
          name: name,
          params: new_params,
          ret_type_spec: ret_type_spec.substitute(type_mapping),
          body_stmts: body_stmts
        ).tap{|sk_method|
          sk_method.set_type(TyMethod.new(name,
                                          new_params.map(&:type),
                                          sk_method.ret_type_spec))
        }
      end

      private

      def check_body_stmts_type(body_stmts, ret_type)
        return if ret_type == TyRaw['Void']
        body_type = if body_stmts.empty?
                      TyRaw['Void']
                    else
                      last_stmt = body_stmts.last
                      return if last_stmt.is_a?(Program::Return)
                      last_stmt.type
                    end
        if body_type != ret_type
          raise SkTypeError, "method `#{name}' is declared to return #{ret_type}"+
            " but returns #{body_type}"
        end
      end

      def check_wrong_return_stmt(body_stmts, ret_type)
        body_stmts.each do |x|
          case x
          when Program::Return
            if x.expr_type != ret_type
              raise SkTypeError, "method `#{name}' is declared to return #{ret_type}"+
                " but tried to return #{x.expr_type}"
            end
          when Program::If
            check_wrong_return_stmt(ret_type, x.then_stmts)
            check_wrong_return_stmt(ret_type, x.else_stmts)
          end
        end
      end
    end

    class SkInitializer < SkMethod
      def initialize(iparams, body_stmts)
        super(name: "initialize", params: iparams, ret_type_spec: TyRaw["Void"], body_stmts: body_stmts)
      end

      def arity
        @params.length
      end

      # Called from Ast::DefClass#to_program
      # (Note: type is not detected at this time)
      def ivars
        params.grep(IParam).map{|x|
          [x.name, SkIvar.new(name: x.name, type_spec: x.type_spec)]
        }.to_h
      end
    end

    class SkClass < Element
      props name: String,
            superclass_template: Type::ConcreteType, # or TyRaw['__noparent__']
            sk_ivars: {String => SkIvar},
            class_methods: {String => SkMethod},
            sk_methods: {String => SkMethod}

      def self.build(hash)
        typarams = hash[:typarams]
        if typarams.any?
          sk_class = SkGenericClass.new(hash)
        else
          sk_class = SkClass.new(hash.except(:typarams))
        end

        meta_name = "Meta:#{sk_class.name}"
        meta_super = if sk_class.name == 'Object'
                       TyRaw['__noparent__']
                     else
                       sk_class.superclass_template.meta_type
                     end
        sk_new = typarams.empty? && make_sk_new(sk_class)

        meta_attrs = {
          name: meta_name,
          superclass_template: meta_super,
          sk_ivars: {},
          class_methods: {},
          sk_methods: (typarams.empty? ? {"new" => sk_new} : {}).merge(sk_class.class_methods)
        }
        if typarams.any?
          meta_class = SkGenericMetaClass.new(meta_attrs.merge(
            typarams: typarams,
            sk_generic_class: sk_class
          ))
        else
          meta_class = SkMetaClass.new(meta_attrs)
        end
        return sk_class, meta_class
      end

      def self.make_sk_new(sk_class)
        sk_new = Program::SkMethod.new(
          name: "new",
          params: sk_class.sk_methods["initialize"].params.map(&:dup),
          ret_type_spec: sk_class.to_type,
          body_stmts: Stdlib.object_new_body_stmts
        )
        return sk_new
      end

      def calc_type!(env)
        menv = methods_env(env)
        @sk_ivars.each_value{|x| x.add_type!(menv)}
        @sk_methods.each_value{|x| x.add_type!(menv)}
        return env, to_type
      end

      def to_type
        TyRaw[name]
      end

      def meta_type
        TyMeta[name]
      end

      def superclass_name
        superclass_template.name
      end

      # Return true if this class is a (maybe indirect) subclass of `other`
      def subclass_of?(other, env)
        if self == other
          false
        elsif self.superclass_template == TyRaw['__noparent__']
          false
        else
          parent = env.find_class(self.superclass_name)
          if parent == other
            true
          else
            parent.subclass_of?(other, env)
          end
        end
      end

      def find_method(name)
        if (ret = @sk_methods[name])
          ret
        else
          raise SkTypeError, "class `#{@name}' does not have an instance method `#{name}'"
        end
      end

      def inspect
        "#<#{self.class.name.sub('Shiika::Program::', '')}:#{name}>"
      end
      alias to_s inspect

      private

      def methods_env(env)
        env.merge(:sk_self, self)
      end
    end

    class SkGenericClass < SkClass
      more_props typarams: [TypeParameter]

      def init
        @specialized_classes = {}
      end
      attr_reader :specialized_classes

      # type_arguments: [Type]
      def specialized_class(type_arguments, env, cls=SkSpecializedClass)
        key = type_arguments.map(&:to_key).join(', ')
        @specialized_classes[key] ||= begin
          sp_cls = cls.new(generic_class: self, type_arguments: type_arguments)
          sp_cls.add_type!(env)
          sp_cls
        end
      end

      def meta_type
        TyGenMeta[name, typarams.map(&:name)]
      end

      def superclass_name
        raise "SkGenericClass does not have a `superclass'"
      end

      private

      def methods_env(env)
        env.merge(:sk_self, self)
           .merge(:typarams, typarams.map{|x| [x.name, x.type]}.to_h)
      end
    end

    class SkSpecializedClass < Element
      props generic_class: SkGenericClass,
            type_arguments: [Type::ConcreteType]
      alias sk_generic_class generic_class

      def init
        n_typarams, n_tyargs = generic_class.typarams.length, type_arguments.length
        if n_typarams != n_tyargs
          raise SkTypeError, "#{generic_class} takes #{n_typarams} type parameters "+
            "but got #{n_tyargs}"
        end
        @name = "#{sk_generic_class.name}<" + type_arguments.map(&:name).join(', ') + ">"
        @methods = {}  # String => SkMethod
      end
      attr_reader :name
      
      def calc_type!(env)
        return env, TySpe[sk_generic_class.name, type_arguments]
      end

      # Return true if this class is a (maybe indirect) subclass of `other`
      def subclass_of?(other, env)
        if self == other
          false
        else
          parent = env.find_class(self.superclass_name)
          if parent == other
            true
          else
            parent.subclass_of?(other, env)
          end
        end
      end

      # Lazy method creation (create when first called)
      def find_method(name)
        @methods[name] ||= begin
          if (ret = sk_generic_class.sk_methods[name])
            ret.inject_type_arguments(type_mapping)
          else
            raise SkTypeError, "specialized class `#{@name}' does not have an instance method `#{name}'"
          end
        end
      end

      # eg. `"A<Int>"` for `B<Int>`, where `class B<T> extends A<T>`
      def superclass_name
        generic_class.superclass_template.substitute(type_mapping).name
      end

      private

      def type_mapping
        generic_class.typarams.zip(type_arguments).map{|typaram, tyarg|
          [typaram.name, tyarg]
        }.to_h
      end
    end

    class TypeParameter < Element
      props :name

      def type
        @type ||= Type::TyParam.new(name)
      end
    end

    # Holds class methods of a class
    class SkMetaClass < SkClass
      def to_type
        TyMeta[name]
      end
    end

    class SkGenericMetaClass < SkGenericClass
      more_props typarams: [TypeParameter], sk_generic_class: SkGenericClass

      def init
        @specialized_classes = {}
      end

      def specialized_class(type_arguments, env)
        super(type_arguments, env, SkSpecializedMetaClass)
      end

      def superclass_name
        raise "SkGenericMetaClass does not have a `superclass'"
      end

      def to_type
        TyGenMeta[name, typarams.map(&:name)]
      end
    end

    class SkSpecializedMetaClass < SkSpecializedClass
      alias sk_generic_meta_class generic_class

      def init
        super
        sk_generic_class = sk_generic_meta_class.sk_generic_class
        @name = "Meta:#{sk_generic_class.name}<" + type_arguments.map(&:name).join(', ') + ">"
        @sk_new = Program::SkMethod.new(
          name: "new",
          params: sk_generic_class.sk_methods["initialize"].params.map(&:dup),
          ret_type_spec: TySpe[sk_generic_class.name, type_arguments],
          body_stmts: Stdlib.object_new_body_stmts,
        )
      end

      def calc_type!(env)
        typarams = sk_generic_meta_class.typarams.zip(type_arguments).map{|tparam, targ|
          [tparam.name, targ]
        }.to_h
        menv = env.merge(:sk_self, self)
                  .merge(:typarams, typarams)
        @sk_new.add_type!(menv)
        return env, TySpeMeta[sk_generic_meta_class.sk_generic_class.name, type_arguments]
      end

      def find_method(name)
        if name == "new"
          return @sk_new.inject_type_arguments(type_mapping)
        else
          super
        end
      end
    end

    class SkConst < Element
      props name: String
    end

    class Main < Element
      props stmts: [Element]

      def calc_type!(env)
        stmts.each{|x| env = x.add_type!(env)}
        return env, (stmts.last ? stmts.last.type : TyRaw["Void"])
      end
    end

    # Base class for those that has a value
    class Expression < Element
    end

    class Return < Element
      props expr: Expression
      attr_reader :expr_type

      def calc_type!(env)
        expr.add_type!(env)
        @expr_type = expr.type
        return env, TyRaw["Void"]
      end
    end

    class If < Expression
      props cond_expr: Expression, then_stmts: [Element], else_stmts: [Element]

      def calc_type!(env)
        cond_expr.add_type!(env)
        if cond_expr.type != TyRaw["Bool"]
          raise SkTypeError, "`if` condition must be Bool"
        end
        then_stmts.each{|x| env = x.add_type!(env)}
        else_stmts.each{|x| env = x.add_type!(env)}

        then_type = then_stmts.last&.type
        else_type = else_stmts.last&.type
        if_type = case
                  when then_type && else_type
                    if then_type != else_type
                      raise SkTypeError, "`if` type mismatch (then-clause: #{then_type},"
                      " else-clause: #{else_type})"
                    end
                    then_type
                  when then_type
                    then_type
                  when else_type
                    else_type
                  else
                    TyRaw["Void"]
                  end
        return env, if_type
      end
    end

    class MethodCall < Expression
      props method_name: String,
            receiver_expr: nil, #TODO Expression or Evaluator::SkObj
            args: nil #TODO [Expression or Evaluator::SkObj]

      def calc_type!(env)
        args.each{|x| env = x.add_type!(env)}
        env = receiver_expr.add_type!(env)
        sk_method = env.find_method(receiver_expr.type, method_name)
        check_arg_types(sk_method, env)
        return env, sk_method.type.ret_type
      end

      private

      def check_arg_types(sk_method, env)
        n_args = args.length
        params = sk_method.params
        varparam = params.find(&:is_vararg)

        # Assert that sufficient number of args are given
        least_arity = varparam ? params.length - 1 : params.length
        if n_args < least_arity
          raise SkTypeError, "method #{sk_method.name} takes " +
            "#{'at least ' if varparam}#{least_arity} parameters but got #{n_args}"
        end

        check_nonvar_arg_types(sk_method, env)

        if varparam
          # Check type of varargs
          elem_type = varparam.type.type_args.first
          varargs = args[sk_method.vararg_range]
          varargs.each do |arg|
            if arg.type != elem_type
              raise SkTypeError, "variable-length parameter #{varparam.name} of `#{sk_method.full_name(receiver_expr.type)}` is #{varparam.type} but got #{arg.type} for its element"
            end
          end
          # Make sure Meta:Array<T> is created (to call .new on it)
          sp_cls = env.find_class('Meta:Array').specialized_class([elem_type], env)
          sp_cls.find_method('new')
        end
      end

      def check_nonvar_arg_types(sk_method, env)
        params = sk_method.params
        n_head = sk_method.n_head_params
        n_tail = sk_method.n_tail_params

        matches = params.first(n_head).zip(args.first(n_head)) +
                  params.last(n_tail).zip(args.last(n_tail))
        matches.each do |param, arg|
          if !env.conforms_to?(arg.type, param.type)
            raise SkTypeError, "parameter `#{param.name}' of `#{sk_method.full_name(receiver_expr.type)}' is #{param.type} but got #{arg.type}"
          end
        end
      end
    end

    class AssignmentExpr < Expression
      def calc_type!(env)
        newenv = expr.add_type!(env)
        raise SkProgramError, "cannot assign Void value" if expr.type == TyRaw["Void"]
        return newenv
      end
    end

    class AssignLvar < AssignmentExpr
      props varname: String, expr: Expression, isvar: :boolean

      def calc_type!(env)
        newenv = super
        lvar = env.find_lvar(varname, allow_missing: true)
        if lvar
          if lvar.kind == :let
            raise SkProgramError, "lvar #{varname} is read-only (missing `var`)"
          end
          unless newenv.conforms_to?(expr.type, lvar.type)
            raise SkTypeError, "the type of expr (#{expr.type}) does not conform to the type of lvar #{varname} (#{lvar.type})"
          end
        else
          lvar = Lvar.new(varname, expr.type, (isvar ? :var : :let))
        end
        retenv = newenv.merge(:local_vars, {varname => lvar})
        return retenv, expr.type
      end
    end

    class AssignIvar < AssignmentExpr
      props varname: String, expr: Expression

      def calc_type!(env)
        newenv = super
        ivar = env.find_ivar(varname)
        if ivar.type != expr.type  # TODO: subtypes
          raise SkTypeError, "ivar #{varname} of class #{env.sk_self} is #{ivar.type} but expr is #{expr.type}"
        end
        return newenv, expr.type
      end
    end

    class AssignConst < AssignmentExpr
      props varname: String, expr: Expression
      
      def calc_type!(env)
        TODO
      end
    end

    class LvarRef < Expression
      props name: String

      def calc_type!(env)
        lvar = env.find_lvar(name)
        return env, lvar.type
      end
    end

    class IvarRef < Expression
      props name: String

      def calc_type!(env)
        ivar = env.find_ivar(name)
        return env, ivar.type
      end
    end

    class ConstRef < Expression
      props name: String

      def calc_type!(env)
        const = env.find_const(name)
        return env, const.type
      end
    end

    class ClassSpecialization < Expression
      props class_expr: ConstRef, type_arg_exprs: [ConstRef]

      def calc_type!(env)
        class_expr.add_type!(env)
        type_arg_exprs.each{|x| x.add_type!(env)}

        unless TyGenMeta === class_expr.type
          raise SkTypeError, "not a generic class: #{class_expr.type}"
        end
        base_class_name = class_expr.type.base_name
        type_args = type_arg_exprs.map{|expr|
          raise SkTypeError, "not a class: #{expr.inspect}" unless expr.type.is_a?(TyMeta)
          expr.type.instance_type
        }
        sp_cls, sp_meta = create_specialized_class(env, base_class_name, type_args)
        newenv = env.merge(:sk_classes, {
          sp_cls.name => sp_cls,
          sp_meta.name => sp_meta.name,
        })
        return newenv, TySpeMeta[base_class_name, type_args]
      end

      private

      # Create specialized class and its metaclass (if they have not been created yet)
      def create_specialized_class(env, base_class_name, type_args)
        gen_cls = env.find_class(base_class_name)
        raise if !(SkGenericClass === gen_cls) &&
                 !(SkGenericMetaClass === gen_cls)
        sp_cls = gen_cls.specialized_class(type_args, env)
        gen_meta = env.find_meta_class(base_class_name)
        sp_meta = gen_meta.specialized_class(type_args, env)
        return sp_cls, sp_meta
      end
    end

    class ArrayExpr < Expression
      props exprs: [Expression]

      def calc_type!(env)
        exprs.each{|x| env = x.add_type!(env)}
        elem_type = exprs.first.type
        exprs.each do |x|
          if x.type != elem_type
            raise SkTypeError, 'Currently all elements of an array must have'+
              ' the same type'
          end
        end
        # Make sure Meta:Array<T> is created (to call .new on it)
        sp_cls = env.find_class('Meta:Array').specialized_class([elem_type], env)
        sp_cls.find_method('new')
        return env, TySpe['Array', [elem_type]]
      end
    end

    class Literal < Expression
      props value: Object  # A Ruby object that describes the value

      def calc_type!(env)
        type = case value
               when true, false
                 TyRaw["Bool"]
               when Integer
                 TyRaw["Int"]
               when Integer
                 TyRaw["Float"]
               else
                 raise "unknown value: #{value.inspect}"
               end
        return env, type
      end
    end

    class Lvar
      # kind : :let, :var, :param, :special
      def initialize(name, type, kind)
        @name, @type, @kind = name, type, kind
      end
      attr_reader :name, :type, :kind

      def inspect
        "#<P::Lvar #{kind} #{name.inspect} #{type}>"
      end
    end
  end
end
