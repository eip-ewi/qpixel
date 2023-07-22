class PostHistory < ApplicationRecord
  include PostRelated
  belongs_to :post_history_type
  belongs_to :user
  has_many :post_history_tags
  has_many :tags, through: :post_history_tags

  # Unfortunately there is a difference between how MySQL and MariaDB handle JSON fields. MySQL regards JSON as a
  # special data type and stores it in a special format. MariaDB considers JSON as an alias for longtext, which would
  # rely on proper serialization in Rails to parse back into JSON data. To support both, we have this method here.
  attribute(:extra) do |cast_type|
    # rubocop:disable Style/CaseEquality - The original code in ActiveRecord also uses a triple equals
    if cast_type.is_a?(ActiveRecord::Type::Json)
      # Database wants a JSON object, no serialization necessary (MySQL)
      cast_type
    else
      # Database doesn't want JSON, convert it into a string with JSON in it (MariaDB)
      cast_type = cast_type.subtype if ActiveRecord::Type::Serialized === cast_type
      ActiveRecord::Type::Serialized.new(cast_type, ActiveRecord::Coders::JSON)
    end
    # rubocop:enable Style/CaseEquality
  end

  def before_tags
    tags.where(post_history_tags: { relationship: 'before' })
  end

  def after_tags
    tags.where(post_history_tags: { relationship: 'after' })
  end

  # @return [Array] the tags that were removed in this history step
  def tags_removed
    before_tags - after_tags
  end

  # @return [Array] the tags that were added in this history step
  def tags_added
    after_tags - before_tags
  end

  # @return [Boolean] whether this history item was rolled back
  def rolled_back?
    extra.present? && !!extra.fetch('rolled_back_with', nil)
  end

  def self.method_missing(name, *args, **opts)
    unless args.length >= 2
      raise NoMethodError
    end

    object, user = args
    fields = [:before, :after, :comment, :before_title, :after_title, :before_tags, :after_tags, :extra]
    values = fields.to_h { |f| [f, nil] }.merge(opts)

    history_type_name = name.to_s
    history_type = PostHistoryType.find_by(name: history_type_name)
    if history_type.nil?
      super
      return
    end

    params = { post_history_type: history_type, user: user, post: object, community_id: object.community_id }
    { before: :before_state, after: :after_state, comment: :comment, before_title: :before_title,
      after_title: :after_title, extra: :extra }.each do |arg, attr|
      next if values[arg].nil?

      params = params.merge(attr => values[arg])
    end

    history = PostHistory.create params

    post_history_tags = { before_tags: 'before', after_tags: 'after' }.to_h do |arg, rel|
      if values[arg].nil?
        [arg, nil]
      else
        [arg, values[arg].map { |t| { post_history_id: history.id, tag_id: t.id, relationship: rel } }]
      end
    end.values.compact.flatten

    history.post_history_tags = PostHistoryTag.create(post_history_tags)

    history
  end

  def self.respond_to_missing?(method_name, include_private = false)
    PostHistoryType.exists?(name: method_name.to_s) || super
  end

  def can_rollback?
    case post_history_type.name
    when 'post_deleted'
      post.deleted?
    when 'post_undeleted'
      !post.deleted?
    when 'question_closed'
      post.closed?
    when 'question_reopened'
      !post.closed?
    when 'post_edited'
      # Post title must be still what it was after the edit
      (after_title.nil? || after_title == before_title || after_title == post.title) &&
        # Post body must be still the same
        (after_state.nil? || after_state == before_state || after_state == post.body_markdown) &&
        # Post tags that were removed must not have been re-added
        (tags_removed & post.tags == []) &&
        # Post tags that were added must not have been removed
        (tags_added - post.tags == [])
    else
      false
    end
  end
end
