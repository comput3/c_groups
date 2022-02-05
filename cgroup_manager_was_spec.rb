require 'spec_helper'

describe 'was_role::cgroup_manager_was' do
  platform 'oracle', '7'

  context 'When recipe execution is enabled' do
    it { is_expected.to create_systemd_unit('cgroup_manager_was.service') }
    it { is_expected.to start_systemd_unit('cgroup_manager_was.service') }
    it { is_expected.to enable_systemd_unit('cgroup_manager_was.service') }
    it {
      is_expected.to create_cookbook_file('/usr/local/bin/cgroup_manager_was.sh').with(
        owner: 'root',
        group: 'root',
        mode: '0755',
        backup: false
      )
    }
    it 'converges successfully' do
      expect { chef_run }.to_not raise_error
    end
  end
end
