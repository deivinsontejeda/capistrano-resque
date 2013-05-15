require "capistrano"
require "capistrano/version"

module CapistranoResque
  class CapistranoIntegration
    def self.load_into(capistrano_config)
      capistrano_config.load do

        _cset(:workers, {"*" => 1})
        _cset(:resque_kill_signal, "QUIT")
        _cset(:interval, "5")

        def workers_roles
          return workers.keys if workers.first[1].is_a? Hash
          [:resque_worker]
        end

        def for_each_workers(&block)
          if workers.first[1].is_a? Hash
            workers_roles.each do |role|
              yield(role.to_sym, workers[role.to_sym])
            end
          else
            yield(:resque_worker,workers)
          end
        end

        def status_command
          "if [ -e #{current_path}/tmp/pids/resque_work_1.pid ]; then \
            for f in $(ls #{current_path}/tmp/pids/resque_work*.pid); \
              do ps -p $(cat $f) | sed -n 2p ; done \
           ;fi"
        end
        
        def start_command(queue, number_of_workers)
          "cd #{current_path} && RAILS_ENV=#{rails_env} QUEUE=#{queue} " <<
          "COUNT=#{number_of_workers} BACKGROUND=yes VERBOSE=1 INTERVAL=#{interval} " <<
          "#{fetch(:bundle_cmd, "bundle")} exec rake resque:workers "
        end

        def stop_command
          "if [ -e `ls #{current_path}/tmp/pids/resque_worker*.pid | head -1` ]; then " << 
          " for f in `ls #{current_path}/tmp/pids/resque_worker*.pid`; " <<
          "  do #{try_sudo} kill -s #{resque_kill_signal} `cat $f` 2> /dev/null " << 
          "   ; rm $f 2> /dev/null; " << 
          " done; " <<
          " fi " 
        end

        def start_scheduler(pid)
          "cd #{current_path} && RAILS_ENV=#{rails_env} \
           PIDFILE=#{pid} BACKGROUND=yes VERBOSE=1 MUTE=1 \
           #{fetch(:bundle_cmd, "bundle")} exec rake resque:scheduler"
        end

        def stop_scheduler(pid)
          "if [ -e #{pid} ]; then \
            #{try_sudo} kill $(cat #{pid}) ; rm #{pid} \
           ;fi"
        end
        
        def generate_pids
          "cd #{current_path} && ps -e -o pid,command | \ 
          grep [r]esque-[0-9] | \ 
          sed 's/^\s*//g' | \
          cut -d ' ' -f 1 | \
          xargs -L1 -I PID sh -c 'echo PID > #{current_path}/tmp/pids/resque_worker_PID.pid' "
        end

        namespace :resque do
          desc "See current worker status"
          task :status, :roles => lambda { workers_roles() }, :on_no_matching_servers => :continue do
            run(status_command)
          end

          desc "Start Resque workers"
          task :start, :roles => lambda { workers_roles() }, :on_no_matching_servers => :continue do
            for_each_workers do |role, workers|
              workers.each_pair do |queue, number_of_workers|
                logger.info "Starting #{number_of_workers} worker(s) with QUEUE: #{queue}"
                queue_name = queue.gsub(/\s+/, "")
                run(start_command(queue_name, number_of_workers), :roles => role)
              end
              run(generate_pids, role: role)
            end
          end
          

          # See https://github.com/defunkt/resque#signals for a descriptions of signals
          # QUIT - Wait for child to finish processing then exit (graceful)
          # TERM / INT - Immediately kill child then exit (stale or stuck)
          # USR1 - Immediately kill child but don't exit (stale or stuck)
          # USR2 - Don't start to process any new jobs (pause)
          # CONT - Start to process new jobs again after a USR2 (resume)
          desc "Quit running Resque workers"
          task :stop, :roles => lambda { workers_roles() }, :on_no_matching_servers => :continue do
            run(stop_command)
          end

          desc "Restart running Resque workers"
          task :restart, :roles => lambda { workers_roles() }, :on_no_matching_servers => :continue do
            stop
            start
          end

          namespace :scheduler do
            desc "Starts resque scheduler with default configs"
            task :start, :roles => :resque_scheduler do
              pid = "#{current_path}/tmp/pids/scheduler.pid"
              run(start_scheduler(pid))
            end

            desc "Stops resque scheduler"
            task :stop, :roles => :resque_scheduler do
              pid = "#{current_path}/tmp/pids/scheduler.pid"
              run(stop_scheduler(pid))
            end

            task :restart do
              stop
              start
            end
          end
        end
      end
    end
  end
end

if Capistrano::Configuration.instance
  CapistranoResque::CapistranoIntegration.load_into(Capistrano::Configuration.instance)
end
