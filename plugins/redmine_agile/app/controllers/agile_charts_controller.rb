# This file is a part of Redmin Agile (redmine_agile) plugin,
# Agile board plugin for redmine
#
# Copyright (C) 2011-2026 RedmineUP
# http://www.redmineup.com/
#
# redmine_agile is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# redmine_agile is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with redmine_agile.  If not, see <http://www.gnu.org/licenses/>.

class AgileChartsController < ApplicationController
  menu_item :agile

  before_action :find_optional_version, :only => [:render_chart, :select_version_chart]
  before_action :find_optional_project, :only => [:show, :render_chart, :select_version_chart]

  helper :issues
  helper :journals
  helper :projects
  include ProjectsHelper
  helper :custom_fields
  include CustomFieldsHelper
  helper :issue_relations
  include IssueRelationsHelper
  helper :watchers
  include WatchersHelper
  helper :attachments
  include AttachmentsHelper
  helper :queries
  include QueriesHelper
  helper :repositories
  include RepositoriesHelper
  helper :sort
  include SortHelper
  include IssuesHelper
  helper :timelog
  include RedmineAgile::Helpers::AgileHelper

  def show
    retrieve_charts_query
    @query.date_to ||= Date.today
    @issues = @query.issues
    respond_to do |format|
      format.html
    end
  end

  def render_chart
    if @version
      @issues = @version.visible_fixed_issues
      options = { date_from: @version.start_date,
                  date_to: [@version.due_date,
                            @issues.maximum(:due_date),
                            @issues.maximum(:updated_on)].compact.max,
                  due_date: @version.due_date || @issues.maximum(:due_date) || @issues.maximum(:updated_on),
                  chart_unit: params[:chart_unit] }
      @chart = params[:chart]
    else
      retrieve_charts_query
      @issues = Issue.visible
      @issues = @issues.joins(:fixed_version) if @query.filters.keys.include?('version_status')
      @issues = @issues.where(@query.statement)
      options = { date_from: @query.date_from,
                  date_to: @query.date_to,
                  interval_size: @query.interval_size_option,
                  cycle_statuses: @query.cycle_statuses,
                  non_working_days: @query.non_working_days,
                  chart_unit: @query.chart_unit }
    end
    render_data(options)
  end

  def select_version_chart
  end

  private

  def render_data(options = {})
    agile_chart = RedmineAgile::Charts::Helper::AGILE_CHARTS[@chart]
    chart_class = agile_chart && agile_chart[:class]
    begin
      data = chart_class.data(@issues, options) if chart_class
    rescue RedmineAgile::Charts::AgileChart::InvalidPeriodError
      return render_404
    end

    if data
      data[:chart] = @chart
      data[:chart_unit] = options[:chart_unit]
      data[:summary_html] = render_to_string(partial: 'agile_charts/summary_tiles', formats: [:html], locals: { tiles: data.delete(:summary) || [] })
      return render json: data
    end

    raise ActiveRecord::RecordNotFound
  end

  def find_optional_version
    return unless params[:version_id]
    @version = Version.visible.where(id: params[:version_id]).first
    render_404 unless @version
  end

  def retrieve_charts_query
    if params[:query_id].present?
      @query = AgileChartsQuery.find(params[:query_id])
      raise ::Unauthorized unless @query.visible?
      @query.project = @project
    elsif params[:set_filter] || session[:agile_charts_query].nil? || session[:agile_charts_query][:project_id] != (@project ? @project.id : nil)
      # Give it a name, required to be valid
      @query = AgileChartsQuery.new(:name => '_')
      @query.project = @project
      @query.build_from_params(params)
      session[:agile_charts_query] = { project_id: @query.project_id,
                                       filters: @query.filters,
                                       group_by: @query.group_by,
                                       column_names: @query.column_names,
                                       date_from: @query.date_from,
                                       date_to: @query.date_to,
                                       interval_size: @query.interval_size_option,
                                       cycle_statuses: @query.cycle_statuses,
                                       non_working_days: @query.non_working_days,
                                       chart: @query.chart,
                                       chart_unit: @query.chart_unit }
    else
      # retrieve from session
      @query = AgileChartsQuery.new(name: '_',
                                    filters: session[:agile_charts_query][:filters] || session[:agile_query][:filters],
                                    group_by: session[:agile_charts_query][:group_by],
                                    column_names: session[:agile_charts_query][:column_names],
                                    date_from: session[:agile_charts_query][:date_from],
                                    date_to: session[:agile_charts_query][:date_to],
                                    interval_size: session[:agile_charts_query][:interval_size],
                                    cycle_statuses: session[:agile_charts_query][:cycle_statuses],
                                    non_working_days: session[:agile_charts_query][:non_working_days],
                                    chart: session[:agile_charts_query][:chart],
                                    chart_unit: session[:agile_charts_query][:chart_unit])
      @query.project = @project
    end
    @chart = params[:chart] || @query.chart
  end
end
