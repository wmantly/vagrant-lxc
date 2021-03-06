require 'open3'

module Vagrant
  module LXC
    module Action
      class ForwardPorts
        def initialize(app, env)
          @app    = app
          @logger = Log4r::Logger.new("vagrant::lxc::action::forward_ports")
        end

        def call(env)
          @env = env

          # Get the ports we're forwarding
          env[:forwarded_ports] = compile_forwarded_ports(env[:machine].config)

          if @env[:forwarded_ports].any? and not redir_installed?
            raise Errors::RedirNotInstalled
          end

          # Warn if we're port forwarding to any privileged ports
          env[:forwarded_ports].each do |fp|
            if fp[:host] <= 1024
              env[:ui].warn I18n.t("vagrant.actions.vm.forward_ports.privileged_ports")
              break
            end
          end

          # Continue, we need the VM to be booted in order to grab its IP
          @app.call env

          if @env[:forwarded_ports].any?
            env[:ui].info I18n.t("vagrant.actions.vm.forward_ports.forwarding")
            forward_ports
          end
        end

        def forward_ports
          @env[:forwarded_ports].each do |fp|
            message_attributes = {
              # TODO: Add support for multiple adapters
              :adapter    => 'eth0',
              :guest_port => fp[:guest],
              :host_port  => fp[:host]
            }

            # TODO: Remove adapter from logging
            @env[:ui].info(I18n.t("vagrant.actions.vm.forward_ports.forwarding_entry",
                                  message_attributes))

            redir_pid = redirect_port(
              fp[:host_ip],
              fp[:host],
              fp[:guest_ip] || @env[:machine].provider.ssh_info[:host],
              fp[:guest]
            )
            store_redir_pid(fp[:host], redir_pid)
          end
        end

        private

        def compile_forwarded_ports(config)
          mappings = {}

          config.vm.networks.each do |type, options|
            next if options[:disabled]

            # TODO: Deprecate this behavior of "automagically" skipping ssh forwarded ports
            if type == :forwarded_port && options[:id] != 'ssh'
              if options.fetch(:host_ip, '').to_s.strip.empty?
                options[:host_ip] = '127.0.0.1'
              end
              mappings[options[:host]] = options
            end
          end

          mappings.values
        end

        def redirect_port(host_ip, host_port, guest_ip, guest_port)
          if redir_version >= 3
            params = %W( -n #{host_ip}:#{host_port} #{guest_ip}:#{guest_port} )
          else
            params = %W( --lport=#{host_port} --caddr=#{guest_ip} --cport=#{guest_port} )
            params.unshift "--laddr=#{host_ip}" if host_ip
          end
          params << '--syslog' if ENV['REDIR_LOG']
          if host_port < 1024
            redir_cmd = "sudo redir #{params.join(' ')} 2>/dev/null"
          else
            redir_cmd = "redir #{params.join(' ')} 2>/dev/null"
          end
          @logger.debug "Forwarding port with `#{redir_cmd}`"
          spawn redir_cmd
        end

        def store_redir_pid(host_port, redir_pid)
          data_dir = @env[:machine].data_dir.join('pids')
          data_dir.mkdir unless data_dir.directory?

          data_dir.join("redir_#{host_port}.pid").open('w') do |pid_file|
            pid_file.write(redir_pid)
          end
        end

        def redir_version
          stdout, stderr, _ = Open3.capture3 "redir --version"
          # For some weird reason redir printed version information in STDERR prior to 3.2
          version = stdout.empty? ? stderr : stdout
          version.split('.')[0].to_i
        end

        def redir_installed?
          system "which redir > /dev/null"
        end
      end
    end
  end
end
