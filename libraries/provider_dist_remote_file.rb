#
# Author:: Didier Bathily (<bathily@njin.fr>)
#
# Copyright 2013, njin
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'chef/provider/remote_file'

class Chef
  class Provider
    class DistRemoteFile < Chef::Provider::RemoteFile

      attr_reader :path, :shared_path, :release_path, :previous_release_path

      def load_current_resource
        super
        @release_path = @new_resource.deploy_to + "/releases/" + @new_resource.revision
        chef_gem "rubyzip" do
        end
        require 'zip'
      end

      def action_deploy
        save_release_state
        if deployed?(release_path )
          if current_release?(release_path ) 
            Chef::Log.debug("#{@new_resource} is the latest version")
          else
            rollback_to release_path
          end
        else
          with_rollback_on_error do
            deploy
          end
        end
      end

      def action_force_deploy
        if deployed?(release_path)
          converge_by("delete deployed app at #{release_path} prior to force-deploy") do 
            Chef::Log.info("Already deployed app at #{release_path}, forcing.")
            FileUtils.rm_rf(release_path)
            Chef::Log.info("#{@new_resource} forcing deploy of already deployed app at #{release_path}")
          end
        end
        deploy
      end
      
      def action_rollback
        rollback_to all_releases[-2]
      end

      def deploy
        verify_directories_exist
        action_create
        extract
        enforce_ownership
        FileUtils.rm_rf(@new_resource.path)
        callback(:before_migrate, @new_resource.before_migrate)
        migrate
        callback(:before_symlink, @new_resource.before_symlink)
        symlink
        callback(:before_restart, @new_resource.before_restart)
        restart
        callback(:after_restart, @new_resource.after_restart)
        cleanup!
        Chef::Log.info "#{@new_resource} deployed to #{@new_resource.deploy_to}"
      end

      def extract
        unzip_file @new_resource.path, @new_resource.deploy_to + "/releases/"
        begin
          FileUtils.chmod "+x", "#{release_path}/start"
        rescue
          Chef::Log.warn("There was no 'start' script in #{release_path}. This may not be a problem.")
        end
      end

      def unzip_file (file, destination)
        Zip::File.open(file) { |zip_file|
          zip_file.each { |f|
            unless f.directory?
              f_path=::File.join(destination, f.name)
              FileUtils.mkdir_p(::File.dirname(f_path))
              zip_file.extract(f, f_path) {true}
            end
          }
        }
      end

      def rollback
        Chef::Log.info "#{@new_resource} rolling back to previous release #{release_path}"
        symlink
        Chef::Log.info "#{@new_resource} restarting with previous release"
        restart
      end

      def callback(what, callback_code=nil)
        @collection = Chef::ResourceCollection.new
        case callback_code
        when Proc
          Chef::Log.info "#{@new_resource} running callback #{what}"
          recipe_eval(&callback_code)
        when String
          run_callback_from_file("#{release_path}/#{callback_code}")
        when nil
          run_callback_from_file("#{release_path}/deploy/#{what}.rb")
        end
      end

      def migrate
        run_symlinks_before_migrate

        if @new_resource.migrate
          enforce_ownership

          environment = @new_resource.environment
          env_info = environment && environment.map do |key_and_val|
            "#{key_and_val.first}='#{key_and_val.last}'"
          end.join(" ")

          converge_by("execute migration command #{@new_resource.migration_command}") do
            Chef::Log.info "#{@new_resource} migrating #{@new_resource.user} with environment #{env_info}"
            run_command(run_options(:command => @new_resource.migration_command, :cwd=>release_path, :log_level => :info))
          end
        end
      end

      def symlink
        purge_tempfiles_from_current_release
        link_tempfiles_to_current_release
        link_current_release_to_production
        Chef::Log.info "#{@new_resource} updated symlinks"
      end

      def restart
        if restart_cmd = @new_resource.restart_command
          if restart_cmd.kind_of?(Proc)
            Chef::Log.info("#{@new_resource} restarting app with embedded recipe")
            recipe_eval(&restart_cmd)
          else
            converge_by("restart app using command #{@new_resource.restart_command}") do
              Chef::Log.info("#{@new_resource} restarting app")
              run_command(run_options(:command => @new_resource.restart_command, :cwd => @new_resource.current_path))
            end
          end
        end
      end

      def cleanup!
        chop = -1 - @new_resource.keep_releases
        all_releases[0..chop].each do |old_release|
          converge_by("remove old release #{old_release}") do
            Chef::Log.info "#{@new_resource} removing old release #{old_release}"
            FileUtils.rm_rf(old_release)
          end
          release_deleted(old_release)
        end
      end

      def all_releases
        Dir.glob(@new_resource.deploy_to + "/releases/*").sort
      end

      def enforce_ownership
        converge_by("force ownership of #{@new_resource.deploy_to} to #{@new_resource.group}:#{@new_resource.user}") do
          FileUtils.chown_R(@new_resource.user, @new_resource.group, @new_resource.deploy_to)
          Chef::Log.info("#{@new_resource} set user to #{@new_resource.user}") if @new_resource.user
          Chef::Log.info("#{@new_resource} set group to #{@new_resource.group}") if @new_resource.group
        end
      end

      def verify_directories_exist
        create_dir_unless_exists(@new_resource.deploy_to)
        create_dir_unless_exists(@new_resource.shared_path)
        create_dir_unless_exists(release_path)
      end

      def link_current_release_to_production
        converge_by(["remove existing link at #{@new_resource.current_path}", 
                    "link release #{release_path} into production at #{@new_resource.current_path}"]) do
          FileUtils.rm_f(@new_resource.current_path)
          begin
            FileUtils.ln_sf(release_path, @new_resource.current_path)
            rescue => e
              raise Chef::Exceptions::FileNotFound.new("Cannot symlink current release to production: #{e.message}")
            end
          Chef::Log.info "#{@new_resource} linked release #{release_path} into production at #{@new_resource.current_path}"
        end
        enforce_ownership
      end

      def run_symlinks_before_migrate
        links_info = @new_resource.symlink_before_migrate.map { |src, dst| "#{src} => #{dst}" }.join(", ")
        converge_by("make pre-migration symliinks: #{links_info}") do
          @new_resource.symlink_before_migrate.each do |src, dest|
            begin
              FileUtils.ln_sf(@new_resource.shared_path + "/#{src}", release_path + "/#{dest}")
            rescue => e
              raise Chef::Exceptions::FileNotFound.new("Cannot symlink #{@new_resource.shared_path}/#{src} to #{release_path}/#{dest} before migrate: #{e.message}")
            end
          end
          Chef::Log.info "#{@new_resource} made pre-migration symlinks"
        end
      end

      def link_tempfiles_to_current_release
        dirs_info = @new_resource.create_dirs_before_symlink.join(",")
        @new_resource.create_dirs_before_symlink.each do |dir| 
          create_dir_unless_exists(release_path + "/#{dir}")
        end
        Chef::Log.info("#{@new_resource} created directories before symlinking: #{dirs_info}")

        links_info = @new_resource.symlinks.map { |src, dst| "#{src} => #{dst}" }.join(", ")
        converge_by("link shared paths into current release:  #{links_info}") do
          @new_resource.symlinks.each do |src, dest|
            begin
              FileUtils.ln_sf(::File.join(@new_resource.shared_path, src), ::File.join(release_path, dest))
            rescue => e
              raise Chef::Exceptions::FileNotFound.new("Cannot symlink shared data #{::File.join(@new_resource.shared_path, src)} to #{::File.join(release_path, dest)}: #{e.message}")
            end
          end
          Chef::Log.info("#{@new_resource} linked shared paths into current release: #{links_info}")
        end
        run_symlinks_before_migrate
        enforce_ownership
      end

      def create_dirs_before_symlink
      end

      def purge_tempfiles_from_current_release
        log_info = @new_resource.purge_before_symlink.join(", ")
        converge_by("purge directories in checkout #{log_info}") do
          @new_resource.purge_before_symlink.each { |dir| FileUtils.rm_rf(release_path + "/#{dir}") }
          Chef::Log.info("#{@new_resource} purged directories in checkout #{log_info}")
        end
      end

      protected

      # Internal callback, called after copy_cached_repo.
      # Override if you need to keep state externally.
      # Note that YOU are responsible for implementing whyrun-friendly behavior 
      # in any actions you take in this callback. 
      def release_created(release_path)
      end

      # Note that YOU are responsible for using appropriate whyrun nomenclature
      # Override if you need to keep state externally.
      # Note that YOU are responsible for implementing whyrun-friendly behavior 
      # in any actions you take in this callback. 
      def release_deleted(release_path)
      end

      def release_slug
        raise Chef::Exceptions::Override, "You must override release_slug in #{self.to_s}"
      end

      def run_options(run_opts={})
        run_opts[:user] = @new_resource.user if @new_resource.user
        run_opts[:group] = @new_resource.group if @new_resource.group
        run_opts[:environment] = @new_resource.environment if @new_resource.environment
        run_opts[:log_tag] = @new_resource.to_s
        run_opts[:log_level] ||= :debug
        if run_opts[:log_level] == :info
          if STDOUT.tty? && !Chef::Config[:daemon] && Chef::Log.info?
            run_opts[:live_stream] = STDOUT
          end
        end
        run_opts
      end

      def run_callback_from_file(callback_file)
        Chef::Log.info "#{@new_resource} queueing checkdeploy hook #{callback_file}"
        recipe_eval do
          Dir.chdir(release_path) do
            from_file(callback_file) if ::File.exist?(callback_file)
          end
        end
      end

      def create_dir_unless_exists(dir)
        if ::File.directory?(dir)
          Chef::Log.debug "#{@new_resource} not creating #{dir} because it already exists"
          return false
        end
        converge_by("create new directory #{dir}") do
          begin
            FileUtils.mkdir_p(dir)
            Chef::Log.debug "#{@new_resource} created directory #{dir}"
            if @new_resource.user
              FileUtils.chown(@new_resource.user, nil, dir)
              Chef::Log.debug("#{@new_resource} set user to #{@new_resource.user} for #{dir}")
            end
            if @new_resource.group
              FileUtils.chown(nil, @new_resource.group, dir)
              Chef::Log.debug("#{@new_resource} set group to #{@new_resource.group} for #{dir}")
            end
          rescue => e
            raise Chef::Exceptions::FileNotFound.new("Cannot create directory #{dir}: #{e.message}")
          end
        end
      end

      def with_rollback_on_error
        yield
      rescue ::Exception => e
        if @new_resource.rollback_on_error
          Chef::Log.warn "Error on deploying #{release_path}: #{e.message}" 
          failed_release = release_path
        
          if previous_release_path
            @release_path = previous_release_path
            rollback
          end
          converge_by("remove failed deploy #{failed_release}") do
            Chef::Log.info "Removing failed deploy #{failed_release}"
            FileUtils.rm_rf failed_release
          end
          release_deleted(failed_release)
        end
        
        raise
      end

      def save_release_state
        if ::File.exists?(@new_resource.current_path)
          release = ::File.readlink(@new_resource.current_path)
          @previous_release_path = release if ::File.exists?(release)
        end
      end

      def deployed?(release)
        all_releases.include?(release)
      end

      def current_release?(release)
        @previous_release_path == release
      end
    end
  end
end
