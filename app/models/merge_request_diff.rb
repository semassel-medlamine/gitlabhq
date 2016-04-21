# == Schema Information
#
# Table name: merge_request_diffs
#
#  id               :integer          not null, primary key
#  state            :string(255)
#  st_commits       :text
#  st_diffs         :text
#  merge_request_id :integer          not null
#  created_at       :datetime
#  updated_at       :datetime
#

class MergeRequestDiff < ActiveRecord::Base
  include Sortable

  # Prevent store of diff if commits amount more then 500
  COMMITS_SAFE_SIZE = 100

  belongs_to :merge_request

  delegate :target_branch, :source_branch, to: :merge_request, prefix: nil

  state_machine :state, initial: :empty do
    state :collected
    state :overflow
    # Deprecated states: these are no longer used but these values may still occur
    # in the database.
    state :timeout
    state :overflow_commits_safe_size
    state :overflow_diff_files_limit
    state :overflow_diff_lines_limit
  end

  serialize :st_commits
  serialize :st_diffs

  after_create :reload_content

  def reload_content
    reload_commits
    reload_diffs
  end

  def size
    real_size.presence || diffs.size
  end

  def diffs(options={})
    if options[:ignore_whitespace_change]
      @diffs_no_whitespace ||= begin
        compare = Gitlab::Git::Compare.new(
          self.repository.raw_repository,
          self.target_branch,
          self.source_sha,
        )
        compare.diffs(options)
      end
    else
      @diffs ||= load_diffs(st_diffs, options)
    end
  end

  def commits
    @commits ||= load_commits(st_commits || [])
  end

  def last_commit
    commits.first
  end

  def first_commit
    commits.last
  end

  def base_commit
    return nil unless self.base_commit_sha

    merge_request.target_project.commit(self.base_commit_sha)
  end

  def last_commit_short_sha
    @last_commit_short_sha ||= last_commit.short_id
  end

  def dump_commits(commits)
    commits.map(&:to_hash)
  end

  def load_commits(array)
    array.map { |hash| Commit.new(Gitlab::Git::Commit.new(hash), merge_request.source_project) }
  end

  def dump_diffs(diffs)
    if diffs.respond_to?(:map)
      diffs.map(&:to_hash)
    end
  end

  def load_diffs(raw, options)
    if raw.respond_to?(:each)
      Gitlab::Git::DiffCollection.new(raw, options)
    else
      Gitlab::Git::DiffCollection.new([])
    end
  end

  # Collect array of Git::Commit objects
  # between target and source branches
  def unmerged_commits
    commits = compare.commits

    if commits.present?
      commits = Commit.decorate(commits, merge_request.source_project).
        sort_by(&:created_at).
        reverse
    end

    commits
  end

  # Reload all commits related to current merge request from repo
  # and save it as array of hashes in st_commits db field
  def reload_commits
    commit_objects = unmerged_commits

    if commit_objects.present?
      self.st_commits = dump_commits(commit_objects)
    end

    save
  end

  # Reload diffs between branches related to current merge request from repo
  # and save it as array of hashes in st_diffs db field
  def reload_diffs
    new_diffs = []

    if commits.size.zero?
      self.state = :empty
    else
      diff_collection = unmerged_diffs

      if diff_collection.overflow?
        # Set our state to 'overflow' to make the #empty? and #collected?
        # methods (generated by StateMachine) return false.
        self.state = :overflow
      end

      self.real_size = diff_collection.real_size

      if diff_collection.any?
        new_diffs = dump_diffs(diff_collection)
        self.state = :collected
      end
    end

    self.st_diffs = new_diffs

    self.base_commit_sha = self.repository.merge_base(self.source_sha, self.target_branch)

    self.save
  end

  # Collect array of Git::Diff objects
  # between target and source branches
  def unmerged_diffs
    compare.diffs(Commit.max_diff_options)
  end

  def repository
    merge_request.target_project.repository
  end

  def source_sha
    source_commit = merge_request.source_project.commit(source_branch)
    source_commit.try(:sha)
  end

  def compare
    @compare ||=
      begin
        # Update ref for merge request
        merge_request.fetch_ref

        Gitlab::Git::Compare.new(
          self.repository.raw_repository,
          self.target_branch,
          self.source_sha
        )
      end
  end
end
