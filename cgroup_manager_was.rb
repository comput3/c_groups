# The OS version must be at least RHEL/OL 7
min_os_version = 7
if node['platform_version'].to_i < min_os_version
  Chef::Log.info("Skipping cgroup management since the local node's OS version is below #{min_os_version} (#{node['platform_version']}).")
  return
end

cookbook_file '/usr/local/bin/cgroup_manager_was.sh' do
  source 'cgroup_manager_was.sh'
  owner 'root'
  group 'root'
  mode '0755'
  backup false
  action :create
end

# Create unit
systemd_unit 'cgroup_manager_was.service' do
  content <<~EOF
    [Unit]
    Description=Cgroup Manager WAS Service

    [Service]
    Type=oneshot
    ExecStart=/usr/local/bin/cgroup_manager_was.sh -a

    [Install]
    WantedBy=multi-user.target
  EOF

  action [:create, :enable, :start]
  notifies :restart, 'systemd_unit[cgroup_manager_was.service]', :delayed
end

# Create timer
systemd_unit 'cgroup_manager_was.timer' do
  content <<~EOF
    [Unit]
    Description=Cgroup Manager WAS Scheduled Execution

    [Timer]
    Unit=cgroup_manager_was.service
    OnCalendar=*:0/5

    [Install]
    WantedBy=timers.target
  EOF

  action [:create, :enable, :start]
  notifies :restart, 'systemd_unit[cgroup_manager_was.timer]', :delayed
end
