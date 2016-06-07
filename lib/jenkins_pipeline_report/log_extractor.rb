require_relative "helpers"
require_relative "block_marker"

module JenkinsPipelineReport
  class LogExtractor
    def self.extract(cache, build, run, force: false)
      if force || !run["logExcerpts"] || !run["logExcerpts"]["consoleText"]
        console_text = cache.console_text(build, run)
        if console_text
          run["logExcerpts"] ||= {}
          run["logExcerpts"]["consoleText"] = LogExtractor.new(console_text).extract_logs
        end
      end
    end

    def initialize(console_text)
      @console_text = console_text
      @lines = console_text.lines
    end

    attr_reader :console_text
    attr_reader :lines

    def extract_logs(context: 2)
      blocks = BlockMarker.new
      last_omnibus_step = nil
      last_omnibus_line = nil
      lines.each_with_index do |line,index|
        # omnibus lines in general: keep the first and last (w/o context)
        if line =~ /^\s*\[([^\]]+)\] [A-Z] \| /
          step = $1
          unless step == last_omnibus_step
            # always mark the first line
            blocks.mark(index, index+1)
            # always mark the last omnibus line of the previous omnibus block
            blocks.mark(last_omnibus_line-1, last_omnibus_line) if last_omnibus_line
            last_omnibus_step = step
          end
          last_omnibus_line = index
        # anonymous omnibus lines
        #                I | 2016-06-07T20:28:20+00:00 |
        elsif line =~ /^\s* [A-Z] \| (\d+-\d+-\d+T\d+:\d+:\d+[+-]\d+:\d+) \|/
          last_omnibus_line = index if last_omnibus_step
        end

        # More specific lines
        case line
        when /The --deployment flag requires a/,
             /EACCES/,
             /\bERROR\b/,
             /\bFATAL\b/i,
             /Errno::ECONNRESET/,
             /Permission denied/i,
             /Connection timed out/i,
             /Failed to complete (.*) action:/i,
             #  java stacktrace
             # 	at com.michelin.cio.hudson.plugins.copytoslave.MyFilePath.copyRecursiveTo(MyFilePath.java:147)
             /^\s*at ([a-z_]\w*\.)+[A-Z_]\w*\.[a-z_]\w*\([^\)]*\)\s*$/,
             # ruby stacktrace
             #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/thread_pool.rb:61:in `block (2 levels) in initialize'
             /^\s*(\S+):(\d+):in `([^']*)'/,
             /^\s*Build step '(.+)' (marked build as|changed build result to) failure\s*$/i,
             /^\s*Verification of component '(.+)' failed.\s*$/i,
             /freed prematurely/,
             /Chef Client failed/i,
             /Slave went offline during the build/i,
             /^\s*(\[([^\]]+)\])? (W|E) \|/ # omnibus warning/error line

          blocks.mark(index-context, index+context)

          #       # Chef error
          #       ================================================================================
          #       Error executing action `restart` on resource 'docker_service_manager_upstart[default]'
          #       ================================================================================
          #
          #       Mixlib::ShellOut::CommandTimeout
          #       --------------------------------
          #       service[docker] (/tmp/kitchen/cache/cookbooks/docker/libraries/docker_service_manager_upstart.rb line 36) had an error: Mixlib::ShellOut::CommandTimeout: Command timed out after 600s:
          #       Command exceeded allowed execution time, process terminated
          #       ---- Begin output of /sbin/start docker ----
          #       STDOUT:
          #       STDERR:
          #       ---- End output of /sbin/start docker ----
          #       Ran /sbin/start docker returned
          #
          #       Cookbook Trace:
          #       ---------------
          #       /tmp/kitchen/cache/cookbooks/compat_resource/files/lib/chef_compat/copied_from_chef/chef/provider.rb:123:in `compile_and_converge_action'
          #       /tmp/kitchen/cache/cookbooks/docker/libraries/docker_service_manager_upstart.rb:53:in `block in <class:DockerServiceManagerUpstart>'
          #       /tmp/kitchen/cache/cookbooks/compat_resource/files/lib/chef_compat/copied_from_chef/chef/provider.rb:122:in `instance_eval'
          #       /tmp/kitchen/cache/cookbooks/compat_resource/files/lib/chef_compat/copied_from_chef/chef/provider.rb:122:in `compile_and_converge_action'
          #       /tmp/kitchen/cache/cookbooks/compat_resource/files/lib/chef_compat/copied_from_chef/chef/provider.rb:123:in `compile_and_converge_action'
          #
          #       Resource Declaration:
          #       ---------------------
          #       # In /tmp/kitchen/cache/cookbooks/docker_test/recipes/service_upstart.rb
          #
          #  7: docker_service_manager_upstart 'default' do
          #  8:   host 'unix:///var/run/docker.sock'
          #  9:   action :start
          # 10: end
          # 11:
          #
          #       Compiled Resource:
          #       ------------------
          #       # Declared in /tmp/kitchen/cache/cookbooks/docker_test/recipes/service_upstart.rb:7:in `from_file'
          #
          #       docker_service_manager_upstart("default") do
          #  action [:start]
          #  updated true
          #  updated_by_last_action true
          #  retries 0
          #  retry_delay 2
          #  default_guard_interpreter :default
          #  declared_type :docker_service_manager_upstart
          #  cookbook_name "docker_test"
          #  recipe_name "service_upstart"
          #  host ["unix:///var/run/docker.sock"]
          #  pidfile "/var/run/docker.pid"
          #       end
          #
          #       Platform:
          #       ---------
          #       x86_64-linux
          #
          #
        when /^(\s*)(={10,})\s*$/
          whitespace = $1
          if lines[index+1].start_with?("#{whitespace}Error executing action")
            # The only good way to do this appears to be to skip through sections until we
            # find a line with less whitespace than the first line
            end_index = skip_until(index) { |line| !line.start_with?(whitespace) } - 1
            blocks.mark(index-context, end_index+context)
          end

        # The following shell command exited with status 128:
        #
        #     $ git ls-remote "http://git.savannah.gnu.org/r/config.git" "master*"
        #
        # Output:
        #
        #     (nothing)
        #
        # Error:
        #
        #     fatal: unable to access 'http://git.savannah.gnu.org/r/config.git/': Failed connect to git.savannah.gnu.org:80; Operation now in progress
        #
        when /^\s*The following shell command exited with status \S+:\s*$/i
          # The following shell command exited with status 128:
          #
          end_index = index
          end_index = skip_until(end_index+1) { |line| line.chomp == "" }

          #     $ git ls-remote "http://git.savannah.gnu.org/r/config.git" "master*"
          #
          end_index = skip_until(end_index+1) { |line| line.chomp == "" }

          # Output:
          #
          end_index = skip_until(end_index+1) { |line| line.chomp == "" }

          #     (nothing)
          #
          end_index = skip_until(end_index+1) { |line| line.chomp == "" }

          # Error:
          #
          end_index = skip_until(end_index+1) { |line| line.chomp == "" }

          #     fatal: unable to access 'http://git.savannah.gnu.org/r/config.git/': Failed connect to git.savannah.gnu.org:80; Operation now in progress
          #
          end_index = skip_until(end_index+1) { |line| line.chomp == "" }

          blocks.mark(index-context, end_index+context)

        # success lines (omnibus timing, test timing ...). Don't bother with
        # context; it's not a failure thing.
        when /^\s*\[([^\]]+)\] . \| .*:\s+(\d+(\.\d+)?)s$/,
             /^CHEF-ACCEPTANCE::\[[^\]]+\]\s+\|(.+)\|\s*$/
          blocks.mark(index-1, index+1)

        end
      end

      # mark the last last omnibus line.
      blocks.mark(last_omnibus_line-1, last_omnibus_line+1) if last_omnibus_line

      # Grab the actual blocks
      result = {}
      blocks.each_block do |block|
        result[block.min+1] = lines[block].map { |line| fix_unsightly_characters(line) }.join("")
      end
      result
    end

    def skip_until(index, match=nil, &block)
      while lines[index]
        break if block && block.call(lines[index])
        break if match && !(match === lines[index])
        break unless lines[index+1]
        index += 1
      end
      index
    end

    def fix_unsightly_characters(line)
      line = line.gsub("\r", "")
      line.gsub("\t", "  ")
    end
  end
end