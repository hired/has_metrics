module Metrics
  def self.included(base)
    base.extend ClassMethods

    klass_name = "#{base}Metrics"
    klass = begin
      Object.const_get(klass_name)
    rescue
      Object.const_set(klass_name, Class.new(ActiveRecord::Base))
    end
    klass.class_eval do
      extend Metrics::MetricsClass
      belongs_to base.to_s.underscore.to_sym, :foreign_key => 'id'
      @object_class = base
    end

    base.class_eval do
      if klass.table_exists?
        @metrics_class = klass
        has_one :metrics, :class_name => klass_name, :foreign_key => 'id', :dependent => :destroy
      else
        @object_class = base
        @metrics_class = base
        base.extend(Metrics::MetricsClass)
      end

      def metrics
        @metrics ||= self.class.metrics_class.find_or_create_by_id(id)
      end
    end
  end

  module ClassMethods
    # CLASS METHODS ADDED
    def metrics_class
      @metrics_class
    end

    def has_metric name, options={}, &block
      options.merge!(single: block) if block
      define_single_method(name, options) if options[:single]

      metrics[name.to_sym] ||= {}
      metrics[name.to_sym].merge!(options)
      metrics_class.class_eval do
        attr_accessible(name, "updated__#{name}__at")
      end
    end

    def has_aggregate_metric(name, sql)
      has_metric name, {}.merge(aggregate: sql)
    end

    def define_single_method(name, options)
      define_method name do |*args|
        frequency = options[:every] || 20.hours
        previous_result = metrics.attributes[name.to_s] unless options[:every] == :always
        datestamp_column = "updated__#{name}__at"
        datestamp = metrics.attributes[datestamp_column]
        force = [:force, true].include?(args[0])
        case
          when !force && previous_result && options[:once]
            # Only calculate this metric once.  If it's not nil, reuse the old value.
            previous_result
          when !force && frequency.is_a?(Fixnum) && datestamp && datestamp > frequency.ago
            # The metric was recently calculated and can be reused.
            previous_result
          else
            result = instance_exec(&options[:single])
            result = nil if result.is_a?(Float) && !result.finite?
            begin
              metrics.send "#{name}=", result
              metrics.send "#{datestamp_column}=", Time.current
            rescue NoMethodError => e
              raise e unless e.name == "#{name}=".to_sym
              # This happens if the migrations haven't run yet for this metric. We should still calculate & return the metric.
            end
            unless changed?
              metrics.save
            end
            result
        end
      end
    end

    def metrics
      @metrics ||= {}
    end

    def single_only_metrics
      metrics.select{ |metric, options| !options.has_key?(:aggregate) }
    end

    def aggregate_metrics
      metrics.select{ |metric, options| options.has_key?(:aggregate) }
    end

    def metrics_column_type(column)
      case
      when (metric = metrics.select { |metric, options| metric == column.to_sym && options[:type] }).any?
        metric.values.first[:type]
      when (column.to_s =~ /^by_(.+)$/) && respond_to?(:segment_categories) && segment_categories.include?($1.to_sym) # TODO: carve out segementation functionality into this gem
        :string
      when (column.to_s =~ /_at$/)
        :datetime
      else
        :integer
      end
    end

    def update_all_metrics!(*args)
      metrics_class.migrate!

      return unless warmup = first
      detected_aggregate_metrics, singular_metrics = collect_metrics(warmup)

      if singular_metrics.any?
        unless ENV['RAILS_ENV'] == 'test'
          puts "Slow Metrics Found :: #{singular_metrics.count} \n"
          puts " --  --  --  -- \n"
          puts "Go implement their aggregate methods in #{self} to speed this up.\n"
          puts singular_metrics.join(', ')
          puts "\n ≈ ≈ ≈ ≈ ≈ ≈ ≈ "
        end

        find_in_batches do |batch|
          metrics_class.transaction do
            batch.each do |record|
              singular_metrics.each do |singular_metric|
                record.send(singular_metric, *args)
              end
            end
          end
        end
      end

      bad_guesses = []
      detected_aggregate_metrics.each do |metric_name, update_sql|
        begin
          ActiveRecord::Base.connection.execute update_sql
        rescue
          bad_guesses << metric_name
        end
      end
      if bad_guesses.any?
        warn "#{bad_guesses.count} bad guesses found, scheduling as singular metrics."
        find_in_batches do |batch|
          metrics_class.transaction do
            batch.each do |record|
              bad_guesses.each do |singular_metric|
                record.send(singular_metric, *args)
              end
            end
          end
        end
      end

      aggregate_metrics.each do |metric_name, options|
        ActiveRecord::Base.connection.execute options[:aggregate]
        metrics_class.update_all "updated__#{metric_name}__at" => Time.current
      end

      metrics
    end

    def collect_metrics(warmup)
      singular_metrics = []
      detected_aggregate_metrics = {}
      metrics.each do |metric_name, options|
        next if options[:aggregate]
        existing_logger = ActiveRecord::Base.logger
        sql_capturer = ActiveRecord::Base.logger = SqlCapturer.new(existing_logger)
        warmup.instance_exec(&options[:single])
        ActiveRecord::Base.logger = existing_logger


        if sql_capturer.query.count != 1
          singular_metrics << metric_name
        else
          subquery = sql_capturer.query.first.gsub(warmup.id.to_s, "#{metrics_class.table_name}.id")
          unless subquery == %Q{SELECT "#{metrics_class.table_name}".* FROM "#{metrics_class.table_name}" WHERE "#{metrics_class.table_name}"."id" = #{metrics_class.table_name}.id LIMIT 1}
            update_sql = %Q{
              UPDATE #{metrics_class.table_name}
                 SET #{metric_name} = (#{subquery}),
                     updated__#{metric_name}__at = '#{Time.current.to_s(:db)}';
            }
            detected_aggregate_metrics[metric_name] = update_sql
          end
        end
      end
      return detected_aggregate_metrics, (singular_metrics - aggregate_metrics.keys)
    end
  end
    ### END CLASS METHODS, START INSTANCE METHODS

  def update_metrics!(*args)
    self.class.metrics.each do |metric, options|
      send(metric, *args)
    end
  end

  ### END INSTANCE METHODS

  ### Sets up a class like "SiteMetrics".  These are all CLASS methods:
  module MetricsClass
    def object_class
      @object_class
    end

    def metrics_updated_at_columns
      @object_class.metrics.keys.map{|metric| "updated__#{metric}__at"}
    end

    def required_columns
      @object_class.metrics.keys.map(&:to_s) + metrics_updated_at_columns
    end

    def missing_columns
      reset_column_information
      required_columns - (columns.map(&:name) - %w(id created_at updated_at))
    end

    def extra_columns
      reset_column_information
      if @object_class == self
        raise "Cannot determine if there were extra columns for has_metric when using the table itself for storing the metric!  Remove any columns manually"
        [] # We wont know what columns are excessive if the source changed
      else
        (columns.map(&:name) - %w(id created_at updated_at)) - required_columns
      end

    end

    class Metrics::Migration < ActiveRecord::Migration
      def self.setup(metrics)
        @metrics = metrics
      end
      def self.up
        @metrics.missing_columns.each do |column|
          column_type = @metrics.object_class.metrics_column_type(column)
          add_column @metrics.table_name, column, column_type, (column_type==:string ? {:null => false, :default => ''} : {})
        end
      end
      def self.down
        @metrics.extra_columns.each do |column|
          remove_column @metrics.table_name, column
        end
      end
    end

    def remigrate!
      old_metrics = @object_class.metrics
      @object_class.class_eval { @metrics = [] }
      migrate!
      @object_class.class_eval { @metrics = old_metrics }
      migrate!
    end

    def migrate!
      # don't migrate if metrics are kept in current class
      return if @object_class == self

      Metrics::Migration.setup(self)
      Metrics::Migration.down unless extra_columns.empty?
      Metrics::Migration.up unless missing_columns.empty?
      reset_column_information
    end
  end
end
