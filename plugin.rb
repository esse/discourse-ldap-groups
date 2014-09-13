# name: LDAP groups
# about: Synchronize groups with LDAP
# version: 0.1
# authors: Damian Hofmann

gem 'net-ldap', '0.8.0'

module ::LdapGroups
  def self.connect
    Net::LDAP.new :host => SiteSetting.ldap_groups_host,
      :port => SiteSetting.ldap_groups_port,
      :auth => {
        :method => :simple,
        :username => SiteSetting.ldap_groups_user,
        :password => SiteSetting.ldap_groups_password
      }
  end

  def self.update_groups!
    return unless SiteSetting.ldap_groups_enabled

    ldap = LdapGroups.connect

    base_dn = SiteSetting.ldap_groups_base_dn
    filter = Net::LDAP::Filter.eq('objectclass', 'posixGroup')

    ldap.search(:base => base_dn, :filter => filter) do |entry|
      LdapGroups.update_from_ldap_entry entry
    end
  end

  def self.update_from_ldap_entry(entry)
    members = entry.memberuid.collect do |m|
      record = SingleSignOnRecord.find_by external_id: m
      next unless record
      User.find record.user_id
    end
    members.compact! # remove nils from users not in discourse
    return if members.empty?

    # Find existing group or create a new one
    external_name = entry.cn.first
    field = GroupCustomField.find_by(name: 'external_id', 
                                     value: external_name)
    if field
      group = field.group
    else
      group = Group.new name: UserNameSuggester.suggest(external_name)
      group.visible = false
      group.custom_fields['external_id'] = external_name
      Rails.logger.info 
        "ldap_group: Created new group '#{group.name}' for external '#{name}'"
    end

    # Update group members
    group.users = members
    group.save!
  end
end

after_initialize do
  module ::LdapGroups
    class UpdateJob < ::Jobs::Scheduled
      every 1.day

      def execute(args)
        LdapGroups.update_groups!
      end
    end
  end
end
