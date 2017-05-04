require 'concurrent'
require 'apartment/migrator'

apartment_namespace = namespace :apartment do

  desc "Create all tenants"
  task create: 'db:migrate' do
    tenants.each do |tenant|
      begin
        puts("Creating #{tenant} tenant")
        quietly { Apartment::Tenant.create(tenant) }
      rescue Apartment::TenantExists => e
        puts e.message
      end
    end
  end

  desc "Migrate all tenants"
  task :migrate do
    warn_if_tenants_empty
    parallel_each(tenants) do |tenant|
      begin
        puts("Migrating #{tenant} tenant")
        Apartment::Migrator.migrate tenant
      rescue Apartment::TenantNotFound => e
        puts e.message
      end
    end
  end

  desc "Seed all tenants"
  task :seed do
    warn_if_tenants_empty

    parallel_each(tenants) do |tenant|
      begin
        puts("Seeding #{tenant} tenant")
        Apartment::Tenant.switch(tenant) do
          Apartment::Tenant.seed
        end
      rescue Apartment::TenantNotFound => e
        puts e.message
      end
    end
  end

  desc "Rolls the migration back to the previous version (specify steps w/ STEP=n) across all tenants."
  task :rollback do
    warn_if_tenants_empty

    step = ENV['STEP'] ? ENV['STEP'].to_i : 1

    parallel_each(tenants) do |tenant|
      begin
        puts("Rolling back #{tenant} tenant")
        Apartment::Migrator.rollback tenant, step
      rescue Apartment::TenantNotFound => e
        puts e.message
      end
    end
  end

  namespace :migrate do
    desc 'Runs the "up" for a given migration VERSION across all tenants.'
    task :up do
      warn_if_tenants_empty

      version = ENV['VERSION'] ? ENV['VERSION'].to_i : nil
      raise 'VERSION is required' unless version

      parallel_each(tenants) do |tenant|
        begin
          puts("Migrating #{tenant} tenant up")
          Apartment::Migrator.run :up, tenant, version
        rescue Apartment::TenantNotFound => e
          puts e.message
        end
      end
    end

    desc 'Runs the "down" for a given migration VERSION across all tenants.'
    task :down do
      warn_if_tenants_empty

      version = ENV['VERSION'] ? ENV['VERSION'].to_i : nil
      raise 'VERSION is required' unless version

      parallel_each(tenants) do |tenant|
        begin
          puts("Migrating #{tenant} tenant down")
          Apartment::Migrator.run :down, tenant, version
        rescue Apartment::TenantNotFound => e
          puts e.message
        end
      end
    end

    desc  'Rolls back the tenant one migration and re migrate up (options: STEP=x, VERSION=x).'
    task :redo do
      if ENV['VERSION']
        apartment_namespace['migrate:down'].invoke
        apartment_namespace['migrate:up'].invoke
      else
        apartment_namespace['rollback'].invoke
        apartment_namespace['migrate'].invoke
      end
    end
  end

  def tenants
    ENV['DB'] ? ENV['DB'].split(',').map { |s| s.strip } : Apartment.tenant_names || []
  end

  def warn_if_tenants_empty
    if tenants.empty?
      puts <<-WARNING
        [WARNING] - The list of tenants to migrate appears to be empty. This could mean a few things:

          1. You may not have created any, in which case you can ignore this message
          2. You've run `apartment:migrate` directly without loading the Rails environment
            * `apartment:migrate` is now deprecated. Tenants will automatically be migrated with `db:migrate`

        Note that your tenants currently haven't been migrated. You'll need to run `db:migrate` to rectify this.
      WARNING
    end
  end

  def parallel_each(items)
    if Apartment.use_parallel_tenant_task
      threads = []
      concurrent_items = Concurrent::Array.new(items)
      start_time = Time.now
      # create workers
      Apartment.num_parallel_threads.times do |worker_id|
        threads << Thread.new(worker_id) do |worker_id|
          sleep 1 # sleep on start up, left time for spawning threads
          item = concurrent_items.shift
          while item
            begin
              yield item
              item = concurrent_items.shift
            rescue ActiveRecord::ConnectionTimeoutError => e
              puts "Connection timeout for #{item}, retry after 1 seconds"
              sleep 1
            end
          end
        end
      end
      threads.each{|t| t.join}
      threads.clear
      puts("Elapsed: #{Time.now - start_time}")
    else
      items.each do |item|
        yield item
      end
    end
  end
end
