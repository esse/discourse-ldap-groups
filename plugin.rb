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

    ldap_group_names = Array.new
    ldap.search(:base => base_dn, :filter => filter) do |entry|
      LdapGroups.update_from_ldap_entry entry
      ldap_group_names << entry.cn.first
    end
    orphaned_groups = GroupCustomField.where(name: 'external_id')
                                      .where.not(value: ldap_group_names)
    orphaned_groups.each do |f|
      delete_group f.group
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
    if field and field.group
      group = field.group
    else
      name = UserNameSuggester.suggest(external_name)
      puts "ldap_group: Creating new group '#{name}' for external '#{name}'"

      group = Group.new name: name
      group.visible = false
      group.custom_fields['external_id'] = external_name
      group.save!
    end
    if SiteSetting.ldap_groups_create_categories
      create_category group, external_name
    end

    # Update group members
    group.users = members
    group.save!
  end

  def self.create_category(group, name)
    return if group.custom_fields.has_key? 'category_id'
    
    cat = Category.new name: name, user: Discourse.system_user
    cat.color = SiteSetting.ldap_group_category_color
    if SiteSetting.ldap_group_category_parent_id
      cat.parent_category = 
        Category.find SiteSetting.ldap_group_category_parent_id
    end
    cat.set_permissions(group => :full)
    cat.save!

    category_definition = cat.topics.first
    category_definition.title = "Private Kategorie der Gruppe #{name}"
    category_definition.save!

    post = category_definition.posts.first
    post.revise Discourse.system_user, <<-TEXT.strip_heredoc
      Dies ist die private Kategorie der Mafiasi-Gruppe *#{name}*.
      Nur Mitglieder dieser Gruppe können hier mitlesen und schreiben.
    TEXT
    post.save!

    group.custom_fields['category_id'] = cat.id
    group.save!
  end

  def self.delete_group(group)
    puts "ldap_group: Deleting '#{group.name}'"

    if group.custom_fields.has_key? 'category_id'
      # Hide category but do not delete it, in case it has to be recovered
      cat = Category.find group.custom_fields['category_id']
      cat.set_permissions(:admins => :readonly)
      cat.parent_category = Category.find(
        SiteSetting.ldap_group_deleted_category_parent_id)
      cat.save!
    end
    group.destroy
  end
end

after_initialize do
  module ::LdapGroups
    class UpdateJob < ::Jobs::Scheduled
      every 1.day

      def execute(args)
        return unless SiteSetting.ldap_groups_enabled
        LdapGroups.update_groups!
      end
    end
  end
end
