class AssignmentController < ApplicationController
  auto_complete_for :user, :name
  before_filter :authorize

  def copy
    Assignment.record_timestamps = false
    #creating a copy of an assignment; along with the dates and submission directory too
    old_assign = Assignment.find(params[:id])
    new_assign = old_assign.clone
    @user =  ApplicationHelper::get_user_role(session[:user])
    @user = session[:user]
    @user.set_instructor(new_assign)
    new_assign.update_attribute('name','Copy of '+new_assign.name)
    new_assign.update_attribute('created_at',Time.now)
    new_assign.update_attribute('updated_at',Time.now)



    if new_assign.save
      Assignment.record_timestamps = true

      old_assign.assignment_questionnaires.each do |aq|
        AssignmentQuestionnaire.create(
          :assignment_id => new_assign.id,
          :questionnaire_id => aq.questionnaire_id,
          :user_id => session[:user].id,
          :notification_limit => aq.notification_limit,
          :questionnaire_weight => aq.questionnaire_weight
        )
      end

      DueDate.copy(old_assign.id, new_assign.id)
      new_assign.create_node()

      flash[:note] = 'Warning: The submission directory for the copy of this assignment will be the same as the submission directory for the existing assignment, which will allow student submissions to one assignment to overwrite submissions to the other assignment.  If you do not want this to happen, change the submission directory in the new copy of the assignment.'
      redirect_to :action => 'edit', :id => new_assign.id
    else
      flash[:error] = 'The assignment was not able to be copied. Please check the original assignment for missing information.'
      redirect_to :action => 'list', :controller => 'tree_display'
    end
  end

  def new
    #creating new assignment and setting default values using helper functions
    if params[:parent_id]
      @course = Course.find(params[:parent_id])
    end

    @assignment = Assignment.new
    if params[:parent_id]
      @instructor = Instructor.find(@course.instructor_id)
      @path=@instructor.name + '/' + @course.name + '/'
    else
      # @instructor = User.find(self.instructor_id).name
      @path=session[:user].name + '/'
    end

    @wiki_types = WikiType.find(:all)
    @private = params[:private] == true
    #calling the defalut values mathods
    get_limits_and_weights
  end


  # Toggle the access permission for this assignment from public to private, or vice versa
  def toggle_access
    assignment = Assignment.find(params[:id])
    assignment.private = !assignment.private
    assignment.save

    redirect_to :controller => 'tree_display', :action => 'list'
  end

  def create
    # The Assignment Directory field to be filled in is the path relative to the instructor's home directory (named after his user.name)
    # However, when an administrator creates an assignment, (s)he needs to preface the path with the user.name of the instructor whose assignment it is.
    @assignment = Assignment.new(params[:assignment])
    @assignment.submitter_count = 0
    if (@assignment.microtask)
      @assignment.name = "MICROTASK - " + @assignment.name
    end
    @user =  ApplicationHelper::get_user_role(session[:user])
    @user = session[:user]
    @user.set_instructor(@assignment)
    #Calculate the days between submissions
    setDaysBetweenSubmissions

    if @assignment.save
      set_questionnaires
      set_limits_and_weights
      begin
        # Create submission directory for this assignment
        # If assignment is a Wiki Assignment (or has no directory) the helper will not create a path
        FileHelper.create_directory(@assignment)

        # Creating node information for assignment display
        @assignment.create_node()

        #Create and set due dates (Raise error if problem)
        ddset = set_due_dates
        raise ddset if (ddset != "")

        #Alert that there is an assignment with same name (Assignment is still created - this is just a nicety)
        flash[:alert] = "There is already an assignment named \"#{@assignment.name}\". &nbsp;<a style='color: blue;' href='../../assignment/edit/#{@assignment.id}'>Edit assignment</a>" if @assignment.duplicate_name?

        #Notify Assignment created
        flash[:note] = 'Assignment was successfully created.'
        if(@assignment.microtask)
          redirect_to :action => 'create_default_for_microtask', :controller => 'sign_up_sheet' , :id => @assignment.id
        else
          redirect_to :action => 'list', :controller => 'tree_display'
        end

      rescue
        flash[:error] = $!
        prepare_to_edit
        @wiki_types = WikiType.find(:all)
        @private = params[:private] == true
        render :action => 'edit'
      end

    else
      get_limits_and_weights
      @wiki_types = WikiType.find(:all)
      @private = params[:private] == true
      render :action => 'new'
    end
  end

  #---------------------------------------------------------------------------------------------------------------------
  #  SET_DAYS_BETWEEN_SUBMISSIONS  (Helper function for CREATE and UPDATE)
  #   Sets days between submissions for staggered assignments
  #---------------------------------------------------------------------------------------------------------------------
  def setDaysBetweenSubmissions
    @days = (params[:days].nil?) ? 0 : params[:days].to_i
    @weeks = (params[:weeks].nil?) ? 0 : params[:weeks].to_i
    @assignment.days_between_submissions = @days + (@weeks*7)
  end

  #---------------------------------------------------------------------------------------------------------------------
  #  SET_DUE_DATES  (Helper function for CREATE and UPDATE)
  #   Creates and sets review deadlines using a helper function written in DueDate.rb
  #   If :id is not blank - update due date in database, else if :due_at is not blank - create due date in database
  #---------------------------------------------------------------------------------------------------------------------
  def set_due_dates
    error_string = ""
    max_round = 2
    if params[:assignment][:rounds_of_reviews].to_i >= 2

      #Resubmission Deadlines
      @Resubmission_deadline = DeadlineType.find_by_name("resubmission").id
      params[:additional_submit_deadline].keys.each do  |resubmit_duedate_key|
        #resubmissionDeadline = params[:additional_submit_deadline][resubmit_duedate_key]
        setDeadline(params[:additional_submit_deadline][resubmit_duedate_key],
                    "Resubmission", @Resubmission_deadline, max_round, error_string)
        max_round = max_round + 1
      end

      max_round = 2
      #ReReview Deadlines
      @Rereview_deadline = DeadlineType.find_by_name("rereview").id
      params[:additional_review_deadline].keys.each do |rereview_duedate_key|
        #reviewDeadline = params[:additional_review_deadline][rereview_duedate_key]
        setDeadline(params[:additional_review_deadline][rereview_duedate_key],
                        "Rereview", @Rereview_deadline, max_round, error_string)
        max_round = max_round + 1
      end
    end

    #Build array for other deadlines
    rows, cols = 5,2
    param_deadline = Array.new(rows) { Array.new(cols) }
    param_deadline[DeadlineType.find_by_name("submission").id] = [:submission_deadline, 1]
    param_deadline[DeadlineType.find_by_name("review").id] = [:review_deadline,1]
    param_deadline[DeadlineType.find_by_name("drop_topic").id] = [:drop_topic_deadline,0]
    param_deadline[DeadlineType.find_by_name("metareview").id] = [:metareview_deadline, max_round]

    puts param_deadline
    #Update/Create all deadlines
    param_deadline.each_with_index do |type, index|
      if (!type[0].nil?)
        type_name = DeadlineType.find_by_id(index).name.capitalize
        deadline = params["#{type[0]}"]
        #Guard to check if the corresponding deadline is not set at creation
        if(!deadline.nil?)
          setDeadline( deadline, type_name, index, type[1], error_string)
        end
        #if (!params["#{type[0]}"][:id].blank?)
         # dueDateTemp = DueDate.find_by_id(params["#{type[0]}"][:id])
          #dueDateTemp.update_attributes(params["#{type[0]}"])
          #errorString += "Please enter a valid" + type_name + "deadline </br>" if dueDateTemp.errors.length > 0
        #elsif (!params["#{type[0]}"][:due_at].blank?)
        #  dueDate = DueDate::set_duedate(params["#{type[0]}"], index, @assignment.id, max_round )
         # errorString += "Please enter a valid #{type[1]} deadline </br>" if !dueDate
        #end
      end
    end
    error_string
  end

  #Used to set deadlines

  def setDeadline(deadline, deadlineTypeName, deadlineIndex, maxround, errorString)
    if (!deadline[:id].blank?)
      dueDateTemp = DueDate.find_by_id(deadline[:id])
      dueDateTemp.update_attributes(deadline)
      errorString.ref += "Please enter a valid" + deadlineTypeName + "deadline </br>" if dueDateTemp.errors.length > 0
    elsif (!deadline[:due_at].blank?)
      dueDate = DueDate::set_duedate(deadline, deadlineIndex, @assignment.id, maxround )
      errorString.ref += "Please enter a valid #{deadlineTypeName} deadline </br>" if !dueDate
    end
  end

  def edit
    @assignment = Assignment.find(params[:id])
    prepare_to_edit
  end

  def prepare_to_edit
    if !@assignment.days_between_submissions.nil?
      @weeks = @assignment.days_between_submissions/7
      @days = @assignment.days_between_submissions - @weeks*7
    else
      @weeks = 0
      @days = 0
    end

    get_limits_and_weights
    @wiki_types = WikiType.find(:all)
  end

  def define_instructor_notification_limit(assignment_id, questionnaire_id, limit)
    existing = NotificationLimit.find(:first, :conditions => ['user_id = ? and assignment_id = ? and questionnaire_id = ?',session[:user].id,assignment_id,questionnaire_id])
    if existing.nil?
      NotificationLimit.create(:user_id => session[:user].id,
                                :assignment_id => assignment_id,
                                :questionnaire_id => questionnaire_id,
                                :limit => limit)
    else
      existing.limit = limit
      existing.save
    end
  end

  def set_questionnaires
    @assignment.questionnaires = Array.new
    params[:questionnaires].each{
      | key, value |
      if value.to_i > 0 and (q = Questionnaire.find(value))
        @assignment.questionnaires << q
     end
    }
  end

  def get_limits_and_weights
    @limits = Hash.new
    @weights = Hash.new

    if session[:user].role.name == "Teaching Assistant"
      user_id = Ta.get_my_instructor(session[:user]).id
    else
      user_id = session[:user].id
    end

    default = AssignmentQuestionnaire.find_by_user_id_and_assignment_id_and_questionnaire_id(user_id,nil,nil)

    if default.nil?
      default_limit_value = 15
    else
      default_limit_value = default.notification_limit
    end

    @limits[:review]     = default_limit_value
    @limits[:metareview] = default_limit_value
    @limits[:feedback]   = default_limit_value
    @limits[:teammate]   = default_limit_value

    @weights[:review] = 100
    @weights[:metareview] = 0
    @weights[:feedback] = 0
    @weights[:teammate] = 0

    @assignment.questionnaires.each{
      | questionnaire |
      aq = AssignmentQuestionnaire.find_by_assignment_id_and_questionnaire_id(@assignment.id, questionnaire.id)
      @limits[questionnaire.symbol] = aq.notification_limit
      @weights[questionnaire.symbol] = aq.questionnaire_weight
    }
  end

  def set_limits_and_weights
    if session[:user].role.name == "Teaching Assistant"
      user_id = TA.get_my_instructor(session[:user]).id
    else
      user_id = session[:user].id
    end

    default = AssignmentQuestionnaire.find_by_user_id_and_assignment_id_and_questionnaire_id(user_id,nil,nil)

    @assignment.questionnaires.each{
      | questionnaire |
      aq = AssignmentQuestionnaire.find_by_assignment_id_and_questionnaire_id(@assignment.id, questionnaire.id)
      if params[:limits][questionnaire.symbol].length > 0
        aq.update_attribute('notification_limit',params[:limits][questionnaire.symbol])
      else
        aq.update_attribute('notification_limit',default.notification_limit)
      end
      aq.update_attribute('questionnaire_weight',params[:weights][questionnaire.symbol])
      aq.update_attribute('user_id',user_id)
    }
  end

  def update
    #find participants for given course
    puts params
    copyCourseParticipants
    @assignment = Assignment.find(params[:id])

    #get file old location
    oldpath = getFilePath

    #Calculate days between submissions
    setDaysBetweenSubmissions

    # The update call below updates only the assignment table. The due dates must be updated separately.
    if @assignment.update_attributes(params[:assignment])
      if params[:questionnaires] and params[:limits] and params[:weights]
        set_questionnaires
        set_limits_and_weights
      end

    #get file location after updating attributes
     newpath = getFilePath

    #getting rid of E202 changes which was introduced to fix a bug - no longer needed
      if oldpath != nil and newpath != nil
        FileHelper.update_file_location(oldpath,newpath)
      end

      begin
        # Iterate over due_dates, from dueDate[0] to the maximum dueDate
        error_string = set_due_dates
        raise error_string if (error_string != "")

        flash[:notice] = 'Assignment was successfully updated.'

        #Microtask Logic
        if (@assignment.microtask)
          topics = SignUpTopic.find_all_by_assignment_id(@assignment.id)
          #already has sign-up topics associated with it
          if (!topics.nil? && topics.size != 0)
            redirect_to :action => 'show', :id => @assignment
            #has no sign-up topics associated with it
            #i.e. - it has been copied or changed TO microtask
          else
            redirect_to :action => 'create_default_for_microtask', :controller => 'sign_up_sheet' , :id => @assignment.id
          end
        else
          redirect_to :action => 'show', :id => @assignment
        end
      rescue
        flash[:error] = $!
        prepare_to_edit
        render :action => 'edit', :id => @assignment
      end
    else # Simply refresh the page
      @wiki_types = WikiType.find(:all)
      render :action => 'edit'
    end
  end

  #--------------------------------------------------------------------------------------------------------------------
  # COPY_PARTICIPANTS_FROM_COURSE
  #  if assignment and course are given copy the course participants to assignment
  #--------------------------------------------------------------------------------------------------------------------
  def copyCourseParticipants
    if params[:assignment][:course_id]
      begin
        Course.find(params[:assignment][:course_id]).copy_participants(params[:id])
      rescue
        flash[:error] = $!
      end
    end
  end

  #--------------------------------------------------------------------------------------------------------------------
  # GET_PATH (Helper function for CREATE and UPDATE)
  #  return the file location if there is any for the assignment
  #--------------------------------------------------------------------------------------------------------------------
  def getFilePath
    begin
      filePath = @assignment.get_path
    rescue
      filePath = nil
    end
    return filePath
  end


  def show
    @assignment = Assignment.find(params[:id])
  end

  def delete
    assignment = Assignment.find(params[:id])

    # If the assignment is already deleted, go back to the list of assignments
    if assignment
      begin
        @user = session[:user]
        id = @user.get_instructor
        if(id != assignment.instructor_id)
          raise "Not authorised to delete this assignment"
        end
        assignment.delete(params[:force])
        @a = Node.find(:first, :conditions => ['node_object_id = ? and type = ?',params[:id],'AssignmentNode'])

        @a.destroy
        flash[:notice] = "The assignment is deleted"
      rescue
        url_yes = url_for :action => 'delete', :id => params[:id], :force => 1
        url_no  = url_for :action => 'delete', :id => params[:id]
        error = $!
        flash[:error] = error.to_s + " Delete this assignment anyway?&nbsp;<a href='#{url_yes}'>Yes</a>&nbsp;|&nbsp;<a href='#{url_no}'>No</a><BR/>"
      end
    end

    redirect_to :controller => 'tree_display', :action => 'list'
  end

  def list
    set_up_display_options("ASSIGNMENT")
    @assignments=super(Assignment)
    #    @assignment_pages, @assignments = paginate :assignments, :per_page => 10
  end

  def associate_assignment_to_course
    @assignment = Assignment.find(params[:id])
    @user =  ApplicationHelper::get_user_role(session[:user])
    @user = session[:user]
    @courses = @user.set_courses_to_assignment
  end

  def remove_assignment_from_course
    assignment = Assignment.find(params[:id])
    oldpath = assignment.get_path rescue nil
    assignment.course_id = nil
    assignment.save
    newpath = assignment.get_path rescue nil
    FileHelper.update_file_location(oldpath,newpath)
    redirect_to :controller => 'tree_display', :action => 'list'
  end
end
