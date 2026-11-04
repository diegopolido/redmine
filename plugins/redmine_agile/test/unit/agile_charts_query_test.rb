# encoding: utf-8
#
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

require File.expand_path('../../test_helper', __FILE__)

class AgileChartsQueryTest < ActiveSupport::TestCase
  fixtures :projects,
           :users,
           :roles,
           :members,
           :member_roles,
           :issue_statuses,
           :issues,
           :versions,
           :trackers,
           :projects_trackers,
           :issue_categories,
           :enabled_modules,
           :enumerations,
           :attachments,
           :workflows,
           :custom_fields,
           :custom_values,
           :custom_fields_projects,
           :custom_fields_trackers,
           :time_entries,
           :journals,
           :journal_details,
           :queries

  def setup
    RedmineAgile.create_issues
  end

  def test_query_chart_period_statement_with_between
    data = [
      [[(Date.today - 5.days).to_s, (Date.today - 1.days).to_s], [(Date.today - 6.days).to_s, (Date.today - 1.days).to_s]],
      [[(Date.today - 5.days).to_s, Date.today.to_s], [(Date.today - 6.days).to_s, Date.today.to_s]],
      [[(Date.today - 5.days).to_s, (Date.today + 5.days).to_s], [(Date.today - 6.days).to_s, (Date.today + 5.days).to_s]],
      [[Date.today.to_s, (Date.today + 5.days).to_s], [(Date.today - 1.days).to_s, (Date.today + 5.days).to_s]],
      [['',''], [Date.today - 1.days, Date.today]]
    ]

    data.each do |values, result|
      hash = { f: ['chart_period'], op: { 'chart_period' => '><' }, v: { 'chart_period' => values } }
      query = AgileChartsQuery.new(:name => '_').build_from_params(hash)
      assert_equal "issues.chart_period > '#{result[0]} 23:59:59.999999' AND issues.chart_period <= '#{result[1]} 23:59:59.999999'", query.send(:chart_period_statement)
    end
  end

  def test_interval_size_is_chosen_by_period_when_auto
    { 30 => 'day', 91 => 'week', 400 => 'week', 731 => 'month' }.each do |days, interval|
      hash = { f: ['chart_period'], op: { 'chart_period' => '><' }, v: { 'chart_period' => [(Date.today - days + 1).to_s, Date.today.to_s] }, interval_size: '' }
      query = AgileChartsQuery.new(:name => '_').build_from_params(hash)
      assert_nil query.interval_size_option
      assert_equal interval, query.interval_size, "#{days} days"
    end
  end

  def test_explicit_interval_size_wins_over_period
    hash = { f: ['chart_period'], op: { 'chart_period' => '><' }, v: { 'chart_period' => [(Date.today - 400).to_s, Date.today.to_s] }, interval_size: 'day' }
    query = AgileChartsQuery.new(:name => '_').build_from_params(hash)
    assert_equal 'day', query.interval_size_option
    assert_equal 'day', query.interval_size
  end

  def test_cycle_options_are_built_from_params_and_default_empty
    query = AgileChartsQuery.new(name: '_').build_from_params(cycle_statuses: ['', '2', '3'], non_working_days: '1')
    assert_equal [2, 3], query.cycle_statuses
    assert query.non_working_days

    query = AgileChartsQuery.new(name: '_').build_from_params({})
    assert_equal [], query.cycle_statuses
    assert_equal false, query.non_working_days
  end
end
