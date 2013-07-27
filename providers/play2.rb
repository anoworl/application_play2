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

include Chef::DSL::IncludeRecipe

action :before_compile do
	include_recipe "play2"
end

action :before_deploy do

	create_initd

	if new_resource.ivy_credentials
		directory "/root/.ivy2" do
			mode 00755
			action :create
		end
		cookbook_file "/root/.ivy2/.credentials" do	
			source new_resource.ivy_credentials
			mode 00755
			action :create
		end
	end

	if new_resource.log_file
		cookbook_file "#{new_resource.shared_path}/logger.xml" do
			source new_resource.log_file
			mode 00644
		end
	end

	if new_resource.application_conf
		cookbook_file "#{new_resource.shared_path}/application.conf" do
			source new_resource.application_conf
			mode 00644
		end
	end

	unless new_resource.restart_command
		new_resource.restart_command do
			run_context.resource_collection.find(:service => new_resource.application.name).run_action(:restart)
		end	
	end
	
end

action :before_migrate do
	unless new_resource.strategy == :dist_remote_file
	 	bash "compilation-#{new_resource.application.name}" do
			cwd new_resource.release_path
			code "play clean stage > compilation.log"
			environment new_resource.environment
		end	
	end 
end

action :before_symlink do
end
action :before_restart do
end
action :after_restart do
end

def create_initd

	opts = ""
	if new_resource.http_port
		opts += "-Dhttp.port=#{new_resource.http_port} "
	end
	if new_resource.https_port
		opts += "-Dhttps.port=#{new_resource.https_port} "
	end
	if new_resource.application_conf
		opts += "-Dconfig.file=#{new_resource.shared_path}/application.conf "	
	end
	if new_resource.log_file
		opts += "-Dlogger.file=#{new_resource.shared_path}/logger.xml "	
	end

	template "/etc/init.d/#{new_resource.application.name}" do
		source new_resource.initd_template || "initd.erb"
		cookbook new_resource.initd_template ? new_resource.cookbook_name.to_s : "application_play2"
	  	owner "root"
    	group "root"
    	mode "0755"
		variables({
			:name => new_resource.application.name,
			:path => new_resource.application.path+"/current",
			:options => opts+new_resource.app_opts,
			:command => new_resource.strategy != :dist_remote_file ? "target/start" : "start"
		})
	end

	service new_resource.application.name do
		supports :status => true, :start => true, :stop => true, :restart => true
		action [ :enable ]
	end
	
end