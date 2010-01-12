require 'active_record/fixtures' # so we can hook it & reset our cache afterwards

module ConstantTableSaver
  module BaseMethods
    def constant_table(options = {})
      options.assert_valid_keys(:name, :name_prefix, :name_suffix)
      class_inheritable_accessor :constant_table_options, :instance_writer => false
      self.constant_table_options = options
      
      class <<self
        def find(*args)
          options = args.last if args.last.is_a?(Hash)
          return super unless options.blank? || options.all? {|k, v| v.nil?}
          scope_options = scope(:find)
          return super unless scope_options.blank? || scope_options.all? {|k, v| v.nil?}

          args.pop unless options.nil?

          @cached_records ||= super(:all).each(&:freeze)
          @cached_records_by_id ||= @cached_records.index_by {|record| record.id.to_param}

          case args.first
            when :first then @cached_records.first
            when :last  then @cached_records.last
            when :all   then @cached_records.dup # shallow copy of the array
            else
              expects_array = args.first.kind_of?(Array)
              return args.first if expects_array && args.first.empty?
              ids = expects_array ? args.first : args
              ids = ids.flatten.compact.uniq

              case ids.size
                when 0
                  raise RecordNotFound, "Couldn't find #{name} without an ID"
                when 1
                  result = @cached_records_by_id[ids.first.to_param]
                  expects_array ? [result] : result
                else
                  ids.collect {|id| @cached_records_by_id[id.to_param]}
              end
          end
        end
        
        # Resets the cached records.  Remember that this only affects this process, so while this
        # is useful for running tests, it's unlikely that you can use this in production - you
        # would need to call it on every Rails instance on every Rails server.  Don't use this
        # plugin on if the table isn't really constant!
        def reset_constant_record_cache!
          @constant_record_methods.each {|method_id| (class << self; self; end;).send(:remove_method, method_id)} if @constant_record_methods
          @cached_records = @cached_records_by_id = @constant_record_methods = nil
        end
      end
      
      class <<self
        def define_named_record_methods
          @constant_record_methods = all.collect do |record|
            method_name = "#{constant_table_options[:name_prefix]}#{record[constant_table_options[:name]].downcase.gsub!(/\W+/, '_')}#{constant_table_options[:name_suffix]}"
            next if method_name.blank?
            (class << self; self; end;).instance_eval { define_method(method_name) { record } }
            method_name.to_sym
          end.compact.uniq
        end
        
        def respond_to?(method_id, include_private = false)
          super || (@constant_record_methods.nil? && define_named_record_methods && super)
        end
        
        def method_missing(method_id, *arguments, &block)
          if @constant_record_methods.nil?
            define_named_record_methods
            send(method_id, *arguments, &block) # retry
          else
            super
          end
        end
      end if constant_table_options[:name]
      
      class <<Fixtures
        # normally, create_fixtures method gets called exactly once - but unfortunately, it
        # loads the class and does a #respond_to?, which causes us to load and cache before
        # the new records are added, so we need to reset our cache afterwards.
        def create_fixtures_with_constant_tables(*args)
          returning(create_fixtures_without_constant_tables(*args)) { ConstantTableSaver.reset_all_caches }
        end
        def reset_cache_with_constant_tables(*args)
          returning(reset_cache_without_constant_tables(*args))     { ConstantTableSaver.reset_all_caches }
        end
        alias_method_chain :create_fixtures, :constant_tables
        alias_method_chain :reset_cache,     :constant_tables
      end unless Fixtures.respond_to?(:create_fixtures_with_constant_tables)
    end
  end

  def self.reset_all_caches
    ActiveRecord::Base.send(:subclasses).each do |klass|
      klass.reset_constant_record_cache! if klass.respond_to?(:reset_constant_record_cache!)
    end
  end
end
