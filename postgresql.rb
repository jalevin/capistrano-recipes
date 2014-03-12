require 'debugger' 
set_default(:postgresql_host, "localhost")
set_default(:postgresql_user) { application }
set_default(:postgresql_password) { Capistrano::CLI.password_prompt "PostgreSQL Password: " }
set_default(:postgresql_database) { "#{application}" }
set_default(:postgresql_dump_path) { "#{current_path}/tmp" }
set_default(:postgresql_dump_file) { "#{application}_dump" }
set_default(:postgresql_local_dump_path) { File.expand_path("../../../tmp", __FILE__) }
set_default(:postgresql_pid) { "/var/run/postgresql/9.1-main.pid" }


namespace :postgresql do
  desc "Install the latest stable release of PostgreSQL."
  task :install, roles: :db, only: {primary: true} do
    run "#{sudo} add-apt-repository -y ppa:pitti/postgresql"
    run "#{sudo} apt-get -y update"
    run "#{sudo} apt-get -y install postgresql libpq-dev"
  end
  after "deploy:install", "postgresql:install"

  desc "Create a database for this application."
  task :create_database, roles: :db, only: {primary: true} do
    run %Q{#{sudo} -u postgres psql -c "create user #{postgresql_user} with password '#{postgresql_password}';"}
    run %Q{#{sudo} -u postgres psql -c "create database #{application}_production owner #{postgresql_user};"}
  end
  after "deploy:setup", "postgresql:create_database"

  desc "Generate the database.yml configuration file."
  task :setup, roles: :app do
    run "mkdir -p #{shared_path}/config"
    template "postgresql.yml.erb", "#{shared_path}/config/database.yml"
  end
  after "deploy:setup", "postgresql:setup"

  desc "Symlink the database.yml file into latest release"
  task :symlink, roles: :app do
    run "ln -nfs #{shared_path}/config/database.yml #{release_path}/config/database.yml"
  end
  after "deploy:finalize_update", "postgresql:symlink"

  desc "database console"
  task :console do
    auth = capture "cat #{shared_path}/config/database.yml"
    puts "PASSWORD::: #{auth.match(/password: (.*$)/).captures.first}"
    hostname = find_servers_for_task(current_task).first
    exec "ssh #{hostname} -t 'source ~/.zshrc && psql -U #{application} #{postgresql_database}'"
  end

  namespace :local do
    desc "Download remote database to tmp/"
    task :download do
      dumpfile = "#{postgresql_local_dump_path}/#{postgresql_dump_file}"
      get "#{postgresql_dump_path}/#{postgresql_dump_file}", dumpfile
    end
    
    desc "Dump local db"
    task :dump do
      run_locally <<-Commands
        pg_dump -Ft -U #{application} #{application}_development > #{postgresql_local_dump_path}/#{postgresql_dump_file}
      Commands
    end

    desc "drop local db"
    task :drop_local, on_error: :abort do
      run_locally "rake db:drop && rake db:create"
    end

    desc "Restores local database from temp file"
    task :restore do
      run_locally <<-EOS
        pg_restore #{postgresql_local_dump_path}/#{postgresql_dump_file} --dbname=#{application}_development -U #{postgresql_user} --no-password -n public
      EOS
    end

    desc "Dump remote database and download it locally"
    task :localize do
      remote.dump
      download
    end

    desc "Dump remote database, download it locally and restore local database"
    task :sync do
      localize
      drop_local
      restore
    end
  end


  namespace :remote do
    desc "Dump remote database"
    task :dump do
      dbyml = capture "cat #{shared_path}/config/database.yml"
      info  = YAML.load dbyml
        db    = info['production']#FIXME ignoring stage naming conventions stage.to_s
      user, pass, database, host = db['username'], db['password'], db['database'], db['host']

      run <<-CMD
        export PGPASSWORD="#{pass}"; \
        pg_dump -Ft -U #{user} -h #{host} #{database} > #{postgresql_dump_path}/#{postgresql_dump_file}
      CMD
    end

    desc "Uploads local dump file to remote server"
    task :upload do
      local.dump
      dumpfile = "#{postgresql_local_dump_path}/#{postgresql_dump_file}"
      upfile   = "#{postgresql_dump_path}/#{postgresql_dump_file}"
      put File.read(dumpfile), upfile
    end

    desc "Restores remote database"
    task :restore do
      backup
      dumpfile = "#{postgresql_dump_path}/#{postgresql_dump_file}"
      dbyml    = capture "cat #{shared_path}/config/database.yml"
      info     = YAML.load dbyml
      db       = info['production']
      user, pass, database, host = db['username'], db['password'], db['database'], db['host']

      run <<-EOS
        export PGPASSWORD="#{pass}"; \
        pg_restore #{postgresql_dump_path}/#{postgresql_dump_file} -U #{user} -h #{host} --dbname=#{database} -n public 
      EOS
    end

    desc "dump backup 10-12-2014_back.tar"
    task :backup do
      dump
      run "mv #{postgresql_dump_path}/#{postgresql_dump_file} #{current_path}/#{application}_failsafe_#{DateTime.now.to_s}_dump"
    end

    desc "Uploads and restores local database to remote"
    task :sync do
      upload
      unicorn.stop
      restore
      unicorn.start
    end
  end
end
