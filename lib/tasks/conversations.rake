namespace :conversations do
  desc "Merge duplicate conversations by guest/channel. Use DRY_RUN=true to preview."
  task deduplicate: :environment do
    dry_run = ENV.key?("DRY_RUN") ? ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN")) : false
    result = Conversations::Deduplicator.new(dry_run: dry_run).call

    puts "DRY_RUN=#{result.dry_run}"
    puts "duplicate_groups=#{result.duplicate_group_count}"
    puts "merged_groups=#{result.merged_groups.size}"
    puts "moved_counts=#{result.moved_counts.to_h}"
    puts "deleted_conversation_ids=#{result.deleted_conversation_ids}"
    puts "possible_duplicate_messages=#{result.possible_duplicate_messages.size}"

    result.merged_groups.each do |group|
      puts group.to_json
    end

    if result.possible_duplicate_messages.any?
      puts "possible_duplicate_message_details=#{result.possible_duplicate_messages.to_json}"
    end
  end

  desc "Add the conversations guest/channel unique index after deduplication."
  task add_unique_index: :environment do
    index_name = Conversations::Deduplicator::INDEX_NAME
    connection = ActiveRecord::Base.connection

    duplicate_groups = Conversations::Deduplicator.new(dry_run: true).duplicate_groups
    if duplicate_groups.any?
      abort "Cannot add #{index_name}: #{duplicate_groups.size} duplicate groups remain. Run bin/rails conversations:deduplicate first."
    end

    unless connection.column_exists?(:conversations, :channel)
      abort "Cannot add #{index_name}: conversations.channel does not exist. Deploy and run migrations first."
    end

    if connection.index_exists?(:conversations, [:guest_id, :channel], name: index_name)
      puts "#{index_name} already exists"
    else
      connection.add_index :conversations, [:guest_id, :channel], unique: true, name: index_name, algorithm: :concurrently
      puts "Added #{index_name}"
    end
  end
end
