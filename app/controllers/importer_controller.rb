require 'fastercsv'
require 'tempfile'

class ImporterController < ApplicationController
  unloadable
  
  before_filter :find_project

  ISSUE_ATTRS = [:id, :subject, :assigned_to, :fixed_version,
    :author, :description, :category, :priority, :tracker, :status,
    :start_date, :due_date, :done_ratio, :estimated_hours]
  
  def index
  end

  def match
    # params 
    file = params[:file]
    splitter = params[:splitter]
    wrapper = params[:wrapper]
    encoding = params[:encoding]
    
    # save import file
    @original_filename = file.original_filename
    tmpfile = Tempfile.new("redmine_importer")
    if tmpfile
      tmpfile.write(file.read)
      tmpfile.close
      tmpfilename = File.basename(tmpfile.path)
      if !$tmpfiles
        $tmpfiles = Hash.new
      end
      $tmpfiles[tmpfilename] = tmpfile
    else
      flash[:error] = "Cannot save import file."
      return
    end
    
    session[:importer_tmpfile] = tmpfilename
    session[:importer_splitter] = splitter
    session[:importer_wrapper] = wrapper
    session[:importer_encoding] = encoding
    
    # display sample
    sample_count = 5
    i = 0
    @samples = []
    
    FasterCSV.foreach(tmpfile.path, {:headers=>true, :encoding=>encoding, :quote_char=>wrapper, :col_sep=>splitter}) do |row|
      @samples[i] = row
      
      i += 1
      if i >= sample_count
        break
      end
    end # do
    
    if @samples.size > 0
      @headers = @samples[0].headers
    end
    
    # fields
    @attrs = Array.new
    ISSUE_ATTRS.each do |attr|
      @attrs.push([l_has_string?("field_#{attr}".to_sym) ? l("field_#{attr}".to_sym) : attr.to_s.humanize, attr])
    end
    @project.all_issue_custom_fields.each do |cfield|
      @attrs.push([cfield.name, cfield.name])
    end
    @attrs.sort!
     
  end

  def result
    tmpfilename = session[:importer_tmpfile]
    splitter = session[:importer_splitter]
    wrapper = session[:importer_wrapper]
    encoding = session[:importer_encoding]
    
    if tmpfilename
      tmpfile = $tmpfiles[tmpfilename]
      if tmpfile == nil
        flash[:error] = "Missing imported file"
        return
      end
    end
    
    default_tracker = params[:default_tracker]
    update_issue = params[:update_issue]
    unique_field = params[:unique_field]
    journal_field = params[:journal_field]
    update_other_project = params[:update_other_project]
    ignore_non_exist = params[:ignore_non_exist]
    fields_map = params[:fields_map]
    unique_attr = fields_map[unique_field]

    # check params
    if update_issue && unique_attr == nil
      flash[:error] = "Unique field hasn't match an issue's field"
      return
    end
    
    @handle_count = 0
    @update_count = 0
    @skip_count = 0
    @failed_count = 0
    @failed_issues = Hash.new
    @affect_projects_issues = Hash.new
    
    # attrs_map is fields_map's invert
    attrs_map = fields_map.invert
      
    FasterCSV.foreach(tmpfile.path, {:headers=>true, :encoding=>encoding, :quote_char=>wrapper, :col_sep=>splitter}) do |row|

      project = Project.find_by_name(row[attrs_map["project"]])
      tracker = Tracker.find_by_name(row[attrs_map["tracker"]])
      status = IssueStatus.find_by_name(row[attrs_map["status"]])
      author = User.find_by_login(row[attrs_map["author"]])
      priority = Enumeration.find_by_name(row[attrs_map["priority"]])
      category = IssueCategory.find_by_name(row[attrs_map["category"]])
      assigned_to = User.find_by_login(row[attrs_map["assigned_to"]])
      fixed_version = Version.find_by_name(row[attrs_map["fixed_version"]])
  
      # new issue or find exists one
      issue = Issue.new
      journal = nil
      issue.project_id = project != nil ? project.id : @project.id
      issue.tracker_id = tracker != nil ? tracker.id : default_tracker
      issue.author_id = author != nil ? author.id : User.current.id

      if update_issue
        # custom field
        if !ISSUE_ATTRS.include?(unique_attr.to_sym)
          issue.available_custom_fields.each do |cf|
            if cf.name == unique_attr
              unique_attr = "cf_#{cf.id}"
              break
            end
          end 
        end
        
        if unique_attr == "id"
          issues = [Issue.find_by_id(row[unique_field])]
        else
          query = Query.new(:name => "_importer", :project => @project)
          query.add_filter("status_id", "*", [1])
          query.add_filter(unique_attr, "=", [row[unique_field]])

          issues = Issue.find :all, :conditions => query.statement, :limit => 2, :include => [ :assigned_to, :status, :tracker, :project, :priority, :category, :fixed_version ]
        end
        
        if issues.size > 1
          flash[:warning] = "Unique field #{unique_field} has duplicate record"
          @failed_count += 1
          @failed_issues[@handle_count + 1] = row
          break
        else
          if issues.size > 0
            # found issue
            issue = issues.first
            
            # ignore other project's issue or not
            if issue.project_id != @project.id && !update_other_project
              @skip_count += 1
              next              
            end
            
            # ignore closed issue except reopen
            if issue.status.is_closed?
              if status == nil || status.is_closed?
                @skip_count += 1
                next
              end
            end
            
            # init journal
            note = row[journal_field] || ''
            journal = issue.init_journal(author || User.current, 
              note || '')
              
            @update_count += 1
          else
            # ignore none exist issues
            if ignore_non_exist
              @skip_count += 1
              next
            end
          end
        end
      end
      
      # project affect
      if project == nil
        project = Project.find_by_id(issue.project_id)
      end
      @affect_projects_issues.has_key?(project.name) ?
        @affect_projects_issues[project.name] += 1 : @affect_projects_issues[project.name] = 1

      # required attributes
      issue.status_id = status != nil ? status.id : issue.status_id
      issue.priority_id = priority != nil ? priority.id : issue.priority_id
      issue.subject = row[attrs_map["subject"]] || issue.subject
      
      # optional attributes
      issue.description = row[attrs_map["description"]] || issue.description
      issue.category_id = category != nil ? category.id : issue.category_id
      issue.start_date = row[attrs_map["start_date"]] || issue.start_date
      issue.due_date = row[attrs_map["due_date"]] || issue.due_date
      issue.assigned_to_id = assigned_to != nil ? assigned_to.id : issue.assigned_to_id
      issue.fixed_version_id = fixed_version != nil ? fixed_version.id : issue.fixed_version_id
      issue.done_ratio = row[attrs_map["done_ratio"]] || issue.done_ratio
      issue.estimated_hours = row[attrs_map["estimated_hours"]] || issue.estimated_hours

      # custom fields
      issue.custom_field_values = issue.available_custom_fields.inject({}) do |h, c|
        if value = row[attrs_map[c.name]]
          h[c.id] = value
        end
        h
      end

      if (!issue.save)
        # 记录错误
        @failed_count += 1
        @failed_issues[@handle_count + 1] = row
      end
  
      if journal
        journal
      end
      
      @handle_count += 1
    end # do
    
    if @failed_issues.size > 0
      @failed_issues = @failed_issues.sort
      @headers = @failed_issues[0][1].headers
    end
  end

private

  def find_project
    @project = Project.find(params[:project_id])
  end
  
end
