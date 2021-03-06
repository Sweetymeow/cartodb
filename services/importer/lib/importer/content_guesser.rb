# encoding: utf-8

require 'ipaddr'
require_relative 'table_sampler'
require_relative 'importer_stats'

module CartoDB
  module Importer2
    class ContentGuesser

      COUNTRIES_COLUMN = 'name_'
      COUNTRIES_QUERY = "SELECT #{COUNTRIES_COLUMN} FROM admin0_synonyms"
      DEFAULT_MINIMUM_ENTROPY = 0.9
      ID_COLUMNS = ['ogc_fid', 'gid', 'cartodb_id']

      attr_reader :country_name_normalizer

      def initialize(db, table_name, schema, options, job=nil)
        @db         = db
        @table_name = table_name
        @schema     = schema
        @options    = options
        @job        = job
        @importer_stats = ImporterStats.instance
        @country_name_normalizer = Proc.new {|str| str.nil? ? '' : str.gsub(/[^a-zA-Z\u00C0-\u00ff]+/, '').downcase }
      end

      def set_importer_stats(importer_stats)
        @importer_stats = importer_stats
      end

      def enabled?
        @options[:guessing][:enabled] rescue false
      end

      def country_column
        return nil if not enabled?
        columns.each do |column|
          return column[:column_name] if is_country_column? column
        end
        nil
      end

      def ip_column
        return nil if not enabled?
        columns.each do |column|
          return column[:column_name] if is_ip_column? column
        end
        nil
      end

      def columns
        @columns ||= @db[%Q(
          SELECT column_name, data_type
          FROM information_schema.columns
          WHERE table_name = '#{@table_name}' AND table_schema = '#{@schema}'
        )]
      end

      def is_country_column?(column)
        return false unless is_text_type? column
        entropy = metric_entropy(column, country_name_normalizer)
        if entropy < minimum_entropy
          false
        else
          proportion = country_proportion(column)
          if proportion < threshold
            false
          else
            log_country_guessing_match_metrics(proportion)
            true
          end
        end
      end

      def log_country_guessing_match_metrics(proportion)
        @importer_stats.gauge('country_proportion', proportion)
      end

      def log_ip_guessing_match_metrics(proportion)
        @importer_stats.gauge('ip_proportion', proportion)
      end

      def is_ip_column?(column)
        return false unless is_text_type? column
        proportion  = ip_proportion(column)
        if proportion > threshold
          log "ip_proportion(#{column[:column_name]}) = #{proportion}; threshold = #{threshold}; sample.count = #{sample.count}"
          log "sample.first(4) = #{sample.first(4)}"
          log_ip_guessing_match_metrics(proportion)
          true
        else
          false
        end
      end


      # See http://en.wikipedia.org/wiki/Entropy_(information_theory)
      # See http://www.shannonentropy.netmark.pl/
      #
      # Returns 0.0 if all elements in the column are repeated
      # Returns 1.0 if all elements in the column are different
      def metric_entropy(column, normalizer=nil)
        shannon_entropy(column, normalizer) / Math.log(sample.count)
      end

      def shannon_entropy(column, normalizer)
        sum = 0.0
        frequencies(column, normalizer).each { |freq| sum += (freq * Math.log(freq)) }
        return sum.abs
      end

      # Returns an array with the relative frequencies of the elements of that column
      def frequencies(column, normalizer)
        frequency_table = {}
        column_name_sym = column[:column_name].to_sym
        if normalizer
          sample.each do |row|
            elem = normalizer.call(row[column_name_sym])
            frequency_table[elem] += 1 rescue frequency_table[elem] = 1
          end
        else
          sample.each do |row|
            elem = row[column_name_sym]
            frequency_table[elem] += 1 rescue frequency_table[elem] = 1
          end
        end
        length = sample.count.to_f
        frequency_table.map { |key, value| value / length }
      end

      def country_proportion(column)
        column_name_sym = column[:column_name].to_sym
        matches = sample.count { |row| countries.include? country_name_normalizer.call(row[column_name_sym]) }
        country_proportion = matches.to_f / sample.count
        log "country_proportion(#{column[:column_name]}) = #{country_proportion}"
        country_proportion
      end

      def log(msg)
        @job.log msg if @job
      end

      def sample
        @sample ||= TableSampler.new(@db, qualified_table_name, id_column, sample_size).sample
      end

      def id_column
        return @id_column if @id_column
        columns.each do |column|
          if ID_COLUMNS.include? column[:column_name]
            @id_column = column[:column_name]
            return @id_column
          end
        end
        raise ContentGuesserException, "Couldn't find an id column for table #{qualified_table_name}"
      end

      def ip_proportion(column)
        column_name_sym = column[:column_name].to_sym
        matches = sample.count { |row| is_ip?(row[column_name_sym]) }
        matches.to_f / sample.count
      end

      def is_ip?(str)
        # The is_integer? check is required because of a bug in IPAddr solved
        # in recent versions of the ruby interpreter. It can be removed in
        # future versions.
        !is_integer?(str) && (IPAddr.new(str) && true) rescue false
      end

      def is_integer?(str)
        /\A[-+]?\d+\z/ === str
      end


      def threshold
        @options[:guessing][:threshold]
      end

      def is_text_type? column
        ['character varying', 'varchar', 'text'].include? column[:data_type]
      end

      def sample_size
        @options[:guessing][:sample_size]
      end

      def minimum_entropy
        @minimum_entropy ||= @options[:guessing].fetch(:minimum_entropy, DEFAULT_MINIMUM_ENTROPY)
      end

      def countries
        return @countries if @countries
        @countries = Set.new()
        geocoder_sql_api.fetch(COUNTRIES_QUERY).each do |country|
          country_name = country[COUNTRIES_COLUMN]
          @countries.add country_name if country_name.length >= 2
        end
        @countries
      end

      def geocoder_sql_api
        @geocoder_sql_api ||= CartoDB::SQLApi.new(@options[:geocoder][:internal])
      end

      attr_writer :geocoder_sql_api

      def qualified_table_name
        %Q("#{@schema}"."#{@table_name}")
      end

    end

    class ContentGuesserException < StandardError; end

  end
end
