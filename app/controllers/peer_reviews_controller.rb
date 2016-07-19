class PeerReviewsController < ApplicationController
  include GroupsHelper
  include PeerReviewHelper
  include RandomAssignHelper

  before_action :set_peer_review, only: [:show, :edit, :update, :destroy]

  def index
    @assignment = Assignment.find(params[:assignment_id])
    @section_column = ''
    if Section.all.size > 0
      @section_column = "{
        id: 'section',
        content: '#{t('summaries_index.section')}',
        sortable: true
      },"
    end
  end

  def populate
    @assignment = Assignment.find(params[:assignment_id])

    reviewer_groups = get_groupings_table_info()
    reviewee_groups = get_groupings_table_info(@assignment.parent_assignment)

    reviewee_to_reviewers_map = create_map_reviewee_to_reviewers(reviewer_groups, reviewee_groups)
    id_to_group_names_map = create_map_group_id_to_name(reviewer_groups, reviewee_groups)
    num_reviews_map = create_map_number_of_reviews_for_reviewer(reviewer_groups)

    render json: [reviewer_groups, reviewee_groups, reviewee_to_reviewers_map,
                  id_to_group_names_map, num_reviews_map]
  end

  def assign_groups
    @assignment = Assignment.find(params[:assignment_id])
    selected_reviewer_group_ids = params[:selectedReviewerGroupIds] || []
    selected_reviewee_group_ids = params[:selectedRevieweeGroupIds] || []
    reviewers_to_remove_from_reviewees_map = params[:selectedReviewerInRevieweeGroups] || {}
    action_string = params[:actionString]
    num_groups_for_reviewers = params[:numGroupsToAssign].to_i

    if action_string == 'assign' || action_string == 'random_assign'
      if selected_reviewer_group_ids.empty?
        render text: t('peer_review.empty_list_reviewers'), status: 400
        return
      elsif selected_reviewee_group_ids.empty?
        render text: t('peer_review.empty_list_reviewees'), status: 400
        return
      end
    end

    case action_string
      when 'random_assign'
        begin
          perform_random_assignment(@assignment, num_groups_for_reviewers,
                                    selected_reviewer_group_ids, selected_reviewee_group_ids)
        rescue UnableToRandomlyAssignGroupException
          render text: t('peer_review.random_assign_failure'), status: 400
          return
        end
      when 'assign'
        reviewer_groups = Grouping.where(id: selected_reviewer_group_ids)
        reviewee_groups = Grouping.where(id: selected_reviewee_group_ids)
        begin
          assign(reviewer_groups, reviewee_groups)
        rescue ActiveRecord::RecordInvalid
          render text: t('peer_review.problem'), status: 400
          return
        rescue SubmissionsNotCollectedException
          render text: t('peer_review.submission_nil_failure'), status: 400
          return
        end
      when 'unassign'
        unassign(selected_reviewee_group_ids, reviewers_to_remove_from_reviewees_map)
      else
        render text: t('peer_review.problem'), status: 400
        return
    end

    head :ok
  end

  def assign(reviewer_groups, reviewee_groups)
    reviewer_groups.each do |reviewer_group|
      reviewee_groups.each do |reviewee_group|
        if reviewee_group.current_submission_used.nil?
          raise SubmissionsNotCollectedException
        end
        PeerReview.create_peer_review_between(reviewer_group, reviewee_group)
      end
    end
  end

  def unassign(selected_reviewee_group_ids, reviewers_to_remove_from_reviewees_map)
    # First do specific unassigning.
    reviewers_to_remove_from_reviewees_map.each do |reviewee_id, reviewer_id_to_bool|
      reviewer_id_to_bool.each do |reviewer_id, dummy_value|
        reviewee_group = Grouping.find_by_id(reviewee_id)
        reviewer_group = Grouping.find_by_id(reviewer_id)
        peer_review = reviewer_group.review_for(reviewee_group)
        peer_review.destroy
      end
    end

    selected_reviewee_group_ids.each { |reviewee_id| Grouping.find(reviewee_id).peer_reviews.map(&:destroy) }
  end

  # Create a mapping of reviewer grouping -> set(reviewee groupings)
  def generate_csv_naming_map(peer_reviews)
    naming_map = Hash.new { |h, k| h[k] = Set.new }
    peer_reviews.each do |peer_review|
      naming_map[peer_review.reviewer].add(peer_review.reviewee)
    end
    naming_map
  end

  def download_reviewer_reviewee_mapping
    @assignment = Assignment.find(params[:assignment_id])
    naming_map = generate_csv_naming_map(@assignment.pr_peer_reviews)

    file_out = MarkusCSV.generate(naming_map) do |reviewer, reviewee_set|
      data = reviewee_set.map { |reviewee| reviewee.group.group_name }
      data.unshift(reviewer.group.group_name)
    end

    send_data(file_out, type: 'text/csv', disposition: 'inline',
              filename: 'peer_review_group_to_group_mapping.csv')
  end

  def csv_upload_handler
    assignment_id = params[:assignment_id]
    parent_assignment_id = Assignment.find(assignment_id).parent_assignment.id
    pr_mapping = params[:peer_review_mapping]
    encoding = params[:encoding]

    if params[:peer_review_mapping].nil?
      flash_message(flash[:error], I18n.t('csv.group_to_grader'))
    else
      result = MarkusCSV.parse(pr_mapping.read, encoding: encoding) do |row|
        raise CSVInvalidLineError if row.size < 2
        reviewer = Group.find_by(group_name: row.first).grouping_for_assignment(assignment_id)
        row.shift  # Drop the reviewer, the rest are reviewees and makes iteration easier.
        row.each do |reviewee_group_name|
          reviewee = Group.find_by(group_name: reviewee_group_name).grouping_for_assignment(parent_assignment_id)
          PeerReview.create_peer_review_between(reviewer, reviewee)
        end
      end
      unless result[:invalid_lines].empty?
        flash_message(:error, result[:invalid_lines])
      end
      unless result[:valid_lines].empty?
        flash_message(:success, result[:valid_lines])
      end
    end

    redirect_to action: 'index', assignment_id: assignment_id
  end

  private
  # Use callbacks to share common setup or constraints between actions.
  def set_peer_review
    @peer_review = PeerReview.find(params[:id])
  end

  # Never trust parameters from the scary internet, only allow the white list through.
  def peer_review_params
    params.require(:peer_review).permit(:reviewer_id, :result_id)
  end
end
