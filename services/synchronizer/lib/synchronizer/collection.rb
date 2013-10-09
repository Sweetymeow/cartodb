# encoding: utf-8
require 'eventmachine'
require 'pg/em'
require 'yaml'
require 'resque'
require_relative '../../../../app/models/synchronization/member'
require_relative '../../../../lib/resque/synchronization_jobs'

module CartoDB
  module Synchronizer
    class Collection
      DEFAULT_RELATION      = 'synchronizations'
      DATABASE_CONFIG_YAML  = File.join(
        File.dirname(__FILE__), '../../../../config/database.yml'
      )

      def initialize(pg_options={}, relation=DEFAULT_RELATION)
        pg_options = default_pg_options.merge(pg_options) if pg_options.empty?
        pg_options.store(:dbname, pg_options.delete(:database))

        @db       = PG::EM::Client.new(pg_options)
        @relation = relation
        @records  = [] 
      end

      def run
        fetch
        process
      end

      def fetch(success, error)
        query = db.query(%Q(
          SELECT * FROM #{relation}
          WHERE EXTRACT(EPOCH FROM run_at) < #{Time.now.utc.to_f}
          AND state == 'success'
        ))

        query.errback   { |errors| error.call(errors) }
        query.callback  { |records| self.members = hydrate(records); success.call(hydrate(records)) }
        self
      end

      def process(members=@members)
        members.each(&:enqueue)
      end

      attr_reader :records, :members

      private

      attr_reader :db, :relation
      attr_writer :records, :members

      def hydrate(records)
        @members = records.map { |record| CartoDB::Synchronization::Member.new(record) }
        self
      end

      def default_pg_options
        configuration = YAML.load_file(DATABASE_CONFIG_YAML)
        options       = configuration[ENV['RAILS_ENV'] || 'development']

        {
          host:       options.fetch('host'),
          port:       options.fetch('port'),
          user:       options.fetch('username'),
          password:   options.fetch('password'),
          database:   options.fetch('database')
        }
      end
    end # Collection
  end # Synchronizer
end # CartoDB

