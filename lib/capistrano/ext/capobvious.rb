#$:.unshift(File.expand_path('./lib', ENV['rvm_path']))
require "rvm/capistrano"

Capistrano::Configuration.instance.load do
  rvmrc = "rvm use #{rvm_ruby_string}"
  set :rvm_type, :user

  default_run_options[:pty] = true
  ssh_options[:forward_agent] = true

  set :rails_env, "production" unless exists?(:rails_env)
  set :branch, "master" unless exists?(:branch)
  set :deploy_to, "/home/#{user}/www/#{application}" unless exists?(:deploy_to)
  set :deploy_via, :remote_cache unless exists?(:deploy_via)
  set :keep_releases, 5 unless exists?(:keep_releases)
  set :use_sudo, false unless exists?(:use_sudo)
  set :scm, :git unless exists?(:scm)


  set :unicorn_init, "unicorn_#{application}"

  run_local_psql = if `uname -a`.include?("Darwin")
    "psql -h localhost -U postgres"
  else
    "#{sudo} -u postgres psql"
  end

  database_yml_path = "config/database.yml"

  serv_path = "#{current_path}/#{database_yml_path}"
  if capture("if [ -f #{serv_path} ]; then echo '1'; fi") == '1'
    database_yml = capture("cat #{serv_path}")
  else
    database_yml = File.open(database_yml_path)
  end
  config = YAML::load(database_yml)
  adapter = config[rails_env]["adapter"]
  database = config[rails_env]["database"]
  db_username = config[rails_env]["username"]
  db_password = config[rails_env]["password"]


  config = YAML::load(File.open(database_yml_path))
  local_rails_env = 'development'
  local_adapter = config[local_rails_env]["adapter"]
  local_database = config[local_rails_env]["database"]
  local_db_username = config[local_rails_env]["username"]
  local_db_password = config[local_rails_env]["password"]



  set :local_folder_path, "tmp/backup"
  set :timestamp, Time.new.to_i.to_s
  set :db_archive_ext, "tar.bz2"
  set :arch_extract, "tar -xvjf"
  set :arch_create, "tar -cjf"

  set :db_file_name, "#{database}-#{timestamp}.sql"
  set :sys_file_name, "#{application}-system-#{timestamp}.#{db_archive_ext}"
  set :del_backup, true



  #after "deploy:symlink", "auto:run"
  #after "deploy:setup", "db:create", "nginx:conf", "install:p7zip"

# load 'deploy/assets'

  after 'deploy:update_code', 'bundle:install'

  
  if !exists?(:assets) || fetch(:assets) == true
    after 'deploy:update_code', 'assets:precompile'
    before 'deploy:finalize_update', 'assets:symlink'
  end
  before "deploy:restart", "auto:run"

  namespace :assets do
    desc "Local Assets precompile"
    task :local_precompile do
      system("bundle exec rake assets:precompile && cd public && tar czf assets.tar.gz assets/")
      upload("public/assets.tar.gz","#{current_path}/public/assets.tar.gz")
      system("rm public/assets.tar.gz && rm -rf tmp/assets && mv public/assets tmp/assets")
      run("cd #{current_path}/public && rm -rf assets/ && tar xzf assets.tar.gz && rm assets.tar.gz")
    end
    desc "Assets precompile"
    task :precompile, :roles => :web, :except => { :no_release => true } do
      run("cd #{latest_release} && bundle exec rake RAILS_ENV=#{rails_env} assets:precompile")
    end
    task :symlink, :roles => :web, :except => { :no_release => true } do
      run <<-CMD
        rm -rf #{latest_release}/public/assets &&
        mkdir -p #{latest_release}/public &&
        mkdir -p #{shared_path}/assets &&
        ln -s #{shared_path}/assets #{latest_release}/public/assets
      CMD
    end
  end

  after "deploy:update_code", "create:dbconf"
  namespace :create do
    task :files do
      create.rvmrc
    end
    desc "Create .rvmrc & files"
    task :rvmrc do
      put rvmrc, "#{current_path}/.rvmrc"
    end
    task :dbconf do
      serv_path = (exists?(:dbconf) && fetch(:dbconf)) || "#{database_yml_path}.server"
      if File.exist?(serv_path)
        run "cd #{latest_release} && cp -v #{serv_path} #{database_yml_path}"
      end
    end
  end
  namespace :bundle do
    desc "Run bundle install"
    task :install do
      deployment = "--deployment --quiet"
      without = ['development','test','production']-[rails_env]
      run "cd #{latest_release} && bundle install --without #{without.join(" ")}"
    end
  end

  namespace :auto do
    task :run do
#      bundle.install
#      if exists?(:assets) && fetch(:assets) == true
#        assets.precompile
#      end
      create.files
      if exists?(:sphinx) && fetch(:sphinx) == true
        sphinx.symlink
      end
      if exists?(:auto_migrate) && fetch(:auto_migrate) == true
        db.migrate
      end
    end
    task :prepare do
      db.create
      nginx.conf
      install.p7zip
    end
  end


  namespace :db do
    task :create do
      if adapter == "postgresql"
        run "echo \"create user #{db_username} with password '#{db_password}';\" | #{sudo} -u postgres psql"
        run "echo \"create database #{database} owner #{db_username};\" | #{sudo} -u postgres psql"
      else
        puts "Cannot create, adapter #{adapter} is not implemented yet"
      end
    end
    task :seed do
      run "cd #{current_path} && bundle exec rake RAILS_ENV=#{rails_env} db:seed"
    end
    task :reset do
      run "cd #{current_path} && bundle exec rake RAILS_ENV=#{rails_env} db:reset"
    end
    task :hard_reset
      run "cd #{current_path} && bundle exec rake RAILS_ENV=#{rails_env} db:migrate VERSION=0 && bundle exec rake RAILS_ENV=#{rails_env} db:migrate && bundle exec rake RAILS_ENV=#{rails_env} db:seed"
    end

    task :migrate do
      run "cd #{current_path} && bundle exec rake RAILS_ENV=#{rails_env} db:migrate"
    end
    task :import do
      file_name = "#{db_file_name}.#{db_archive_ext}"
      file_path = "#{local_folder_path}/#{file_name}"
      system "cd #{local_folder_path} && #{arch_extract} #{file_name}"
      system "echo \"drop database #{local_database}\" | #{run_local_psql}"
      system "echo \"create database #{local_database} owner #{local_db_username};\" | #{run_local_psql}"
      #    system "#{run_local_psql} #{local_database} < #{local_folder_path}/#{db_file_name}"
      puts "ENTER your development password: #{local_db_password}"
      system "#{run_local_psql} -U#{local_db_username} #{local_database} < #{local_folder_path}/#{db_file_name}"
      system "rm #{local_folder_path}/#{db_file_name}"
    end
    task :pg_import do
      backup.db
      db.import
    end
  end

  namespace :import do
    task :sys do
      backup.sys
      system "rm -rfv public/system/"
      system "#{arch_extract} #{local_folder_path}/#{sys_file_name} -opublic"
    end
    task :db do
      db.pg_import
    end
  end

  #def prompt_with_default(var, default)
  #  set(var) do
  #    Capistrano::CLI.ui.ask “#{var} [#{default}] : ”
  #  end
  #  set var, default if eval(“#{var.to_s}.empty?”)
  #end

  namespace :restore do
    task :sys do
      result = {}
      i = 0
      Dir.foreach(local_folder_path) do |d|
        regexp = Regexp.new("\d+?(\.#{archive_ext})")
        if d.include?(sys_file_name.gsub(regexp,""))
          result[i.to_s] = d
          i+=1
        end
      end
      result.each{|key,value| puts "#{key} - #{value} ##{Time.at(value.scan(/\d+/).first.to_i)} #{File.size(local_folder_path+'/'+value)}"}
      puts "WARNING: IT WILL OVERWRITE public/system FOLDER!"
      select = Capistrano::CLI.ui.ask "select : "
      file = result[select]
      unless file.nil?
        puts "You selected #{file}"
        upload("#{local_folder_path}/#{file}","#{shared_path}/#{file}")
        run "rm -rfv #{shared_path}/system/*"
        run "#{arch_extract} #{shared_path}/#{file} -o#{shared_path}"
        run "chmod -R o=rX #{shared_path}/system"
        run "rm -v #{shared_path}/#{file}"
      end
    end
  end

  # PRIKHA-TASK
  desc "Run custom task usage: cap rake TASK=patch:project_category"
  task :rake do
    if ENV.has_key?('TASK')
      p "running rake task: #{ENV['TASK']}"
      run "cd #{current_path} && bundle exec rake RAILS_ENV=#{rails_env} #{ENV['TASK']}"
    else
      puts 'Please specify correct task: cap rake TASK= some_task'
    end
  end

  namespace :backup do
    desc "Backup a database"
    task :db do
      file_name = fetch(:db_file_name)
      archive_ext = fetch(:db_archive_ext)
      dump_file_path = "#{shared_path}/backup/#{file_name}"
      output_file = "#{file_name}.#{archive_ext}"
      output_file_path = "#{dump_file_path}.#{archive_ext}"
      require 'yaml'
      run "mkdir -p #{shared_path}/backup"
      if adapter == "postgresql"
        logger.important("Backup database #{database}", "Backup:db")
        run "export PGPASSWORD=\"#{db_password}\" && pg_dump -U #{db_username} #{database} > #{dump_file_path}"
        run "cd #{shared_path}/backup && #{arch_create} #{output_file} #{file_name} && rm #{dump_file_path}"
      else
        puts "Cannot backup, adapter #{adapter} is not implemented for backup yet"
      end
      system "mkdir -p #{local_folder_path}"
      download_path = "#{local_folder_path}/#{file_name}.#{archive_ext}"
      logger.important("Downloading database to #{download_path}", "Backup:db")
      download(output_file_path, download_path)
      run "rm -v #{output_file_path}" if fetch(:del_backup)
    end
    desc "Backup public/system folder"
    task :sys do
      file_path = "#{shared_path}/backup/#{sys_file_name}"
      logger.important("Backup shared/system folder", "Backup:sys")
      run "#{arch_create} #{file_path} -C #{shared_path} system"
      download_path = "#{local_folder_path}/#{sys_file_name}"
      logger.important("Downloading system to #{download_path}", "Backup:db")
      download(file_path, download_path)
      run "rm -v #{file_path}" if fetch(:del_backup)
    end
    task :all do
      backup.db
      backup.sys
    end
    desc "Clean backup folder"
    task :clean do
      run "rm -rfv #{shared_path}/backup/*"
    end
  end
  if exists?(:backup_db) && fetch(:backup_db) == true
    before "deploy:update", "backup:db"
  end
  if exists?(:backup_sys) && fetch(:backup_sys) == true
    before "deploy:update", "backup:sys"
  end


  namespace :nginx do
    [:stop, :start, :restart, :reload].each do |action|
    desc "#{action.to_s} nginx"
    task action, :roles => :web do
      run "#{sudo} /etc/init.d/nginx #{action.to_s}"
    end
  end

    desc "Add app nginx conf to server"
    task :conf do
  default_nginx_template = <<-EOF
    server {
    listen  80;
    server_name  #{server_name};
    root #{current_path}/public;

#    access_log  #{shared_path}/log/nginx.access_log;# buffer=32k;
#    error_log   #{shared_path}/log/nginx.error_log error;

#    location ~ ^/assets/ {
#      expires 1y;
#      add_header Cache-Control public;
#      add_header ETag "";
#      break;
#    }
    #{exists?(:nginx_add)? fetch(:nginx_add) : ""}

    location ~ ^/(assets)/  {
      root #{current_path}/public;
      gzip_static on; # to serve pre-gzipped version
      expires max;
      add_header Cache-Control public;
    }

    location / {
        try_files  $uri @unicorn;
    }
    location @unicorn {
        proxy_set_header  Client-Ip $remote_addr;
        proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header  Host $host;
        proxy_pass  http://unix:#{shared_path}/pids/unicorn.sock;
    }
    }
      EOF
      if exists?(:server_redirect)
        server_redirect = fetch(:server_redirect)#.split(" ")
      redirect_template = <<-RED
        server {
          server_name #{server_redirect};
          rewrite ^(.*)$ http://#{server_name.split(' ').first}$1 permanent;
        }
        RED
        default_nginx_template += redirect_template
      end

      puts default_nginx_template

      if exists?(:server_name)
        #location = fetch(:template_dir, "config") + '/nginx.conf.erb'
        #template = File.file?(location) ? File.read(location) : default_nginx_template
        config = ERB.new(default_nginx_template)
        #  puts config.result
        put config.result(binding), "#{shared_path}/nginx.conf"
        run "#{sudo} ln -sfv #{shared_path}/nginx.conf /etc/nginx/sites-enabled/#{application}"
      else
        puts "Aborting because :server_name is not setted in deploy.rb"
      end
    end
    desc "Del nginx config"
    task :delconf do
      run "#{sudo} rm -v /etc/nginx/sites-enabled/#{application}"
    end
  end
  after "nginx:conf", "nginx:reload"
  after "nginx:delconf", "nginx:reload"



  namespace :log do
    desc "tail -f production.log"
    task :tail do
      stream("tail -f -n 0 #{current_path}/log/production.log")
    end
  end




  namespace :install do
    desc "Install apt-nyaa"
    task :aptnyaa do
      run "#{sudo} apt-get --assume-yes install wget > /dev/null 2>&1 && cd /usr/bin/ && #{sudo} wget -Nq https://raw.github.com/nyaa/UbuntuScript/master/apt-nyaa && #{sudo} chmod +x apt-nyaa"
    end
    task :p7zip do
      run "#{sudo} apt-get --assume-yes install p7zip-full"
    end
    desc "cap install:shmmax MAX=1024 (MB)"
    task :shmmax do
      if ENV.has_key?('MAX')
        bits = ENV['MAX'].to_i*1024*1024
        puts "setting shmmax to #{bits}"
        run "#{sudo} sysctl -w kernel.shmmax=#{bits}"
        run "echo 'kernel.shmmax=#{bits}' | #{sudo} tee -a /etc/sysctl.conf"
      else
        puts "Please run with MAX="
      end
    end
  end


  namespace :sphinx do
    desc "Rebuild indexes"
    task :rebuild, :roles => :app, :except => {:no_release => true} do
      run "cd #{current_path} && bundle exec rake RAILS_ENV=#{rails_env} ts:rebuild"
    end
    desc "Sphinx start"
    task :start, :roles => :app, :except => {:no_release => true} do
      run "cd #{current_path} && bundle exec rake RAILS_ENV=#{rails_env} ts:start"
    end
    desc "Sphinx stop"
    task :stop, :roles => :app, :except => {:no_release => true} do
      run "cd #{current_path} && bundle exec rake RAILS_ENV=#{rails_env} ts:stop"
    end
    desc "Sphinx configure"
    task :stop, :roles => :app, :except => {:no_release => true} do
      run "cd #{current_path} && bundle exec rake RAILS_ENV=#{rails_env} ts:conf"
    end
    desc "Re-establish symlinks"
    task :symlink do
      if exists?(:sphinx) && fetch(:sphinx) == true
        run "mkdir -pv #{shared_path}/sphinx"
        run "rm -rf #{release_path}/db/sphinx && ln -sfv #{shared_path}/sphinx #{release_path}/db/sphinx"
        run "ln -sfv #{shared_path}/sphinx/#{rails_env}.sphinx.conf #{release_path}/config/#{rails_env}.sphinx.conf"
      else
        puts "sphinx is disabled in config/deploy.rb to enable add line set :sphinx, true"
      end
    end
  end



  # Check if remote file exists
        #
  def remote_file_exists?(full_path)
    'true' ==  capture("if [ -e #{full_path} ]; then echo 'true'; fi").strip
  end
        
  # Check if process is running
  #
  def remote_process_exists?(pid_file)
    capture("ps -p $(cat #{pid_file}) ; true").strip.split("\n").size == 2
  end

  set :unicorn_conf, "#{current_path}/config/unicorn.rb"
  set :unicorn_pid, "#{shared_path}/pids/unicorn.pid"
  namespace :unicorn do
    desc "start unicorn"
    task :start do
      if remote_file_exists?(unicorn_pid)
        if remote_process_exists?(unicorn_pid)
          logger.important("Unicorn is already running!", "Unicorn")
          next
        else
          run "rm #{unicorn_pid}"
        end
      end
      logger.important("Starting...", "Unicorn")
      run "cd #{current_path} && bundle exec unicorn -c #{unicorn_conf} -E #{rails_env} -D"
    end
    desc "stop unicorn"
    #task :stop, :roles => :app, :except => {:no_release => true} do
    task :stop do
      if remote_file_exists?(unicorn_pid)
        if remote_process_exists?(unicorn_pid)
          logger.important("Stopping...", "Unicorn")
          run "if [ -f #{unicorn_pid} ] && [ -e /proc/$(cat #{unicorn_pid}) ]; then kill -QUIT `cat #{unicorn_pid}`; fi"
        else
          run "rm #{unicorn_pid}"
          logger.important("Unicorn is not running.", "Unicorn")
        end
      else
        logger.important("No PIDs found. Check if unicorn is running.", "Unicorn")
      end
    end
    desc "restart unicorn"
    task :restart do
      if remote_file_exists?(unicorn_pid)
        logger.important("Stopping...", "Unicorn")
        run "kill -s USR2 `cat #{unicorn_pid}`"
      else
        logger.important("No PIDs found. Starting Unicorn server...", "Unicorn")
        run "cd #{current_path} && bundle exec unicorn -c #{unicorn_conf} -E #{rails_env} -D"
      end
    end

    task :init do
      template = <<EOF
#! /bin/sh
# File: /etc/init.d/<%= unicorn_init %>
### BEGIN INIT INFO
# Provides:          unicorn
# Required-Start:    $local_fs $remote_fs $network $syslog
# Required-Stop:     $local_fs $remote_fs $network $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: starts the unicorn web server
# Description:       starts unicorn
### END INIT INFO

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
DAEMON=/home/nyaa/.rvm/bin/system_unicorn
DAEMON_OPTS="<%= unicorn_conf %>"
NAME=unicorn_<%= application %>
DESC="Unicorn app for <%= application %>"
PID=<% unicorn_pid %>

case "$1" in
  start)
	echo -n "Starting $DESC: "
	$DAEMON $DAEMON_OPTS
	echo "$NAME."
	;;
  stop)
	echo -n "Stopping $DESC: "
        kill -QUIT `cat $PID`
	echo "$NAME."
	;;
  restart)
	echo -n "Restarting $DESC: "
        kill -QUIT `cat $PID`
	sleep 1
	$DAEMON $DAEMON_OPTS
	echo "$NAME."
	;;
  reload)
        echo -n "Reloading $DESC configuration: "
        kill -HUP `cat $PID`
        echo "$NAME."
        ;;
  *)
	echo "Usage: $NAME {start|stop|restart|reload}" >&2
	exit 1
	;;
esac

exit 0
EOF
      erb = ERB.new(template)
      init = erb.result(binding)
      file_path = "/etc/init.d/#{unicorn_init}"
      put init, "/tmp/#{unicorn_init}"
      run "#{sudo} mv /tmp/#{unicorn_init} #{file_path} && #{sudo} chmod +x #{file_path}"
    end
    task :init_defaults do
      "#{sudo} /usr/sbin/update-rc.d -f #{unicorn_init} defaults"
    end
    task :init_remove do
      "sudo update-rc.d #{unicorn_init} remove"
    end
  end

  namespace :deploy do
    task :restart do
      unicorn.restart
    end
  end


  def file_size(file_path)
    size = run("wc -c #{file_path} | cut -d' ' -f1")
    return size
  end
end
